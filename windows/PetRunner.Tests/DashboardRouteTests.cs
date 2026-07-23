using PetRunner.Core;

namespace PetRunner.Tests;

internal static class DashboardRouteTests
{
    public static void Run()
    {
        const string token = "abc123";
        Check.Equal(DashboardRouteKind.Asset, DashboardRoute.Parse("/abc123/", token).Kind);
        Check.Equal(DashboardRouteKind.Usage, DashboardRoute.Parse("/abc123/api/v1/usage", token).Kind);
        Check.Equal("pet one", DashboardRoute.Parse("/abc123/api/v1/pets/pet%20one/preview", token).Value!);
        Check.Equal(DashboardRouteKind.NotFound, DashboardRoute.Parse("/wrong/api/v1/state", token).Kind);
        Check.Equal(DashboardRouteKind.NotFound, DashboardRoute.Parse("/abc123/api/v1/pets/%2e%2e/preview", token).Kind);
        Check.Equal(DashboardRouteKind.NotFound, DashboardRoute.Parse("/abc123/../settings.json", token).Kind);
        Check.Equal(DashboardRouteKind.DeletePet, DashboardRoute.Parse("/abc123/api/v1/pets/misty", token).Kind);
        Check.Equal("misty", DashboardRoute.Parse("/abc123/api/v1/pets/misty", token).Value!);
        Check.Equal(DashboardRouteKind.ChoosePetsDirectory, DashboardRoute.Parse("/abc123/api/v1/pets/choose-directory", token).Kind);
        Check.Equal(DashboardRouteKind.RevealPetsDirectory, DashboardRoute.Parse("/abc123/api/v1/pets/reveal-directory", token).Kind);
    }
}
