# Omarchy Tool

[English](README.md) · **Español**

Plugin para [Omarchy](https://omarchy.org/) con utilidades del sistema que se
activan y desactivan con un interruptor. Añade un icono a la barra que abre un
panel con un módulo por función. El panel usa los componentes y colores del
tema de Omarchy, así que cambia junto con el tema.

El panel, sus módulos, estados y avisos siguen automáticamente el idioma del sistema (`LC_ALL`, `LC_MESSAGES`, `LANG`). Incluye inglés y español; otros idiomas usan inglés como respaldo. Los nombres de discos y periféricos se conservan. Los mensajes de los auxiliares dentro de Windows siguen el idioma de interfaz de Windows; sus nombres de archivo y rutas se mantienen para conservar los accesos existentes.

## Instalar, actualizar y desinstalar

```bash
omarchy plugin add https://github.com/gsus67/omarchy-tool.git --enable
omarchy plugin update io.github.gsus67.omarchy-tool
omarchy plugin remove io.github.gsus67.omarchy-tool
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

### Discos en Windows

Comparte discos con la VM de Windows de Omarchy igual que Omarchy
comparte `~/Windows`: como carpetas de red en `\\host.lan` (`Data2` y `Data3`,
junto a la `Data` de Omarchy). En Windows les puedes poner letra con *Conectar
unidad de red*. Marca los discos montados en `/mnt`, `/media` o `/run/media`, o
añade una carpeta por su ruta (también vale `/home`).

**Máximo 2 discos activados a la vez**, porque la imagen de Windows solo sirve
dos carpetas extra (`Data2` y `Data3`). Para usar otro, desmarca uno primero.

**Letras:** Omarchy pone `Z:` a su carpeta Shared una sola vez, al instalar
Windows. Para tus discos eliges la letra en el panel (por defecto `X:` e `Y:`)
y el plugin deja en Shared › **Omarchy Tool › Discos** el archivo **Activar discos**,
que hace lo mismo que hizo Omarchy (`net use X: \\host.lan\Data2
/persistent:yes` y un acceso en el escritorio), y además pone a cada unidad el nombre del disco en *Este equipo* (por ejemplo "Datos (X:)"). Se abre una vez dentro de
Windows; si cambias letras o discos, se vuelve a abrir. **Quitar discos** lo
deshace y, si el plugin está apagado o eliminado, se borra a sí mismo.

Cómo funciona: la imagen `dockurr/windows` que usa Omarchy sirve `/shared2` y
`/shared3` si existen. El plugin añade esas dos líneas a la configuración de la
VM (`/var/lib/omarchy/windows/docker-compose.yml`, de root) con
`bin/compose-edit.sh` vía `pkexec`, así que cada cambio pide tu contraseña y
se ve al volver a abrir Windows. Ese script solo toca esas dos líneas y valida
las rutas. Si reinstalas Windows desde Omarchy, el plugin vuelve a ponerlas.

Al ser carpetas de red, algunos instaladores muy estrictos pueden negarse a
instalar en ellas.

### Periféricos en Windows

Pasa dispositivos USB a la VM de Windows de Omarchy para usar apps que solo
existen en Windows (por ejemplo **Glorious CORE** con un ratón Glorious Model
O 2). Windows los ve como si estuvieran enchufados a él; **mientras estén en
Windows, Linux no los tiene** (un USB solo puede estar en un sistema a la vez).
Máximo 4 dispositivos.

- **El interruptor de la función** prepara Windows: la VM recibe acceso a los
  USB (`/dev/bus/usb` en `devices`, como documenta `dockurr/windows`), escrito
  por el mismo `bin/compose-edit.sh` que los discos con `pkexec`. Se nota la
  próxima vez que abras Windows.
- **El interruptor de cada dispositivo** significa "en Windows": con Windows
  abierto pasa al momento, y si no, en cuanto lo abras (el panel lo vigila con
  `bin/usb-watch.sh`). Apagado, vuelve a Linux al momento. Usa el monitor de
  QEMU de la VM (`bin/usb-live.sh`, con `pkexec`).
- **Sin ratón:** **SUPER + ALT + U** devuelve todo a Linux y apaga esos
  interruptores, aunque la ventana de Windows tenga el teclado (atajo con
  `dont_inhibit`, en `~/.config/hypr/omarchy-tool.lua`, que `hyprland.lua` carga
  con una línea protegida). Dentro de Windows, **Shared › Omarchy Tool ›
  Periféricos › Devolver periféricos a Linux** hace lo mismo. Al pasar algo a
  Windows, una notificación te recuerda las dos formas.

Ojo con el cursor: Omarchy muestra Windows como **sesión remota**; un ratón
pasado por USB mueve el cursor de la pantalla "física" de la VM, no el de esa
sesión. Para verlo, cierra la ventana de Windows y usa **Abrir Windows con mi
ratón**: arranca Windows sin la ventana remota (`omarchy-windows-vm launch
--keep-alive` con un `xfreerdp3` vacío delante en el `PATH`) y abre su pantalla
propia (el noVNC de `dockurr/windows` en `127.0.0.1:8006`) como web app; ahí
entras con tu contraseña de Windows y el cursor del ratón pasado sí se ve. Al
terminar: **SUPER + ALT + U** y **Apagar Windows**.

### Periféricos en navegador

Deja que el navegador hable con los dispositivos USB que marques (WebHID), para
configuradores web como **CORSAIR Web Hub**. Sin esto, Chromium ve el
dispositivo pero al darle a conectar no pasa nada, porque en Linux esos
dispositivos solo los puede usar root.

El plugin escribe una regla en `/etc/udev/rules.d/70-omarchy-tool-webhid.rules`
(con `bin/udev-webhid.sh` vía `pkexec`, así que pide tu contraseña) que da
acceso solo a la sesión con la que has entrado. Al desmarcar un dispositivo,
desactivar la función o quitar el plugin, la regla se borra y el acceso ya dado
se retira al momento.

Ojo: con acceso, cualquier programa de tu sesión puede hablar con ese
dispositivo (en un teclado, también leer lo que escribes). Marca solo lo que
vayas a configurar y desmárcalo al terminar si quieres.

## Línea de comandos

El panel solo llama a `bin/omarchy-tool`, que también se puede usar a mano:

```bash
omarchy-tool status                          # estado de todos los módulos (JSON)
omarchy-tool uninstall                       # borra todo rastro fuera del plugin
omarchy-tool self-update                     # actualiza ya si hay versión nueva
omarchy-tool windows-disks enable|disable
omarchy-tool windows-disks add /mnt/datos [Nombre]
omarchy-tool windows-disks remove /mnt/datos
omarchy-tool windows-disks letter /mnt/datos X   # o "next"
omarchy-tool web-devices enable|disable
omarchy-tool web-devices add 1b1c:2b0d            # vendor:product (lsusb)
omarchy-tool web-devices remove 1b1c:2b0d
omarchy-tool usb-windows enable|disable
omarchy-tool usb-windows add 093a:822a            # vendor:product (lsusb)
omarchy-tool usb-windows remove 093a:822a
omarchy-tool usb-windows move linux|windows 093a:822a  # con Windows abierto
omarchy-tool usb-windows move linux --all            # lo mismo que SUPER+ALT+U
```

## Añadir un módulo

1. `bin/modules/<nombre>.sh` con funciones `<nombre>_<acción>`. Debe tener
   `<nombre>_enable`, `<nombre>_disable`, `<nombre>_status` (JSON con
   `enabled`) y `<nombre>_apply`. Al desactivarse, `apply` debe borrar todo lo
   que el módulo escribió; si toca algo fuera de su carpeta, añade su limpieza
   a `bin/uninstall.sh`.
2. `modules/<Nombre>.qml`: la página del módulo. Recibe `status` y llama a
   `tool.run([...])`.
3. Añádelo a la lista `modules` de `ToolPanel.qml`, con su `group`, junto a los
   demás de su grupo. En el panel sale bajo el título del grupo, con su nombre y
   su interruptor.

## Pruebas

```bash
tests/run.sh
omarchy plugin validate .
```
