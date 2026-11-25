# Correcciones experimentales de Win2Go

Esta rama está en desarrollo y **no se ha validado el arranque de Windows en hardware real**.

## Corregido
- Selector USB por dispositivo, no por palabras de `lsblk`.
- Rechazo de discos que no sean USB y de particiones montadas.
- Búsqueda de ISO sin romper rutas con espacios.
- Evita el cierre silencioso por `grep` cuando no hay sistemas montados.
- Evita ejecutar dos veces la limpieza con traps `EXIT` y `ERR`.
- Reconoce `install.wim` e `install.esd` y permite elegir índice.
- Exige BCD-SYS antes del borrado y crea arranque UEFI con `bcd-sys -s`.
- Valida la ISO y el índice antes de particionar.
- Aplica la imagen directamente sobre NTFS.
- Resuelve el respaldo de la ISO y del anfitrión mediante `findmnt`, `stat`, sysfs y, para imágenes montadas, `losetup`. Sigue particiones y dispositivos apilados y se detiene ante un origen ambiguo.
- Mantiene abierto el archivo de origen y comprueba su identidad, la del disco USB y la de sus particiones antes de escribir. Usa la secuencia del disco cuando el kernel la expone.
- `--dry-run` muestra el plan tras las comprobaciones de identidad. El montaje de la ISO y la selección de edición x86-64 se reservan para la instalación.
- Propaga el estado del verificador de dependencias. Si falla el desmontaje, conserva el directorio para inspección, intenta limpiar los montajes restantes y devuelve un error.
- Comprueba que el BCD se puede abrir y contiene la lista de arranque de Windows Boot Manager. Comprueba también la presencia del cargador UEFI de respaldo.
- Retirado `New changes`, que solo contenía un diff antiguo del selector USB.

## Diagnóstico USB de solo lectura

Antes de crear Windows To Go, identifica el dispositivo con `lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS`.
Ejemplo (sustituye el dispositivo después de verificarlo):

```bash
sudo bash scripts/usb-health.sh --device /dev/sdb --mib 1024 --timeout 180
```

El diagnóstico:
- Rechaza discos SATA/internos y particiones (solo dispositivos USB completos).
- Lee 1 GiB por defecto con `dd` y muestra su velocidad.
- Comprueba los mensajes **nuevos** de error del kernel cuando `dmesg` está disponible.
- No escribe datos, no modifica particiones ni formatea.
- Permite ajustar el tamaño con `--mib` (hasta 4096) y el límite de tiempo con `--timeout`.
- **No demuestra** velocidad de escritura, capacidad real ni arranque de Windows.

GitHub Actions comprueba la sintaxis y ejecuta las suites de entradas, dependencias e integración simulada. La prueba de lectura se ejecuta manualmente en el equipo, ya que requiere el dispositivo USB real.

## Instalación automatizada de dependencias (Ubuntu / Linux Mint)

Primero verificar, sin modificar el sistema:

```bash
bash scripts/deps-ubuntu.sh --check
```

Instalar los paquetes APT faltantes:

```bash
bash scripts/deps-ubuntu.sh --install
```

El instalador usa `libhivex-bin` (no `hivex-bin`), `pev`, `attr` y `fatattr`.
Si falta BCD-SYS ofrece descargar su repositorio para revisión, **pero no ejecuta su
instalador automáticamente**, puesto que es código de terceros. Después de revisar
`setup.sh`, ejecutar manualmente `sudo ./setup.sh install` desde su directorio.

El comando `bcd-sys --help` también puede reportar dependencias faltantes, aunque
`command -v bcd-sys` ya devuelva una ruta.

## Dependencias adicionales
`parted`, `partprobe`, `udevadm`, `mkfs.vfat`, `mkfs.ntfs`, `mount`, `ntfs-3g`, `wimlib-imagex` y **BCD-SYS** (`bcd-sys`).

BCD-SYS: https://github.com/jpz4085/BCD-SYS. Debe instalarse y comprobarse antes de usar este instalador.

## Limitaciones actuales
- Solamente UEFI; no prepara arranque Legacy BIOS.
- No implementa creación automática de usuario, omisión de OOBE ni instalación de drivers.
- Windows 10/11 To Go todavía debe probarse con dispositivo físico.
- No se debe ejecutar contra discos con información importante.
- La opción `-y` se rechaza. La confirmación del borrado es explícita.

## Pruebas no destructivas

```bash
bash tests/smoke.sh
bash tests/dependencies.sh
bash tests/integration.sh
bash tests/images.sh
```

Las imágenes dispersas permiten verificar la tabla GPT, los sistemas FAT32 y NTFS y la extracción directa de WIM y ESD sintéticos sobre NTFS. Las pruebas simuladas cubren el flujo de instalación, cambios de identidad, automontaje, fallos de permisos, cancelaciones, señales, montaje parcial, BCD inválido y desmontaje ocupado. Quedan pendientes el montaje real de la ISO por su descriptor, la generación del BCD con BCD-SYS sobre una imagen real de Windows y una prueba de arranque UEFI.

## Riesgos operativos pendientes

- Hay una ventana entre revalidar y abrir el dispositivo en cada utilidad. Un cambio concurrente o una desconexión en esa ventana puede provocar escrituras parciales o sobre un dispositivo reasignado. La detección de montajes observa el espacio de nombres del instalador.
- `sudo -v` comprueba la autenticación. Una regla de sudo por comando, un controlador o una operación de E/S aún pueden fallar durante la instalación. Una vez creada la GPT, un fallo puede dejar el disco parcialmente preparado.
- La versión de BCD-SYS inspeccionada usa nombres temporales fijos bajo `/tmp`. Evita ejecuciones concurrentes de BCD-SYS durante la instalación.
- Si un punto de montaje sigue ocupado, el instalador conserva su directorio e informa la ruta para inspección. Una terminación forzada o la pérdida de alimentación pueden impedir la limpieza.
