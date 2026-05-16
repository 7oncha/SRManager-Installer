using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using SRManager.Models;

namespace SRManager.Services;

public sealed class ModService
{
    private readonly HttpClient _http;
    private readonly ConfigService _configService;

    public ModService(HttpClient http, ConfigService configService)
    {
        _http = http;
        _configService = configService;
    }

    public async Task<List<ModManifestItem>?> GetServerModsAsync(LauncherConfig config, ServerConfig server, CancellationToken cancellationToken = default)
    {
        var manifest = await GetManifestFromBotAsync(config, server, cancellationToken);
        if (manifest is { Count: > 0 })
        {
            foreach (var mod in manifest.Where(m => string.IsNullOrWhiteSpace(m.Url)))
            {
                mod.Url = $"http://{server.Ip}:{server.WebPort}/mods/{Uri.EscapeDataString(mod.Name)}";
            }

            return manifest;
        }

        return await ScrapeModsHtmlAsync(server, cancellationToken);
    }

    public async Task<List<ModListItem>> CompareAsync(LauncherConfig config, ServerConfig server, CancellationToken cancellationToken = default)
    {
        var serverMods = await GetServerModsAsync(config, server, cancellationToken) ?? [];
        var localFiles = Directory.Exists(config.ModsPath)
            ? Directory.GetFiles(config.ModsPath, "*.zip").Select(path => new FileInfo(path)).ToList()
            : [];

        var result = new List<ModListItem>();
        var localByName = localFiles.ToDictionary(f => f.Name, StringComparer.OrdinalIgnoreCase);
        var missingOrOutdated = 0;

        foreach (var serverMod in serverMods)
        {
            var fileName = serverMod.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)
                ? serverMod.Name
                : $"{serverMod.Name}.zip";
            var displayName = Path.GetFileNameWithoutExtension(fileName);

            if (!localByName.TryGetValue(fileName, out var local))
            {
                missingOrOutdated++;
                result.Add(new ModListItem
                {
                    Status = "FALI",
                    Name = displayName,
                    Local = "Ne",
                    Server = "Da",
                    Size = "-",
                    FileName = fileName
                });
                continue;
            }

            var outdated = await IsOutdatedAsync(config, local, serverMod, cancellationToken);
            if (outdated)
            {
                missingOrOutdated++;
                result.Add(new ModListItem
                {
                    Status = "ZASTARIO",
                    Name = displayName,
                    Local = "Da",
                    Server = serverMod.Size > 0 ? $"Da ({FormatSize(serverMod.Size)})" : "Da (azurirano)",
                    Size = FormatSize(local.Length),
                    FileName = fileName
                });
            }
            else
            {
                result.Add(new ModListItem
                {
                    Status = "OK",
                    Name = displayName,
                    Local = "Da",
                    Server = "Da",
                    Size = FormatSize(local.Length),
                    FileName = fileName
                });
            }
        }

        var serverNames = serverMods
            .Select(m => m.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) ? m.Name : $"{m.Name}.zip")
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var extra in localFiles.Where(f => !serverNames.Contains(f.Name)))
        {
            result.Add(new ModListItem
            {
                Status = "Extra",
                Name = Path.GetFileNameWithoutExtension(extra.Name),
                Local = "Da",
                Server = "Ne",
                Size = FormatSize(extra.Length),
                FileName = extra.Name
            });
        }

        config.LastSync = DateTime.Now.ToString("dd.MM.yyyy HH:mm", CultureInfo.InvariantCulture);
        return result;
    }

    public async Task<int> DownloadMissingAsync(
        LauncherConfig config,
        ServerConfig server,
        IEnumerable<ModListItem> currentItems,
        Action<string>? progress,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(config.ModsPath))
        {
            throw new InvalidOperationException("Mods folder nije postavljen.");
        }

        Directory.CreateDirectory(config.ModsPath);
        var needed = currentItems
            .Where(i => i.Status is "FALI" or "ZASTARIO")
            .Select(i => i.FileName)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (needed.Count == 0)
        {
            return 0;
        }

        var serverMods = await GetServerModsAsync(config, server, cancellationToken) ?? [];
        var downloaded = 0;
        foreach (var fileName in needed)
        {
            var mod = serverMods.FirstOrDefault(m =>
                m.Name.Equals(fileName, StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileNameWithoutExtension(m.Name).Equals(Path.GetFileNameWithoutExtension(fileName), StringComparison.OrdinalIgnoreCase));
            if (mod is null || string.IsNullOrWhiteSpace(mod.Url))
            {
                continue;
            }

            progress?.Invoke($"Skidam {mod.Name}...");
            var destination = Path.Combine(config.ModsPath, fileName);
            using var response = await _http.GetAsync(mod.Url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            response.EnsureSuccessStatusCode();
            await using var remote = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using var local = File.Create(destination);
            await remote.CopyToAsync(local, cancellationToken);
            downloaded++;
        }

        progress?.Invoke($"Skinuto {downloaded}/{needed.Count} modova.");
        return downloaded;
    }

    public static string FormatSize(long bytes)
    {
        if (bytes >= 1024L * 1024L * 1024L)
        {
            return $"{bytes / 1024d / 1024d / 1024d:N1} GB";
        }

        return $"{bytes / 1024d / 1024d:N1} MB";
    }

    private async Task<List<ModManifestItem>?> GetManifestFromBotAsync(LauncherConfig config, ServerConfig server, CancellationToken cancellationToken)
    {
        var api = _configService.GetLicenseApi(config);
        if (api is null)
        {
            return null;
        }

        try
        {
            var serverId = string.IsNullOrWhiteSpace(server.Id) ? server.Name : server.Id;
            var url = $"{api.Url}/api/mods/manifest?server={Uri.EscapeDataString(serverId)}";
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", api.Token);
            using var response = await _http.SendAsync(request, cancellationToken);
            response.EnsureSuccessStatusCode();
            var json = await response.Content.ReadAsStringAsync(cancellationToken);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True || !root.TryGetProperty("mods", out var mods))
            {
                return null;
            }

            var result = new List<ModManifestItem>();
            foreach (var mod in mods.EnumerateArray())
            {
                result.Add(new ModManifestItem
                {
                    Name = ReadString(mod, "name"),
                    Sha256 = ReadString(mod, "sha256").ToLowerInvariant(),
                    Size = ReadLong(mod, "size"),
                    Version = ReadString(mod, "version"),
                    UpdatedAt = ReadString(mod, "updatedAt"),
                    Source = "bot"
                });
            }

            return result.Where(m => !string.IsNullOrWhiteSpace(m.Name)).ToList();
        }
        catch
        {
            return null;
        }
    }

    private async Task<List<ModManifestItem>?> ScrapeModsHtmlAsync(ServerConfig server, CancellationToken cancellationToken)
    {
        try
        {
            var baseUri = new Uri($"http://{server.Ip}:{server.WebPort}/");
            var html = await _http.GetStringAsync(new Uri(baseUri, "mods.html"), cancellationToken);
            var result = new List<ModManifestItem>();
            foreach (Match match in Regex.Matches(html, "href=\"([^\"]*?([^/\\\"]+\\.zip))\"", RegexOptions.IgnoreCase))
            {
                var href = match.Groups[1].Value;
                var name = match.Groups[2].Value;
                var absolute = Uri.TryCreate(href, UriKind.Absolute, out var parsed)
                    ? parsed
                    : new Uri(baseUri, href.TrimStart('/'));
                if (result.All(m => !m.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
                {
                    result.Add(new ModManifestItem
                    {
                        Name = name,
                        Url = absolute.ToString(),
                        Source = "html"
                    });
                }
            }

            return result;
        }
        catch
        {
            return null;
        }
    }

    private async Task<bool> IsOutdatedAsync(LauncherConfig config, FileInfo local, ModManifestItem serverMod, CancellationToken cancellationToken)
    {
        if (!string.IsNullOrWhiteSpace(serverMod.Sha256))
        {
            if (serverMod.Size > 0 && Math.Abs(local.Length - serverMod.Size) > 1024)
            {
                return true;
            }

            var localHash = await GetLocalHashAsync(config, local, cancellationToken);
            return !localHash.Equals(serverMod.Sha256, StringComparison.OrdinalIgnoreCase);
        }

        var serverSize = await TryGetRemoteSizeAsync(serverMod.Url, cancellationToken);
        return serverSize > 0 && Math.Abs(local.Length - serverSize) > 1024;
    }

    private async Task<string> GetLocalHashAsync(LauncherConfig config, FileInfo file, CancellationToken cancellationToken)
    {
        var sig = $"{file.Length}|{file.LastWriteTimeUtc.Ticks}";
        if (config.ModHashCache.TryGetValue(file.FullName, out var cached) &&
            cached.Sig == sig &&
            !string.IsNullOrWhiteSpace(cached.Sha))
        {
            return cached.Sha;
        }

        await using var stream = file.OpenRead();
        var bytes = await SHA256.HashDataAsync(stream, cancellationToken);
        var hash = Convert.ToHexString(bytes).ToLowerInvariant();
        config.ModHashCache[file.FullName] = new ModHashCacheEntry { Sig = sig, Sha = hash };
        return hash;
    }

    private async Task<long> TryGetRemoteSizeAsync(string url, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(url))
        {
            return 0;
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, url);
            using var response = await _http.SendAsync(request, cancellationToken);
            return response.Content.Headers.ContentLength ?? 0;
        }
        catch
        {
            return 0;
        }
    }

    private static string ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null ? value.ToString() : string.Empty;

    private static long ReadLong(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt64(out var parsed) ? parsed : 0;
}
