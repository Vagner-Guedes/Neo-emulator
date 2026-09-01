using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class RuntimeStateService
{
    private readonly object _sync = new();
    private RuntimeState _current = RuntimeState.Stopped;

    public RuntimeState Current
    {
        get { lock (_sync) return _current; }
    }

    public event EventHandler<RuntimeState>? Changed;

    public void Set(RuntimeState state)
    {
        lock (_sync) _current = state;
        Changed?.Invoke(this, state);
    }
}
