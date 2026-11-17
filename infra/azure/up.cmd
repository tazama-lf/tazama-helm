@echo off
REM SPDX-License-Identifier: Apache-2.0
REM Windows launcher. Avoids PowerShell execution-policy blocks on up.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0up.ps1" %*
exit /b %ERRORLEVEL%
