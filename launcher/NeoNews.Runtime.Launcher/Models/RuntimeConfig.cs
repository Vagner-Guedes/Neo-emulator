using System.Text.Json.Serialization;

namespace NeoNews.Runtime.Launcher.Models;

public sealed class RuntimeConfig
{
    public int SchemaVersion { get; set; } = 1;
    public ReleaseConfig Release { get; set; } = new();
    public RuntimeSettings Runtime { get; set; } = new();
    public RuntimeTimeoutConfig Timeouts { get; set; } = new();
    public AndroidConfig Android { get; set; } = new();
    [JsonPropertyName("neonews")]
    public NeoNewsConfig NeoNews { get; set; } = new();
    public WebViewConfig WebView { get; set; } = new();
    public TtsConfig Tts { get; set; } = new();
    public SupervisorConfig Supervisor { get; set; } = new();
    public StartupConfig Startup { get; set; } = new();
    public LauncherConfig Launcher { get; set; } = new();
    public DiagnosticsConfig Diagnostics { get; set; } = new();
    public ResilienceConfig Resilience { get; set; } = new();
    public BenchmarkConfig Benchmark { get; set; } = new();
    public QualityConfig Quality { get; set; } = new();
}

public sealed class ReleaseConfig
{
    public string Status { get; set; } = string.Empty;
    public string FinalReport { get; set; } = string.Empty;
}

public sealed class RuntimeSettings
{
    public string Name { get; set; } = "NeoNews Digital Signage Runtime";
    public string Environment { get; set; } = "production";
    public string Timezone { get; set; } = "America/Bahia";
    public string Hotkey { get; set; } = "Ctrl+Alt+Shift+F12";
}

public sealed class RuntimeTimeoutConfig
{
    public int AdbSeconds { get; set; } = 30;
    public int BootSeconds { get; set; } = 180;
    public int NeoNewsStartSeconds { get; set; } = 120;
    public int InstallSeconds { get; set; } = 600;
    public int EmulatorStopSeconds { get; set; } = 20;
}

public sealed class AndroidConfig
{
    public int ApiLevel { get; set; } = 25;
    public string Release { get; set; } = "7.1.1";
    public string ImageVariant { get; set; } = "google_apis";
    public string PreferredAbi { get; set; } = "x86";
    public string PreferredImage { get; set; } = string.Empty;
    public string PreferredAvd { get; set; } = "NeoNews_API25_x86";
    public List<string> FallbackAvds { get; set; } = [];
    [JsonPropertyName("abiValidation")]
    public AbiValidationConfig AbiValidation { get; set; } = new();
    public ToolingConfig Tooling { get; set; } = new();
    public EmulatorConfig Emulator { get; set; } = new();
    public OptimizationConfig Optimization { get; set; } = new();
    public KioskConfig Kiosk { get; set; } = new();
}

public sealed class AbiValidationConfig
{
    public string Status { get; set; } = string.Empty;
    public List<string> ApkAbis { get; set; } = [];
    public string X86InstallResult { get; set; } = string.Empty;
    public string X86NativeBridge { get; set; } = string.Empty;
    public string Arm32LegacyInstallResult { get; set; } = string.Empty;
    public bool Validated { get; set; }
    public string Report { get; set; } = string.Empty;
}

public sealed class ToolingConfig
{
    public string SdkRoot { get; set; } = "runtime/android-sdk";
    public string AdbRelativePath { get; set; } = "platform-tools/adb.exe";
    public string EmulatorRelativePath { get; set; } = "emulator/emulator.exe";
    public bool AllowEnvironmentFallback { get; set; } = true;
}

public sealed class EmulatorConfig
{
    public string Acceleration { get; set; } = "auto";
    public string Gpu { get; set; } = "swiftshader";
    public bool NoBootAnimation { get; set; } = true;
    public string SnapshotPolicy { get; set; } = "quick-boot-with-cold-boot-fallback";
    public int ValidationPort { get; set; } = 5556;
    public bool ShowWindow { get; set; } = true;
}

public sealed class OptimizationConfig
{
    public ScreenConfig Screen { get; set; } = new();
    public int RamMb { get; set; } = 2048;
    public int CpuCores { get; set; } = 4;
    public string DataPartitionSize { get; set; } = "8192M";
    public string GpuMode { get; set; } = "swiftshader_indirect";
    public bool AudioInput { get; set; } = true;
    public bool AudioOutput { get; set; } = true;
    public string Profile { get; set; } = "signage-landscape";
    public string BenchmarkScript { get; set; } = string.Empty;
}

public sealed class ScreenConfig
{
    public int Width { get; set; } = 1920;
    public int Height { get; set; } = 1080;
    public int Density { get; set; } = 160;
}

public sealed class KioskConfig
{
    public string DisplaySize { get; set; } = "1920x1080";
    public int DisplayDensity { get; set; } = 160;
    public string ImmersivePolicy { get; set; } = "immersive.full=*";
    public int ScreenOffTimeoutMs { get; set; } = int.MaxValue;
    public int StayAwakePluggedIn { get; set; } = 3;
    public string Orientation { get; set; } = "landscape";
    public string Status { get; set; } = string.Empty;
    public int MonitorIndex { get; set; }
}

public sealed class NeoNewsConfig
{
    public string PackageName { get; set; } = "com.in9midia.neonews.player";
    public string ApkPath { get; set; } = "packages/neonews/neonews.apk";
    public string VersionName { get; set; } = string.Empty;
    public int VersionCode { get; set; }
    public string LaunchActivity { get; set; } = "com.in9midia.neonews.player.TerminalActivity";
    public string IntegrationStatus { get; set; } = string.Empty;
    public string ValidationScript { get; set; } = string.Empty;
    public List<string> SupportedApkAbis { get; set; } = [];
    public string SigningCertificateSha256 { get; set; } = string.Empty;
}

public sealed class WebViewConfig
{
    public string Provider { get; set; } = "com.google.android.webview";
    public string HomologatedVersion { get; set; } = string.Empty;
    public string InstalledVersion { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public bool Validated { get; set; }
    public string Report { get; set; } = string.Empty;
}

public sealed class TtsConfig
{
    public string Locale { get; set; } = "pt-BR";
    public string Engine { get; set; } = "RHVoice";
    public List<string> AvailableEngines { get; set; } = [];
    public bool RhvoicePresent { get; set; }
    public string Status { get; set; } = string.Empty;
    public bool Validated { get; set; }
    public string Report { get; set; } = string.Empty;
}

public sealed class SupervisorConfig
{
    public int PollSeconds { get; set; } = 5;
    public bool RestartOnActivityLoss { get; set; } = true;
    public string LogPath { get; set; } = "logs/supervisor.log";
    public string Script { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
}

public sealed class StartupConfig
{
    public string TaskName { get; set; } = "NeoNews Runtime Supervisor";
    public int LogonDelaySeconds { get; set; } = 30;
    public string Script { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public bool StartWithWindows { get; set; }
    public bool StartNeoNews { get; set; } = true;
    public bool AutoKiosk { get; set; } = true;
}

public sealed class LauncherConfig
{
    public string Project { get; set; } = string.Empty;
    public string OutputName { get; set; } = "NeoNewsRuntime.exe";
    public string Version { get; set; } = "1.0.0";
    public string Status { get; set; } = string.Empty;
}

public sealed class DiagnosticsConfig
{
    public string Script { get; set; } = string.Empty;
    public string DefaultReport { get; set; } = "reports/diagnostics.json";
    public string Status { get; set; } = string.Empty;
}

public sealed class ResilienceConfig
{
    public int MaxAttempts { get; set; } = 3;
    public int RetryDelaySeconds { get; set; } = 5;
    public string LockPath { get; set; } = "runtime/neonews-runtime.lock";
    public string LogPath { get; set; } = "logs/resilience.log";
    public string Script { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
}

public sealed class BenchmarkConfig
{
    public string Script { get; set; } = string.Empty;
    public int DefaultIterations { get; set; } = 3;
    public string Status { get; set; } = string.Empty;
}

public sealed class QualityConfig
{
    public string Script { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
}
