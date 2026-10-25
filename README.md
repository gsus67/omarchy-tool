# Omarchy Tool

Plugin para [Omarchy](https://omarchy.org/) con utilidades del sistema que se
activan y desactivan con un interruptor. Añade un icono a la barra que abre un
panel con un módulo por función. El panel usa los componentes y colores del
tema de Omarchy, así que cambia junto con el tema.

## Instalar, actualizar y desinstalar

```bash
omarchy plugin add https://github.com/gsus67/omarchy-tool.git --enable
omarchy plugin update gsus.tool
omarchy plugin remove gsus.tool
```

Tu configuración se guarda en `~/.config/omarchy-tool/config.json`, fuera del
plugin, así que las actualizaciones no la borran.

## Módulos

### Windows · discos

Con el interruptor activado, la VM de Windows de Omarchy (la app **Windows**)
se abre con los discos que marques como unidades dentro de Windows (en *Este
equipo*). Puedes marcar los discos montados en `/mnt`, `/media` o `/run/media`
o añadir cualquier carpeta por su ruta. Un disco desconectado se omite.

Cómo funciona: `omarchy-windows-vm launch` sigue arrancando y conectando la VM.
El plugin solo antepone a su `PATH` un `xfreerdp3` que añade un `/drive:` por
cada disco. Mientras está activado, la entrada `windows-vm.desktop` apunta a un
lanzador en `~/.local/share/omarchy-tool/`. Si quitas el plugin, ese lanzador
vuelve al comando de Omarchy, así que la app Windows nunca se rompe. Al
desactivarlo, la entrada vuelve a quedar como estaba.

## Línea de comandos

El panel solo llama a `bin/omarchy-tool`, que también se puede usar a mano:

```bash
omarchy-tool status                          # estado de todos los módulos (JSON)
omarchy-tool windows-disks enable|disable
omarchy-tool windows-disks add /mnt/datos [Nombre]
omarchy-tool windows-disks remove /mnt/datos
omarchy-tool windows-disks launch [--keep-alive]
```

## Añadir un módulo

1. `bin/modules/<nombre>.sh` con funciones `<nombre>_<acción>`, y de forma
   opcional `<nombre>_status` (JSON para el panel) y `<nombre>_apply`.
2. `modules/<Nombre>.qml`, que recibe `status` y llama a `tool.run([...])`.
3. Añádelo a la lista `modules` de `ToolPanel.qml`.

## Pruebas

```bash
tests/run.sh
omarchy plugin validate .
```
