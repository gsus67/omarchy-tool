# Omarchy Tool

[English](README.md) · **Español**

Plugin para [Omarchy](https://omarchy.org/) con utilidades del sistema que se
activan y desactivan con un interruptor. Añade un icono a la barra que abre un
panel con un módulo por función. El panel usa los componentes y colores del
tema de Omarchy, así que cambia junto con el tema.

Cada interruptor muestra el cambio en curso y avisa al empezar, terminar o
fallar. La vista de discos distingue la instalación terminada de la vista ya
cargada: si Archivos estaba abierto, indica que hay que cerrarlo y volver a
abrirlo. Las sincronizaciones automáticas al arrancar no generan avisos.

El panel, sus módulos, estados y avisos siguen automáticamente el idioma del sistema (`LC_ALL`, `LC_MESSAGES`, `LANG`). Incluye inglés y español; otros idiomas usan inglés como respaldo. Los nombres de discos y periféricos se conservan. Los mensajes de los auxiliares dentro de Windows siguen el idioma de interfaz de Windows; sus nombres de archivo y rutas se mantienen para conservar los accesos existentes.

## Requisitos

- Omarchy con el sistema de plugins de Quickshell (`omarchy plugin`).
- `jq`, `socat`, `acl` (`setfacl`), `polkit` (`pkexec`) y `udev`, incluidos en
  Omarchy. **Iconos de .exe** instala `icoutils` si falta y usa `python3` del sistema.
- **Abrir .exe con Proton** necesita el repositorio `multilib` habilitado. Instala
  `umu-launcher` si falta y usa `xdg-mime`, `notify-send` y la sesión de usuario
  de systemd. Nunca modifica `pacman.conf`.
- Los módulos de **Windows** necesitan la VM de Windows de Omarchy
  (`omarchy-windows-vm`, basada en `dockurr/windows` bajo Docker), instalada
  desde el menú de Omarchy.
- Los cambios en archivos de root piden contraseña con `pkexec`.

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
  Proton conserva siempre el prefijo Wine, con los programas y partidas guardadas,
  y todas las copias hechas con **Copias de Proton**.
- **Eliminar el plugin** deja el sistema como estaba: quita los discos de la
  configuración de Windows (pide tu contraseña) y borra la configuración del
  plugin y la entrada del menú. Como `omarchy plugin remove` no ejecuta código
  del plugin, la limpieza la hace una copia de `bin/uninstall.sh` guardada fuera
  del plugin, que el panel lanza al descargarse.
- `omarchy-tool uninstall` hace esa misma limpieza a mano (ver
  [Línea de comandos](#línea-de-comandos)).

Archivos que el plugin puede escribir fuera de su carpeta, retirados al limpiar
salvo el prefijo Wine, tus copias de Proton, los registros y los runtimes/cachés
gestionados por umu:

- `~/.config/omarchy-tool/` (configuración) y `~/.local/share/omarchy-tool/`
  (estado y copia del desinstalador)
- Una entrada en `~/.config/omarchy/extensions/omarchy-menu.jsonc`, más las
  entradas de IP y DNS por adaptador mientras **Red por adaptador** está activado
- `~/.config/hypr/omarchy-tool.lua` y una línea protegida en `hyprland.lua`
  (el atajo **SUPER + ALT + U**)
- Las líneas `/shared2`, `/shared3` y `/dev/bus/usb` en
  `/var/lib/omarchy/windows/docker-compose.yml`
- `/etc/udev/rules.d/70-omarchy-tool-webhid.rules`
- `/usr/local/bin/omarchy-tool-exe-thumbnailer` y
  `~/.local/share/thumbnailers/omarchy-tool-exe.thumbnailer`
- `~/.local/share/applications/omarchy-tool-run-exe.desktop` y los valores MIME
  de Windows en los `mimeapps.list` del usuario (se restauran los anteriores)
- Una versión de GE-Proton en los directorios de compatibilidad de umu, retirada
  solo si la descargó el módulo; las versiones anteriores se conservan
- `~/.local/share/umu/default/` (prefijo Wine, **siempre se conserva**) y
  `~/.cache/run-exe.log`, `~/.cache/omarchy-tool-proton-prepare.log` (registros, conservados)
- Los auxiliares en la carpeta `Omarchy Tool` de Shared en Windows (si aún hay
  letras asignadas, **Quitar discos** se conserva y se borra al ejecutarlo)

## Módulos

### Discos en mosaicos (Extras)

Un interruptor para abrir Archivos en **Este equipo**, con los discos en mosaicos,
barra de ocupación y espacio libre y total. Al abrir un disco navegas normalmente
en Nautilus; las carpetas abiertas por su ruta mantienen su destino.

Requiere Nautilus 50/51, `nautilus-python`, GTK4 y libadwaita. Después de activar,
cierra las ventanas de Archivos y vuelve a abrirlo. No pide contraseña, instala
paquetes ni interrumpe operaciones de archivos. Al desactivar o desinstalar se
retiran la extensión y el acceso añadido, conservando marcadores y cambios del
usuario. La integración depende de estructuras internas de Nautilus; detalles,
huella y pruebas en [Discos en mosaicos](docs/DISK_TILES.md).

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

### Extras

**Omarchy › Extras** abre una página con nombre e interruptor por submódulo,
con las mismas filas que la lista principal. Pulsa el nombre para abrir su
página; su flecha vuelve a Extras, y la de Extras vuelve a la lista principal.
Extras no tiene interruptor. Los ids y la configuración guardada se conservan.

### Iconos de .exe

En **Omarchy › Extras**, hace que Archivos (Nautilus) muestre el icono propio
de cada programa de Windows. Al activar, instala `icoutils` si falta y copia
`bin/exe-thumbnailer`, versionado en el plugin, a
`/usr/local/bin/omarchy-tool-exe-thumbnailer`, de root y con permisos 0755.
Nautilus ejecuta los generadores de miniaturas en una caja de bubblewrap que
solo ve directorios del sistema: una copia bajo tu carpeta personal no funciona.
El registro `~/.local/share/thumbnailers/omarchy-tool-exe.thumbnailer` admite
los tipos MIME de ejecutables EXE, MSI y DLL. Con `python3` del sistema, solo
borra los fallos de miniaturas de GNOME cuyo `Thumb::URI` termina en `.exe`,
`.msi` o `.dll` (sin distinguir mayúsculas), para que Archivos vuelva a probar.
Las demás miniaturas se conservan.

`bin/exe-icons.sh` hace la instalación con una sola petición de contraseña por
`pkexec`, y la retirada con otra. Si la copia de root ya tiene el mismo contenido,
aplicar no pide contraseña; el registro de usuario se puede reparar sin pedirla.
Adopta la instalación manual `/usr/local/bin/exe-thumbnailer` junto con
`~/.local/share/thumbnailers/exe.thumbnailer` solo si ambos coinciden exactamente
con los originales: borra ambos en la misma ejecución privilegiada antes de
registrar el sustituto. Desactivar o desinstalar quita los archivos y el estado
del módulo, e `icoutils` solo si lo instaló el módulo; si ya estaba, lo conserva.

### Abrir .exe con Proton

En **Omarchy › Extras**, abre programas de Windows (`.exe`/`.msi`) con doble
clic para ejecutarlos con GE-Proton mediante `umu-run`. Al activar, instala
`umu-launcher` con `pacman -S --needed --noconfirm umu-launcher` en una sola
petición de `pkexec` solo si falta. Si `multilib` está deshabilitado, muestra
un error sin modificar `pacman.conf`. Un paquete previo nunca se elimina.

El `bin/run-exe.sh` versionado se instala como ejecutable del usuario en
`~/.local/share/omarchy-tool/exe-proton/run-exe`; nunca se ejecuta como root.
El manejador oculto `omarchy-tool-run-exe.desktop` pasa a ser predeterminado
para los cinco tipos MIME de ejecutables/instaladores Windows. Se guarda una
sola vez el valor anterior de cada uno; al desactivar/desinstalar se restaura,
o se quita si estaba vacío. Adopta el `~/.local/bin/run-exe` original exacto
(SHA-256) junto con `~/.local/share/applications/run-exe.desktop` si su Exec
apunta a ese script: borra ambos archivos manuales y deja un solo manejador.
Al desactivar no restaura un manejador manual borrado; conserva las
instalaciones manuales modificadas.

La preparación usa una unidad separada de systemd de usuario: el panel no
espera a la descarga ni a inicializar el prefijo. Avisa «Preparando GE-Proton…»
y después «Listo: ya puedes abrir .exe con doble clic», o indica el fallo.
Usa el propio mecanismo de umu, `PROTONPATH=GE-Proton umu-run wineboot -u`,
y lo omite si GE-Proton ya existe en `~/.local/share/umu/compatibilitytools` o
`~/.local/share/Steam/compatibilitytools.d`. Solo registra para eliminar las
versiones que descarga el módulo; al desactivar detiene primero la preparación.
Los archivos de runtime/caché de umu siguen gestionados por umu.

El runner usa `msiexec /i` para MSI, avisa al arrancar/fallar y deja el registro
en `~/.cache/run-exe.log`; la preparación escribe en
`~/.cache/omarchy-tool-proton-prepare.log`. Su prefijo predeterminado es
`~/.local/share/umu/default` (`GAMEID=umu-default`), igual que la instalación
manual. El runner respeta `WINEPREFIX`, `GAMEID` y `PROTONPATH`.
**Desactivar o desinstalar nunca borra ese prefijo ni sus juegos/partidas.**
Si quieres borrarlos, elimina tú `~/.local/share/umu/default`.
Se respetan las rutas XDG de datos/caché y `UMU_FOLDERS_PATH` de umu.

### Copias de Proton

Una entrada propia en **Omarchy › Extras**. Su interruptor es la copia automática;
un clic en su nombre abre la página. Copia a un archivo lo
que los programas de Windows guardan en el prefijo de Proton, y lo restaura después.
Funciona con **Abrir .exe con Proton** desactivado, siempre que el prefijo exista.

- **Qué se copia:** `Documents`, `Saved Games` y `AppData/{Local,LocalLow,Roaming}`
  dentro de `drive_c/users/steamuser`, sin `AppData/Local/{dxvk,Temp,Microsoft,Programs,openvr}`
  ni `AppData/Roaming/Microsoft`. Los enlaces nunca se siguen. Los juegos abiertos
  desde Steam usan su propio prefijo y no se incluyen.
- **Verlo antes:** la página lista lo que **Guardar** incluirá. **Ver** lista lo que
  contiene una copia, y solo entonces ofrece **Cargar**.
- **Cargar** sobrescribe lo que está en la copia y deja lo demás, así que una ranura
  creada después de la copia sigue ahí. Antes hace una copia `antes-de-cargar-…`, y
  no carga si esa copia falla. Una copia con rutas inseguras, enlaces o daños se
  rechaza entera antes de cambiar nada.
- **Con Proton abierto** (un `wineserver` en marcha) no se puede guardar ni cargar.
- **Dónde:** `<carpeta>/Partidas Proton/`, con `~/Documents` como carpeta por defecto.
  La carpeta elegida debe existir y estar fuera del prefijo. Si más tarde falta su
  subcarpeta `Partidas Proton`, o su disco está en `/etc/fstab` y no está montado, la
  copia falla en vez de escribir en el disco del sistema. Se rechaza una carpeta que
  se borraría al desinstalar. Las copias son privadas
  (`0700`/`0600`); los discos sin permisos Unix, como NTFS, no pueden garantizarlo,
  y un disco compartido con la VM de Windows las deja visibles allí. `AppData` puede
  contener sesiones de programas.
- **Copia automática al encender:** el interruptor de la entrada en Extras, apagado
  hasta que lo actives. Necesita una carpeta elegida: sin ella, al activarlo sale un
  aviso en rojo y sigue apagado. Entra en la entrada, pulsa **Aplicar** y actívalo. Se hace una vez al
  iniciar el shell de Omarchy, desde el paso de arranque que el plugin ya tiene: sin
  servicios, temporizadores ni procesos en segundo plano. Crea `automatica-…` solo
  si algo cambió, se omite con Proton abierto y avisa si falta el disco. Se conservan
  las 5 automáticas más recientes; las manuales y las `antes-de-cargar` nunca se
  borran. **La última sesión no tiene copia hasta el siguiente encendido, así que
  usa Guardar antes de reinstalar.**

Desactivar o desinstalar nunca toca una copia.

### Red por adaptador

En **Omarchy › Extras**, permite elegir el adaptador (cable o Wi-Fi) al cambiar
su IP o sus DNS desde el menú de Omarchy:

- **Setup › Network › IP** › *adaptador*: **DHCP** vuelve a recibir la dirección
  y la puerta de enlace del router; **Custom** abre un terminal flotante que
  pide la dirección con su prefijo (`192.168.1.20/24`) y la puerta de enlace,
  y Enter deja el valor actual que se muestra entre corchetes.
- **Setup › Network › DNS** › *adaptador*: **DHCP**, **Cloudflare**, **Google** o
  **Custom** (servidores separados por espacios, IPv4 o IPv6) solo para ese
  adaptador. Las cuatro opciones propias de Omarchy siguen encima y valen para
  todos los adaptadores.

Hay una entrada por adaptador de cable o Wi-Fi, visible solo mientras está
conectado: los ajustes son de la conexión activa en él (en Wi-Fi, la red a la
que estás conectado). Una ✓ marca lo elegido. Antes se comprueba todo (IPv4
válida, prefijo 1–32, puerta de enlace en la misma red, sin dirección de red
ni de broadcast, servidores DNS válidos); si algo falla no cambia nada.

Los cambios se hacen con `nmcli` como el usuario de la sesión: NetworkManager
ya deja que una sesión local cambie las conexiones, así que no pide contraseña
ni hay que instalar nada. Los errores desde el menú salen como notificación.

La opción de DNS de Omarchy para todos los adaptadores (Cloudflare, Google o
Custom) es un ajuste global de NetworkManager que manda sobre los de cada
adaptador, así que los DNS por adaptador se rechazan con un aviso hasta que el
DNS de Omarchy vuelva a **DHCP**.

Con una IP fija el router ya no da DNS. Si el adaptador no tiene DNS propios,
la IP **Custom** conserva los servidores que se usan en ese momento, y **DHCP**
quita después exactamente esos, salvo que hayan cambiado entretanto. Con IP
fija, los DNS **DHCP** se rechazan porque el router no daría ninguno.

La página del módulo muestra cada adaptador con su IP y sus DNS y, con IP fija,
un botón **Volver a DHCP**. Desactivar el módulo o desinstalar quita las
entradas del menú y la copia del script en `~/.local/share/omarchy-tool/`; la
red se queda con lo último que se eligió.

### Plugins

Activa y desactiva desde el panel tus plugins de Omarchy instalados, con un
interruptor para cada uno. La lista sale de `omarchy plugin list`, así que los
plugins que añadas después aparecen solos; los plugins integrados de Omarchy y
el propio Omarchy Tool no salen. Usa el propio `omarchy plugin enable|disable`
de Omarchy: no pide contraseña y no escribe nada fuera de la configuración del
plugin. Al desactivar un icono de la barra se recuerda su sitio (sección y
posición) y vuelve ahí al activarlo. No cambia nada por sí mismo, así que en la
lista del panel no tiene interruptor propio. Un plugin de barra completa sale
sin interruptor: Omarchy no permite apagar una barra, solo cambiarla con
`omarchy bar use`.

## Línea de comandos

El panel solo llama a `bin/omarchy-tool`, que también se puede usar a mano. No
está en el `PATH`; crea antes un alias:

```bash
alias omarchy-tool=~/.config/omarchy/plugins/io.github.gsus67.omarchy-tool/bin/omarchy-tool
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
omarchy-tool exe-icons enable|disable
omarchy-tool exe-proton enable|disable
omarchy-tool exe-proton saves-list                # JSON: lo que tendría una copia, y las copias
omarchy-tool exe-proton saves-preview NOMBRE      # JSON: lo que contiene una copia
omarchy-tool exe-proton saves-save
omarchy-tool exe-proton saves-load NOMBRE
omarchy-tool exe-proton saves-folder /mnt/datos   # "" vuelve a la carpeta por defecto y apaga la copia automática
omarchy-tool proton-saves enable|disable          # la copia automática; necesita carpeta elegida
omarchy-tool network-ip enable|disable
omarchy-tool network-ip dhcp enp6s0              # adaptador a DHCP
omarchy-tool usb-windows enable|disable
omarchy-tool usb-windows add 093a:822a            # vendor:product (lsusb)
omarchy-tool usb-windows remove 093a:822a
omarchy-tool usb-windows move linux|windows 093a:822a  # con Windows abierto
omarchy-tool usb-windows move linux --all            # lo mismo que SUPER+ALT+U
omarchy-tool plugins on|off io.github.gsus67.omarchy-taskbar
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
   su interruptor. Para un submódulo de Extras, usa `parent: "extras"` en
   lugar de `group`; ambos niveles comparten el componente de fila.

## Pruebas

```bash
bash tests/run.sh
bash tests/i18n.sh
omarchy plugin validate .
```
