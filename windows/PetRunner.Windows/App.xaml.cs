using System.IO;
using System.Windows;
using PetRunner.Core;

namespace PetRunner.Windows;

public partial class App : System.Windows.Application
{
    private OverlayWindow? overlay;
    private TrayController? tray;
    private AppSettings settings = new();
    private string petsPath = "";
    private IReadOnlyList<PetDescriptor> pets = [];
    private IReadOnlyList<PetFailure> failures = [];

    private void OnStartup(object sender, StartupEventArgs args)
    {
        petsPath = ResolvePetsPath(args.Args);
        settings = SettingsStore.Load();
        overlay = new OverlayWindow();
        settings.SetAutonomyConfiguration(settings.GetAutonomyConfiguration());
        overlay.SetAutonomyEnabled(settings.AutonomyEnabled);
        overlay.SetAutonomyConfiguration(settings.GetAutonomyConfiguration());
        tray = new TrayController(ChangePet, ChangeSize, Reload, ToggleAutonomy, ResetPosition, OpenSettings, Quit);
        Reload();
    }

    private void Reload()
    {
        var scan = PetPackageLoader.LoadDirectory(petsPath);
        pets = scan.Pets;
        failures = scan.Failures;
        var selected = pets.FirstOrDefault(pet => pet.Id == settings.SelectedPetId) ?? pets.FirstOrDefault();
        if (selected is null)
        {
            overlay?.HidePet();
        }
        else
        {
            ShowPet(selected, restorePosition: true);
        }
        RefreshTray(selected?.Id);
    }

    private void ChangePet(string id)
    {
        var pet = pets.FirstOrDefault(candidate => candidate.Id == id);
        if (pet is null) return;
        ShowPet(pet, restorePosition: false);
        RefreshTray(pet.Id);
    }

    private void ShowPet(PetDescriptor pet, bool restorePosition)
    {
        try
        {
            overlay!.ShowPet(
                pet,
                settings.Width,
                restorePosition && settings.Left is not null && settings.Top is not null
                    ? (settings.Left.Value, settings.Top.Value)
                    : null);
            settings.SelectedPetId = pet.Id;
            overlay.PositionChanged = (left, top) =>
            {
                settings.Left = left;
                settings.Top = top;
                SettingsStore.Save(settings);
            };
            SettingsStore.Save(settings);
        }
        catch (Exception error)
        {
            failures = [.. failures, new PetFailure(pet.Id, error.Message)];
            overlay?.HidePet();
        }
    }

    private void ChangeSize(double width)
    {
        settings.Width = width;
        overlay?.SetWidth(width);
        SettingsStore.Save(settings);
        RefreshTray(settings.SelectedPetId);
    }

    private void ToggleAutonomy()
    {
        settings.AutonomyEnabled = !settings.AutonomyEnabled;
        overlay?.SetAutonomyEnabled(settings.AutonomyEnabled);
        SettingsStore.Save(settings);
        RefreshTray(settings.SelectedPetId);
    }

    private void ResetPosition()
    {
        overlay?.ResetPositionToDefault();
    }

    private void OpenSettings()
    {
        var window = new SettingsWindow(settings, configuration =>
        {
            settings.SetAutonomyConfiguration(configuration);
            overlay?.SetAutonomyConfiguration(configuration);
            SettingsStore.Save(settings);
        });
        window.Show();
        window.Activate();
    }

    private void RefreshTray(string? selectedId) =>
        tray?.Update(pets, failures, selectedId, settings.Width, settings.AutonomyEnabled);

    private void Quit()
    {
        Shutdown();
    }

    private void OnExit(object sender, ExitEventArgs args)
    {
        overlay?.Dispose();
        tray?.Dispose();
    }

    private static string ResolvePetsPath(string[] args)
    {
        var index = Array.IndexOf(args, "--pets-dir");
        if (index >= 0 && index + 1 < args.Length) return Path.GetFullPath(args[index + 1]);
        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        return string.IsNullOrWhiteSpace(codexHome)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "pets")
            : Path.Combine(codexHome, "pets");
    }
}
