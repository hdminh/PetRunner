using System.Drawing;
using System.IO;
using System.Windows.Forms;
using PetRunner.Core;

namespace PetRunner.Windows;

internal sealed class TrayController : IDisposable
{
    private readonly Action<string> changePet;
    private readonly Action<double> changeSize;
    private readonly Action reload;
    private readonly Action toggleAutonomy;
    private readonly Action togglePetHidden;
    private readonly Action toggleQuotaBarVisible;
    private readonly Action<string> setQuotaBarMode;
    private readonly Action resetPosition;
    private readonly Action openDashboard;
    private readonly Action quit;
    private readonly Icon applicationIcon;
    private readonly NotifyIcon icon;
    private readonly Dictionary<string, Image> thumbnails = [];

    public TrayController(
        Action<string> changePet,
        Action<double> changeSize,
        Action reload,
        Action toggleAutonomy,
        Action togglePetHidden,
        Action toggleQuotaBarVisible,
        Action<string> setQuotaBarMode,
        Action resetPosition,
        Action openDashboard,
        Action quit)
    {
        this.changePet = changePet;
        this.changeSize = changeSize;
        this.reload = reload;
        this.toggleAutonomy = toggleAutonomy;
        this.togglePetHidden = togglePetHidden;
        this.toggleQuotaBarVisible = toggleQuotaBarVisible;
        this.setQuotaBarMode = setQuotaBarMode;
        this.resetPosition = resetPosition;
        this.openDashboard = openDashboard;
        this.quit = quit;
        applicationIcon = LoadApplicationIcon();
        icon = new NotifyIcon
        {
            Icon = applicationIcon,
            Text = "PetRunner",
            Visible = true,
        };
    }

    private static Icon LoadApplicationIcon()
    {
        using var stream = typeof(TrayController).Assembly.GetManifestResourceStream("PetRunner.AppIcon.ico");
        if (stream is null) return (Icon)SystemIcons.Application.Clone();
        using var source = new Icon(stream);
        return (Icon)source.Clone();
    }

    public void Update(
        IReadOnlyList<PetDescriptor> pets,
        IReadOnlyList<PetFailure> failures,
        string? selectedId,
        double selectedWidth,
        bool autonomyEnabled,
        bool petHidden,
        bool quotaBarVisible = true,
        string quotaBarMode = "auto")
    {
        foreach (var image in thumbnails.Values) image.Dispose();
        thumbnails.Clear();
        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem("PetRunner") { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());

        var changePetMenu = new ToolStripMenuItem("Change Pet");
        BuildPetMenu(changePetMenu, pets, selectedId);
        menu.Items.Add(changePetMenu);

        var sizeMenu = new ToolStripMenuItem("Size");
        foreach (var choice in new[] { ("Small", 80d), ("Medium", 112d), ("Large", 160d), ("XL", 224d) })
        {
            var item = new ToolStripMenuItem($"{choice.Item1} — {choice.Item2:0} px")
            {
                Checked = Math.Abs(selectedWidth - choice.Item2) < 0.5,
            };
            item.Click += (_, _) => changeSize(choice.Item2);
            sizeMenu.DropDownItems.Add(item);
        }
        menu.Items.Add(sizeMenu);

        var autonomyItem = new ToolStripMenuItem("Autonomous Pet") { Checked = autonomyEnabled };
        autonomyItem.Click += (_, _) => toggleAutonomy();
        menu.Items.Add(autonomyItem);

        var quotaMenu = new ToolStripMenuItem("Quota Bar");
        var showQuota = new ToolStripMenuItem(quotaBarVisible ? "Hide Quota Bar" : "Show Quota Bar");
        showQuota.Click += (_, _) => toggleQuotaBarVisible();
        quotaMenu.DropDownItems.Add(showQuota);
        quotaMenu.DropDownItems.Add(new ToolStripSeparator());
        foreach (var mode in new[] { ("auto", "Auto"), ("daily", "Daily Limit"), ("monthly", "Monthly Limit"), ("plan", "Plan Quota") })
        {
            var item = new ToolStripMenuItem(mode.Item2)
            {
                Checked = string.Equals(quotaBarMode, mode.Item1, StringComparison.OrdinalIgnoreCase),
                Enabled = quotaBarVisible,
            };
            var selected = mode.Item1;
            item.Click += (_, _) => setQuotaBarMode(selected);
            quotaMenu.DropDownItems.Add(item);
        }
        menu.Items.Add(quotaMenu);

        var hideItem = new ToolStripMenuItem(petHidden ? "Show Pet" : "Hide Pet")
        {
            Enabled = selectedId is not null || pets.Count > 0,
        };
        hideItem.Click += (_, _) => togglePetHidden();
        menu.Items.Add(hideItem);
        var resetItem = new ToolStripMenuItem("Reset Position");
        resetItem.Click += (_, _) => resetPosition();
        menu.Items.Add(resetItem);
        var dashboardItem = new ToolStripMenuItem("Open Dashboard…");
        dashboardItem.Click += (_, _) => openDashboard();
        menu.Items.Add(dashboardItem);
        var reloadItem = new ToolStripMenuItem("Reload Pets");
        reloadItem.Click += (_, _) => reload();
        menu.Items.Add(reloadItem);
        if (failures.Count > 0)
        {
            var unavailable = new ToolStripMenuItem($"Unavailable Pets ({failures.Count})");
            foreach (var failure in failures)
            {
                unavailable.DropDownItems.Add(new ToolStripMenuItem(failure.Id) { Enabled = false, ToolTipText = failure.Message });
            }
            menu.Items.Add(unavailable);
        }
        menu.Items.Add(new ToolStripSeparator());
        var quitItem = new ToolStripMenuItem("Quit PetRunner");
        quitItem.Click += (_, _) => quit();
        menu.Items.Add(quitItem);
        icon.ContextMenuStrip = menu;
    }

    private void BuildPetMenu(ToolStripMenuItem parent, IReadOnlyList<PetDescriptor> pets, string? selectedId)
    {
        if (pets.Count == 0)
        {
            parent.DropDownItems.Add(new ToolStripMenuItem("No valid pets found") { Enabled = false });
            return;
        }
        foreach (var pet in pets)
        {
            var item = new ToolStripMenuItem(pet.DisplayName)
            {
                Checked = pet.Id == selectedId,
                ToolTipText = pet.Description,
            };
            if (TryThumbnail(pet) is { } thumb)
            {
                item.Image = thumb;
                thumbnails[pet.Id] = thumb;
            }
            var id = pet.Id;
            item.Click += (_, _) => changePet(id);
            parent.DropDownItems.Add(item);
        }
    }

    private Image? TryThumbnail(PetDescriptor pet)
    {
        try
        {
            using var atlas = SpriteAtlas.Load(pet.SpritesheetPath, pet.Version);
            var png = atlas.FramePng(new AtlasAddress(0, 0));
            using var stream = new MemoryStream(png);
            using var source = Image.FromStream(stream);
            return new Bitmap(source, new Size(24, 26));
        }
        catch
        {
            return null;
        }
    }

    public void Dispose()
    {
        foreach (var image in thumbnails.Values) image.Dispose();
        thumbnails.Clear();
        icon.Visible = false;
        icon.Dispose();
        applicationIcon.Dispose();
    }
}
