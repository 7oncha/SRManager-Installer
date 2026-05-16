using System.IO;
using System.Net.Http;
using System.Text.Json;
using SRManager.Models;

namespace SRManager.Services;

public sealed class ConfigService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    private readonly HttpClient _http;

    public ConfigService(HttpClient http)
    {
        _http = http;
    }

    public string BaseDirectory { get; } = AppContext.BaseDirectory;
    public string ConfigPath => Path.Combine(BaseDirectory, "sr_config.json");
    public string SharedConfigPath => Path.Combine(BaseDirectory, "sr_shared_config.json");
    public string WebUrl { get; private set; } = "https://slavonska-ravnica.com";
    public string DiscordUrl { get; private set; } = "https://discord.gg/slavonskaravnica";

    public async Task<LauncherConfig> LoadAsync(CancellationToken cancellationToken = default)
    {
        LauncherConfig? config = null;
        if (File.Exists(ConfigPath))
        {
            try
            {
                await using var stream = File.OpenRead(ConfigPath);
                config = await JsonSerializer.DeserializeAsync<LauncherConfig>(stream, JsonOptions, cancellationToken);
            }
            catch
            {
                config = null;
            }
        }

        config ??= CreateDefaultConfig();
        Normalize(config);
        await SaveAsync(config, cancellationToken);
        return config;
    }

    public async Task SaveAsync(LauncherConfig config, CancellationToken cancellationToken = default)
    {
        Normalize(config);
        Directory.CreateDirectory(BaseDirectory);
        await using var stream = File.Create(ConfigPath);
        await JsonSerializer.SerializeAsync(stream, config, JsonOptions, cancellationToken);
    }

    public async Task<bool> SyncSharedConfigAsync(LauncherConfig config, CancellationToken cancellationToken = default)
    {
        SharedConfig? shared = await TryDownloadSharedAsync("https://raw.githubusercontent.com/7oncha/SRManager-Installer/master/sr_shared_config.json", cancellationToken)
            ?? await TryDownloadSharedAsync("https://slavonska-ravnica.com/sr_shared_config.json", cancellationToken)
            ?? await TryReadLocalSharedAsync(cancellationToken);

        if (shared?.Servers is not { Count: > 0 })
        {
            return false;
        }

        MergeSharedConfig(config, shared);
        await SaveAsync(config, cancellationToken);
        return true;
    }

    public ServerConfig GetActiveServer(LauncherConfig config)
    {
        Normalize(config);
        return config.Servers[config.ActiveServer];
    }

    public LicenseApiConfig? GetLicenseApi(LauncherConfig config)
    {
        if (config.LicenseApi?.IsConfigured == true)
        {
            return new LicenseApiConfig
            {
                Url = config.LicenseApi.Url.TrimEnd('/'),
                Token = config.LicenseApi.Token
            };
        }

        return null;
    }

    private async Task<SharedConfig?> TryReadLocalSharedAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(SharedConfigPath))
        {
            return null;
        }

        try
        {
            await using var stream = File.OpenRead(SharedConfigPath);
            return await JsonSerializer.DeserializeAsync<SharedConfig>(stream, JsonOptions, cancellationToken);
        }
        catch
        {
            return null;
        }
    }

    private async Task<SharedConfig?> TryDownloadSharedAsync(string url, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.UserAgent.ParseAdd("SRManager-CSharp");
            using var response = await _http.SendAsync(request, cancellationToken);
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            return await JsonSerializer.DeserializeAsync<SharedConfig>(stream, JsonOptions, cancellationToken);
        }
        catch
        {
            return null;
        }
    }

    private void MergeSharedConfig(LauncherConfig config, SharedConfig shared)
    {
        foreach (var remote in shared.Servers)
        {
            var local = config.Servers.FirstOrDefault(s => s.Name.Equals(remote.Name, StringComparison.OrdinalIgnoreCase));
            if (local is null)
            {
                config.Servers.Add(remote);
                continue;
            }

            local.Id = remote.Id;
            local.Ip = remote.Ip;
            local.WebPort = remote.WebPort;
            local.GamePort = remote.GamePort;
            local.StatsCode = remote.StatsCode;
            if (!string.IsNullOrWhiteSpace(remote.Password))
            {
                local.Password = remote.Password;
            }
        }

        var remoteNames = shared.Servers.Select(s => s.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        config.Servers = config.Servers
            .Where(s => s.IsCustom || remoteNames.Contains(s.Name))
            .ToList();

        if (!string.IsNullOrWhiteSpace(shared.WebUrl))
        {
            WebUrl = shared.WebUrl;
        }

        if (!string.IsNullOrWhiteSpace(shared.DiscordUrl))
        {
            DiscordUrl = shared.DiscordUrl;
        }

        if (!string.IsNullOrWhiteSpace(shared.GithubRepo))
        {
            config.GithubRepo = NormalizeGithubRepo(shared.GithubRepo);
        }

        if (shared.LicenseApi?.IsConfigured == true)
        {
            config.LicenseApi = shared.LicenseApi;
        }

        Normalize(config);
    }

    private static LauncherConfig CreateDefaultConfig() => new()
    {
        Servers =
        [
            new ServerConfig
            {
                Name = "Slavonska Ravnica",
                Ip = "176.57.169.250",
                WebPort = 8620,
                GamePort = 11363,
                StatsCode = "oXuXiWxTnqiShUny",
                Password = "ravnica"
            }
        ]
    };

    private static void Normalize(LauncherConfig config)
    {
        if (config.Servers.Count == 0)
        {
            config.Servers = CreateDefaultConfig().Servers;
        }

        config.ActiveServer = Math.Clamp(config.ActiveServer, 0, config.Servers.Count - 1);
        config.GithubRepo = NormalizeGithubRepo(config.GithubRepo);
    }

    private static string NormalizeGithubRepo(string? repo)
    {
        if (string.IsNullOrWhiteSpace(repo))
        {
            return "7oncha/SRManager-Installer";
        }

        return repo.Trim()
            .Replace("https://github.com/", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Trim('/');
    }
}
