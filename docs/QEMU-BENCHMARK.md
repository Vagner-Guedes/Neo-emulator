# QEMU benchmark

The legacy AVD benchmark scripts remain available for historical comparison.
The commercial runtime path uses the QEMU-specific scripts below.

`Measure-QemuAndroidRuntime.ps1` starts the configured persistent qcow2 with
WHPX, records the ADB-ready and `sys.boot_completed=1` milestones, starts the
installed NeoNews activity, samples QEMU working set/private memory and CPU in
an idle phase and an application-workload phase, captures Android release/API/
ABI/display/memory/graphics data, and runs a prolonged activity stability
window before requesting QMP shutdown.

```powershell
.\scripts\benchmark\Measure-QemuAndroidRuntime.ps1 `
  -ReportPath .\reports\qemu-baseline.json
```

`Run-QemuNeoNewsBenchmark.ps1` repeats the same boot, NeoNews launch, workload,
stability and shutdown cycle. It reports ADB-ready, ADB-to-boot, boot-to-app,
boot min/average/max, host memory/CPU samples, and stability across all
iterations. It does not install, uninstall, clear data, or recreate the qcow2
disk; the official APK and guest components must already be provisioned.

```powershell
.\scripts\benchmark\Run-QemuNeoNewsBenchmark.ps1 `
  -Iterations 3 `
  -ReportPath .\reports\qemu-benchmark.json
```

Both scripts fail when QEMU, the configured ADB, the persistent disk, or WHPX
is missing, or when the configured Android release/API or NeoNews activity is
not stable. Use `-StabilitySeconds` to set the evidence window explicitly.
The final homologation checklist requires a Native Bridge evidence report with
at least 600 seconds of observed stability; a short smoke or baseline window
does not approve the release.
Shutdown uses QMP and never uses `adb emu kill`.
