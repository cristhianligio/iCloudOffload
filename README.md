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

## Registro de copias (manifiesto)

En la interfaz aparece como «Registro de copias». Es el archivo `Destino/.icloud-offload/manifest.jsonl`, con una línea JSON por evento: elemento copiado y verificado (archivos, tamaños, SHA-256) o elemento borrado de iCloud (fecha y hora). Sirve para:

- **Reanudar**: lo ya copiado no se vuelve a copiar.
- **Re-verificar** los archivos antes de borrar nada de iCloud, también en ejecuciones posteriores.
- **Auditar** qué se borró de iCloud y cuándo, y comprobar en el futuro que las copias no se dañaron.

## Salvaguardas

- Solo se borra un elemento si **todos** sus archivos están copiados y verificados.
- **Solo se admiten discos externos físicos** (USB, Thunderbolt, tarjeta SD). Se rechazan el disco de arranque, cualquier carpeta del disco interno, las imágenes de disco (`.dmg`, que en realidad ocupan el disco interno) y las unidades de red. El selector de carpetas lo impide y el motor lo vuelve a comprobar antes y durante la copia (si el disco se desconecta, se detiene).
- Se detiene si quedan menos de 2 GB libres en el disco externo, o menos de 3 GB en el disco interno: Fotos guarda allí temporalmente los originales que descarga de iCloud. Se puede reanudar después.
- Las fechas del filtro no pueden ser futuras ni anteriores a 1900, y «Desde» nunca es posterior a «Hasta».
- Al empezar se eliminan los temporales `.partial` que hubiera dejado una ejecución interrumpida.

## Red

La app vigila la conexión durante todo el proceso (`NWPathMonitor` + resultado de las descargas):

- **Sin conexión** (el Mac pierde la red): las descargas nuevas quedan en espera y aparece un aviso con cuenta atrás.
- **La red está fallando**: hay red, pero las descargas de iCloud fallan, o todas las descargas en curso llevan más de 20 s sin recibir ningún dato (descarga atascada).
- **Conexión inestable**: dos o más cortes o fallos en 3 minutos. Las descargas que fallen se reintentan.
- Si pasa **más de 1 minuto sin conexión útil**, se detienen todas las copias y borrados. Lo ya verificado se conserva y la próxima ejecución continúa donde se quedó.

## Mensajes y progreso

- Cada error se muestra en lenguaje coloquial, con un botón «Mostrar detalles técnicos» (dominio, código y nombre del error, p. ej. `PHPhotosErrorDomain 3169 (networkError)`) que se puede copiar.
- En el panel de actividad, cada elemento que se está copiando tiene su propia barra de progreso: descarga desde iCloud, copia, verificación, reintento o espera de red.
- Al detener (manualmente o por falta de red) aparece una barra con las operaciones en curso que faltan por terminar y el tiempo estimado.
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

## Diseño

La interfaz sigue la guía de Apple [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass): componentes estándar (formulario agrupado, barra de herramientas, inspector) para que el sistema aplique Liquid Glass, sin fondos personalizados, acción principal en la barra con `.glassProminent`, botones de icono con etiqueta de accesibilidad agrupados con `ToolbarSpacer`, y el registro de actividad en un inspector. En macOS 14–15 se usa el estilo equivalente previo.

## Estructura

```
Sources/OffloadCore/      lógica (sin UI)
  OffloadEngine.swift     pipeline: escaneo → copia → verificación → borrado
  ResourceExporter.swift  descarga en streaming + hash + escritura atómica
  Verifier.swift / FileHasher.swift  verificación SHA-256 desde disco
  Manifest.swift          registro JSONL para auditar y reanudar
  PhotoLibrary.swift      PhotoKit (permisos, búsqueda, borrado)
  PathBuilder.swift       nombres de archivo y carpetas, sin colisiones
  VolumeInfo.swift        solo discos externos físicos + espacio libre
  DateRange.swift         reglas de fechas realistas
  NetworkMonitor.swift    vigilancia de red, atascos y parada al minuto
  ErrorDescriber.swift    errores en lenguaje coloquial + detalle técnico
Sources/iCloudOffload/    interfaz SwiftUI
Tests/OffloadCoreTests/   pruebas unitarias
```
