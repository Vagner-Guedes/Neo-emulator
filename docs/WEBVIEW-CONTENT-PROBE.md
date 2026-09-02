# WebView content probe

`Test-WebViewContent.ps1` is the functional probe for the configured WebView
provider. It checks the provider package and exact version, then installs a
temporary local probe APK with `adb install -r`.

The probe has two phases:

1. render local HTML, apply CSS, and execute JavaScript;
2. load an HTTPS URL and confirm a non-empty document body.

The report status is `validated` only when the provider version and both content
phases pass. The APK is a temporary debug probe and is kept by default so the
test does not perform a destructive guest operation. Use `-CleanupProbe` only
when an operator explicitly wants to remove it; `-KeepProbe` remains accepted
for compatibility. It does not alter the official NeoNews APK.

```powershell
.\scripts\validation\Test-WebViewContent.ps1 `
  -ContentUrl https://example.com `
  -ReportPath .\reports\webview-content.json
```

For an offline compile check, use the local Android SDK without a running
guest:

```powershell
.\scripts\validation\Test-WebViewContent.ps1 `
  -SdkRoot C:\Users\<user>\AppData\Local\Android\Sdk `
  -BuildOnly
```

This build-only mode proves the probe packaging toolchain, not WebView runtime
homologation. A live result still requires the QEMU Android-x86 API 25 guest,
the configured WebView 119 package, network access, and ADB TCP.
