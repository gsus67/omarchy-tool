# Omarchy Tool

Plugin para [Omarchy](https://omarchy.org/) con utilidades del sistema que se
activan y desactivan con un interruptor. Añade un icono a la barra que abre un
panel con un módulo por función. El panel usa los componentes y colores del
tema de Omarchy, así que cambia junto con el tema.

## Instalar, actualizar y desinstalar

```bash
omarchy plugin add https://github.com/gsus67/omarchy-tool.git --enable
omarchy plugin update omarchy-tool
omarchy plugin remove omarchy-tool
```

El plugin se actualiza solo: comprueba GitHub al arrancar y cada 6 horas, y si
hay versión nueva se actualiza con `omarchy plugin update` y te avisa con una
notificación.

Tu configuración se guarda en `~/.config/omarchy-tool/config.json`, fuera del
plugin, así que las actualizaciones no la borran.

El plugin añade una entrada **Omarchy Tool** al menú de Omarchy (si tienes
`~/.config/omarchy/extensions/omarchy-menu.jsonc`).

## Sin suciedad

- **Desactivar una función** borra todo lo que esa función escribió en el
  sistema. Solo se recuerda tu elección (por ejemplo, qué discos marcaste).
- **Eliminar el plugin** deja el sistema como estaba: devuelve la app Windows a
  Omarchy y borra el lanzador, la configuración y la entrada del menú. Como
  `omarchy plugin remove` no ejecuta código del plugin, la limpieza la hace una
  copia de `bin/uninstall.sh` guardada fuera del plugin: la lanza el panel al
  descargarse y, si no llegó a hacerlo, el lanzador de Windows la próxima vez.
- `omarchy-tool uninstall` hace esa misma limpieza a mano.

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
omarchy-tool uninstall                       # borra todo rastro fuera del plugin
omarchy-tool self-update                     # actualiza ya si hay versión nueva
omarchy-tool windows-disks enable|disable
omarchy-tool windows-disks add /mnt/datos [Nombre]
omarchy-tool windows-disks remove /mnt/datos
omarchy-tool windows-disks launch [--keep-alive]
```

## Añadir un módulo

1. `bin/modules/<nombre>.sh` con funciones `<nombre>_<acción>`. Debe tener
   `<nombre>_enable`, `<nombre>_disable`, `<nombre>_status` (JSON con
   `enabled`) y `<nombre>_apply`. Al desactivarse, `apply` debe borrar todo lo
   que el módulo escribió; si toca algo fuera de su carpeta, añade su limpieza
   a `bin/uninstall.sh`.
2. `modules/<Nombre>.qml`: la página del módulo. Recibe `status` y llama a
   `tool.run([...])`.
3. Añádelo a la lista `modules` de `ToolPanel.qml`. En la lista del panel sale
   con su nombre y su interruptor.

## Pruebas

```bash
tests/run.sh
omarchy plugin validate .
```
