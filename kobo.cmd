@echo off
where py >nul 2>nul
if not errorlevel 1 goto use_py
python "%~dp0kobo.py" %*
goto done
:use_py
py -3 "%~dp0kobo.py" %*
:done
exit /b %errorlevel%
