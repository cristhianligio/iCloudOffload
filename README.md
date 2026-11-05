# iCloud Offload

App de macOS (SwiftUI) que **copia** tus fotos y videos de Fotos de iCloud a un disco externo, **verifica** cada archivo con SHA-256 y, si lo autorizas, los **borra** de la fototeca (y por lo tanto de iCloud) para liberar espacio.

## Compilar y abrir

```bash
./build.sh
open "build/iCloud Offload.app"
```

Requisitos: macOS 14+, Xcode o Command Line Tools con Swift 5.10+. Pruebas: `swift test`.

## Cómo funciona

1. **Escaneo**: lee la fototeca con PhotoKit (filtro opcional por tipo y fechas).
2. **Copia**: para cada elemento exporta **todos sus recursos originales** (foto, video de Live Photo, versión editada, RAW, datos de ajustes…). Si el original solo está en iCloud ("Optimizar almacenamiento"), se descarga. Hay varias descargas simultáneas (configurable).
   - Se escribe a un archivo temporal oculto, se fuerza el vaciado a disco (`F_FULLFSYNC`) y solo entonces se renombra. Nunca queda un archivo final a medias.
   - Estructura: `Destino/AAAA/MM/IMG_0001.HEIC`, `IMG_0001.MOV`, `IMG_0001_edited.heic`… Se conserva la fecha original del archivo.
3. **Verificación**: el SHA-256 se calcula mientras llegan los bytes desde Fotos; después se **relee el archivo desde el disco** (sin caché, `F_NOCACHE`) y se compara hash y tamaño.
4. **Borrado** (opcional, desactivado por defecto): los elementos verificados se acumulan y se borran **en lotes** mientras la copia continúa, así el espacio se va liberando durante el proceso. Justo antes de cada lote se vuelven a verificar los archivos.

Todo queda registrado en `Destino/.icloud-offload/manifest.jsonl` (identificador, rutas, tamaños, hashes, fecha de verificación y de borrado). Gracias a eso **se puede reanudar**: lo ya copiado no se vuelve a copiar.

## Salvaguardas

- Solo se borra un elemento si **todos** sus archivos están copiados y verificados.
- El destino debe ser un disco externo; se detiene si quedan menos de 2 GB libres.
- Reintenta cada elemento hasta 3 veces; si falla, no se borra.
- Al cancelar no se borra nada más.
- Si rechazas el diálogo de borrado de macOS, el borrado se desactiva y la copia sigue.

## Limitaciones importantes

- **"Eliminado recientemente"**: Fotos guarda lo borrado 30 días. El espacio en iCloud no se libera del todo hasta que vacíes esa carpeta (Fotos › Eliminado recientemente). Apple no permite a las apps vaciarla.
- **Confirmación del sistema**: macOS pide confirmar cada lote de borrado; no se puede evitar (es una protección de Apple). Por eso hay lotes configurables (por defecto 100).
- **Fotos de iCloud debe estar activado** en este Mac para que el borrado se propague a iCloud y a tus otros dispositivos.
- Se necesita **acceso completo** a Fotos (no "limitado").
- No incluye álbumes compartidos ni fotos ocultas.
- Los álbumes, caras y metadatos propios de Fotos (favoritos, descripciones) no se copian; sí los metadatos EXIF incluidos en el archivo.
- Discos FAT32 no admiten archivos de más de 4 GB: usa APFS o exFAT.

## Recomendación

Haz la primera ejecución **sin** borrado, revisa los archivos en el disco y después vuelve a ejecutarla con el borrado activado: los elementos ya copiados se re-verifican y se borran sin volver a descargarlos. Lo ideal es tener una segunda copia (otro disco) antes de borrar de iCloud.

## Estructura

```
Sources/OffloadCore/      lógica (sin UI)
  OffloadEngine.swift     pipeline: escaneo → copia → verificación → borrado
  ResourceExporter.swift  descarga en streaming + hash + escritura atómica
  Verifier.swift / FileHasher.swift  verificación SHA-256 desde disco
  Manifest.swift          registro JSONL para auditar y reanudar
  PhotoLibrary.swift      PhotoKit (permisos, búsqueda, borrado)
  PathBuilder.swift       nombres de archivo y carpetas, sin colisiones
  VolumeInfo.swift        detección de disco externo y espacio libre
Sources/iCloudOffload/    interfaz SwiftUI
Tests/OffloadCoreTests/   pruebas unitarias
```
