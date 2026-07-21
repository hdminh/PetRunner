using System.Windows;
using PetRunner.Core;
using WpfControls = System.Windows.Controls;

namespace PetRunner.Windows;

internal sealed class SettingsWindow : Window
{
    private readonly WpfControls.ComboBox minimumWait = new();
    private readonly WpfControls.ComboBox maximumWait = new();
    private readonly Dictionary<AutonomousActionKind, WpfControls.CheckBox> actionBoxes = [];
    private readonly Action<AutonomyConfiguration> save;

    public SettingsWindow(AppSettings settings, Action<AutonomyConfiguration> save)
    {
        this.save = save;
        Title = "PetRunner Settings";
        Width = 330;
        Height = 310;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var panel = new WpfControls.StackPanel { Margin = new Thickness(20) };
        Content = panel;
        panel.Children.Add(new WpfControls.TextBlock { Text = "Autonomous Pet", FontWeight = FontWeights.SemiBold });
        panel.Children.Add(new WpfControls.TextBlock { Text = "Wait between actions", Margin = new Thickness(0, 12, 0, 4) });
        var waits = new WpfControls.StackPanel { Orientation = WpfControls.Orientation.Horizontal };
        for (var seconds = 5; seconds <= 30; seconds++)
        {
            minimumWait.Items.Add(seconds);
            maximumWait.Items.Add(seconds);
        }
        minimumWait.SelectedItem = (int)settings.AutonomyMinimumWait;
        maximumWait.SelectedItem = (int)settings.AutonomyMaximumWait;
        waits.Children.Add(minimumWait);
        waits.Children.Add(new WpfControls.TextBlock { Text = " to ", VerticalAlignment = VerticalAlignment.Center });
        waits.Children.Add(maximumWait);
        waits.Children.Add(new WpfControls.TextBlock { Text = " seconds", VerticalAlignment = VerticalAlignment.Center });
        panel.Children.Add(waits);

        panel.Children.Add(new WpfControls.TextBlock { Text = "Enabled actions", Margin = new Thickness(0, 16, 0, 4) });
        foreach (var action in Enum.GetValues<AutonomousActionKind>())
        {
            var box = new WpfControls.CheckBox { Content = action.ToString(), IsChecked = settings.EnabledAutonomousActions.Contains(action) };
            actionBoxes.Add(action, box);
            panel.Children.Add(box);
        }

        var buttons = new WpfControls.StackPanel { Orientation = WpfControls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = new WpfControls.Button { Content = "Cancel", MinWidth = 80, Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => Close();
        var apply = new WpfControls.Button { Content = "Save", MinWidth = 80, IsDefault = true };
        apply.Click += (_, _) => Apply();
        buttons.Children.Add(cancel);
        buttons.Children.Add(apply);
        panel.Children.Add(buttons);
    }

    private void Apply()
    {
        var enabled = actionBoxes.Where(pair => pair.Value.IsChecked == true).Select(pair => pair.Key);
        if (minimumWait.SelectedItem is not int minimum || maximumWait.SelectedItem is not int maximum ||
            !AutonomyConfiguration.TryCreate(minimum, maximum, enabled, out var configuration))
        {
            System.Windows.MessageBox.Show(this, "Choose at least one action and a valid wait range.", "PetRunner Settings", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        save(configuration!);
        Close();
    }
}
