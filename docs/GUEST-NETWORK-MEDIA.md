# Guest network, HLS and offline probe

`Test-GuestNetworkMedia.ps1` is a live Android API 25 probe for the QEMU
guest. It builds a temporary local APK and validates, in order:

1. DNS resolution plus HTTP and HTTPS responses;
2. an HLS playlist containing `#EXTM3U`;
3. actual HLS preparation and playback through Android `MediaPlayer`;
4. a non-empty cached response;
5. reading that cache while the QEMU virtual NIC is disabled through QMP and
   confirming that the network request fails.

The probe does not modify NeoNews, clear application data, recreate the qcow2,
or use `adb emu kill`. The NIC is restored in a `finally` block. The QEMU
runtime and benchmark assign the network device the stable QMP id
`neonewsnic` for this reversible offline test.

Run it only after the QEMU guest is booted and provisioned:

```powershell
.\scripts\validation\Test-GuestNetworkMedia.ps1 `
  -HlsUrl https://your-approved-host.example/live.m3u8 `
  -ReportPath .\reports\guest-network-media.json
```

`-HlsUrl` is intentionally required for a live run so the operator chooses an
approved stream instead of relying on an undocumented public fixture. Use
`-BuildOnly` to validate the local API 25 build toolchain without ADB or
network access.

This probe validates guest networking and media capabilities. It is not, by
itself, evidence that the proprietary NeoNews activity rendered a particular
playlist; that must still be recorded in the combined NeoNews stability and
content run.
