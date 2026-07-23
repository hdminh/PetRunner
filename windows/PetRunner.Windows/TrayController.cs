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
        Action resetPosition,
        Action openDashboard,
        Action quit)
    {
        this.changePet = changePet;
        this.changeSize = changeSize;
        this.reload = reload;
        this.toggleAutonomy = toggleAutonomy;
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
        bool autonomyEnabled)
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
        var resetItem = new ToolStripMenuItem("Reset Position");
        resetItem.Click += (_, _) => resetPosition();
        menu.Items.Add(resetItem);
        var dashboardItem = new ToolStripMenuItem("Open Dashboard…");
        dashboardItem.Click += (_, _) => openDashboard();
        menu.Items.Add(dashboardItem);

        if (failures.Count > 0)
        {
            var unavailable = new ToolStripMenuItem($"Unavailable Pets ({failures.Count})");
            foreach (var failure in failures)
                unavailable.DropDownItems.Add(new ToolStripMenuItem(failure.Id) { Enabled = false, ToolTipText = failure.Message });
            menu.Items.Add(unavailable);
        }

        menu.Items.Add(new ToolStripSeparator());
        var reloadItem = new ToolStripMenuItem("Reload Pets");
        reloadItem.Click += (_, _) => reload();
        menu.Items.Add(reloadItem);
        var quitItem = new ToolStripMenuItem("Quit PetRunner");
        quitItem.Click += (_, _) => quit();
        menu.Items.Add(quitItem);

        var previous = icon.ContextMenuStrip;
        icon.ContextMenuStrip = menu;
        previous?.Dispose();
    }

    private void BuildPetMenu(ToolStripMenuItem parent, IReadOnlyList<PetDescriptor> pets, string? selectedId)
    {
        if (pets.Count == 0)
        {
            parent.DropDownItems.Add(new ToolStripMenuItem("No valid pets found") { Enabled = false });
            return;
        }

        var preview = new ToolStripMenuItem(pets[0].DisplayName) { Enabled = false };
        parent.DropDownItems.Add(preview);
        parent.DropDownItems.Add(new ToolStripSeparator());
        foreach (var pet in pets)
        {
            var thumbnail = Thumbnail(pet);
            var item = new ToolStripMenuItem(pet.DisplayName, thumbnail)
            {
                Checked = pet.Id == selectedId,
                ToolTipText = pet.Description ?? "",
            };
            item.MouseEnter += (_, _) =>
            {
                preview.Text = pet.DisplayName;
                preview.Image = thumbnail;
                preview.ToolTipText = pet.Description ?? "";
            };
            item.Click += (_, _) => changePet(pet.Id);
            parent.DropDownItems.Add(item);
        }
    }

    private Image? Thumbnail(PetDescriptor pet)
    {
        try
        {
            using var atlas = SpriteAtlas.Load(pet.SpritesheetPath, pet.Version);
            using var stream = new MemoryStream(atlas.FramePng(new AtlasAddress(0, 0)));
            using var source = Image.FromStream(stream);
            var thumbnail = new Bitmap(source, new Size(28, 30));
            thumbnails[pet.Id] = thumbnail;
            return thumbnail;
        }
        catch
        {
            return null;
        }
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        applicationIcon.Dispose();
        foreach (var image in thumbnails.Values) image.Dispose();
    }
}
