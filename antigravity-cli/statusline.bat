@echo off
REM Windows batch wrapper for Antigravity statusline script. Needs bash on PATH (Git for Windows).
where bash >nul 2>nul || (echo statusline: bash is not on PATH & exit /b 1)
bash "%~dp0statusline.sh"
