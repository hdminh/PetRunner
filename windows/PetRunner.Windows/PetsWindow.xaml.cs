using System.Diagnostics;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace PetRunner.Windows;

public partial class PetsWindow : Window
{
    private readonly string petsUrl;
    private readonly string allowedOrigin;
    private bool configured;

    public PetsWindow(string petsUrl, string allowedOrigin)
    {
        this.petsUrl = petsUrl;
        this.allowedOrigin = allowedOrigin.TrimEnd('/');
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (configured) return;
        configured = true;
        try
        {
            await WebView.EnsureCoreWebView2Async();
            WebView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
            WebView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            WebView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            WebView.CoreWebView2.NewWindowRequested += OnNewWindowRequested;
            WebView.CoreWebView2.NavigationStarting += OnNavigationStarting;
            WebView.Source = new Uri(petsUrl);
        }
        catch (Exception error)
        {
            System.Windows.MessageBox.Show(
                $"WebView2 could not start. Install the WebView2 Runtime and try again.\n\n{error.Message}",
                "PetRunner",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            Close();
        }
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (IsAllowedNavigation(args.Uri)) return;
        OpenExternal(args.Uri);
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (IsAllowedNavigation(args.Uri)) return;
        args.Cancel = true;
        OpenExternal(args.Uri);
    }

    private bool IsAllowedNavigation(string uri)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed)) return false;
        // WebView2 may briefly use about:blank during init; keep it in-process.
        if (parsed.Scheme.Equals("about", StringComparison.OrdinalIgnoreCase)
            && (string.IsNullOrEmpty(parsed.AbsolutePath) || parsed.AbsolutePath == "blank"))
            return true;
        if (parsed.Scheme is not ("http" or "https")) return false;
        return string.Equals(parsed.GetLeftPart(UriPartial.Authority), allowedOrigin, StringComparison.OrdinalIgnoreCase);
    }

    private static void OpenExternal(string uri)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed)) return;
        if (parsed.Scheme is not ("http" or "https")) return;
        try
        {
            Process.Start(new ProcessStartInfo(parsed.AbsoluteUri) { UseShellExecute = true });
        }
        catch
        {
            // Ignore failures opening the system browser.
        }
    }
}
