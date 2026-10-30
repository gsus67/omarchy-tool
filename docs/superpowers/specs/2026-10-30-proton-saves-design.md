# Guardar y cargar datos de Proton: diseño

## Para qué

Los `.exe` y juegos abiertos con GE-Proton guardan partidas y datos dentro del
prefijo, en Mis Documentos y otras carpetas. Hoy nada los copia. Se quiere
guardarlos en un archivo y poder cargarlos después, viendo antes qué contienen.

## Objetivos

- **Guardar**: crea un archivo con los datos del prefijo.
- **Cargar**: devuelve a su sitio el contenido de una copia.
- **Elegir la carpeta** de las copias, para poder usar otro disco.
- **Copia automática opcional** al encender, además del botón manual.
- **Ver el contenido antes de actuar**: tanto al guardar como al cargar se lista
  lo que incluye, por ejemplo «God of War · Saved Games · 12 KB».

## Fuera de alcance

- Elegir juegos sueltos (opción B, descartada).
- Prefijos de Steam en `steamapps/compatdata`: hoy solo existe el `0`.
- Copias programadas por horario, copia incremental, NAS o nube.
- Copia automática al apagar o al cerrar cada juego.

## Lo que no debe pasar

- Perder partidas más nuevas por cargar una copia antigua.
- Cargar sobre un juego abierto.
- Que desactivar o desinstalar el módulo borre las copias.
- Que una copia manipulada escriba fuera del prefijo.

## Enfoques

- **A. Una copia de todo (elegida por el usuario).** Un archivo por copia; se
  guarda y se carga completo. Simple, y no se pierde un juego por no marcarlo.
  A cambio, cargar afecta a todos los juegos a la vez.
- **B. Copia por juego (descartada).** Permite restaurar un juego solo, pero la
  pantalla es más compleja y cada juego usa nombres distintos, así que la lista
  puede salir confusa o incompleta.

## Comportamiento

Decisiones del usuario: enfoque A, mostrar el contenido antes de guardar y de
cargar. Copia previa automática al cargar y negativa con un juego abierto:
propuestas por Claude y presentadas junto a los enfoques, sin objeción.

Decisiones de Claude, pendientes de revisar:

- **Qué se copia**, desde `~/.local/share/umu/default/drive_c/users/steamuser`:
  `Documents`, `Saved Games` y `AppData/{Local,LocalLow,Roaming}`. Con los datos
  actuales son unos 38 MB sin comprimir.
- **Qué se excluye**: `AppData/Local/{dxvk,Temp,Microsoft,Programs,openvr}` y
  `AppData/Roaming/Microsoft`. Solo `dxvk` ocupa 280 MB. Los enlaces simbólicos no
  se siguen.
- **Dónde quedan las copias**: en `<carpeta elegida>/Partidas Proton/`, con nombre
  `partidas-AAAAMMDD-HHMMSS.tar.zst`. Por defecto la carpeta elegida es `~/Documents`.
  Debe existir y estar fuera del prefijo. La subcarpeta evita cambiar los permisos
  de un disco entero. Subcarpeta `0700` y archivos `0600`, porque `AppData` puede
  contener sesiones de programas; en NTFS esos permisos no aplican, y si ese disco
  se comparte con la VM de Windows, ella también verá las copias.
- **Disco no conectado**: si en una carpeta elegida falta la subcarpeta, se da error
  y no se crea de nuevo, para no escribir en el disco del sistema si el disco no
  está montado. La subcarpeta se crea solo al elegir la carpeta.
- **Copia automática**: un interruptor en la página, apagado al principio. Se hace
  una vez al iniciar el shell de Omarchy, es decir, al encender e iniciar sesión,
  y también si se reinicia el shell. Usa el arranque que el plugin ya tiene: no
  añade servicios, temporizadores ni procesos en segundo plano. Crea
  `automatica-AAAAMMDD-HHMMSS.tar.zst`. Si nada cambió desde la última automática,
  no crea otra. Si Proton está abierto, no copia y lo intenta en el siguiente
  inicio. Si el disco no está, avisa.
- **Sin copia al apagar**: exigiría un servicio de systemd, con tiempo limitado y
  con el riesgo de que el disco ya esté desmontado. Por eso, la última sesión queda
  sin copia hasta el siguiente encendido; antes de reinstalar hay que usar Guardar.
- **Limpieza**: se conservan las 5 automáticas más recientes y se borran las
  anteriores. Las manuales y las `antes-de-cargar` nunca se borran.
- **Cargar no borra**: sobrescribe lo que está en la copia y deja lo demás. Si un
  juego creó una ranura después de la copia, esa ranura sigue ahí.
- **Antes de cargar** se crea una copia `antes-de-cargar-….tar.zst`, que aparece
  en la misma lista. Si no se puede crear, no se carga.
- **Con Proton abierto** (hay un `wineserver` en marcha) se rechaza tanto guardar
  como cargar, porque guardar a mitad de escritura daría una copia incompleta.
- **Al cargar se valida el archivo antes de escribir nada**: solo rutas relativas
  bajo las carpetas de arriba, sin `..`, enlaces ni dispositivos. Si algo falla,
  se rechaza la copia entera.

## Pantalla

En la página de «Abrir .exe con Proton», visible si el prefijo existe aunque el
módulo esté desactivado (desactivarlo conserva el prefijo):

```
Partidas y datos
Guardar incluirá:
  God of War · Saved Games · 12 KB
  TunnelForge.exe · AppData · 4,2 MB
  [Guardar]

Carpeta de copias: [ ~/Documents            ] [Aplicar]
Copia automática al encender: [interruptor]

Copias:
  30 oct 2026, 08:45 · 4,7 MB          [Ver]
    God of War · Saved Games · 12 KB
    TunnelForge.exe · AppData · 4,2 MB
    [Cargar] [Cancelar]
```

Cargar solo se ofrece después de «Ver». Al terminar llega una notificación,
porque el panel puede haberse cerrado.

## Encaje en el código

- `bin/modules/exe-proton.sh`: nuevas acciones del módulo (listar, guardar,
  cargar, elegir carpeta, activar la automática), ejecutadas por la herramienta como las demás.
- Helper nuevo en `bin/`, con pruebas que usen un prefijo temporal.
- `bin/omarchy-tool`: `cmd_apply` llama a un paso de inicio del módulo. No va en
  `exe_proton_apply`, porque esa función también corre al activar o desactivar.
- `modules/ExeProton.qml`: la pantalla. Todo texto con `Text.PlainText` (lo exige
  `tests/test_qml_security.py`), porque los nombres de carpeta vienen de fuera.
- La página lee la lista con su propio `Process`, ya que `tool.run` no devuelve
  la salida. No va en `exe_proton_status`, que se ejecuta muy a menudo.
- Textos en `i18n/messages.json`; documentación en `README.md` y `README.es.md`.
  `bin/uninstall.sh` no toca las copias.

## Queda a criterio de quien lo implemente

Estructura interna del helper, formato JSON entre backend y página, y cómo se
agrupan los nombres de la lista.
