using System.Text.Json.Serialization;

namespace SRManager.Models;

public sealed class LauncherConfig
{
    public string Version { get; set; } = "3.0";
    public string AdminHash { get; set; } = string.Empty;
    public string GamePath { get; set; } = string.Empty;
    public string ModsPath { get; set; } = string.Empty;
    public int ActiveServer { get; set; }
    public string LastSync { get; set; } = string.Empty;
    public string GithubRepo { get; set; } = "7oncha/SRManager-Installer";
    public string? LastLaunchAt { get; set; }
    public bool IntroScene { get; set; } = true;
    public bool DeveloperConsole { get; set; }
    public LicenseApiConfig? LicenseApi { get; set; }
    public List<ServerConfig> Servers { get; set; } = [];
    public Dictionary<string, ModHashCacheEntry> ModHashCache { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class SharedConfig
{
    public List<ServerConfig> Servers { get; set; } = [];
    public string? WebUrl { get; set; }
    public string? DiscordUrl { get; set; }
    public string? GithubRepo { get; set; }
    public LicenseApiConfig? LicenseApi { get; set; }
}

public sealed class LicenseApiConfig
{
    public string Url { get; set; } = string.Empty;
    public string Token { get; set; } = string.Empty;

    [JsonIgnore]
    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(Url) &&
        !string.IsNullOrWhiteSpace(Token) &&
        !Url.Contains("REPLACE", StringComparison.OrdinalIgnoreCase) &&
        !Token.Contains("REPLACE", StringComparison.OrdinalIgnoreCase);
}

public sealed class ServerConfig
{
    public string? Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Ip { get; set; } = string.Empty;
    public int WebPort { get; set; }
    public int GamePort { get; set; }
    public string StatsCode { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public bool IsCustom { get; set; }
}

public sealed class PlayerStatus
{
    public string Name { get; set; } = string.Empty;
    public int UptimeMinutes { get; set; }
    public bool IsAdmin { get; set; }
    public string UptimeText => UptimeMinutes >= 60
        ? $"{UptimeMinutes / 60}h {UptimeMinutes % 60}m"
        : $"{UptimeMinutes} min";
}

public sealed class ServerStatus
{
    public bool Online { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Map { get; set; } = string.Empty;
    public int PlayersOnline { get; set; }
    public int PlayersMax { get; set; }
    public string GameVersion { get; set; } = string.Empty;
    public List<PlayerStatus> Players { get; set; } = [];
}

public sealed class ModManifestItem
{
    public string Name { get; set; } = string.Empty;
    public string Url { get; set; } = string.Empty;
    public string Sha256 { get; set; } = string.Empty;
    public long Size { get; set; }
    public string Version { get; set; } = string.Empty;
    public string UpdatedAt { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;
}

public sealed class ModListItem
{
    public string Status { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Local { get; set; } = string.Empty;
    public string Server { get; set; } = string.Empty;
    public string Size { get; set; } = string.Empty;
    public string FileName { get; set; } = string.Empty;
}

public sealed class ModHashCacheEntry
{
    public string Sig { get; set; } = string.Empty;
    public string Sha { get; set; } = string.Empty;
}

public sealed class LatestVersion
{
    public string Version { get; set; } = string.Empty;
    public string Url { get; set; } = string.Empty;
    public string DownloadUrl { get; set; } = string.Empty;
    public string File { get; set; } = string.Empty;
    public string Notes { get; set; } = string.Empty;
    public string Sha256 { get; set; } = string.Empty;
}
