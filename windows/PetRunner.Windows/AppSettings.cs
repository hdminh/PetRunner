using System.IO;
using System.Text.Json;
using PetRunner.Core;

namespace PetRunner.Windows;

internal sealed class AppSettings
{
    public string? SelectedPetId { get; set; }
    public double Width { get; set; } = 112;
    public double? Left { get; set; }
    public double? Top { get; set; }
    public bool AutonomyEnabled { get; set; } = true;
    public double AutonomyMinimumWait { get; set; } = AutonomyPolicy.MinimumWait;
    public double AutonomyMaximumWait { get; set; } = AutonomyPolicy.MaximumWait;
    public AutonomousActionKind[] EnabledAutonomousActions { get; set; } = Enum.GetValues<AutonomousActionKind>();

    public AutonomyConfiguration GetAutonomyConfiguration()
    {
        return AutonomyConfiguration.TryCreate(
            AutonomyMinimumWait,
            AutonomyMaximumWait,
            EnabledAutonomousActions ?? [],
            out var configuration)
            ? configuration!
            : AutonomyConfiguration.Default;
    }

    public void SetAutonomyConfiguration(AutonomyConfiguration configuration)
    {
        AutonomyMinimumWait = configuration.MinimumWait;
        AutonomyMaximumWait = configuration.MaximumWait;
        EnabledAutonomousActions = configuration.EnabledActions.ToArray();
    }
}

internal static class SettingsStore
{
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PetRunner");
    private static readonly string FilePath = Path.Combine(DirectoryPath, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings()
                : new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(settings));
    }
}
