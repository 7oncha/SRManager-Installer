using System.Net.Http;
using System.Xml.Linq;
using SRManager.Models;

namespace SRManager.Services;

public sealed class ServerStatusService
{
    private readonly HttpClient _http;

    public ServerStatusService(HttpClient http)
    {
        _http = http;
    }

    public async Task<ServerStatus> GetStatusAsync(ServerConfig server, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(server.StatsCode))
        {
            return new ServerStatus { Online = false, Name = server.Name };
        }

        try
        {
            var url = $"http://{server.Ip}:{server.WebPort}/feed/dedicated-server-stats.xml?code={Uri.EscapeDataString(server.StatsCode)}";
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.UserAgent.ParseAdd("SRManager-CSharp");
            using var response = await _http.SendAsync(request, cancellationToken);
            response.EnsureSuccessStatusCode();
            var xmlText = (await response.Content.ReadAsStringAsync(cancellationToken))
                .TrimStart('\uFEFF')
                .Trim();

            var doc = XDocument.Parse(xmlText);
            var root = doc.Root;
            if (root is null)
            {
                return new ServerStatus { Online = false, Name = server.Name };
            }

            var slots = root.Element("Slots");
            var players = slots?
                .Elements("Player")
                .Where(p => string.Equals((string?)p.Attribute("isUsed"), "true", StringComparison.OrdinalIgnoreCase))
                .Select(ReadPlayer)
                .Where(p => !string.IsNullOrWhiteSpace(p.Name))
                .ToList() ?? [];

            return new ServerStatus
            {
                Online = true,
                Name = (string?)root.Attribute("name") ?? server.Name,
                Map = (string?)root.Attribute("mapName") ?? "?",
                GameVersion = (string?)root.Attribute("version") ?? string.Empty,
                PlayersOnline = ReadInt(slots?.Attribute("numUsed")),
                PlayersMax = ReadInt(slots?.Attribute("capacity")),
                Players = players
            };
        }
        catch
        {
            return new ServerStatus { Online = false, Name = server.Name, Map = "Offline" };
        }
    }

    private static PlayerStatus ReadPlayer(XElement player)
    {
        var name = player.Value;
        if (string.IsNullOrWhiteSpace(name))
        {
            name = (string?)player.Attribute("name") ?? string.Empty;
        }

        return new PlayerStatus
        {
            Name = name,
            UptimeMinutes = ReadInt(player.Attribute("uptime")),
            IsAdmin = string.Equals((string?)player.Attribute("isAdmin"), "true", StringComparison.OrdinalIgnoreCase)
        };
    }

    private static int ReadInt(XAttribute? attribute) =>
        int.TryParse(attribute?.Value, out var value) ? value : 0;
}
