Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$BaseDir = Join-Path $env:ProgramData 'GowEdayEliasGutpuncherFix'
$SessionRoot = Join-Path $BaseDir 'sessions'
$ActiveFile = Join-Path $BaseDir 'active.json'
$StoreName = 'Root'
$StoreLocation = 'LocalMachine'
$StoreRegistryKey = 'HKLM\SOFTWARE\Microsoft\SystemCertificates\Root'
$GostOidPrefix = '1.2.643.'
$KeepSessions = 3
$MutexName = 'Global\GowEdayEliasGutpuncherFix'

$SystemSid = 'S-1-5-18'
$AdministratorsSid = 'S-1-5-32-544'
$SessionIdPattern = '^\d{8}-\d{6}-[a-f0-9]{32}$'
$RegExe = Join-Path ([Environment]::SystemDirectory) 'reg.exe'
$RegistryBackupName = 'root-store-before.reg'
$ManifestName = 'manifest.json'
$ReadyMessage = "Готово, можно запускать игру`nОкно можно закрыть. После игры снова запусти start и выбери 2"

function Open-Store([Security.Cryptography.X509Certificates.OpenFlags]$Flags) {
    $store = [Security.Cryptography.X509Certificates.X509Store]::new($StoreName, $StoreLocation)
    $store.Open($Flags)

    return $store
}

function Test-GostCert([Security.Cryptography.X509Certificates.X509Certificate2]$Cert) {
    return [string]$Cert.PublicKey.Oid.Value -like "$GostOidPrefix*"
}

function Get-StoreCerts {
    $store = Open-Store 'ReadOnly'
    try {
        return @($store.Certificates)
    } finally {
        $store.Close()
    }
}

function Get-StoreGostCerts {
    return @(Get-StoreCerts | Where-Object { Test-GostCert $_ })
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256([string]$Path) {
    return Get-BytesSha256 ([IO.File]::ReadAllBytes($Path))
}

# Пишет файл сразу на диск, чтобы после выключения питания он не остался пустым
function Write-BytesDurable([string]$Path, [byte[]]$Bytes) {
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

# reg.exe пишет через кэш: без сброса после выключения питания файл может остаться пустым, и проверка копии не пройдёт
function Sync-FileToDisk([string]$Path) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Save-JsonDurable([object]$Value, [string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        throw "Файл уже существует: $Path"
    }
    $json = $Value | ConvertTo-Json -Depth 8
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        Write-BytesDurable $tmp ([Text.UTF8Encoding]::new($false).GetBytes($json))
        [IO.File]::Move($tmp, $Path)
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force
        }
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Нужны права администратора, ничего не изменено'
    }
}

function Assert-NotReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Папка $Path является ссылкой, работа остановлена, ничего не изменено"
    }
}

function Assert-TrustedOwner([string]$Path) {
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $AdministratorsSid -and $owner -ne $SystemSid) {
        throw "У папки $Path чужой владелец, работа остановлена, ничего не изменено"
    }
}

# Доступ только у администраторов и SYSTEM, чтобы обычный пользователь не мог подменить копию
function New-BaseDirSecurity {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($AdministratorsSid))
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    @($SystemSid, $AdministratorsSid) | ForEach-Object {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($_),
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }

    return $acl
}

function Protect-BaseDir {
    [IO.Directory]::SetAccessControl($BaseDir, (New-BaseDirSecurity))
}

# Папка создаётся сразу с правами: иначе до их установки обычный пользователь успел бы создать в ней свои файлы
function New-BaseDir {
    $null = [IO.Directory]::CreateDirectory($BaseDir, (New-BaseDirSecurity))
}

function Initialize-BaseDir {
    if (Test-Path -LiteralPath $BaseDir) {
        Assert-NotReparsePoint $BaseDir
        Assert-TrustedOwner $BaseDir
    } else {
        New-BaseDir
    }
    Protect-BaseDir
    if (-not (Test-Path -LiteralPath $SessionRoot)) {
        New-Item -ItemType Directory -Path $SessionRoot | Out-Null
    }
    Assert-NotReparsePoint $SessionRoot
}

function Read-SessionFile([object]$Session, [string]$Name) {
    $path = Join-Path $Session.Dir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    # запятая не даёт PowerShell развернуть массив байтов в поток отдельных значений
    return , [IO.File]::ReadAllBytes($path)
}

function Get-DamagedCopyMessage([string]$Detail) {
    return "Копия повреждена или изменена, ничего не импортировано: $Detail"
}

# Читает сертификат из копии и проверяет его по манифесту; проверка идёт по тем же байтам, что потом импортируются
function Read-VerifiedCert([object]$Session, [object]$Entry) {
    $thumb = [string]$Entry.Thumbprint
    if ($thumb -notmatch '^[A-F0-9]{40}$' -or [string]$Entry.Sha256 -notmatch '^[A-F0-9]{64}$') {
        throw (Get-DamagedCopyMessage "неверная запись в манифесте $thumb")
    }
    $bytes = Read-SessionFile $Session "$thumb.sercert"
    if ($null -eq $bytes) {
        throw (Get-DamagedCopyMessage "нет файла $thumb")
    }
    if ((Get-BytesSha256 $bytes) -ne $Entry.Sha256) {
        throw (Get-DamagedCopyMessage $thumb)
    }
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
    if ($cert.Thumbprint -ne $thumb -or -not (Test-GostCert $cert)) {
        throw (Get-DamagedCopyMessage $thumb)
    }

    return $cert
}

function Assert-SessionIntact([object]$Session) {
    $entries = @($Session.Entries)
    $unique = @($entries | ForEach-Object { $_.Thumbprint } | Select-Object -Unique)
    if ($entries.Count -eq 0 -or $unique.Count -ne $entries.Count) {
        throw (Get-DamagedCopyMessage 'неверный список сертификатов')
    }
    $entries | ForEach-Object { $null = Read-VerifiedCert $Session $_ }
    $registry = Read-SessionFile $Session $RegistryBackupName
    if ($null -eq $registry -or (Get-BytesSha256 $registry) -ne $Session.RegistrySha256) {
        throw (Get-DamagedCopyMessage 'копия реестра')
    }
}

# Возвращает сессию или $null, если копия не законченная (нет целого манифеста)
function Read-Session([string]$Dir) {
    $id = Split-Path -Path $Dir -Leaf
    $manifestPath = Join-Path $Dir $ManifestName
    if ($id -notmatch $SessionIdPattern -or -not (Test-Path -LiteralPath $manifestPath)) {
        return $null
    }
    try {
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $certs = @($manifest.Certificates)
        if ($manifest.Version -ne 1 -or $manifest.SessionId -ne $id -or $certs.Count -ne [int]$manifest.Count) {
            return $null
        }
        $entries = @($certs | ForEach-Object {
                [pscustomobject]@{ Thumbprint = [string]$_.Thumbprint; Sha256 = [string]$_.Sha256 }
            })
        $createdAt = [datetime]::ParseExact($id.Substring(0, 15), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)

        return [pscustomobject]@{
            Id             = $id
            Dir            = $Dir
            CreatedAt      = $createdAt
            Entries        = $entries
            RegistrySha256 = [string]$manifest.RegistrySha256
        }
    } catch {
        return $null
    }
}

function New-Session([Security.Cryptography.X509Certificates.X509Certificate2[]]$Certs) {
    $id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
    $dir = Join-Path $SessionRoot $id
    New-Item -ItemType Directory -Path $dir | Out-Null

    $registryPath = Join-Path $dir $RegistryBackupName
    & $RegExe export $StoreRegistryKey $registryPath /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $registryPath)) {
        throw 'Не удалось сохранить копию реестра, ничего не изменено'
    }
    Sync-FileToDisk $registryPath

    # один сертификат может лежать в нескольких физических хранилищах Root (например, ещё и в групповой политике)
    $unique = @($Certs | Group-Object Thumbprint | ForEach-Object { $_.Group[0] })
    $entries = @($unique | ForEach-Object {
            $thumb = $_.Thumbprint.ToUpperInvariant()
            $bytes = $_.Export([Security.Cryptography.X509Certificates.X509ContentType]::SerializedCert)
            Write-BytesDurable (Join-Path $dir "$thumb.sercert") $bytes
            [pscustomobject]@{ Thumbprint = $thumb; Sha256 = Get-BytesSha256 $bytes }
        })
    $manifest = [ordered]@{
        Version        = 1
        SessionId      = $id
        Count          = $entries.Count
        RegistrySha256 = Get-FileSha256 $registryPath
        Certificates   = $entries
    }
    # манифест пишется последним: сессия без него считается незаконченной
    Save-JsonDurable $manifest (Join-Path $dir $ManifestName)

    $session = Read-Session $dir
    if ($null -eq $session) {
        throw 'Не удалось записать копию, ничего не изменено'
    }
    Assert-SessionIntact $session

    return $session
}

function Get-SessionDirs {
    if (-not (Test-Path -LiteralPath $SessionRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $SessionRoot -Directory | Where-Object { $_.Name -match $SessionIdPattern })
}

function Get-CompleteSessions {
    return @(Get-SessionDirs |
            Sort-Object Name -Descending |
            ForEach-Object { Read-Session $_.FullName } |
            Where-Object { $null -ne $_ })
}

function Read-ActiveMarker {
    if (-not (Test-Path -LiteralPath $ActiveFile)) {
        return [pscustomobject]@{ Status = 'None'; SessionId = $null }
    }
    $damaged = [pscustomobject]@{ Status = 'Damaged'; SessionId = $null }
    try {
        $marker = [IO.File]::ReadAllText($ActiveFile) | ConvertFrom-Json
        if ($null -eq $marker -or $marker.Version -ne 1 -or [string]$marker.SessionId -notmatch $SessionIdPattern) {
            return $damaged
        }
        $id = [string]$marker.SessionId
        if ($null -eq (Read-Session (Join-Path $SessionRoot $id))) {
            # метка цела, а её копия не читается: подставлять вместо неё другую копию нельзя
            return [pscustomobject]@{ Status = 'Broken'; SessionId = $id }
        }

        return [pscustomobject]@{ Status = 'Valid'; SessionId = $id }
    } catch {
        return $damaged
    }
}

function Save-ActiveMarker([object]$Session) {
    Save-JsonDurable ([ordered]@{ Version = 1; SessionId = $Session.Id }) $ActiveFile
}

function Remove-ActiveMarker {
    if (Test-Path -LiteralPath $ActiveFile) {
        Remove-Item -LiteralPath $ActiveFile -Force
    }
}

# Незаконченную копию можно удалить, только если по ней ничего не удаляли: манифеста нет и все её сертификаты на месте
function Test-AbandonedCopy([string]$Dir, [hashtable]$Present) {
    if (Test-Path -LiteralPath (Join-Path $Dir $ManifestName)) {
        return $false
    }
    $removed = @(Get-ChildItem -LiteralPath $Dir -Filter '*.sercert' -File |
            Where-Object { -not $Present.ContainsKey($_.BaseName) })

    return $removed.Count -eq 0
}

# Удаляет незаконченные копии и лишние законченные; активную не трогает никогда
# Возвращает число папок, которые не удалось удалить: сбой очистки не должен мешать восстановлению
function Remove-OldSessions {
    $marker = Read-ActiveMarker
    if ($marker.Status -in @('Damaged', 'Broken')) {
        return 0
    }
    $keep = @{}
    if ($null -ne $marker.SessionId) {
        $keep[$marker.SessionId] = $true
    }
    $sessions = @(Get-CompleteSessions)
    $complete = @{}
    $sessions | ForEach-Object { $complete[$_.Id] = $true }
    $sessions | Select-Object -First $KeepSessions | ForEach-Object { $keep[$_.Id] = $true }
    $present = Get-ThumbprintSet (Get-StoreCerts)
    $failed = @(Get-SessionDirs |
            Where-Object { -not $keep.ContainsKey($_.Name) } |
            ForEach-Object {
                $dir = $_
                try {
                    if ($complete.ContainsKey($dir.Name) -or (Test-AbandonedCopy $dir.FullName $present)) {
                        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
                    }
                } catch {
                    $dir.Name
                }
            })

    return $failed.Count
}

function Get-ThumbprintSet([object[]]$Items) {
    $set = @{}
    $Items | Where-Object { $null -ne $_ } | ForEach-Object { $set[[string]$_.Thumbprint] = $true }

    return $set
}

function Get-MissingEntries([object]$Session, [hashtable]$Present) {
    return @($Session.Entries | Where-Object { -not $Present.ContainsKey($_.Thumbprint) })
}

function Get-PresentEntries([object]$Session) {
    $present = Get-ThumbprintSet (Get-StoreCerts)

    return @($Session.Entries | Where-Object { $present.ContainsKey($_.Thumbprint) })
}

function Get-State {
    $storeCerts = @(Get-StoreCerts)
    $present = Get-ThumbprintSet $storeCerts
    $storeGost = @($storeCerts | Where-Object { Test-GostCert $_ })
    $marker = Read-ActiveMarker
    $session = $null
    if ($marker.Status -eq 'Valid') {
        $session = Read-Session (Join-Path $SessionRoot $marker.SessionId)
    }
    if ($marker.Status -eq 'Damaged') {
        # метка не читается — берём последнюю целую копию
        $session = Get-CompleteSessions | Select-Object -First 1
    }
    $state = [pscustomobject]@{
        Kind           = 'NoGost'
        Session        = $session
        MarkerDamaged  = $marker.Status -eq 'Damaged'
        Total          = 0
        Present        = 0
        NewGostCount   = 0
        StoreGostCount = $storeGost.Count
        Orphan         = $null
        CleanupFailed  = $false
    }

    if ($marker.Status -eq 'Broken') {
        $state.Kind = 'Broken'

        return $state
    }
    if ($null -ne $session) {
        $inCopy = Get-ThumbprintSet $session.Entries
        $state.Total = @($session.Entries).Count
        $state.Present = $state.Total - @(Get-MissingEntries $session $present).Count
        $state.NewGostCount = @($storeGost | Where-Object { -not $inCopy.ContainsKey($_.Thumbprint) }).Count
        $state.Kind = 'Interrupted'
        if ($state.Present -eq 0) {
            $state.Kind = 'Removed'
        }

        return $state
    }

    if ($storeGost.Count -gt 0) {
        $state.Kind = 'Installed'
    }
    # сессии нет, но в последней копии есть сертификаты, которых нет в хранилище (например, метку удалили вручную)
    $latest = Get-CompleteSessions | Select-Object -First 1
    if ($null -ne $latest -and @(Get-MissingEntries $latest $present).Count -gt 0) {
        $state.Orphan = $latest
    }

    return $state
}

function Remove-StoreCert([string]$Thumbprint) {
    $store = Open-Store 'ReadWrite'
    try {
        $store.Certificates.Find('FindByThumbprint', $Thumbprint, $false) | ForEach-Object { $store.Remove($_) }
    } finally {
        $store.Close()
    }
}

function Add-StoreCert([Security.Cryptography.X509Certificates.X509Certificate2]$Cert) {
    $store = Open-Store 'ReadWrite'
    try {
        $store.Add($Cert)
    } finally {
        $store.Close()
    }
}

# Сначала проверяет всю копию, потом возвращает только недостающие сертификаты
function Restore-FromSession([object]$Session) {
    Assert-SessionIntact $Session
    $missing = @(Get-MissingEntries $Session (Get-ThumbprintSet (Get-StoreCerts)))
    $missing | ForEach-Object { Add-StoreCert (Read-VerifiedCert $Session $_) }
    $notRestored = @(Get-MissingEntries $Session (Get-ThumbprintSet (Get-StoreCerts)))
    if ($notRestored.Count -gt 0) {
        throw "Восстановление не завершено: $($notRestored[0].Thumbprint)"
    }

    return $missing.Count
}

function Get-RestoredMessage([object]$Session) {
    $total = @($Session.Entries).Count

    return "Восстановлено и проверено: $total из $total"
}

function Remove-SessionCerts([object]$Session) {
    $Session.Entries | ForEach-Object { Remove-StoreCert $_.Thumbprint }
}

function Undo-Removal([object]$Session) {
    $null = Restore-FromSession $Session
    Remove-ActiveMarker
}

function Invoke-FreshRemoval([object]$State) {
    if ($State.MarkerDamaged) {
        Remove-ActiveMarker
    }
    $session = New-Session @(Get-StoreGostCerts)
    # метка пишется до удаления: если ПК выключится посередине, копия найдётся
    Save-ActiveMarker $session
    try {
        Remove-SessionCerts $session
        if (@(Get-StoreGostCerts).Count -eq 0) {
            return $ReadyMessage
        }
        Undo-Removal $session

        return 'Сертификаты вернулись, отменено'
    } catch {
        $reason = $_.Exception.Message
        try {
            Undo-Removal $session
        } catch {
            return "ОШИБКА ОТКАТА: $($_.Exception.Message). Не удаляй папку $BaseDir, запусти скрипт ещё раз и выбери 2"
        }

        return "Ошибка при удалении, сертификаты возвращены: $reason"
    }
}

function Invoke-ContinueRemoval([object]$Session) {
    Remove-SessionCerts $Session
    $left = @(Get-PresentEntries $Session).Count
    if ($left -gt 0) {
        return "Не удалось удалить сертификаты ($left шт.), выбери 2, чтобы вернуть все"
    }

    return $ReadyMessage
}

function Invoke-Remove([object]$State) {
    switch ($State.Kind) {
        'NoGost' {
            return 'Удалять нечего'
        }
        'Removed' {
            return 'Уже удалены, можно играть'
        }
        'Broken' {
            return 'Копия повреждена или изменена, удаление отключено'
        }
        'Interrupted' {
            return Invoke-ContinueRemoval $State.Session
        }
        default {
            return Invoke-FreshRemoval $State
        }
    }
}

function Invoke-Restore([object]$State, [scriptblock]$Confirm) {
    if ($State.Kind -eq 'Broken') {
        return Get-DamagedCopyMessage 'не читается список сертификатов'
    }
    if ($null -ne $State.Session) {
        $null = Restore-FromSession $State.Session
        Remove-ActiveMarker

        return Get-RestoredMessage $State.Session
    }
    if ($null -eq $State.Orphan) {
        return 'Восстанавливать нечего'
    }
    if (-not (& $Confirm)) {
        return 'Отменено'
    }
    $null = Restore-FromSession $State.Orphan

    return Get-RestoredMessage $State.Orphan
}

function New-ScreenLine([string]$Text, [string]$Color, [string]$Background = '') {
    return [pscustomobject]@{ Text = $Text; Color = $Color; Background = $Background }
}

function Write-ScreenLine([object]$Line) {
    $colors = @{ ForegroundColor = $Line.Color }
    if ($Line.Background) {
        $colors.BackgroundColor = $Line.Background
    }
    # отступ печатается отдельно, чтобы фон не захватывал его
    Write-Host ' ' -NoNewline
    Write-Host $Line.Text @colors
}

function Format-SessionDate([object]$Session) {
    return $Session.CreatedAt.ToString('dd.MM.yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-KindLines([object]$State) {
    switch ($State.Kind) {
        'Installed' {
            return New-ScreenLine "Состояние: ГОСТ-сертификаты установлены ($($State.StoreGostCount) шт.)" 'Green'
        }
        'Removed' {
            $date = Format-SessionDate $State.Session

            return @(
                New-ScreenLine "Состояние: ГОСТ-сертификаты УДАЛЕНЫ ($($State.Total) шт., с $date)" 'Yellow'
                New-ScreenLine '' 'Gray'
                New-ScreenLine 'ЭЦП и госсервисы сейчас не работают — после игры верни сертификаты (пункт 2)' 'White' 'DarkRed'
            )
        }
        'Interrupted' {
            return @(
                New-ScreenLine "Состояние: операция прервана, в хранилище $($State.Present) из $($State.Total) сертификатов" 'Red'
                New-ScreenLine 'Выбери 2, чтобы вернуть все, или 1, чтобы удалить оставшиеся' 'Red'
            )
        }
        'Broken' {
            return @(
                New-ScreenLine 'Состояние: копия сертификатов повреждена или изменена, восстановить из неё нельзя' 'Red'
                New-ScreenLine "Не удаляй папку $BaseDir и создай обращение в Issues на GitHub" 'Red'
            )
        }
    }
    if ($null -ne $State.Orphan) {
        return @()
    }

    return New-ScreenLine 'Состояние: ГОСТ-сертификатов нет, этот фикс тебе не нужен' 'Yellow'
}

function Get-StatusLines([object]$State) {
    $lines = @(Get-KindLines $State)
    if ($State.MarkerDamaged -and $null -ne $State.Session) {
        $lines += New-ScreenLine 'Файл сессии был повреждён, используется последняя целая копия' 'Yellow'
    }
    if ($State.MarkerDamaged -and $null -eq $State.Session) {
        $lines += New-ScreenLine "Файл сессии повреждён, а целой копии нет. Не удаляй папку $BaseDir" 'Red'
    }
    if ($State.NewGostCount -gt 0) {
        $lines += New-ScreenLine "Появились новые ГОСТ-сертификаты ($($State.NewGostCount)) — если игра снова выдаёт ошибку, выбери 2, затем 1" 'Yellow'
    }
    if ($null -ne $State.Orphan) {
        $missing = @(Get-MissingEntries $State.Orphan (Get-ThumbprintSet (Get-StoreCerts))).Count
        $lines += New-ScreenLine "Найдена копия от $(Format-SessionDate $State.Orphan), в хранилище нет $missing сертификатов из неё" 'Yellow'
        $lines += New-ScreenLine 'Выбери 2, чтобы вернуть их' 'Yellow'
    }
    if ($State.CleanupFailed) {
        $lines += New-ScreenLine 'Не удалось удалить старую копию, попробую при следующем запуске' 'Gray'
    }

    return $lines
}

function ConvertTo-MenuChoice([string]$Text) {
    $choice = $Text.Trim()
    if ($choice -notin @('0', '1', '2')) {
        return -1
    }

    return [int]$choice
}

function Get-MessageColor([string]$Message) {
    if ($Message -match '^(Готово|Восстановлено)') {
        return 'Green'
    }
    if ($Message -match '^(Ошибка|Не удалось|Копия)') {
        return 'Red'
    }

    return 'Yellow'
}

function Wait-Enter {
    $null = Read-Host ' Нажми Enter, чтобы закрыть окно'
}

function Confirm-Restore {
    $answer = [string](Read-Host ' Вернуть сертификаты из этой копии? (да/нет)')

    return $answer.Trim().ToLowerInvariant() -in @('да', 'д', 'y', 'yes')
}

function Invoke-MenuAction([int]$Choice, [object]$State) {
    try {
        $message = switch ($Choice) {
            1 {
                Invoke-Remove $State
            }
            2 {
                Invoke-Restore $State { Confirm-Restore }
            }
            default {
                'Нет такого пункта. Введи цифру действия (0-2) и нажми Enter'
            }
        }

        return New-ScreenLine $message (Get-MessageColor $message)
    } catch {
        return New-ScreenLine "ОШИБКА: $($_.Exception.Message)" 'Red'
    }
}

function Show-Screen([object]$State, [object]$Result) {
    Clear-Host
    Write-Host ''
    Write-Host ' Gears of War E-Day — elias-gutpuncher fix'
    Write-Host ''
    Get-StatusLines $State | ForEach-Object { Write-ScreenLine $_ }
    Write-Host ''
    Write-Host ' Список действий:'
    Write-Host ''
    Write-Host ' 1. Удалить сертификаты для игры'
    Write-Host ' 2. Восстановить сертификаты'
    Write-Host ''
    Write-Host ' 0. Выход'
    Write-Host ''
    Write-Host ''
    if ($null -ne $Result) {
        $Result.Text -split "`n" | ForEach-Object { Write-ScreenLine (New-ScreenLine $_ $Result.Color) }
        Write-Host ''
    }
}

function Show-MenuLoop {
    $result = $null
    while ($true) {
        $cleanupFailed = (Remove-OldSessions) -gt 0
        $state = Get-State
        $state.CleanupFailed = $cleanupFailed
        Show-Screen $state $result
        $choice = ConvertTo-MenuChoice (Read-Host ' Введи цифру действия (0-2) и нажми Enter')
        if ($choice -eq 0) {
            return
        }
        $result = Invoke-MenuAction $choice $state
    }
}

function Start-Menu {
    try {
        Assert-Administrator
    } catch {
        Write-Host " $($_.Exception.Message)" -ForegroundColor Red
        Wait-Enter

        return
    }
    $mutex = $null
    $owned = $false
    try {
        $mutex = [Threading.Mutex]::new($false, $MutexName)
        try {
            $owned = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            # прошлое окно закрыли, не отпустив mutex — он теперь наш
            $owned = $true
        }
        if (-not $owned) {
            Write-Host ' Скрипт уже запущен в другом окне' -ForegroundColor Yellow
            Wait-Enter

            return
        }
        Initialize-BaseDir
        Show-MenuLoop
    } catch {
        Write-Host " ОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
        Wait-Enter
    } finally {
        if ($owned) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

Start-Menu
