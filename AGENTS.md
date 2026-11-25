# Cambios realizados en Win2Go

## Instalador USB

- Usa directorios temporales privados y desmonta únicamente los volúmenes que montó la ejecución actual. La limpieza también se ejecuta al recibir `SIGINT` o `SIGTERM`.
- Valida los argumentos y limita los índices de los menús antes de evaluarlos. La opción `-v` activa el trazado de comandos y `-y` devuelve un error. El borrado requiere confirmación manual.
- Comprueba que el destino sea un disco USB completo y que no tenga sistemas de archivos montados ni volúmenes activos. Repite la comprobación antes de particionar y formatear, y verifica que las particiones esperadas pertenezcan al disco seleccionado.
- Ejecuta `parted` directamente con argumentos entrecomillados y comprueba que el almacén BCD y el cargador UEFI de respaldo estén presentes y tengan contenido.

## Diagnóstico y dependencias

- El diagnóstico USB de solo lectura aplica un único límite de tiempo a la operación completa y detecta lecturas incompletas. Compara las capturas del registro del kernel para detectar una posible rotación antes de evaluar los mensajes nuevos.
- El instalador de dependencias comprueba herramientas adicionales usadas por Win2Go y BCD-SYS, entre ellas `ntfs-3g`, `sfdisk` y `hexdump`.

## Documentación y pruebas

- Se actualizaron `README.md` y `FIXES.md` para reflejar las opciones, los requisitos y las limitaciones actuales.
- Las pruebas básicas comprueban la sintaxis de todos los scripts, el rechazo de entradas inválidas y que esas entradas no invoquen `sudo`.
- Pasaron `bash tests/smoke.sh`, `bash scripts/deps-ubuntu.sh --check` y `git diff --check`. El particionado, la aplicación de la imagen y el arranque en hardware real quedan sin verificar.
