@echo off
setlocal

rem Use the launcher next to this file if it exists (for example a full copy of the repository).
set "WINDIAG_DIR=%~dp0"
if exist "%WINDIAG_DIR%winDiagLauncher.ps1" goto launch

rem Otherwise install to the user's profile so a lone run.cmd in Downloads stays tidy.
set "WINDIAG_DIR=%LOCALAPPDATA%\WinDiag\"
if exist "%WINDIAG_DIR%winDiagLauncher.ps1" goto launch

echo Downloading WinDiag to %WINDIAG_DIR% ...
if not exist "%WINDIAG_DIR%" mkdir "%WINDIAG_DIR%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $target = Join-Path $env:WINDIAG_DIR 'winDiagLauncher.ps1'; $temporary = $target + '.download'; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/SimplyFluke/WinDiag/main/winDiagLauncher.ps1' -OutFile $temporary; Move-Item -LiteralPath $temporary -Destination $target -Force"
if errorlevel 1 (
    echo.
    echo Could not download the WinDiag launcher. Check the internet connection and try again.
    pause
    exit /b 1
)

:launch
start "" powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -STA -File "%WINDIAG_DIR%winDiagLauncher.ps1"
exit /b
