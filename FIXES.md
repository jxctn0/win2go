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

GitHub Actions comprueba la sintaxis de los scripts y ejecuta las pruebas básicas sin acceso a dispositivos físicos. La prueba de lectura se ejecuta manualmente en el equipo, ya que requiere el dispositivo USB real.

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
```sh
bash -n win2go.sh
bash tests/smoke.sh
```

**Advertencia:** esas pruebas verifican algunos fallos básicos, pero no demuestran que la imagen de Windows arranque.
