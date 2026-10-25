@echo off
rem Omarchy Tool: asks Linux to take back every peripheral Windows has, the
rem same as SUPER+ALT+U. Linux notices within a few seconds.
type nul > "%~dp0.devolver-usb"
echo Pedido enviado a Linux.
echo Escribe tu contrasena cuando Linux la pida y tus perifericos volveran.
timeout /t 8
