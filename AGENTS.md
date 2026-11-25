# Instrucciones para agentes: Win2Go

Este archivo contiene **instrucciones de trabajo para Codex y otros agentes**. La documentación para usuarios está en `README.md`; el estado de los arreglos está en `FIXES.md`.

## Objetivo del proyecto

Crear desde Linux una memoria USB con Windows To Go y arranque UEFI, sin poner en riesgo el disco del sistema anfitrión. El repositorio contiene `win2go.sh`, diagnósticos en `scripts/` y pruebas en `tests/`.

**Estado actual:** el código ha pasado algunas pruebas de sintaxis y de entradas inválidas, pero **no se ha verificado todavía un arranque real de Windows en hardware físico**. No afirmar que la herramienta ya es segura o funcional de extremo a extremo sin evidencia.

## Reglas obligatorias de seguridad

1. **No ejecutar operaciones destructivas** contra dispositivos de bloque físicos sin autorización explícita y específica del usuario para el dispositivo identificado en la sesión actual. Esto incluye `parted`, `mkfs*`, `wipefs`, `sgdisk`, `dd` de escritura, `wimlib-imagex apply`, cambios a tablas de particiones y otros equivalentes.
2. No utilizar `sudo` o permisos irrestrictos por defecto para Codex. Solicitar autorización para comandos privilegiados cuando sean realmente necesarios. No interpretar la autorización para editar código como permiso para ejecutarlo contra unidades reales.
3. Antes de cualquier operación destructiva, verificar la identidad del destino (ruta canónica, tipo, transporte, `MAJ:MIN`, tamaño, modelo, serie si existe), su relación con discos y particiones, y que no contenga el sistema anfitrión ni la ISO de origen. Revalidar inmediatamente antes de cada etapa destructiva.
4. **Nunca borrar el disco que contiene la ISO.** Resolver el origen de la ISO hasta su dispositivo físico principal, contemplando particiones, montajes indirectos y dispositivos de loop; rechazar cuando la ISO resida en el USB de destino. Preferir detenerse ante cualquier ambigüedad.
5. Las pruebas ordinarias no deben tocar dispositivos físicos. Para pruebas de integración utilizar mocks o dispositivos virtuales/archivos de imagen, con límites y limpieza robusta; avisar si alguna prueba requiere permisos especiales. No conectar automáticamente unidades del usuario a tests.
6. El script `scripts/usb-health.sh` es de **solo lectura**; mantener esa propiedad. Una lectura correcta no certifica capacidad real, fiabilidad de escritura ni arranque de Windows.
7. No publicar un PR upstream ni efectuar operaciones de borrado reales automáticamente. Preparar cambios en la rama de trabajo, ejecutar pruebas y resumir los resultados y riesgos pendientes.

## Correcciones prioritarias pendientes

### 1. Proteger la ISO de origen (prioridad alta)

- Localizar el dispositivo real que respalda el archivo ISO, incluso cuando está almacenado en una partición del mismo USB, usando información de `findmnt`, `lsblk` y relaciones padre/hijo.
- Evitar que la unidad de destino sea la misma que contiene la ISO. Un simple cotejo de cadenas `/dev/sdb` vs `/dev/sdb1` no basta para todos los casos.
- Añadir pruebas para ISO en el disco de destino, ISO en otro disco, ISO en sistema de archivos no resoluble y cambios de identidad del dispositivo. Si no se puede confirmar, detenerse antes del borrado.

### 2. Corregir exit status del verificador (prioridad alta)

- En `scripts/deps-ubuntu.sh --check`, devolver código de salida distinto de cero cuando falten comandos requeridos. Actualmente el modo de comprobación termina con `exit 0` incluso cuando `check_commands` falla.
- Añadir una prueba automatizada que simule una dependencia ausente y confirme que el proceso falla; comprobar que el modo normal termina en cero con todas las dependencias presentes.

### 3. Aumentar cobertura de pruebas sin riesgo (prioridad alta)

- Probar selección de discos, validaciones, particiones esperadas, limpieza de montajes, cancelaciones y manejo de errores con comandos simulados.
- Probar la invocación y validación de BCD-SYS y la detección de `install.wim`/`install.esd` sin escribir sobre discos reales.
- Si se realizan pruebas de integración con un dispositivo loop o imagen de archivo, aislarlas y documentar los requisitos; el CI no debe requerir un disco USB físico.
- Ejecutar pruebas de regresión antes de cada commit y antes de proponer un PR.

### 4. Higiene del repositorio (prioridad baja)

- Retirar el archivo accidental `New changes`, que contiene un diff antiguo con códigos ANSI, una vez comprobado que no tiene contenido necesario.
- Mantener `AGENTS.md` como instrucciones operativas; dejar el registro de modificaciones y resultados en `FIXES.md` o en los mensajes de commit.
- Mantener consistentes las instrucciones de uso de `README.md` con las opciones realmente soportadas por el instalador.

## Comprobaciones mínimas antes de un commit

```bash
bash -n win2go.sh
bash -n scripts/deps-ubuntu.sh
bash -n scripts/usb-health.sh
bash tests/smoke.sh
git diff --check
```

Si alguna comprobación requiere acceso a dispositivos de bloque o root, **no ejecutarla automáticamente**. Informar qué se pudo validar, qué falló y qué queda pendiente.

## Contexto de hardware de pruebas

El equipo de desarrollo es un ThinkPad T430 con Linux Mint. En una inspección previa, `/dev/sda` era el SSD de Linux y `/dev/sdb` una memoria USB de 128 GB. **Esos nombres no son permanentes y jamás deben usarse como garantía de identidad.** El usuario realizará cualquier prueba destructiva solo después de revisar y aprobar el destino exacto.

## Estilo de trabajo

- Preferir correcciones pequeñas, revisables y probadas.
- Describir errores con claridad y códigos de salida correctos; evitar ignorar fallos silenciosamente.
- Conservar rutas entrecomilladas, evitar evaluación de texto no confiable como comandos y respetar la limpieza de recursos en caso de error o señal.
- Al finalizar, entregar un resumen de cambios, comandos de prueba ejecutados, resultados y riesgos no resueltos.
