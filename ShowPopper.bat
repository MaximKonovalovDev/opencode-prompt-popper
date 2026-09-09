@echo off
REM Prompt Popper — double-click to pop the button panel. Starts the tray if needed.
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -STA -WindowStyle Hidden -File "%USERPROFILE%\.config\opencode\prompt-popper\prompt-popper.ps1" -Show
) else (
  powershell -NoProfile -STA -WindowStyle Hidden -File "%USERPROFILE%\.config\opencode\prompt-popper\prompt-popper.ps1" -Show
)
