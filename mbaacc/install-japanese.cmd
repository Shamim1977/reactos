@echo off
echo Installing Japanese support for Melty Blood (font + code page 932)...
copy /y "%~dp0DroidSansFallback.ttf" "%SystemRoot%\Fonts\"
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" /v "Droid Sans Fallback (TrueType)" /t REG_SZ /d "DroidSansFallback.ttf" /f
for %%F in ("MS Gothic" "MS PGothic" "MS UI Gothic" "MS Mincho" "MS PMincho") do reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes" /v %%F /t REG_SZ /d "Droid Sans Fallback" /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" /v ACP /t REG_SZ /d 932 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" /v OEMCP /t REG_SZ /d 932 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" /v MACCP /t REG_SZ /d 10001 /f
echo.
echo Done. Restart ReactOS for the change to take effect.
pause
