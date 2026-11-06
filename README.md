# iCloud Offload

**English** · [Español](README.es.md)

A macOS app (SwiftUI) that **copies** your photos and videos from iCloud Photos to an external drive, **verifies** every file with SHA-256 and, if you allow it, **deletes** them from the library (and therefore from iCloud) to free up space.

![iCloud Offload icon](Icon/vista-previa.png)

> [!WARNING]
> **Use it at your own risk.** This app deletes photos and videos from your iCloud library. The basic features have been tested (copying, verification, deletion and rejecting internal disks), but **no extensive testing has been done** with large libraries, different macOS versions or a variety of drives. It may fail. Read the [disclaimer](#disclaimer) before using it.

## Why it exists

I have a MacBook with little storage and the basic iCloud plan. Over the years my photos and videos filled up iCloud, and I couldn't download them to the Mac to move them out because there was no room on the internal disk either.

I built this app to solve both problems at once: **free up iCloud space** and keep **physical copies** of my photos and videos on an external drive. It copies from iCloud to the external drive without having to download the whole library to the Mac, verifies each file, and only then deletes it from iCloud. If you're in the same situation, it may help you too.

## Build and run

```bash
./build.sh
open "build/iCloud Offload.app"
```

Requirements: macOS 14+, Xcode or Command Line Tools with Swift 5.10+. If you ever distribute a prebuilt app, sign it with a Developer ID certificate and notarize it; until then, building from source is the safest option. Tests: `swift test`.

## Languages

The app is available in **English** and **Spanish**: it follows the system language (any other language falls back to English). The strings live in `Resources/Localizable.xcstrings`; after changing strings in the code, run `scripts/update-strings.sh` and add the English translation for the new strings.

## How it works

1. **Scan**: reads the library with PhotoKit (optional filter by type and dates).
2. **Copy**: for each item it exports **all of its original resources** (photo, Live Photo video, edited version, RAW, adjustment data…). If the original is only in iCloud ("Optimize Mac Storage"), it is downloaded. Several downloads run at once (configurable).
   - Data is written to a hidden temporary file, flushed to disk (`F_FULLFSYNC`) and only then renamed. A half-written final file is never left behind.
   - Layout: `Destination/YYYY/MM/IMG_0001.HEIC`, `IMG_0001.MOV`, `IMG_0001_edited.heic`… The file's original date is preserved.
3. **Verification**: the SHA-256 is computed while the bytes arrive from Photos; then the file is **read back from disk** (uncached, `F_NOCACHE`) and hash and size are compared.
4. **Deletion** (optional, off by default): verified items are collected and deleted **in batches** while copying continues, so space is freed during the process. Files are verified again right before each batch.

## Copy log (manifest)

In the app it appears as "Copy Log". It is the file `Destination/.icloud-offload/manifest.jsonl`, with one JSON line per event: item copied and verified (files, sizes, SHA-256) or item deleted from iCloud (date and time). It is used to:

- **Resume**: what was already copied is not copied again.
- **Re-verify** the files before deleting anything from iCloud, including on later runs.
- **Audit** what was deleted from iCloud and when, and check in the future that the copies haven't been damaged.

Each line is **signed** (HMAC-SHA256) with a secret key created on first use and stored in the Mac's **Keychain**, never on the drive. If someone edits the log or swaps the copies on the drive, the signature no longer matches and the app doesn't trust that line. Lines without a valid signature (for example, from earlier versions of the app) are used to resume, but before deleting that item from iCloud the app downloads the original again, compares it with the copy and, if they don't match, copies it again.

The first time, and after rebuilding the app, macOS may ask you to let iCloud Offload use its Keychain key. If you deny it, the app keeps working, but it will check every previous copy against iCloud before deleting it.

## Safeguards

- An item is only deleted if **all** of its files have been copied and verified.
- **Only physical external drives are allowed** (USB, Thunderbolt, SD card). The startup disk, any folder on the internal disk, disk images (`.dmg`, which actually live on the internal disk) and network drives are rejected. The folder picker prevents it, and the engine checks again before and during copying (if the drive is disconnected, it stops).
- It stops if less than 2 GB is free on the external drive, or less than 3 GB on the internal disk: Photos temporarily stores the originals it downloads from iCloud there. You can resume afterwards.
- Filter dates can't be in the future or before 1900, and "From" is never after "To".
- On start, leftover `.partial` temporary files from an interrupted run are removed.

## Security

- **Hardened Runtime**: the app is signed with macOS's hardened runtime, which prevents other programs from injecting code into it (for example with `DYLD_INSERT_LIBRARIES`) and abusing its Photos access. The only declared entitlement is Photos access (`Resources/iCloudOffload.entitlements`).
- **The external drive is not trusted**: paths in the log can't leave the destination folder (`..`, absolute paths and symbolic links are rejected), and if a `YYYY/MM` folder on the drive is a link pointing elsewhere, the app won't copy there.
- **Before each deletion**, besides re-reading and comparing the files, the app checks that what is logged (number of files, types and original names) matches what Photos currently has for that item.
- **No third-party dependencies** and no network connections of its own: it only uses Apple frameworks.
- Copies are stored **unencrypted** on the external drive. If you're worried about someone accessing it, use a drive formatted as encrypted APFS.

## Network

The app monitors the connection throughout the process (`NWPathMonitor` + download results):

- **No connection** (the Mac loses the network): new downloads are put on hold and a warning with a countdown appears.
- **The network is failing**: there is a network, but iCloud downloads fail, or every download in progress has gone more than 20 s without receiving any data (stalled download).
- **Unstable connection**: two or more drops or failures within 3 minutes. Failed downloads are retried.
- If **more than 1 minute passes without a usable connection**, all copies and deletions stop. Everything already verified is kept and the next run continues where it left off.

## Messages and progress

- Every error is shown in plain language, with a "Show Technical Details" button (error domain, code and name, e.g. `PHPhotosErrorDomain 3169 (networkError)`) that can be copied.
- In the activity panel, each item being copied has its own progress bar: download from iCloud, copy, verification, retry or waiting for the network.
- When stopping (manually or because of the network) a bar shows the operations still in progress and the estimated time.
- Each item is retried up to 3 times; if it fails, it is not deleted.
- Cancelling never deletes anything more.
- If you decline the macOS deletion dialog, deletion is turned off and copying continues.

## Important limitations

- **"Recently Deleted"**: Photos keeps deleted items for 30 days. iCloud space isn't fully freed until you empty that folder (Photos › Recently Deleted). Apple doesn't let apps empty it.
- **System confirmation**: macOS asks you to confirm each deletion batch; this can't be avoided (it is an Apple protection). That's why batches are configurable (100 by default).
- **iCloud Photos must be turned on** on this Mac for deletions to reach iCloud and your other devices.
- **Full access** to Photos is required (not "limited").
- Shared albums and hidden photos are not included.
- Albums, faces and Photos-specific metadata (favorites, captions) are not copied; the EXIF metadata inside the file is.
- FAT32 drives don't support files larger than 4 GB: use APFS or exFAT.

## Recommendation

Do the first run **without** deletion, check the files on the drive, and then run it again with deletion turned on: already copied items are re-verified and deleted without downloading them again. Ideally, keep a second copy (another drive) before deleting from iCloud.

## Design

The interface follows Apple's [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) guide: standard components (grouped form, toolbar, inspector) so the system applies Liquid Glass, no custom backgrounds, the main action in the toolbar with `.glassProminent`, icon buttons with accessibility labels grouped with `ToolbarSpacer`, and the activity log in an inspector. On macOS 14–15 the equivalent earlier style is used.

## Structure

```
Sources/OffloadCore/      logic (no UI)
  OffloadEngine.swift     pipeline: scan → copy → verify → delete
  ResourceExporter.swift  streaming download + hash + atomic write
  Verifier.swift / FileHasher.swift  SHA-256 verification from disk
  Manifest.swift          signed JSONL log for auditing and resuming
  ManifestKey.swift       log signing key (Keychain)
  PathSafety.swift        paths and symbolic links that can't leave the destination
  PhotoLibrary.swift      PhotoKit (permissions, fetching, deletion)
  PathBuilder.swift       file and folder names, without collisions
  VolumeInfo.swift        physical external drives only + free space
  DateRange.swift         realistic date rules
  NetworkMonitor.swift    network monitoring, stalls and one-minute stop
  ErrorDescriber.swift    plain-language errors + technical details
Sources/iCloudOffload/    SwiftUI interface
Resources/Localizable.xcstrings  app strings in Spanish and English
scripts/update-strings.sh updates the string catalog from the code
Icon/AppIcon.icon         Liquid Glass icon (open it in Icon Composer to edit)
Icon/capas/               original SVG layers of the icon
Tests/OffloadCoreTests/   unit tests
```

## Disclaimer

This is a personal project, published as is, without warranties of any kind.

- The app **may have bugs**. The basic features have been tested, but not extensively or in every possible configuration.
- **I am not responsible** for any loss of photos, videos or other data, or for any damage resulting from using this app.
- **Before deleting anything from iCloud**, check for yourself that the copies on the external drive open correctly. The safest approach is to start with a small date range and with "Delete from iCloud after verifying" turned off, check the copies, and only then turn deletion on.
- Deleted items go to "Recently Deleted" in Photos for 30 days: that is your safety net. Don't empty that folder until you're sure about your copies.
- A single external drive is not a complete backup. Drives fail; consider keeping a second copy.
- This project is not affiliated with or endorsed by Apple. iCloud and Photos are trademarks of Apple Inc.

## License

[MIT](LICENSE) © 2026 Cristhian Ligio
