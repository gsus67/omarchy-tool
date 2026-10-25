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
- **Eliminar el plugin** deja el sistema como estaba: quita los discos de la
  configuración de Windows (pide tu contraseña) y borra la configuración del
  plugin y la entrada del menú. Como `omarchy plugin remove` no ejecuta código
  del plugin, la limpieza la hace una copia de `bin/uninstall.sh` guardada fuera
  del plugin, que el panel lanza al descargarse.
- `omarchy-tool uninstall` hace esa misma limpieza a mano.

## Módulos

### Windows

Comparte discos con la VM de Windows de Omarchy igual que Omarchy
comparte `~/Windows`: como carpetas de red en `\\host.lan` (`Data2` y `Data3`,
junto a la `Data` de Omarchy). En Windows les puedes poner letra con *Conectar
unidad de red*. Marca los discos montados en `/mnt`, `/media` o `/run/media`, o
añade una carpeta por su ruta (también vale `/home`).

**Máximo 2 discos activados a la vez**, porque la imagen de Windows solo sirve
dos carpetas extra (`Data2` y `Data3`). Para usar otro, desmarca uno primero.

Cómo funciona: la imagen `dockurr/windows` que usa Omarchy sirve `/shared2` y
`/shared3` si existen. El plugin añade esas dos líneas a la configuración de la
VM (`/var/lib/omarchy/windows/docker-compose.yml`, de root) con
`bin/compose-shares.sh` vía `pkexec`, así que cada cambio pide tu contraseña y
se ve al volver a abrir Windows. Ese script solo toca esas dos líneas y valida
las rutas. Si reinstalas Windows desde Omarchy, el plugin vuelve a ponerlas.

Al ser carpetas de red, algunos instaladores muy estrictos pueden negarse a
instalar en ellas.

## Línea de comandos

El panel solo llama a `bin/omarchy-tool`, que también se puede usar a mano:

```bash
omarchy-tool status                          # estado de todos los módulos (JSON)
omarchy-tool uninstall                       # borra todo rastro fuera del plugin
omarchy-tool self-update                     # actualiza ya si hay versión nueva
omarchy-tool windows-disks enable|disable
omarchy-tool windows-disks add /mnt/datos [Nombre]
omarchy-tool windows-disks remove /mnt/datos
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
