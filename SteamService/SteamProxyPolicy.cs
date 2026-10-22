using System.Net;
using SteamKit2;

namespace MotiscapeSteamService;

/// Process-lifetime policy supplied by the host app, never by remote responses.
internal sealed class SteamProxyPolicy
{
    internal static readonly SteamProxyPolicy Current = FromEnvironment();
    internal bool Enabled { get; }
    private readonly IWebProxy? proxy;

    internal SteamProxyPolicy(bool enabled, string? address)
    {
        Enabled = enabled;
        if (!enabled) return;
        if (!Uri.TryCreate(address, UriKind.Absolute, out var endpoint) || endpoint.Scheme != "http" ||
            string.IsNullOrEmpty(endpoint.Host) || endpoint.Port is < 1 or > 65535 ||
            !string.IsNullOrEmpty(endpoint.UserInfo) || endpoint.AbsolutePath != "/" ||
            !string.IsNullOrEmpty(endpoint.Query) || !string.IsNullOrEmpty(endpoint.Fragment))
            throw new InvalidOperationException("Invalid HTTP proxy configuration; direct connections are disabled.");
        proxy = new RequiredProxy(endpoint);
    }

    private static SteamProxyPolicy FromEnvironment()
    {
        var mode = Environment.GetEnvironmentVariable("MOTISCAPE_HTTP_PROXY_ENABLED");
        if (mode is not (null or "0" or "1"))
            throw new InvalidOperationException("Invalid HTTP proxy mode; refusing to start Steam networking.");
        return new SteamProxyPolicy(mode == "1", Environment.GetEnvironmentVariable("MOTISCAPE_HTTP_PROXY_URL"));
    }

    internal void Configure(ISteamConfigurationBuilder builder)
    {
        // TCP/UDP CM connections do not use HttpClient and must not be fallback paths.
        if (Enabled) builder.WithProtocolTypes(ProtocolTypes.WebSocket);
    }
    internal void Apply(SocketsHttpHandler handler)
    {
        if (!Enabled) return;
        handler.UseProxy = true;
        handler.Proxy = proxy;
    }
    internal void Apply(HttpClientHandler handler)
    {
        if (!Enabled) return;
        handler.UseProxy = true;
        handler.Proxy = proxy;
    }

    /// WebProxy may bypass local destinations. This policy has no bypass list,
    /// including for loopback, and ignores HTTP_PROXY/NO_PROXY inherited by dotnet.
    private sealed class RequiredProxy(Uri endpoint) : IWebProxy
    {
        public ICredentials? Credentials { get; set; }
        public Uri GetProxy(Uri destination) => endpoint;
        public bool IsBypassed(Uri host) => false;
    }
}
