using System.Diagnostics;
using System.IO;
using System.Windows;
using PetRunner.Core;
using Forms = System.Windows.Forms;

namespace PetRunner.Windows;

public partial class App : System.Windows.Application
{
    private OverlayWindow? overlay;
    private TrayController? tray;
    private DashboardServer? dashboard;
    private SingleInstanceBridge? singleInstance;
    private AppSettings settings = new();
    private string petsPath = "";
    private string petsDirectorySource = "default";
    private bool petsDirectoryLockedByCLI;
    private IReadOnlyList<PetDescriptor> pets = [];
    private IReadOnlyList<PetFailure> failures = [];

    private void OnStartup(object sender, StartupEventArgs args)
    {
        var background = args.Args.Contains("--background", StringComparer.Ordinal);
        singleInstance = SingleInstanceBridge.TryBecomePrimary(
            () => Dispatcher.BeginInvoke(new Action(OpenDashboard)),
            activateExisting: !background);
        if (singleInstance is null)
        {
            Shutdown();
            return;
        }
        settings = SettingsStore.Load();
        settings.ClaudeBudget ??= new ProviderBudgetSettings();
        settings.CodexBudget ??= new ProviderBudgetSettings();
        petsPath = ResolvePetsPath(args.Args);
        InstallBundledDefaultPetIfNeeded();
        overlay = new OverlayWindow();
        settings.SetAutonomyConfiguration(settings.GetAutonomyConfiguration());
        overlay.SetAutonomyEnabled(settings.AutonomyEnabled);
        overlay.SetAutonomyConfiguration(settings.GetAutonomyConfiguration());
        tray = new TrayController(ChangePet, ChangeSize, Reload, ToggleAutonomy, ResetPosition, OpenDashboard, Quit);
        Reload();
        StartDashboard();
        if (!background) OpenDashboard();
    }

    private void Reload()
    {
        var scan = PetPackageLoader.LoadDirectory(petsPath);
        pets = scan.Pets;
        failures = scan.Failures;
        var selected = PetSelectionOrdering.OrderedCandidates(pets, settings.SelectedPetId).FirstOrDefault();
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

    private void StartDashboard()
    {
        try
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var codexRoot = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (string.IsNullOrWhiteSpace(codexRoot)) codexRoot = Path.Combine(home, ".codex");
            var usage = new LocalUsageIndex(
                codexRoot,
                [Path.Combine(home, ".claude", "projects"), Path.Combine(home, ".config", "claude", "projects")]);
            var callbacks = new DashboardCallbacks(
                () => Dispatcher.Invoke(CaptureDashboardState),
                request => Dispatcher.Invoke(() => UpdatePet(request)),
                request => Dispatcher.Invoke(() => UpdateAutonomy(request)),
                () => Dispatcher.Invoke(ResetPosition),
                () => Dispatcher.Invoke(ImportPet),
                id => Dispatcher.Invoke(() => RemovePet(id)),
                () => Dispatcher.Invoke(ChoosePetsDirectory),
                () => Dispatcher.Invoke(RevealPetsDirectory),
                request => Dispatcher.Invoke(() => UpdateSettings(request)));
            dashboard = new DashboardServer(Path.Combine(AppContext.BaseDirectory, "DashboardWeb"), usage, callbacks);
            dashboard.Start();
        }
        catch (Exception error)
        {
            dashboard?.Dispose();
            dashboard = null;
            System.Windows.MessageBox.Show(
                $"The local dashboard could not start.\n\n{error.Message}",
                "PetRunner Dashboard",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void OpenDashboard()
    {
        if (dashboard is null) return;
        try { Process.Start(new ProcessStartInfo(dashboard.DashboardUrl) { UseShellExecute = true }); }
        catch (Exception error)
        {
            System.Windows.MessageBox.Show(error.Message, "PetRunner Dashboard", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private DashboardHostSnapshot CaptureDashboardState() => new(
        pets,
        failures,
        settings.SelectedPetId,
        settings.Width,
        settings.AutonomyEnabled,
        settings.GetAutonomyConfiguration(),
        settings.ClaudeBudget,
        settings.CodexBudget,
        settings.ClaudeEnabled,
        settings.CodexEnabled,
        petsPath,
        petsDirectorySource,
        !petsDirectoryLockedByCLI);

    private void UpdatePet(PetRequest request)
    {
        if (request.Id is null && request.Width is null)
            throw new DashboardApiException("invalid_pet", "Provide a pet id or width.");
        if (request.Id is not null)
        {
            if (!pets.Any(pet => pet.Id == request.Id)) throw new DashboardApiException("pet_not_found", "Pet not found.", 404);
            ChangePet(request.Id);
        }
        if (request.Width is { } width)
        {
            if (!double.IsFinite(width) || width is < 80 or > 224)
                throw new DashboardApiException("invalid_size", "Pet width must be between 80 and 224.");
            ChangeSize(width);
        }
    }

    private void UpdateAutonomy(AutonomyRequest request)
    {
        var current = settings.GetAutonomyConfiguration();
        var actions = current.EnabledActions;
        if (request.Actions is not null)
        {
            var parsed = new List<AutonomousActionKind>();
            foreach (var value in request.Actions)
            {
                if (!Enum.TryParse<AutonomousActionKind>(value, ignoreCase: true, out var action) || !Enum.IsDefined(action))
                    throw new DashboardApiException("invalid_autonomy", $"Unknown autonomous action: {value}");
                parsed.Add(action);
            }
            actions = parsed.ToHashSet();
        }
        if (!AutonomyConfiguration.TryCreate(
                request.MinimumWait ?? current.MinimumWait,
                request.MaximumWait ?? current.MaximumWait,
                actions,
                out var configuration))
            throw new DashboardApiException("invalid_autonomy", "Waits must be between 5 and 30 seconds and at least one action must be enabled.");

        settings.SetAutonomyConfiguration(configuration!);
        if (request.Enabled is { } enabled) settings.AutonomyEnabled = enabled;
        overlay?.SetAutonomyEnabled(settings.AutonomyEnabled);
        overlay?.SetAutonomyConfiguration(configuration!);
        SettingsStore.Save(settings);
        RefreshTray(settings.SelectedPetId);
    }

    private void UpdateSettings(SettingsRequest request)
    {
        if (request.ShowStatusItem == false)
            throw new DashboardApiException("unsupported_action", "The Windows tray icon cannot be hidden.", 409);
        if (request.PetsDirectory is { } petsDirectory)
        {
            ApplyPetsDirectory(petsDirectory);
        }
        if (request.Budgets is null)
        {
            if (request.PetsDirectory is not null) SettingsStore.Save(settings);
            return;
        }
        if (request.Budgets.Cursor is { DailyUSD: not null } or { MonthlyUSD: not null })
            throw new DashboardApiException("unsupported_action", "Cursor usage budgets are not available on Windows.", 409);
        if (request.Budgets.Claude is { } claude) UpdateBudget(settings.ClaudeBudget, claude);
        if (request.Budgets.Codex is { } codex) UpdateBudget(settings.CodexBudget, codex);
        SettingsStore.Save(settings);
    }

    private object RemovePet(string id)
    {
        try
        {
            _ = PetRemovalService.Remove(id, petsPath);
        }
        catch (PetRemovalException error)
        {
            throw new DashboardApiException(error.Code, error.Message, error.Code == "pet_not_found" ? 404 : 400);
        }
        if (string.Equals(settings.SelectedPetId, id, StringComparison.Ordinal))
            settings.SelectedPetId = null;
        Reload();
        SettingsStore.Save(settings);
        return new { ok = true, removed = id, selectedID = settings.SelectedPetId };
    }

    private void ChoosePetsDirectory()
    {
        if (petsDirectoryLockedByCLI)
            throw new DashboardApiException("invalid_pets_directory", "Pets directory was set with --pets-dir and cannot be changed while running.");
        using var picker = new Forms.FolderBrowserDialog
        {
            Description = "Choose the folder PetRunner should scan for pet packages",
            UseDescriptionForTitle = true,
            SelectedPath = Directory.Exists(petsPath) ? petsPath : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        if (picker.ShowDialog() != Forms.DialogResult.OK || string.IsNullOrWhiteSpace(picker.SelectedPath)) return;
        ApplyPetsDirectory(picker.SelectedPath);
        SettingsStore.Save(settings);
    }

    private void RevealPetsDirectory()
    {
        Directory.CreateDirectory(petsPath);
        Process.Start(new ProcessStartInfo(petsPath) { UseShellExecute = true });
    }

    private void ApplyPetsDirectory(string path)
    {
        if (petsDirectoryLockedByCLI)
            throw new DashboardApiException("invalid_pets_directory", "Pets directory was set with --pets-dir and cannot be changed while running.");
        var trimmed = path.Trim();
        if (string.IsNullOrEmpty(trimmed))
            throw new DashboardApiException("invalid_pets_directory", "Choose a valid pets folder path.");
        petsPath = Path.GetFullPath(trimmed);
        settings.PetsDirectory = petsPath;
        petsDirectorySource = "preference";
        InstallBundledDefaultPetIfNeeded();
        Reload();
    }

    private void InstallBundledDefaultPetIfNeeded()
    {
        try
        {
            var bundled = Path.Combine(AppContext.BaseDirectory, DefaultPet.BundleRelativePath);
            _ = new DefaultPetInstaller().InstallIfMissing(bundled, petsPath);
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to install bundled default pet: {error.Message}");
        }
    }

    private static void UpdateBudget(ProviderBudgetSettings target, BudgetRequest request)
    {
        if (!ValidBudget(request.DailyUSD) || !ValidBudget(request.MonthlyUSD))
            throw new DashboardApiException("invalid_budget", "Budgets must be positive USD values up to 1,000,000.");
        target.Update(request.DailyUSD, request.MonthlyUSD);
    }

    private static bool ValidBudget(double? value) => value is null || double.IsFinite(value.Value) && value is > 0 and <= 1_000_000;

    private bool ImportPet()
    {
        var choice = System.Windows.MessageBox.Show(
            "Import a ZIP download (Yes) or an unzipped pet folder (No)?",
            "Import Pet",
            MessageBoxButton.YesNoCancel,
            MessageBoxImage.Question);
        if (choice == MessageBoxResult.Cancel) return false;

        string? source = null;
        if (choice == MessageBoxResult.Yes)
        {
            using var zipPicker = new Forms.OpenFileDialog
            {
                Title = "Import pet package ZIP",
                Filter = "Pet package ZIP (*.zip)|*.zip|All files (*.*)|*.*",
                CheckFileExists = true,
                Multiselect = false,
            };
            if (zipPicker.ShowDialog() != Forms.DialogResult.OK) return false;
            source = zipPicker.FileName;
        }
        else
        {
            using var folderPicker = new Forms.FolderBrowserDialog
            {
                Description = "Choose a PetRunner pet package folder",
                UseDescriptionForTitle = true,
                ShowNewFolderButton = false,
            };
            if (folderPicker.ShowDialog() != Forms.DialogResult.OK) return false;
            source = folderPicker.SelectedPath;
        }

        var backupRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PetRunner", "pet-backups");
        var importer = new PetImportService();
        try
        {
            _ = importer.Import(source, petsPath, backupRoot);
        }
        catch (DuplicatePetException duplicate)
        {
            var result = System.Windows.MessageBox.Show(
                $"A pet with id {duplicate.PetId} already exists. Replace it? A local backup will be kept.",
                "Replace Pet",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);
            if (result != MessageBoxResult.Yes) return false;
            try { _ = importer.Import(source, petsPath, backupRoot, replaceExisting: true); }
            catch (Exception error)
            {
                System.Windows.MessageBox.Show(error.Message, "Could Not Import Pet", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }
        }
        catch (Exception error)
        {
            System.Windows.MessageBox.Show(error.Message, "Could Not Import Pet", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
        Reload();
        return true;
    }

    private void RefreshTray(string? selectedId) =>
        tray?.Update(pets, failures, selectedId, settings.Width, settings.AutonomyEnabled);

    private void Quit()
    {
        Shutdown();
    }

    private void OnExit(object sender, ExitEventArgs args)
    {
        dashboard?.Dispose();
        overlay?.Dispose();
        tray?.Dispose();
        singleInstance?.Dispose();
    }

    private string ResolvePetsPath(string[] args)
    {
        var index = Array.IndexOf(args, "--pets-dir");
        if (index >= 0 && index + 1 < args.Length)
        {
            petsDirectoryLockedByCLI = true;
            petsDirectorySource = "cli";
            return Path.GetFullPath(args[index + 1]);
        }
        if (!string.IsNullOrWhiteSpace(settings.PetsDirectory))
        {
            petsDirectorySource = "preference";
            return Path.GetFullPath(settings.PetsDirectory);
        }
        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (!string.IsNullOrWhiteSpace(codexHome))
        {
            petsDirectorySource = "codexHome";
            return Path.Combine(codexHome, "pets");
        }
        petsDirectorySource = "default";
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "pets");
    }
}
