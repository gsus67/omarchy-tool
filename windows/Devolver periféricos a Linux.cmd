@echo off
rem Omarchy Tool: asks Linux to take back every peripheral Windows has, the
rem same as SUPER+ALT+U. Linux notices within a few seconds.
type nul > "%~dp0.devolver-usb"
powershell -NoProfile -Command "if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'es') { Write-Host 'Pedido enviado a Linux.'; Write-Host 'Escribe tu contrasena cuando Linux la pida y tus perifericos volveran.' } else { Write-Host 'Request sent to Linux.'; Write-Host 'Enter your password when Linux asks and your peripherals will return.' }"
timeout /t 8
