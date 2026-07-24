using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PetRunner.Core;

public enum UsageProvider { Claude, Codex }
public enum UsageCostProvenance { Calculated, Unavailable }

public readonly record struct UsageTokens(long Input = 0, long CachedInput = 0, long Output = 0, long Reasoning = 0)
{
    public long Total => Input + CachedInput + Output;

    public static UsageTokens operator +(UsageTokens left, UsageTokens right) => new(
        left.Input + right.Input,
        left.CachedInput + right.CachedInput,
        left.Output + right.Output,
        left.Reasoning + right.Reasoning);

    internal UsageTokens Delta(UsageTokens previous) => new(
        Math.Max(0, Input - previous.Input),
        Math.Max(0, CachedInput - previous.CachedInput),
        Math.Max(0, Output - previous.Output),
        Math.Max(0, Reasoning - previous.Reasoning));
}

public sealed record UsageCost(double? Usd, UsageCostProvenance Provenance, string? PricingVersion = null);

public sealed record UsageRecord(
    string Id,
    UsageProvider Provider,
    string SessionId,
    DateTimeOffset OccurredAt,
    string? Model,
    UsageTokens Tokens,
    UsageCost Cost);

public sealed record UsageAggregate(UsageTokens Tokens, double KnownCostUsd, int SessionCount, int RecordCount);

public sealed record UsageSession(
    string Id,
    UsageProvider Provider,
    string? Model,
    DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt,
    double DurationSeconds,
    UsageTokens Tokens,
    double KnownCostUsd,
    int RecordCount);

public sealed record UsageFilter(string Range = "30d", UsageProvider? Provider = null, string? Model = null);

public static class UsagePricing
{
    public const string Version = "2026-07-01";

    public static UsageCost Cost(string? model, UsageTokens tokens)
    {
        if (string.IsNullOrWhiteSpace(model)) return new(null, UsageCostProvenance.Unavailable);
        var normalized = model.ToLowerInvariant();
        (double Input, double Cached, double Output)? rates = normalized.Contains("claude", StringComparison.Ordinal)
            ? normalized.Contains("opus", StringComparison.Ordinal) ? (15, 1.5, 75)
            : normalized.Contains("haiku", StringComparison.Ordinal) ? (0.8, 0.08, 4)
            : (3, 0.3, 15)
            : normalized.Contains("gpt", StringComparison.Ordinal) || normalized.Contains("o3", StringComparison.Ordinal) || normalized.Contains("codex", StringComparison.Ordinal)
                ? normalized.Contains("mini", StringComparison.Ordinal) ? (1.1, 0.11, 4.4) : (2.5, 0.25, 10)
                : null;
        if (rates is not { } price) return new(null, UsageCostProvenance.Unavailable);
        var usd = (tokens.Input * price.Input + tokens.CachedInput * price.Cached + tokens.Output * price.Output) / 1_000_000d;
        return new(usd, UsageCostProvenance.Calculated, Version);
    }
}

public static class UsageAnalytics
{
    public static IReadOnlyList<UsageRecord> Filter(
        IEnumerable<UsageRecord> records,
        UsageFilter filter,
        DateTimeOffset? currentTime = null)
    {
        var now = currentTime ?? DateTimeOffset.Now;
        var start = filter.Range.ToLowerInvariant() switch
        {
            "today" => new DateTimeOffset(now.Year, now.Month, now.Day, 0, 0, 0, now.Offset),
            "7d" => now.AddDays(-7),
            "30d" => now.AddDays(-30),
            "90d" => now.AddDays(-90),
            "month" => new DateTimeOffset(now.Year, now.Month, 1, 0, 0, 0, now.Offset),
            "all" => DateTimeOffset.MinValue,
            _ => throw new ArgumentException("range must be today, 7d, 30d, 90d, month, or all", nameof(filter)),
        };
        return records
            .Where(record => record.OccurredAt >= start && record.OccurredAt <= now)
            .Where(record => filter.Provider is null || record.Provider == filter.Provider)
            .Where(record => string.IsNullOrWhiteSpace(filter.Model) ||
                (record.Model?.Contains(filter.Model.Trim(), StringComparison.OrdinalIgnoreCase) ?? false))
            .OrderBy(record => record.OccurredAt)
            .ToArray();
    }

    public static UsageAggregate Aggregate(IEnumerable<UsageRecord> records)
    {
        var materialized = records.ToArray();
        return new(
            materialized.Aggregate(new UsageTokens(), (tokens, record) => tokens + record.Tokens),
            materialized.Sum(record => record.Cost.Usd ?? 0),
            materialized.Select(record => $"{record.Provider}:{record.SessionId}").Distinct(StringComparer.OrdinalIgnoreCase).Count(),
            materialized.Length);
    }

    public static IReadOnlyList<UsageSession> Sessions(IEnumerable<UsageRecord> records) => records
        .GroupBy(record => new { record.Provider, record.SessionId })
        .Select(group =>
        {
            var ordered = group.OrderBy(record => record.OccurredAt).ToArray();
            var latestModel = ordered.LastOrDefault(record => !string.IsNullOrWhiteSpace(record.Model))?.Model;
            return new UsageSession(
                group.Key.SessionId,
                group.Key.Provider,
                latestModel,
                ordered[0].OccurredAt,
                ordered[^1].OccurredAt,
                Math.Max(0, (ordered[^1].OccurredAt - ordered[0].OccurredAt).TotalSeconds),
                ordered.Aggregate(new UsageTokens(), (tokens, record) => tokens + record.Tokens),
                ordered.Sum(record => record.Cost.Usd ?? 0),
                ordered.Length);
        })
        .OrderByDescending(session => session.UpdatedAt)
        .ToArray();
}

public sealed class LocalUsageIndex
{
    private readonly string codexRoot;
    private readonly IReadOnlyList<string> claudeRoots;
    private readonly object gate = new();
    private readonly Dictionary<string, CachedFile> cache = new(StringComparer.OrdinalIgnoreCase);

    public LocalUsageIndex(string codexRoot, IReadOnlyList<string> claudeRoots)
    {
        this.codexRoot = Path.GetFullPath(codexRoot);
        this.claudeRoots = claudeRoots.Select(Path.GetFullPath).ToArray();
    }

    public IReadOnlyList<UsageRecord> Records(bool forceRefresh = false)
    {
        lock (gate)
        {
            var sources = SourceFiles().ToArray();
            var active = sources.Select(source => source.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var removed in cache.Keys.Where(path => !active.Contains(path)).ToArray()) cache.Remove(removed);
            foreach (var source in sources)
            {
                FileStamp stamp;
                DateTimeOffset fallbackDate;
                try
                {
                    var info = new FileInfo(source.Path);
                    stamp = new FileStamp(info.LastWriteTimeUtc.Ticks, info.Length);
                    fallbackDate = new DateTimeOffset(info.LastWriteTimeUtc);
                }
                catch { continue; }
                if (!forceRefresh && cache.TryGetValue(source.Path, out var existing) && existing.Stamp == stamp) continue;
                try { cache[source.Path] = new CachedFile(stamp, Parse(source.Path, source.Provider, fallbackDate)); }
                catch (IOException) { if (!cache.ContainsKey(source.Path)) cache[source.Path] = new CachedFile(stamp, []); }
                catch (UnauthorizedAccessException) { if (!cache.ContainsKey(source.Path)) cache[source.Path] = new CachedFile(stamp, []); }
            }
            return cache.Values.SelectMany(value => value.Records).OrderBy(record => record.OccurredAt).ToArray();
        }
    }

    public void ClearCache()
    {
        lock (gate) cache.Clear();
    }

    private IEnumerable<(string Path, UsageProvider Provider)> SourceFiles()
    {
        // Prefer live sessions over archived copies of the same basename (ccusage/CodexBar).
        var codexByBasename = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in JsonlFiles(Path.Combine(codexRoot, "archived_sessions")))
            codexByBasename[Path.GetFileName(file)] = file;
        foreach (var file in JsonlFiles(Path.Combine(codexRoot, "sessions")))
            codexByBasename[Path.GetFileName(file)] = file;
        foreach (var file in codexByBasename.Values) yield return (file, UsageProvider.Codex);
        foreach (var root in claudeRoots)
            foreach (var file in JsonlFiles(root)) yield return (file, UsageProvider.Claude);
    }

    private static IReadOnlyList<string> JsonlFiles(string root)
    {
        if (!Directory.Exists(root)) return [];
        var files = new List<string>();
        var pending = new Stack<string>();
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        pending.Push(root);
        while (pending.TryPop(out var directory))
        {
            string resolvedDirectory;
            try { resolvedDirectory = Path.GetFullPath(directory); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { continue; }
            if (!visited.Add(resolvedDirectory)) continue;
            try
            {
                files.AddRange(Directory.EnumerateFiles(resolvedDirectory, "*.jsonl").Select(Path.GetFullPath));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            try
            {
                foreach (var child in new DirectoryInfo(resolvedDirectory).EnumerateDirectories())
                {
                    if ((child.Attributes & FileAttributes.ReparsePoint) == 0) pending.Push(child.FullName);
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return files;
    }

    private static IReadOnlyList<UsageRecord> Parse(string path, UsageProvider provider, DateTimeOffset fallbackDate) =>
        provider == UsageProvider.Codex ? ParseCodex(path, fallbackDate) : ParseClaude(path, fallbackDate);

    private static IReadOnlyList<UsageRecord> ParseCodex(string path, DateTimeOffset fallbackDate)
    {
        var records = new List<UsageRecord>();
        var previous = new Dictionary<string, UsageTokens>(StringComparer.Ordinal);
        var sessionModels = new Dictionary<string, string>(StringComparer.Ordinal);
        string? fileModel = null;
        foreach (var (line, root) in JsonObjects(path))
        {
            var hasPayload = root.TryGetProperty("payload", out var payload) && payload.ValueKind == JsonValueKind.Object;
            var observedModel = Model(root) ?? (hasPayload ? Model(payload) : null);
            var observedSession = (hasPayload ? Session(payload) : null) ?? Session(root);
            if (observedModel is not null)
            {
                if (observedSession is not null) sessionModels[observedSession] = observedModel;
                else fileModel = observedModel;
            }
            if (!hasPayload || Text(payload, "type") != "token_count" ||
                !payload.TryGetProperty("info", out var info) || !info.TryGetProperty("total_token_usage", out var totals)) continue;
            var session = Session(payload) ?? Path.GetFileNameWithoutExtension(path);
            var current = Tokens(totals, "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens");
            previous.TryGetValue(session, out var old);
            previous[session] = current;
            var delta = current.Delta(old);
            if (delta.Total <= 0) continue;
            var model = Model(info) ?? (sessionModels.TryGetValue(session, out var sessionModel) ? sessionModel : fileModel);
            if (model is not null) sessionModels[session] = model;
            records.Add(new UsageRecord(SourceId("codex", path, line), UsageProvider.Codex, session, Date(root, fallbackDate), model, delta, UsagePricing.Cost(model, delta)));
        }
        return records;
    }

    private static IReadOnlyList<UsageRecord> ParseClaude(string path, DateTimeOffset fallbackDate)
    {
        // Last-wins on message.id + requestId (CodexBar / fixed ccusage). Claude Code
        // streams multiple assistant rows per API call; uuid/line keys over-bill input.
        var keyed = new Dictionary<string, UsageRecord>(StringComparer.Ordinal);
        var unkeyed = new List<UsageRecord>();
        foreach (var (line, root) in JsonObjects(path))
        {
            if (Text(root, "type") != "assistant" || !root.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("usage", out var usage)) continue;
            var tokens = new UsageTokens(
                Number(usage, "input_tokens") + Number(usage, "cache_creation_input_tokens"),
                Number(usage, "cache_read_input_tokens"),
                Number(usage, "output_tokens"),
                Number(usage, "reasoning_output_tokens"));
            if (tokens.Total <= 0) continue;
            var model = Text(message, "model");
            var session = Text(root, "sessionId") ?? Text(root, "session_id") ?? Path.GetFileNameWithoutExtension(path);
            var messageId = Text(message, "id");
            var requestId = Text(root, "requestId");
            string sourceId;
            string? dedupeKey;
            if (!string.IsNullOrEmpty(messageId) && !string.IsNullOrEmpty(requestId))
            {
                sourceId = $"claude:{session}:{messageId}:{requestId}";
                dedupeKey = $"{messageId}:{requestId}";
            }
            else if (!string.IsNullOrEmpty(messageId))
            {
                sourceId = $"claude:{session}:mid:{messageId}";
                dedupeKey = $"mid:{messageId}";
            }
            else if (!string.IsNullOrEmpty(requestId))
            {
                sourceId = $"claude:{session}:req:{requestId}";
                dedupeKey = $"req:{requestId}";
            }
            else
            {
                sourceId = SourceId("claude", path, line);
                dedupeKey = null;
            }
            var record = new UsageRecord(sourceId, UsageProvider.Claude, session, Date(root, fallbackDate), model, tokens, UsagePricing.Cost(model, tokens));
            if (dedupeKey is null) unkeyed.Add(record);
            else keyed[dedupeKey] = record;
        }
        return keyed.Values.Concat(unkeyed).OrderBy(record => record.OccurredAt).ToArray();
    }

    private static IReadOnlyList<(int Line, JsonElement Root)> JsonObjects(string path)
    {
        var objects = new List<(int, JsonElement)>();
        try
        {
            using var reader = File.OpenText(path);
            var lineNumber = 0;
            while (reader.ReadLine() is { } line)
            {
                var current = lineNumber++;
                if (string.IsNullOrWhiteSpace(line)) continue;
                JsonDocument? document = null;
                try { document = JsonDocument.Parse(line); }
                catch (JsonException) { }
                if (document is null) continue;
                using (document) objects.Add((current, document.RootElement.Clone()));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return objects;
    }

    private static UsageTokens Tokens(JsonElement objectValue, string input, string cached, string output, string reasoning) =>
        new(Number(objectValue, input), Number(objectValue, cached), Number(objectValue, output), Number(objectValue, reasoning));

    private static long Number(JsonElement objectValue, string key) =>
        objectValue.TryGetProperty(key, out var value) && value.TryGetInt64(out var number) ? Math.Max(0, number) : 0;

    private static string? Text(JsonElement objectValue, string key) =>
        objectValue.ValueKind == JsonValueKind.Object && objectValue.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static string? Model(JsonElement objectValue) =>
        Text(objectValue, "model") ?? Text(objectValue, "model_name") ?? Text(objectValue, "modelName");

    private static string? Session(JsonElement objectValue) =>
        Text(objectValue, "conversation_id") ?? Text(objectValue, "session_id") ?? Text(objectValue, "sessionId");

    private static DateTimeOffset Date(JsonElement objectValue, DateTimeOffset fallback) =>
        DateTimeOffset.TryParse(Text(objectValue, "timestamp"), out var value) ? value : fallback;

    private static string SourceId(string provider, string path, int line)
    {
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path))).ToLowerInvariant()[..16];
        return $"{provider}:{digest}:{line}";
    }

    private readonly record struct FileStamp(long LastWriteTicks, long Length);
    private sealed record CachedFile(FileStamp Stamp, IReadOnlyList<UsageRecord> Records);
}
