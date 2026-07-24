using PetRunner.Core;

namespace PetRunner.Tests;

internal static class UsageTests
{
    public static void Run()
    {
        CodexCumulativeCountersBecomeDeltas();
        ClaudeUsageAndSessionsAggregate();
        ClaudeStreamingChunksDedupLastWins();
        FiltersByRangeProviderAndModel();
        RecursivelyFindsNestedUsage();
    }

    private static void CodexCumulativeCountersBecomeDeltas()
    {
        using var fixture = new UsageFixture();
        fixture.WriteCodex("session-a",
            """{"timestamp":"2026-07-21T09:59:00Z","payload":{"conversation_id":"session-a","modelName":"gpt-5-codex"}}""",
            """{"timestamp":"2026-07-21T10:00:00Z","payload":{"type":"token_count","conversation_id":"session-a","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1}}}}""",
            """{"timestamp":"2026-07-21T10:01:00Z","payload":{"type":"token_count","conversation_id":"session-a","info":{"model":"gpt-5-codex","total_token_usage":{"input_tokens":14,"cached_input_tokens":4,"output_tokens":7,"reasoning_output_tokens":2}}}}"""
        );

        var records = fixture.Index.Records(forceRefresh: true).Where(record => record.Provider == UsageProvider.Codex).ToArray();
        Check.Equal(2, records.Length);
        Check.Equal(15L, records[0].Tokens.Total);
        Check.Equal(10L, records[1].Tokens.Total);
        Check.True(records.All(record => record.Model == "gpt-5-codex"), "Token records should inherit the preceding file/session model");
        Check.True(records.All(record => record.Cost.Usd is > 0), "Known Codex models should receive local cost estimates");
    }

    private static void ClaudeUsageAndSessionsAggregate()
    {
        using var fixture = new UsageFixture();
        fixture.WriteClaude("session-b",
            """{"type":"assistant","timestamp":"2026-07-21T11:00:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":20,"cache_creation_input_tokens":8,"cache_read_input_tokens":5,"output_tokens":7}}}""",
            """{"type":"assistant","timestamp":"2026-07-21T11:02:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":3,"output_tokens":2}}}"""
        );

        var records = fixture.Index.Records(forceRefresh: true);
        var session = UsageAnalytics.Sessions(records).Single();
        Check.Equal("session-b", session.Id);
        Check.Equal(28L, records[0].Tokens.Input);
        Check.Equal(5L, records[0].Tokens.CachedInput);
        Check.Equal(45L, session.Tokens.Total);
        Check.Equal(120d, session.DurationSeconds);
    }

    private static void ClaudeStreamingChunksDedupLastWins()
    {
        using var fixture = new UsageFixture();
        fixture.WriteClaude("session-stream",
            """{"type":"assistant","uuid":"u1","requestId":"req-1","sessionId":"session-stream","timestamp":"2026-07-22T10:00:00Z","message":{"id":"msg_abc","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":5}}}""",
            """{"type":"assistant","uuid":"u2","requestId":"req-1","sessionId":"session-stream","timestamp":"2026-07-22T10:00:01Z","message":{"id":"msg_abc","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":50}}}""",
            """{"type":"assistant","uuid":"u3","requestId":"req-1","sessionId":"session-stream","timestamp":"2026-07-22T10:00:02Z","message":{"id":"msg_abc","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":200}}}"""
        );

        var records = fixture.Index.Records(forceRefresh: true).Where(record => record.Provider == UsageProvider.Claude).ToArray();
        Check.Equal(1, records.Length);
        Check.Equal(1000L, records[0].Tokens.Input);
        Check.Equal(200L, records[0].Tokens.CachedInput);
        Check.Equal(5L, records[0].Tokens.Output); // ccgauge earliest-wins
        Check.True(records[0].Id.Contains("msg_abc:req-1", StringComparison.Ordinal), "Stable message/request source key");
    }

    private static void FiltersByRangeProviderAndModel()
    {
        var now = new DateTimeOffset(2026, 7, 22, 12, 0, 0, TimeSpan.Zero);
        var records = new[]
        {
            Record("a", UsageProvider.Claude, "claude-sonnet", now.AddHours(-1)),
            Record("b", UsageProvider.Codex, "gpt-5-codex", now.AddDays(-10)),
        };
        var filtered = UsageAnalytics.Filter(records, new UsageFilter("7d", UsageProvider.Claude, "sonnet"), now);
        Check.Equal(1, filtered.Count);
        Check.Equal("a", filtered[0].SessionId);
    }

    private static void RecursivelyFindsNestedUsage()
    {
        using var fixture = new UsageFixture();
        fixture.WriteNestedClaude("project/session-c",
            """{"type":"assistant","timestamp":"2026-07-21T11:00:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":1}}}""");

        var records = fixture.Index.Records(forceRefresh: true);
        Check.Equal(1, records.Count);
        Check.Equal("session-c", records[0].SessionId);
    }

    private static UsageRecord Record(string session, UsageProvider provider, string model, DateTimeOffset time) =>
        new($"test:{session}", provider, session, time, model, new UsageTokens(1, 2, 3, 0), UsagePricing.Cost(model, new UsageTokens(1, 2, 3, 0)));

    private sealed class UsageFixture : IDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), $"petrunner-usage-{Guid.NewGuid():N}");

        public UsageFixture()
        {
            Directory.CreateDirectory(CodexRoot);
            Directory.CreateDirectory(ClaudeRoot);
            Index = new LocalUsageIndex(CodexRoot, [ClaudeRoot]);
        }

        public LocalUsageIndex Index { get; }
        private string CodexRoot => Path.Combine(root, "codex");
        private string ClaudeRoot => Path.Combine(root, "claude");

        public void WriteCodex(string id, params string[] lines) => Write(Path.Combine(CodexRoot, "sessions", $"{id}.jsonl"), lines);
        public void WriteClaude(string id, params string[] lines) => Write(Path.Combine(ClaudeRoot, $"{id}.jsonl"), lines);
        public void WriteNestedClaude(string relativePath, params string[] lines) => Write(Path.Combine(ClaudeRoot, $"{relativePath}.jsonl"), lines);

        private static void Write(string path, string[] lines)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllLines(path, lines);
        }

        public void Dispose()
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }
}
