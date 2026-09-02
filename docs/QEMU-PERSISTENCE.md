# Persistent qcow2 validation

`Test-QemuPersistence.ps1` boots the configured QEMU guest, writes a unique
marker to `/sdcard/NeoNewsRuntime/persistence-marker.txt`, shuts QEMU down via
QMP, boots the same qcow2 again, reads the marker, and shuts the process down
again. It never recreates the disk, clears data, uninstalls NeoNews, or uses
`adb emu kill`.

```powershell
.\scripts\validation\Test-QemuPersistence.ps1 `
  -ReportPath .\reports\qemu-persistence.json
```

This proves guest-storage persistence across QEMU process restarts. It is not a
substitute for a later run that records a real NeoNews preference or downloaded
asset surviving Android, Windows, and launcher restarts; that evidence must be
collected with the official application installed.
