# QEMU benchmark

The legacy AVD benchmark scripts remain available for historical comparison.
The commercial runtime path uses the QEMU-specific scripts below.

`Measure-QemuAndroidRuntime.ps1` starts the configured persistent qcow2 with
WHPX, waits for ADB TCP and `sys.boot_completed=1`, then records Android
release/API/ABI, display configuration, `dumpsys meminfo`, `dumpsys gfxinfo`,
package presence, and the QEMU shutdown result.

```powershell
.\scripts\benchmark\Measure-QemuAndroidRuntime.ps1 `
  -ReportPath .\reports\qemu-baseline.json
```

`Run-QemuNeoNewsBenchmark.ps1` repeats the same boot/shutdown cycle and reports
boot min/average/max plus stability across all iterations. It does not install,
uninstall, clear data, or recreate the qcow2 disk.

```powershell
.\scripts\benchmark\Run-QemuNeoNewsBenchmark.ps1 `
  -Iterations 3 `
  -ReportPath .\reports\qemu-benchmark.json
```

Both scripts fail when QEMU, the configured ADB, the persistent disk, or WHPX
is missing. Shutdown uses QMP and never uses `adb emu kill`.
