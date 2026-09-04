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

Both scripts fail when QEMU, the configured ADB, the approved Android image,
the persistent disk, the provisioning state, or WHPX is missing, or when the
configured Android release/API or NeoNews activity is not stable. They also
recheck the registered hashes of QEMU, ADB and the image before recording
evidence. Use `-StabilitySeconds` to set the evidence window explicitly.
The final homologation checklist requires a Native Bridge evidence report with
at least 600 seconds of observed stability; a short smoke or baseline window
does not approve the release.
Shutdown negotiates QMP, confirms the positive response to `quit`, and never
uses `adb emu kill`. The response reader skips asynchronous QMP events and
accepts only the `return`/`error` message associated with each command.

## Evidência atual — runtime WebView 119

Em 04/09/2026, na cópia descartável publicada em
`tmp/NeoNewsRuntime-CycleTest`, foram concluídos três ciclos com o qcow2
`webview-integration-119.qcow2`: boot Android 7.1.2/API 25, ADB TCP privado
`127.0.0.1:5556`, NeoNews presente, `primaryCpuAbi=armeabi-v7a`,
`TerminalActivity` em primeiro plano por 60 segundos e desligamento QMP sem
força em todos os ciclos. O relatório bruto foi
`tmp/NeoNewsRuntime-CycleTest/reports/qemu-runtime-cycles-final.json`.

O benchmark também reinicia apenas o daemon ADB privado na porta 5038 entre
iterações. Isso evita que um serial TCP antigo permaneça `offline` depois de
um shutdown do QEMU e não interfere no daemon ADB global da máquina.
