@echo off
"%SystemRoot%\System32\chcp.com" 65001 >nul
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%~dp0fix.ps1" (
    echo.
    echo  Не найден fix.ps1 — распакуй архив целиком в одну папку
    echo.
    pause
    exit /b 1
)

"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if errorlevel 1 goto elevate

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix.ps1"
rem окно не должно закрыться раньше, чем человек прочитает ошибку PowerShell
if errorlevel 1 pause
exit /b

:elevate
rem окно уже перезапускалось с запросом прав, а прав всё равно нет: повторный перезапуск зациклился бы
if /i "%~1"=="elevated" goto noadmin
rem путь передаётся через переменную окружения: апостроф в пути сломал бы строку команды
rem двойные кавычки вокруг аргументов cmd /c сохраняют путь с & целым
set "SELF=%~f0"
"%PS%" -NoProfile -Command "$q = [char]34; try { Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') -ArgumentList ('/c ' + $q + $q + $env:SELF + $q + ' elevated' + $q) -Verb RunAs -ErrorAction Stop } catch { Write-Host ' Нужны права администратора, ничего не изменено' -ForegroundColor Red; $null = Read-Host ' Нажми Enter, чтобы закрыть окно' }"
exit /b

:noadmin
echo.
echo  Нужны права администратора, ничего не изменено
echo.
pause
exit /b 1
