@echo off
rem Troubleshooting launcher: runs the dialer in this console so you can read the output.
rem Double-clicking the desktop shortcut does NOT need this file.
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0dial.ps1" %*
