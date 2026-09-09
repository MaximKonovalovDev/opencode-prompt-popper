@echo off
REM Opencode Prompt Popper starter. Double-click to run. No window stays open.
where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "" /min pwsh -NoProfile -STA -WindowStyle Hidden -File "%~dp0prompt-popper.ps1"
) else (
  start "" /min powershell -NoProfile -STA -WindowStyle Hidden -File "%~dp0prompt-popper.ps1"
)
