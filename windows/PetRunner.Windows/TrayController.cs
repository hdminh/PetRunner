using System.Diagnostics;
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
    private readonly Action resetPosition;
    private readonly Action openPets;
    private readonly Action downloadMorePets;
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
        Action resetPosition,
        Action openPets,
        Action downloadMorePets,
        Action quit)
    {
        this.changePet = changePet;
        this.changeSize = changeSize;
        this.reload = reload;
        this.toggleAutonomy = toggleAutonomy;
        this.togglePetHidden = togglePetHidden;
        this.resetPosition = resetPosition;
        this.openPets = openPets;
        this.downloadMorePets = downloadMorePets;
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
        bool petHidden)
    {
        foreach (var image in thumbnails.Values) image.Dispose();
        thumbnails.Clear();
        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem("PetRunner") { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());

        var petsMenu = new ToolStripMenuItem("Pets");
        BuildPetMenu(petsMenu, pets, selectedId);
        menu.Items.Add(petsMenu);

        var appearanceMenu = new ToolStripMenuItem("Appearance");
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
        appearanceMenu.DropDownItems.Add(sizeMenu);
        var hideItem = new ToolStripMenuItem(petHidden ? "Show Pet" : "Hide Pet")
        {
            Enabled = selectedId is not null || pets.Count > 0,
        };
        hideItem.Click += (_, _) => togglePetHidden();
        appearanceMenu.DropDownItems.Add(hideItem);
        var resetItem = new ToolStripMenuItem("Reset Position");
        resetItem.Click += (_, _) => resetPosition();
        appearanceMenu.DropDownItems.Add(resetItem);
        menu.Items.Add(appearanceMenu);

        var behaviorMenu = new ToolStripMenuItem("Behavior");
        var autonomyItem = new ToolStripMenuItem("Autonomous Pet") { Checked = autonomyEnabled };
        autonomyItem.Click += (_, _) => toggleAutonomy();
        behaviorMenu.DropDownItems.Add(autonomyItem);
        menu.Items.Add(behaviorMenu);

        var libraryMenu = new ToolStripMenuItem("Library");
        var openPetsItem = new ToolStripMenuItem("Open Pets…");
        openPetsItem.Click += (_, _) => openPets();
        libraryMenu.DropDownItems.Add(openPetsItem);
        var reloadItem = new ToolStripMenuItem("Reload Pets");
        reloadItem.Click += (_, _) => reload();
        libraryMenu.DropDownItems.Add(reloadItem);
        var downloadItem = new ToolStripMenuItem("Download more pets…");
        downloadItem.Click += (_, _) => downloadMorePets();
        libraryMenu.DropDownItems.Add(downloadItem);
        if (failures.Count > 0)
        {
            var unavailable = new ToolStripMenuItem($"Unavailable Pets ({failures.Count})");
            foreach (var failure in failures)
            {
                unavailable.DropDownItems.Add(new ToolStripMenuItem(failure.Id) { Enabled = false, ToolTipText = failure.Message });
            }
            libraryMenu.DropDownItems.Add(unavailable);
        }
        menu.Items.Add(libraryMenu);

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
            return new Bitmap(source, new Size(24, 24));
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
