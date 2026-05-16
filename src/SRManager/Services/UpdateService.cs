using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using SRManager.Models;

namespace SRManager.Services;

public sealed class UpdateService
{
    public const string AppVersion = "3.0.0";
    private readonly HttpClient _http;
    private readonly ConfigService _configService;

    public UpdateService(HttpClient http, ConfigService configService)
    {
        _http = http;
        _configService = configService;
    }

    public async Task<LatestVersion?> CheckAsync(LauncherConfig config, CancellationToken cancellationToken = default)
    {
        var apiLatest = await CheckBotAsync(config, cancellationToken);
        if (apiLatest is not null)
        {
            return apiLatest;
        }

        return await CheckGitHubAsync(config.GithubRepo, cancellationToken);
    }

    public async Task InstallAsync(LatestVersion latest, Action<string>? progress, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(latest.DownloadUrl))
        {
            Process.Start(new ProcessStartInfo { FileName = latest.Url, UseShellExecute = true });
            return;
        }

        var currentExe = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(currentExe) || !latest.DownloadUrl.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            Process.Start(new ProcessStartInfo { FileName = latest.Url, UseShellExecute = true });
            return;
        }

        progress?.Invoke("Skidam novu verziju...");
        var tempExe = Path.Combine(Path.GetTempPath(), $"SRManager-update-{Guid.NewGuid():N}.exe");
        using (var response = await _http.GetAsync(latest.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken))
        {
            response.EnsureSuccessStatusCode();
            await using var remote = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using var local = File.Create(tempExe);
            await remote.CopyToAsync(local, cancellationToken);
        }

        var script = Path.Combine(Path.GetTempPath(), $"sr-update-{Guid.NewGuid():N}.cmd");
        var currentPid = Environment.ProcessId;
        var content = $"""
@echo off
chcp 65001 >nul 2>&1
echo Cekam da se SR Manager zatvori...
:wait
tasklist /FI "PID eq {currentPid}" | find "{currentPid}" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
copy /Y "{tempExe}" "{currentExe}" >nul
start "" "{currentExe}"
del "{tempExe}" >nul 2>&1
del "%~f0" >nul 2>&1
""";
        await File.WriteAllTextAsync(script, content, Encoding.UTF8, cancellationToken);
        Process.Start(new ProcessStartInfo
        {
            FileName = script,
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Hidden
        });
    }

    private async Task<LatestVersion?> CheckBotAsync(LauncherConfig config, CancellationToken cancellationToken)
    {
        var api = _configService.GetLicenseApi(config);
        if (api is null)
        {
            return null;
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"{api.Url}/launcher/latest");
            request.Headers.UserAgent.ParseAdd("SRManager-CSharp");
            using var response = await _http.SendAsync(request, cancellationToken);
            response.EnsureSuccessStatusCode();
            var json = await response.Content.ReadAsStringAsync(cancellationToken);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var remote = ReadString(root, "version").TrimStart('v');
            if (string.IsNullOrWhiteSpace(remote) || SameVersion(remote))
            {
                return null;
            }

            return new LatestVersion
            {
                Version = remote,
                DownloadUrl = ReadString(root, "downloadUrl"),
                Url = ReadString(root, "downloadUrl"),
                Notes = ReadString(root, "notes"),
                File = ReadString(root, "file"),
                Sha256 = ReadString(root, "sha256")
            };
        }
        catch
        {
            return null;
        }
    }

    private async Task<LatestVersion?> CheckGitHubAsync(string repo, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{repo}/releases/latest");
            request.Headers.UserAgent.ParseAdd("SRManager-CSharp");
            using var response = await _http.SendAsync(request, cancellationToken);
            response.EnsureSuccessStatusCode();
            var json = await response.Content.ReadAsStringAsync(cancellationToken);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var remote = ReadString(root, "tag_name").TrimStart('v');
            if (string.IsNullOrWhiteSpace(remote) || SameVersion(remote))
            {
                return null;
            }

            var downloadUrl = string.Empty;
            var file = string.Empty;
            if (root.TryGetProperty("assets", out var assets))
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    file = ReadString(asset, "name");
                    if (file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                    {
                        downloadUrl = ReadString(asset, "browser_download_url");
                        break;
                    }
                }
            }

            return new LatestVersion
            {
                Version = remote,
                Url = ReadString(root, "html_url"),
                DownloadUrl = downloadUrl,
                File = file,
                Notes = ReadString(root, "body")
            };
        }
        catch
        {
            return null;
        }
    }

    private static bool SameVersion(string remote)
    {
        if (Version.TryParse(remote, out var remoteVersion) && Version.TryParse(AppVersion, out var currentVersion))
        {
            return remoteVersion <= currentVersion;
        }

        return remote.Equals(AppVersion, StringComparison.OrdinalIgnoreCase);
    }

    private static string ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null ? value.ToString() : string.Empty;
}
