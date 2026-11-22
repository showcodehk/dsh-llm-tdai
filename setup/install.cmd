@echo off
rem Install the dsh-llm-tdai plugin into a DSH profile.
rem
rem   curl -fsSL https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.cmd -o install.cmd && install.cmd
rem
rem This file is a thin wrapper: it downloads install.ps1 and runs it, so the
rem install logic lives in exactly one place and does not drift between shells.
rem
rem Environment variables:
rem   DSH_PROFILE         profile to install into            (default: desktop)
rem   DSH_BIN             path to dsh.cmd                    (default: auto-detect)
rem   DSH_LLM_TDAI_URL    download URL for the tarball       (default: latest release)
rem   DSH_LLM_TDAI_PKG    local tarball, skips the download  (for offline installs)
rem   DSH_LLM_TDAI_PS1    override the install.ps1 URL       (for mirrors)

setlocal EnableExtensions

set "OWNER=showcodehk"
set "REPO=dsh-llm-tdai"
set "REF=main"

if defined DSH_LLM_TDAI_PS1 (
  set "PS1_URL=%DSH_LLM_TDAI_PS1%"
) else (
  set "PS1_URL=https://raw.githubusercontent.com/%OWNER%/%REPO%/%REF%/setup/install.ps1"
)

set "CURL_OPTS=-fsSL"
if "%DSH_LLM_TDAI_INSECURE%"=="1" set "CURL_OPTS=%CURL_OPTS% -k"

set "WORK=%TEMP%\dsh-llm-tdai-%RANDOM%-%RANDOM%"
mkdir "%WORK%" 2>nul

echo Fetching installer...
curl.exe %CURL_OPTS% "%PS1_URL%" -o "%WORK%\install.ps1" 2>nul
if exist "%WORK%\install.ps1" goto :run

rem curl.exe ships with Windows 10 1803 and later; fall back just in case.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri '%PS1_URL%' -OutFile '%WORK%\install.ps1' -UseBasicParsing } catch { exit 1 }" 2>nul
if not exist "%WORK%\install.ps1" goto :fail

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORK%\install.ps1"
set "RC=%ERRORLEVEL%"
rmdir /s /q "%WORK%" 2>nul
if not "%RC%"=="0" goto :fail
endlocal & exit /b 0

:fail
rmdir /s /q "%WORK%" 2>nul
echo.
echo Installation failed. Read the message above.
endlocal & exit /b 1
