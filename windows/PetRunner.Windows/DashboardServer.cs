using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using PetRunner.Core;

namespace PetRunner.Windows;

internal sealed record DashboardHostSnapshot(
    IReadOnlyList<PetDescriptor> Pets,
    IReadOnlyList<PetFailure> Failures,
    string? SelectedPetId,
    double Width,
    bool AutonomyEnabled,
    AutonomyConfiguration Autonomy,
    ProviderBudgetSettings ClaudeBudget,
    ProviderBudgetSettings CodexBudget,
    bool ClaudeEnabled,
    bool CodexEnabled,
    string PetsDirectory,
    string PetsDirectorySource,
    bool PetsDirectoryEditable);

internal sealed record DashboardCallbacks(
    Func<DashboardHostSnapshot> Snapshot,
    Action<PetRequest> UpdatePet,
    Action<AutonomyRequest> UpdateAutonomy,
    Action ResetPosition,
    Func<bool> ImportPet,
    Func<string, object> RemovePet,
    Action ChoosePetsDirectory,
    Action RevealPetsDirectory,
    Action<SettingsRequest> UpdateSettings);

internal sealed record PetRequest(string? Id = null, double? Width = null);
internal sealed record AutonomyRequest(bool? Enabled = null, double? MinimumWait = null, double? MaximumWait = null, string[]? Actions = null);
internal sealed record BudgetRequest(double? DailyUSD = null, double? MonthlyUSD = null);
internal sealed record BudgetCollection(BudgetRequest? Claude = null, BudgetRequest? Codex = null, BudgetRequest? Cursor = null);
internal sealed record SettingsRequest(bool? ShowStatusItem = null, BudgetCollection? Budgets = null, string? PetsDirectory = null);

internal sealed class DashboardApiException(string code, string message, int statusCode = 400) : Exception(message)
{
    public string Code { get; } = code;
    public int StatusCode { get; } = statusCode;
}

internal sealed class DashboardServer : IDisposable
{
    private const int PreferredPort = 47835;
    private const int PortAttempts = 20;
    private const int MaxBodyBytes = 64 * 1024;
    private readonly string assetDirectory;
    private readonly LocalUsageIndex usage;
    private readonly DashboardCallbacks callbacks;
    private readonly string token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
    private readonly CancellationTokenSource cancellation = new();
    private readonly JsonSerializerOptions jsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
    private HttpListener? listener;
    private Task? listenerTask;

    public DashboardServer(string assetDirectory, LocalUsageIndex usage, DashboardCallbacks callbacks)
    {
        this.assetDirectory = Path.GetFullPath(assetDirectory);
        this.usage = usage;
        this.callbacks = callbacks;
    }

    public int Port { get; private set; }
    public string Origin => $"http://127.0.0.1:{Port}";
    public string DashboardUrl => $"{Origin}/{token}/";

    public void Start()
    {
        if (listener is not null) return;
        if (!Directory.Exists(assetDirectory)) throw new DirectoryNotFoundException($"Dashboard assets are missing: {assetDirectory}");
        for (var candidate = PreferredPort; candidate < PreferredPort + PortAttempts; candidate++)
        {
            var attempt = new HttpListener();
            attempt.Prefixes.Add($"http://127.0.0.1:{candidate}/");
            try
            {
                attempt.Start();
                listener = attempt;
                Port = candidate;
                listenerTask = Task.Run(ListenLoop);
                return;
            }
            catch (HttpListenerException)
            {
                attempt.Close();
            }
        }
        throw new InvalidOperationException($"Could not bind the local dashboard on ports {PreferredPort}-{PreferredPort + PortAttempts - 1}.");
    }

    private async Task ListenLoop()
    {
        while (!cancellation.IsCancellationRequested && listener?.IsListening == true)
        {
            HttpListenerContext context;
            try { context = await listener.GetContextAsync(); }
            catch (Exception) when (cancellation.IsCancellationRequested || listener?.IsListening != true) { return; }
            _ = Task.Run(() => Handle(context));
        }
    }

    private async Task Handle(HttpListenerContext context)
    {
        ApplySecurityHeaders(context.Response);
        try
        {
            var route = DashboardRoute.Parse(context.Request.Url?.AbsolutePath ?? "", token);
            if (route.Kind == DashboardRouteKind.NotFound) throw new DashboardApiException("not_found", "Not found.", 404);
            if (IsMutation(route.Kind)) ValidateSameOrigin(context.Request);
            switch (route.Kind)
            {
                case DashboardRouteKind.Asset:
                    RequireMethod(context.Request, "GET");
                    await WriteAsset(context.Response, route.Value!);
                    break;
                case DashboardRouteKind.State:
                    RequireMethod(context.Request, "GET");
                    await WriteJson(context.Response, State());
                    break;
                case DashboardRouteKind.Usage:
                    RequireMethod(context.Request, "GET");
                    await WriteJson(context.Response, UsagePayload(context.Request));
                    break;
                case DashboardRouteKind.Sessions:
                    RequireMethod(context.Request, "GET");
                    await WriteJson(context.Response, SessionsPayload(context.Request));
                    break;
                case DashboardRouteKind.Session:
                    RequireMethod(context.Request, "GET");
                    await WriteJson(context.Response, SessionPayload(route.Value!));
                    break;
                case DashboardRouteKind.PetPreview:
                    RequireMethod(context.Request, "GET");
                    await WritePreview(context.Response, context.Request, route.Value!);
                    break;
                case DashboardRouteKind.RefreshUsage:
                    RequireMethod(context.Request, "POST");
                    _ = usage.Records(forceRefresh: true);
                    await WriteJson(context.Response, new { ok = true });
                    break;
                case DashboardRouteKind.Pet:
                    RequireMethod(context.Request, "PUT");
                    callbacks.UpdatePet(await ReadJson<PetRequest>(context.Request));
                    await WriteJson(context.Response, new { ok = true });
                    break;
                case DashboardRouteKind.Autonomy:
                    RequireMethod(context.Request, "PUT");
                    callbacks.UpdateAutonomy(await ReadJson<AutonomyRequest>(context.Request));
                    await WriteJson(context.Response, new { ok = true });
                    break;
                case DashboardRouteKind.ResetPetPosition:
                    RequireMethod(context.Request, "POST");
                    callbacks.ResetPosition();
                    await WriteJson(context.Response, new { ok = true });
                    break;
                case DashboardRouteKind.ImportPet:
                    RequireMethod(context.Request, "POST");
                    await WriteJson(context.Response, new { ok = true, imported = callbacks.ImportPet() });
                    break;
                case DashboardRouteKind.DeletePet:
                    RequireMethod(context.Request, "DELETE");
                    await WriteJson(context.Response, callbacks.RemovePet(route.Value!));
                    break;
                case DashboardRouteKind.ChoosePetsDirectory:
                    RequireMethod(context.Request, "POST");
                    callbacks.ChoosePetsDirectory();
                    await WriteJson(context.Response, new { ok = true });
                    break;
                case DashboardRouteKind.RevealPetsDirectory:
                    RequireMethod(context.Request, "POST");
                    callbacks.RevealPetsDirectory();
                    await WriteJson(context.Response, new { ok = true });
                    break;
                case DashboardRouteKind.Settings:
                    RequireMethod(context.Request, "PUT");
                    callbacks.UpdateSettings(await ReadJson<SettingsRequest>(context.Request));
                    await WriteJson(context.Response, new { ok = true });
                    break;
                case DashboardRouteKind.History:
                    RequireMethod(context.Request, "DELETE");
                    throw new DashboardApiException("unsupported_action", "Windows usage is read directly from provider history and cannot be cleared by PetRunner.", 409);
                default:
                    throw new DashboardApiException("not_found", "Not found.", 404);
            }
        }
        catch (DashboardApiException error)
        {
            await WriteError(context.Response, error.StatusCode, error.Code, error.Message);
        }
        catch (System.Reflection.TargetInvocationException error) when (error.InnerException is DashboardApiException)
        {
            var apiError = (DashboardApiException)error.InnerException;
            await WriteError(context.Response, apiError.StatusCode, apiError.Code, apiError.Message);
        }
        catch (JsonException)
        {
            await WriteError(context.Response, 400, "invalid_json", "The request body is not valid JSON.");
        }
        catch (Exception)
        {
            await WriteError(context.Response, 500, "internal_error", "The dashboard request failed.");
        }
        finally
        {
            context.Response.Close();
        }
    }

    private object State()
    {
        var snapshot = callbacks.Snapshot();
        var records = EnabledRecords(snapshot, usage.Records());
        var today = UsageAnalytics.Filter(records, new UsageFilter("today"));
        var month = UsageAnalytics.Filter(records, new UsageFilter("month"));
        var todayTotals = UsageAnalytics.Aggregate(today);
        var monthTotals = UsageAnalytics.Aggregate(month);
        var topModel = records.Where(record => !string.IsNullOrWhiteSpace(record.Model))
            .GroupBy(record => record.Model!, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(group => group.Sum(record => record.Tokens.Total)).FirstOrDefault()?.Key;
        var inputTotal = todayTotals.Tokens.Input + todayTotals.Tokens.CachedInput;
        return new
        {
            platform = "windows",
            capabilities = new
            {
                usage = true,
                sessions = true,
                petImport = true,
                petRemove = true,
                statusItem = false,
                clearHistory = false,
                cursorUsage = false,
                petsDirectory = true,
                petsDirectoryBrowse = snapshot.PetsDirectoryEditable,
            },
            kpis = new
            {
                todayTokens = todayTotals.Tokens.Total,
                todayCost = todayTotals.KnownCostUsd,
                cacheRatio = inputTotal == 0 ? 0 : (double)todayTotals.Tokens.CachedInput / inputTotal,
                topModel,
                sessionCount = todayTotals.SessionCount,
                monthCost = monthTotals.KnownCostUsd,
            },
            providers = new
            {
                claude = new { enabled = snapshot.ClaudeEnabled },
                codex = new { enabled = snapshot.CodexEnabled },
                cursor = new { enabled = false },
            },
            pets = snapshot.Pets.Select(pet => new { pet.Id, name = pet.DisplayName, pet.Description, version = (int)pet.Version }),
            pet = new
            {
                selectedID = snapshot.SelectedPetId,
                snapshot.Width,
                autonomy = new
                {
                    enabled = snapshot.AutonomyEnabled,
                    minimumWait = snapshot.Autonomy.MinimumWait,
                    maximumWait = snapshot.Autonomy.MaximumWait,
                    actions = snapshot.Autonomy.EnabledActions,
                },
            },
            settings = new
            {
                showStatusItem = true,
                petsDirectory = snapshot.PetsDirectory,
                petsDirectorySource = snapshot.PetsDirectorySource,
                petsDirectoryEditable = snapshot.PetsDirectoryEditable,
                budgets = new
                {
                    claude = snapshot.ClaudeBudget,
                    codex = snapshot.CodexBudget,
                    cursor = new ProviderBudgetSettings(),
                },
            },
            failures = snapshot.Failures,
            server = new { status = "running", host = "127.0.0.1", port = Port },
        };
    }

    private object UsagePayload(HttpListenerRequest request)
    {
        var records = FilteredRecords(request);
        var orderedRecords = records.OrderByDescending(record => record.OccurredAt).ToArray();
        var responseRecords = orderedRecords.Take(500).ToArray();
        var totals = UsageAnalytics.Aggregate(records);
        var buckets = records.GroupBy(record => record.OccurredAt.ToLocalTime().Date)
            .OrderBy(group => group.Key)
            .Select(group => new
            {
                date = group.Key.ToString("yyyy-MM-dd"),
                tokens = group.Sum(record => record.Tokens.Total),
                cost = group.Sum(record => record.Cost.Usd ?? 0),
            });
        return new
        {
            totals = new
            {
                tokens = totals.Tokens.Total,
                input = totals.Tokens.Input,
                cachedInput = totals.Tokens.CachedInput,
                output = totals.Tokens.Output,
                cost = totals.KnownCostUsd,
                sessions = totals.SessionCount,
                recordCount = records.Count,
            },
            buckets,
            records = responseRecords.Select(record => new
            {
                record.Id,
                provider = record.Provider.ToString().ToLowerInvariant(),
                sessionID = record.SessionId,
                record.OccurredAt,
                record.Model,
                tokens = new { record.Tokens.Input, record.Tokens.CachedInput, record.Tokens.Output, record.Tokens.Reasoning, record.Tokens.Total },
                cost = record.Cost.Usd,
            }),
            truncated = orderedRecords.Length > responseRecords.Length,
        };
    }

    private object SessionsPayload(HttpListenerRequest request)
    {
        var sessions = UsageAnalytics.Sessions(FilteredRecords(request));
        var query = request.QueryString["q"] ?? request.QueryString["search"];
        if (!string.IsNullOrWhiteSpace(query))
            sessions = sessions.Where(session =>
                session.Id.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                (session.Model?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false) ||
                session.Provider.ToString().Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        return new
        {
            sessions = sessions.Select(session => new
            {
                id = SessionKey(session),
                name = session.Id,
                provider = session.Provider.ToString().ToLowerInvariant(),
                session.Model,
                status = "finished",
                activity = $"{session.Tokens.Total:N0} tokens",
                cost = session.KnownCostUsd,
                firstSeenAt = session.StartedAt,
                session.UpdatedAt,
                finishedAt = session.UpdatedAt,
                tokens = session.Tokens.Total,
                session.DurationSeconds,
            }),
        };
    }

    private object SessionPayload(string key)
    {
        var snapshot = callbacks.Snapshot();
        var records = EnabledRecords(snapshot, usage.Records());
        var session = UsageAnalytics.Sessions(records).FirstOrDefault(candidate => SessionKey(candidate) == key)
            ?? throw new DashboardApiException("session_not_found", "Session not found.", 404);
        var matching = records.Where(record => record.Provider == session.Provider && record.SessionId == session.Id).OrderBy(record => record.OccurredAt).ToArray();
        return new
        {
            id = key,
            name = session.Id,
            provider = session.Provider.ToString().ToLowerInvariant(),
            session.Model,
            status = "finished",
            activity = $"{session.Tokens.Total:N0} tokens",
            cost = session.KnownCostUsd,
            firstSeenAt = session.StartedAt,
            session.UpdatedAt,
            finishedAt = session.UpdatedAt,
            timeline = matching.Select(record => new
            {
                record.OccurredAt,
                status = "finished",
                record.Model,
                activity = $"{record.Tokens.Total:N0} tokens",
                cost = record.Cost.Usd,
            }),
        };
    }

    private IReadOnlyList<UsageRecord> FilteredRecords(HttpListenerRequest request)
    {
        var range = request.QueryString["range"] ?? "30d";
        UsageProvider? provider = null;
        if (request.QueryString["provider"] is { Length: > 0 } rawProvider)
        {
            if (!Enum.TryParse<UsageProvider>(rawProvider, ignoreCase: true, out var parsed))
                throw new DashboardApiException("invalid_provider", "provider must be claude or codex.");
            provider = parsed;
        }
        try
        {
            var snapshot = callbacks.Snapshot();
            return UsageAnalytics.Filter(
                EnabledRecords(snapshot, usage.Records()),
                new UsageFilter(range, provider, request.QueryString["model"]));
        }
        catch (ArgumentException error) { throw new DashboardApiException("invalid_range", error.Message); }
    }

    private static IReadOnlyList<UsageRecord> EnabledRecords(DashboardHostSnapshot snapshot, IReadOnlyList<UsageRecord> records) =>
        records.Where(record => record.Provider switch
        {
            UsageProvider.Claude => snapshot.ClaudeEnabled,
            UsageProvider.Codex => snapshot.CodexEnabled,
            _ => true,
        }).ToArray();

    private async Task WritePreview(HttpListenerResponse response, HttpListenerRequest request, string petId)
    {
        var pet = callbacks.Snapshot().Pets.FirstOrDefault(candidate => string.Equals(candidate.Id, petId, StringComparison.Ordinal));
        if (pet is null) throw new DashboardApiException("pet_not_found", "Pet not found.", 404);
        var row = QueryInt(request, "row", 0, 0, pet.Version.RowCount() - 1);
        var column = QueryInt(request, "column", 0, 0, 7);
        using var atlas = SpriteAtlas.Load(pet.SpritesheetPath, pet.Version);
        var png = atlas.FramePng(new AtlasAddress(row, column));
        response.ContentType = "image/png";
        response.ContentLength64 = png.Length;
        await response.OutputStream.WriteAsync(png);
    }

    private async Task WriteAsset(HttpListenerResponse response, string name)
    {
        var path = Path.Combine(assetDirectory, name);
        if (!File.Exists(path)) throw new DashboardApiException("asset_not_found", "Dashboard asset not found.", 404);
        var bytes = await File.ReadAllBytesAsync(path, cancellation.Token);
        response.ContentType = name.EndsWith(".css", StringComparison.Ordinal) ? "text/css; charset=utf-8"
            : name.EndsWith(".js", StringComparison.Ordinal) ? "text/javascript; charset=utf-8"
            : "text/html; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        await response.OutputStream.WriteAsync(bytes, cancellation.Token);
    }

    private async Task<T> ReadJson<T>(HttpListenerRequest request)
    {
        if (request.ContentLength64 > MaxBodyBytes) throw new DashboardApiException("body_too_large", "Request body is too large.");
        using var limited = new MemoryStream();
        var buffer = new byte[8192];
        var total = 0;
        while (true)
        {
            var read = await request.InputStream.ReadAsync(buffer, cancellation.Token);
            if (read == 0) break;
            total += read;
            if (total > MaxBodyBytes) throw new DashboardApiException("body_too_large", "Request body is too large.");
            limited.Write(buffer, 0, read);
        }
        limited.Position = 0;
        return await JsonSerializer.DeserializeAsync<T>(limited, jsonOptions, cancellation.Token)
            ?? throw new DashboardApiException("invalid_json", "The request body is empty.");
    }

    private async Task WriteJson(HttpListenerResponse response, object value, int statusCode = 200)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, value.GetType(), jsonOptions);
        response.StatusCode = statusCode;
        response.ContentType = "application/json; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        await response.OutputStream.WriteAsync(bytes, cancellation.Token);
    }

    private Task WriteError(HttpListenerResponse response, int statusCode, string code, string message) =>
        WriteJson(response, new { code, message }, statusCode);

    private void ValidateSameOrigin(HttpListenerRequest request)
    {
        if (string.Equals(request.Headers["Origin"], Origin, StringComparison.OrdinalIgnoreCase)) return;
        if (request.Headers["Origin"] is null && string.Equals(request.Headers["Sec-Fetch-Site"], "same-origin", StringComparison.OrdinalIgnoreCase)) return;
        throw new DashboardApiException("origin_rejected", "Mutation requests must originate from this dashboard.", 400);
    }

    private static void RequireMethod(HttpListenerRequest request, string method)
    {
        if (!string.Equals(request.HttpMethod, method, StringComparison.Ordinal))
            throw new DashboardApiException("invalid_method", $"This endpoint requires {method}.");
    }

    private static bool IsMutation(DashboardRouteKind route) => route is
        DashboardRouteKind.RefreshUsage or DashboardRouteKind.Pet or DashboardRouteKind.Autonomy or
        DashboardRouteKind.ResetPetPosition or DashboardRouteKind.ImportPet or DashboardRouteKind.DeletePet or
        DashboardRouteKind.ChoosePetsDirectory or DashboardRouteKind.RevealPetsDirectory or
        DashboardRouteKind.Settings or DashboardRouteKind.History;

    private static int QueryInt(HttpListenerRequest request, string key, int fallback, int minimum, int maximum)
    {
        var raw = request.QueryString[key];
        if (raw is null) return fallback;
        if (!int.TryParse(raw, out var value) || value < minimum || value > maximum)
            throw new DashboardApiException("invalid_frame", $"{key} must be between {minimum} and {maximum}.");
        return value;
    }

    private static string SessionKey(UsageSession session) => $"{session.Provider.ToString().ToLowerInvariant()}:{session.Id}";

    private static void ApplySecurityHeaders(HttpListenerResponse response)
    {
        response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
        response.Headers["Cache-Control"] = "no-store";
        response.Headers["X-Content-Type-Options"] = "nosniff";
        response.Headers["X-Frame-Options"] = "DENY";
        response.Headers["Referrer-Policy"] = "no-referrer";
    }

    public void Dispose()
    {
        cancellation.Cancel();
        listener?.Stop();
        listener?.Close();
        listener = null;
        try { listenerTask?.Wait(TimeSpan.FromSeconds(1)); } catch { }
        cancellation.Dispose();
    }
}
