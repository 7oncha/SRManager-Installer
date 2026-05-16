using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using SRManager.Models;

namespace SRManager.Services;

public sealed class LicenseService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };
    private readonly HttpClient _http;
    private readonly ConfigService _configService;
    private readonly GameSettingsService _gameSettingsService;

    public LicenseService(HttpClient http, ConfigService configService, GameSettingsService gameSettingsService)
    {
        _http = http;
        _configService = configService;
        _gameSettingsService = gameSettingsService;
    }

    public string? CurrentLicenseKey { get; private set; }
    public bool IsDisabled { get; private set; }
    public string CachePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "SR-Launcher",
        "license.dat");

    public async Task<LicenseCheckResult> EnsureValidAsync(LauncherConfig config, CancellationToken cancellationToken = default)
    {
        var api = _configService.GetLicenseApi(config);
        if (api is null)
        {
            IsDisabled = true;
            return LicenseCheckResult.Success();
        }

        var cache = LoadCache();
        if (string.IsNullOrWhiteSpace(cache?.Key))
        {
            return LicenseCheckResult.Failure("Unesi licencni kljuc.");
        }

        var result = await ActivateAsync(config, cache.Key, cancellationToken);
        if (result.Ok)
        {
            CurrentLicenseKey = cache.Key;
            SaveCache(new LicenseCache
            {
                Key = cache.Key,
                KeyHash = ComputeSha256(cache.Key),
                Hwid = GetHwid(),
                ExpiresAt = result.ExpiresAt,
                DiscordId = result.DiscordId,
                Permanent = result.Permanent,
                LastCheck = DateTimeOffset.UtcNow
            });
            return LicenseCheckResult.Success();
        }

        if (result.Status is "network" or "config" && IsInsideGrace(cache))
        {
            CurrentLicenseKey = cache.Key;
            return LicenseCheckResult.Success();
        }

        return LicenseCheckResult.Failure(result.Reason);
    }

    public async Task<LicenseApiResult> ActivateAsync(LauncherConfig config, string key, CancellationToken cancellationToken = default)
    {
        var body = new
        {
            key,
            hwid = GetHwid(),
            gameUid = $"{Environment.MachineName}/{Environment.UserName}",
            playerName = _gameSettingsService.TryReadPlayerName() ?? Environment.UserName
        };

        var response = await InvokeLicenseApiAsync(config, "activate", body, cancellationToken);
        if (response.Ok)
        {
            CurrentLicenseKey = key;
            SaveCache(new LicenseCache
            {
                Key = key,
                KeyHash = ComputeSha256(key),
                Hwid = GetHwid(),
                ExpiresAt = response.ExpiresAt,
                DiscordId = response.DiscordId,
                Permanent = response.Permanent,
                LastCheck = DateTimeOffset.UtcNow
            });
        }

        return response;
    }

    public async Task<LicenseApiResult> RequestTrialAsync(LauncherConfig config, CancellationToken cancellationToken = default)
    {
        var api = _configService.GetLicenseApi(config);
        if (api is null)
        {
            return LicenseApiResult.Fail("License API nije konfiguriran.", "config");
        }

        try
        {
            var url = $"{api.Url}/api/license/trial";
            using var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = JsonContent(new
                {
                    hwid = GetHwid(),
                    playerName = _gameSettingsService.TryReadPlayerName() ?? Environment.UserName
                })
            };
            using var response = await _http.SendAsync(request, cancellationToken);
            var json = await response.Content.ReadAsStringAsync(cancellationToken);
            var parsed = ParseApiResult(json, response.IsSuccessStatusCode);
            return parsed;
        }
        catch (Exception ex)
        {
            return LicenseApiResult.Fail($"Greska kod spajanja na server: {ex.Message}", "network");
        }
    }

    public Task SendHeartbeatAsync(LauncherConfig config, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(CurrentLicenseKey))
        {
            CurrentLicenseKey = LoadCache()?.Key;
        }

        if (string.IsNullOrWhiteSpace(CurrentLicenseKey))
        {
            return Task.CompletedTask;
        }

        var body = new
        {
            key = CurrentLicenseKey,
            hwid = GetHwid(),
            gameUid = $"{Environment.MachineName}/{Environment.UserName}",
            playerName = _gameSettingsService.TryReadPlayerName() ?? Environment.UserName
        };

        return InvokeLicenseApiAsync(config, "heartbeat", body, cancellationToken);
    }

    public void StartDetachedSessionWatcher(LauncherConfig config)
    {
        if (string.IsNullOrWhiteSpace(CurrentLicenseKey))
        {
            CurrentLicenseKey = LoadCache()?.Key;
        }

        var api = _configService.GetLicenseApi(config);
        var exePath = Environment.ProcessPath;
        if (api is null || string.IsNullOrWhiteSpace(CurrentLicenseKey) || string.IsNullOrWhiteSpace(exePath))
        {
            return;
        }

        var payloadPath = Path.Combine(Path.GetTempPath(), $"sr-session-{Guid.NewGuid():N}.json");
        var payload = new SessionWatcherPayload
        {
            Key = CurrentLicenseKey,
            Hwid = GetHwid(),
            GameUid = $"{Environment.MachineName}/{Environment.UserName}",
            ApiUrl = api.Url,
            ApiToken = api.Token,
            StartedAt = DateTimeOffset.UtcNow
        };
        File.WriteAllText(payloadPath, JsonSerializer.Serialize(payload, JsonOptions), Encoding.UTF8);

        Process.Start(new ProcessStartInfo
        {
            FileName = exePath,
            Arguments = $"--session-watch \"{payloadPath}\"",
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden
        });
    }

    public LicenseCache? LoadCache()
    {
        try
        {
            if (!File.Exists(CachePath))
            {
                return null;
            }

            var encrypted = File.ReadAllBytes(CachePath);
            var bytes = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<LicenseCache>(Encoding.UTF8.GetString(bytes), JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    public void SaveCache(LicenseCache cache)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(CachePath)!);
        var json = JsonSerializer.Serialize(cache, JsonOptions);
        var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(json), null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(CachePath, bytes);
    }

    public static async Task RunSessionWatcherAsync(string payloadPath)
    {
        try
        {
            if (!File.Exists(payloadPath))
            {
                return;
            }

            var payload = JsonSerializer.Deserialize<SessionWatcherPayload>(
                await File.ReadAllTextAsync(payloadPath), JsonOptions);
            if (payload is null)
            {
                return;
            }

            for (var attempt = 0; attempt < 60 && !IsFs25Running(); attempt++)
            {
                await Task.Delay(TimeSpan.FromSeconds(5));
            }

            while (IsFs25Running())
            {
                await Task.Delay(TimeSpan.FromSeconds(30));
            }

            var minutes = Math.Max(0, (int)Math.Floor((DateTimeOffset.UtcNow - payload.StartedAt).TotalMinutes));
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{payload.ApiUrl.TrimEnd('/')}/api/license/session-end")
            {
                Content = JsonContent(new
                {
                    key = payload.Key,
                    hwid = payload.Hwid,
                    gameUid = payload.GameUid,
                    sessionMinutes = minutes
                })
            };
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", payload.ApiToken);
            await http.SendAsync(request);
        }
        catch
        {
        }
        finally
        {
            try { File.Delete(payloadPath); } catch { }
        }
    }

    public static string GetHwid()
    {
        var machineGuid = string.Empty;
        try
        {
            machineGuid = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid", null)?.ToString() ?? string.Empty;
        }
        catch
        {
        }

        var raw = $"{machineGuid}|{Environment.MachineName}|{Environment.UserName}";
        return ComputeSha256(raw);
    }

    private async Task<LicenseApiResult> InvokeLicenseApiAsync(LauncherConfig config, string path, object body, CancellationToken cancellationToken)
    {
        var api = _configService.GetLicenseApi(config);
        if (api is null)
        {
            return LicenseApiResult.Fail("License API nije konfiguriran.", "config");
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{api.Url}/api/license/{path}")
            {
                Content = JsonContent(body)
            };
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", api.Token);
            using var response = await _http.SendAsync(request, cancellationToken);
            var json = await response.Content.ReadAsStringAsync(cancellationToken);
            return ParseApiResult(json, response.IsSuccessStatusCode);
        }
        catch (Exception ex)
        {
            return LicenseApiResult.Fail($"Greska kod spajanja na server: {ex.Message}", "network");
        }
    }

    private static LicenseApiResult ParseApiResult(string json, bool success)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var ok = root.TryGetProperty("ok", out var okProp) && okProp.ValueKind == JsonValueKind.True;
            var result = ok
                ? LicenseApiResult.Success()
                : LicenseApiResult.Fail(ReadString(root, "reason") ?? (success ? "Neispravan odgovor servera." : "HTTP greska."), ReadString(root, "status") ?? "unknown");

            result.DiscordId = ReadString(root, "discordId") ?? string.Empty;
            result.Key = ReadString(root, "key")
                ?? ReadString(root, "licenseKey")
                ?? ReadString(root, "trialKey")
                ?? string.Empty;
            result.Permanent = root.TryGetProperty("permanent", out var permanent) && permanent.ValueKind == JsonValueKind.True;
            if (root.TryGetProperty("expiresAt", out var expiresAt))
            {
                result.ExpiresAt = expiresAt.ValueKind == JsonValueKind.Number && expiresAt.TryGetInt64(out var ms)
                    ? DateTimeOffset.FromUnixTimeMilliseconds(ms)
                    : DateTimeOffset.TryParse(expiresAt.ToString(), out var parsed) ? parsed : null;
            }

            return result;
        }
        catch
        {
            return LicenseApiResult.Fail(success ? "Neispravan odgovor servera." : "HTTP greska.", success ? "unknown" : "network");
        }
    }

    private static HttpContent JsonContent(object body) =>
        new StringContent(JsonSerializer.Serialize(body, JsonOptions), Encoding.UTF8, "application/json");

    private static bool IsFs25Running() =>
        Process.GetProcesses().Any(p => p.ProcessName.StartsWith("FarmingSimulator2025", StringComparison.OrdinalIgnoreCase));

    private static bool IsInsideGrace(LicenseCache cache)
    {
        if (cache.LastCheck == default || DateTimeOffset.UtcNow - cache.LastCheck > TimeSpan.FromHours(48))
        {
            return false;
        }

        return cache.Permanent || cache.ExpiresAt is null || DateTimeOffset.UtcNow <= cache.ExpiresAt.Value;
    }

    private static string? ReadString(JsonElement root, string name) =>
        root.TryGetProperty(name, out var property) && property.ValueKind != JsonValueKind.Null
            ? property.ToString()
            : null;

    private static string ComputeSha256(string text)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}

public sealed class LicenseCache
{
    public string Key { get; set; } = string.Empty;
    public string KeyHash { get; set; } = string.Empty;
    public string Hwid { get; set; } = string.Empty;
    public DateTimeOffset? ExpiresAt { get; set; }
    public string DiscordId { get; set; } = string.Empty;
    public bool Permanent { get; set; }
    public DateTimeOffset LastCheck { get; set; }
}

public sealed class LicenseApiResult
{
    public bool Ok { get; private set; }
    public string Reason { get; private set; } = string.Empty;
    public string Status { get; private set; } = string.Empty;
    public string Key { get; set; } = string.Empty;
    public DateTimeOffset? ExpiresAt { get; set; }
    public string DiscordId { get; set; } = string.Empty;
    public bool Permanent { get; set; }

    public static LicenseApiResult Success() => new() { Ok = true };

    public static LicenseApiResult Fail(string reason, string status) => new()
    {
        Ok = false,
        Reason = reason,
        Status = status
    };
}

public sealed class LicenseCheckResult
{
    public bool Ok { get; private init; }
    public string Reason { get; private init; } = string.Empty;

    public static LicenseCheckResult Success() => new() { Ok = true };
    public static LicenseCheckResult Failure(string reason) => new() { Ok = false, Reason = reason };
}

public sealed class SessionWatcherPayload
{
    public string Key { get; set; } = string.Empty;
    public string Hwid { get; set; } = string.Empty;
    public string GameUid { get; set; } = string.Empty;
    public string ApiUrl { get; set; } = string.Empty;
    public string ApiToken { get; set; } = string.Empty;
    public DateTimeOffset StartedAt { get; set; }
}
