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

## Validación con una ISO real en una imagen RAW

La prueba de laboratorio usa `tests/windows-image.sh`. Comparte con el instalador la definición GPT, la selección x86-64, la aplicación directa sobre NTFS y la comprobación del BCD. El laboratorio ensambló las particiones en archivos dispersos y reservó el uso de loop para BCD-SYS. Esa vía no cubre la selección de una USB física ni el montaje de la ISO por descriptor que hace el instalador.

### Repetir las etapas sin privilegios

```bash
iso=/home/santi/Descargas/Win10_22H2_Spanish_Mexico_x64v1.iso
work="/tmp/win2go-lab-$USER-$(date +%s)"
bash tests/windows-image.sh inspect "$iso" "$work"
bash tests/windows-image.sh prepare "$work" 4
```

`inspect` registra la huella SHA-256, comprueba la estructura UDF con 7-Zip, valida el encabezado x86-64 del cargador EFI de la ISO y verifica el WIM o ESD con wimlib. `prepare` estima el espacio de trabajo, crea una RAW dispersa de 32 GiB y registra las particiones y los archivos de Windows verificados. Si solo se interrumpió el ensamblaje y existe `raw-build/applied.ok`, `bash tests/windows-image.sh assemble "$work"` retoma esa etapa con las particiones intermedias.

### Generar el BCD y probar el arranque

La etapa BCD requiere autorización específica para escribir en el loop de `"$work/raw-build/windows-togo.raw"`, un sistema con loop habilitado, BCD-SYS instalado y permisos para montar. Ejecútala solo después de confirmar el archivo de destino. El script vuelve a comprobar el dispositivo y el inodo de respaldo y monta Windows en solo lectura. El espacio de nombres de montajes permite aislar los archivos temporales de BCD-SYS.

```bash
set -o pipefail
sudo unshare --mount --propagation private \
  bash tests/windows-image.sh bcd "$work" --allow-loop-writes 2>&1 | tee "$work/bcd.log"
```

Con QEMU x86 y OVMF instalados, utiliza una pareja de firmware y variables del mismo paquete. El laboratorio presenta la RAW como almacenamiento USB virtual y conserva los cambios del invitado en una instantánea temporal. La máquina arranca sin red y usa emulación TCG, que puede resultar lenta.

```bash
bash tests/windows-image.sh boot "$work" \
  /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
```

En el monitor de QEMU, guarda capturas con `screendump etapa.ppm`. Se guardan junto con `qemu.log` y `serial.log`. Registra por separado la pantalla o error de Windows Boot Manager, evidencia del kernel (por ejemplo, un código de detención de Windows) y la llegada a OOBE. Para acreditar que el primer arranque terminó, documenta el final de OOBE y la pantalla de inicio de sesión o el escritorio. [Monitor de QEMU](https://www.qemu.org/docs/master/system/monitor.html) · [Opciones de ejecución de QEMU](https://www.qemu.org/docs/master/system/invocation.html)

### Resultado con Windows 10 22H2 es-MX

| Etapa | Resultado observado |
| --- | --- |
| ISO y archivo de instalación | 7-Zip comprobó 906 archivos. El cargador de la ISO es una aplicación EFI x86-64. `sources/install.wim` se verificó completo con wimlib. |
| Ediciones | Los índices 1–6 son x86-64 e incluyen Boot Manager y `winload.efi`. Home, Home Single Language, Education, Pro, Pro Education y Pro for Workstations. Se aplicó Pro (4). |
| GPT y formatos | RAW de 32 GiB lógicos y 10,1 GiB asignados. GPT verificada por `sfdisk`. ESP FAT32 de 512 MiB desde 1 MiB (sin errores de `fsck.fat -n`) y Windows NTFS 3.1 desde 513 MiB. Se compararon las particiones con los archivos intermedios y se volvieron a leer sus firmas desde la RAW. |
| Aplicación | wimlib completó la extracción sobre NTFS y avisó que omitió atributos extendidos de 11 393 archivos. `ntfscat` permitió comprobar `bootmgfw.efi`, `winload.efi`, `ntoskrnl.exe` y el registro `SYSTEM`. `winload.efi` usa el subsistema Windows Boot Application. |
| BCD-SYS | Pendiente. El entorno aislado no exponía el control de loop y el intento autorizado de ejecutar BCD-SYS devolvió `sudo: a password is required` antes de asociar el archivo. El Boot Manager verificado provenía de la partición Windows. |
| QEMU y OVMF | Pendiente. Los paquetes no estaban instalados y la instalación autorizada no pudo continuar sin autenticación de sudo. No se observó ninguna pantalla de arranque. |

La primera comprobación PE trataba `winload.efi` como aplicación EFI genérica. Se corrigió el criterio para comprobar su subsistema real y se reanudó el ensamblaje desde el NTFS ya aplicado. El verificador de BCD también se probó con un registro sintético.

SHA-256 registrado de la ISO: `bf02c401644a4a9249ee206faa9fd1691f4ec18bb37a9ea4ffe5c010dc147492`. Es una huella de la copia probada. La comparación con una huella oficial queda pendiente.

Antes de una prueba física, queda por verificar que BCD-SYS escriba el BCD y el cargador de respaldo en la ESP y que Windows complete el primer arranque desde el USB virtual.

### Reanudación desde a2cbb81

- Se reutilizó la RAW de 32 GiB de la prueba inicial (UID 1000, modo 0600, un enlace, inodo 4589254). `sfdisk --verify` y las sondas a los desplazamientos de ambas particiones confirmaron GPT, FAT32 y NTFS. La inspección de la ESP mostró un directorio vacío. La consulta por archivo de respaldo y los montajes visibles no mostraron asociaciones de pruebas anteriores.
- El intento autorizado de generar el BCD registró `sudo: a password is required` antes de crear el loop. Quedan pendientes el BCD, ambas copias del Boot Manager en la ESP y la verificación de las referencias del BCD real.
- El entorno informó 4 CPU lógicas (Core i5-3320M con VT-x), 7,4 GiB de RAM total, 2,6 GiB disponibles y 51 GiB libres. No exponía `/dev/kvm` ni `/dev/loop-control`. QEMU, su paquete de interfaz gráfica y OVMF estaban ausentes. Se dejó la instalación de paquetes pendiente al detenerse en la etapa BCD.
- El comando `boot` acepta un quinto argumento `gtk` o `sdl` para observar la pantalla. El valor predeterminado `none` conserva el modo sin ventana. Con acceso de lectura y escritura a `/dev/kvm`, intenta KVM con TCG de respaldo. La consola `info kvm` distingue el acelerador activo de la preferencia que anota el registro. Guarda las capturas con `screendump etapa.ppm` y evita `commit` en el monitor para preservar la imagen base. [Invocación de QEMU](https://www.qemu.org/docs/master/system/invocation.html) · [Monitor de QEMU](https://www.qemu.org/docs/master/system/monitor.html)
- Ningún hito de inicio fue observado. Siguen pendientes el reconocimiento del USB por OVMF, la ejecución de Boot Manager, el inicio de `winload.efi`, la ejecución del kernel, la llegada a OOBE y el inicio de sesión o escritorio.

#### Atributos extendidos omitidos

En wimlib 1.14.4 el aviso cuenta inodos con atributos extendidos, una vez por inodo aunque existan varios enlaces duros. La aplicación directa mediante el backend NTFS-3G no declara soporte para restaurarlos. Ese recuento es independiente de los datos de archivo, los flujos con nombre, los descriptores de seguridad y los puntos de reanálisis. El registro de esta aplicación conserva el total de 11 393, pero no enumera rutas, nombres de atributos ni valores. Los atributos ausentes tampoco pueden inventariarse a partir de la copia ya aplicada. [Recuento y avisos de wimlib](https://github.com/ebiggers/wimlib/blob/v1.14.4/src/extract.c#L1173-L1205) · [Backend NTFS-3G de wimlib](https://github.com/ebiggers/wimlib/blob/v1.14.4/src/ntfs-3g_apply.c#L49-L69)

Los componentes que consultan esos metadatos podrían comportarse de forma distinta. Windows contempla atributos con la marca `FILE_NEED_EA`, y el registro obtenido no permite determinar si la tenían los atributos de esta edición ni si afectan al arranque. El aviso por sí solo no permite atribuirle un fallo de Boot Manager, del cargador o del kernel. [Especificación de atributos extendidos de Microsoft](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/0eb94f48-6aac-41df-a878-79f4dcfd8989)

### BCD-SYS ejecutado sobre la RAW original

BCD-SYS generó el almacén y los binarios EFI en el loop de la RAW identificada. El validado posterior leyó los tres archivos directamente de la ESP en modo de solo lectura. El BCD contiene una entrada predeterminada en el orden de arranque que apunta a `\Windows\system32\winload.efi`. `bootmgfw.efi` y `BOOTX64.efi` son aplicaciones EFI x86-64 idénticas. BCD-SYS avisó que el anfitrión carecía de acceso a variables EFI. Se configuró la ruta de arranque de respaldo en la ESP. El arranque bajo OVMF sigue pendiente.

La primera ejecución real detectó que `losetup -r` significa solo lectura y se rechaza en consultas de identidad. La consulta usa ahora `--raw`. El escritorio había automontado el NTFS del loop. Tras comprobar el inodo y el origen del montaje, se desmontó únicamente ese volumen. El laboratorio admite reutilizar explícitamente el loop verificado, siempre que esté desmontado. El NTFS se montó en solo lectura dentro del espacio de nombres del laboratorio y se liberó el loop al finalizar.
