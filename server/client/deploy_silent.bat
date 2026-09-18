@echo off
REM Despliegue silencioso para Microsoft Intune / GPO / SCCM
REM Requiere privilegios de Administrador
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1" %*
exit /b %errorlevel%
