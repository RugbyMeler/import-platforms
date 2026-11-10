@echo off
rem Starts the GUI. The console is minimised; if the GUI cannot start (for example because the
rem PowerShell execution policy blocks scripts) it stays open with the error so you can read it.
start "Platform Variant Importer" /min cmd /c "powershell.exe -NoProfile -STA -File "%~dp0Start-PlatformImportGui.ps1" || pause"
