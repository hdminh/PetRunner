namespace PetRunner.Core;

public enum DashboardRouteKind
{
    NotFound,
    Asset,
    State,
    Usage,
    Sessions,
    Session,
    PetPreview,
    PetSpritesheet,
    RefreshUsage,
    Pet,
    Autonomy,
    ResetPetPosition,
    ImportPet,
    DeletePet,
    ChoosePetsDirectory,
    RevealPetsDirectory,
    Settings,
    History,
}

public readonly record struct DashboardRoute(DashboardRouteKind Kind, string? Value = null)
{
    /// <summary>Flat files Vite copies from DashboardWeb/public/ plus the HTML shell.</summary>
    private static readonly HashSet<string> Assets =
    [
        "index.html",
        "favicon.svg",
        "favicon-32.png",
        "favicon-48.png",
        "apple-touch-icon.png",
        // Legacy non-Vite shell (kept for older layouts / tests).
        "styles.css",
        "app.js",
    ];

    public static DashboardRoute Parse(string absolutePath, string token)
    {
        if (string.IsNullOrEmpty(absolutePath) || absolutePath[0] != '/') return new(DashboardRouteKind.NotFound);
        var prefix = $"/{token}";
        if (!absolutePath.StartsWith(prefix, StringComparison.Ordinal) ||
            (absolutePath.Length > prefix.Length && absolutePath[prefix.Length] != '/')) return new(DashboardRouteKind.NotFound);
        var relative = absolutePath[prefix.Length..].TrimStart('/');
        if (relative.Length == 0) return new(DashboardRouteKind.Asset, "index.html");
        if (IsAllowedAsset(relative)) return new(DashboardRouteKind.Asset, relative);

        const string api = "api/v1/";
        if (!relative.StartsWith(api, StringComparison.Ordinal)) return new(DashboardRouteKind.NotFound);
        var endpoint = relative[api.Length..].TrimEnd('/');
        return endpoint switch
        {
            "state" or "overview" => new(DashboardRouteKind.State),
            "usage" => new(DashboardRouteKind.Usage),
            "sessions" => new(DashboardRouteKind.Sessions),
            "usage/refresh" => new(DashboardRouteKind.RefreshUsage),
            "pet" => new(DashboardRouteKind.Pet),
            "autonomy" => new(DashboardRouteKind.Autonomy),
            "pet/reset-position" => new(DashboardRouteKind.ResetPetPosition),
            "pet/import" => new(DashboardRouteKind.ImportPet),
            "pets/choose-directory" => new(DashboardRouteKind.ChoosePetsDirectory),
            "pets/reveal-directory" => new(DashboardRouteKind.RevealPetsDirectory),
            "settings" => new(DashboardRouteKind.Settings),
            "history" => new(DashboardRouteKind.History),
            _ when endpoint.StartsWith("sessions/", StringComparison.Ordinal) && endpoint.Length > "sessions/".Length =>
                ValueRoute(DashboardRouteKind.Session, endpoint["sessions/".Length..]),
            _ when endpoint.StartsWith("pets/", StringComparison.Ordinal) && endpoint.EndsWith("/preview", StringComparison.Ordinal) =>
                ValueRoute(DashboardRouteKind.PetPreview, endpoint["pets/".Length..^"/preview".Length]),
            _ when endpoint.StartsWith("pets/", StringComparison.Ordinal) && endpoint.EndsWith("/spritesheet", StringComparison.Ordinal) =>
                ValueRoute(DashboardRouteKind.PetSpritesheet, endpoint["pets/".Length..^"/spritesheet".Length]),
            _ when endpoint.StartsWith("pets/", StringComparison.Ordinal) && endpoint.Length > "pets/".Length && !endpoint["pets/".Length..].Contains('/') =>
                ValueRoute(DashboardRouteKind.DeletePet, endpoint["pets/".Length..]),
            _ => new(DashboardRouteKind.NotFound),
        };
    }

    private static bool IsAllowedAsset(string relative)
    {
        if (relative.Contains("..", StringComparison.Ordinal) || relative.Contains('\\')) return false;
        var parts = relative.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Any(part => part is "." or "..")) return false;
        if (Assets.Contains(relative)) return true;
        // Vite hashed bundles: assets/<file>
        return relative.StartsWith("assets/", StringComparison.Ordinal) && parts.Length == 2;
    }

    private static DashboardRoute ValueRoute(DashboardRouteKind kind, string encoded)
    {
        if (encoded.Length == 0 || encoded.Contains('/')) return new(DashboardRouteKind.NotFound);
        try
        {
            var decoded = Uri.UnescapeDataString(encoded);
            return decoded.Length == 0 || decoded.Contains('/') || decoded is "." or ".."
                ? new(DashboardRouteKind.NotFound)
                : new(kind, decoded);
        }
        catch (UriFormatException)
        {
            return new(DashboardRouteKind.NotFound);
        }
    }
}
