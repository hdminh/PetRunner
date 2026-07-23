namespace PetRunner.Tests;

internal static class Program
{
    private static int Main()
    {
        var tests = new (string Name, Action Run)[]
        {
            (nameof(AnimationTests), AnimationTests.Run),
            (nameof(AutonomyTests), AutonomyTests.Run),
            (nameof(PhysicsTests), PhysicsTests.Run),
            (nameof(PetLoaderTests), PetLoaderTests.Run),
            (nameof(PetImportTests), PetImportTests.Run),
            (nameof(PetRemovalTests), PetRemovalTests.Run),
            (nameof(SpriteAtlasTests), SpriteAtlasTests.Run),
            (nameof(UsageTests), UsageTests.Run),
            (nameof(DashboardRouteTests), DashboardRouteTests.Run),
        };

        try
        {
            foreach (var test in tests)
            {
                test.Run();
                Console.WriteLine($"PASS {test.Name}");
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"FAIL {error.Message}");
            return 1;
        }
    }
}

internal static class Check
{
    public static void Equal<T>(T expected, T actual) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}, got {actual}");
    }

    public static void True(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
}
