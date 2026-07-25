using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using PetRunner.Core;
using Forms = System.Windows.Forms;

namespace PetRunner.Windows;

internal sealed class OverlayWindow : Window, IDisposable
{
    private readonly DockPanel root = new();
    private readonly System.Windows.Controls.Image sprite = new() { Stretch = Stretch.Fill };
    private readonly Canvas quotaCanvas = new() { Height = 0, IsHitTestVisible = false };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private AnimationPlayback playback = new();
    private SpriteAtlas? atlas;
    private PetDescriptor? pet;
    private MotionState? motion;
    private AutonomyPolicy autonomy = new();
    private bool autonomyEnabled = true;
    private AutonomousWalk? autonomousWalk;
    private bool autonomousAnimationActive;
    private double previousTick;
    private bool interacting;
    private bool resizing;
    private bool moved;
    private System.Windows.Point pointerStart;
    private System.Windows.Point previousPointer;
    private double dragStartLeft;
    private double dragStartTop;
    private double resizeStartWidth;
    private double previousMoveTime;
    private double velocityX;
    private double velocityY;
    private System.Drawing.Point? lastPointerScreenPosition;
    private double lastPointerMovementTime = double.NegativeInfinity;
    private IReadOnlyList<QuotaBarSegment> quotaSegments = [];

    private const double PhysicalPointerLookDuration = 0.6;
    private const double QuotaBarHeight = 12;
    private const double QuotaBarSpacing = 3;

    public OverlayWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        // Soft outer halo matching the session-bubble / macOS pet window shadow.
        sprite.Effect = new DropShadowEffect
        {
            BlurRadius = 14,
            ShadowDepth = 0,
            Opacity = 0.42,
            Color = Color.FromRgb(0x1A, 0x17, 0x40),
        };
        DockPanel.SetDock(quotaCanvas, Dock.Bottom);
        root.Children.Add(quotaCanvas);
        root.Children.Add(sprite);
        Content = root;
        MouseLeftButtonDown += OnPointerDown;
        MouseMove += OnPointerMove;
        MouseLeftButtonUp += OnPointerUp;
        MouseEnter += OnPointerEnter;
        MouseLeave += OnPointerLeave;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    public Action<double, double>? PositionChanged { get; set; }

    public void SetAutonomyEnabled(bool enabled)
    {
        autonomyEnabled = enabled;
        CancelAutonomy();
        Render();
    }

    public void SetAutonomyConfiguration(AutonomyConfiguration configuration)
    {
        autonomy.Update(configuration);
        CancelAutonomy();
        Render();
    }

    public void ResetPositionToDefault()
    {
        if (!IsVisible) return;
        motion = null;
        CancelAutonomy();
        interacting = false;
        resizing = false;
        var area = ScreenBounds.PrimaryWorkingArea(this);
        var centered = PhysicsEngine.CenteredOrigin(new SizeD(Width, Height), area);
        Left = centered.X;
        Top = centered.Y;
        ClampToScreen();
        if (playback.State != AnimationState.Idle) playback.Start(AnimationState.Idle);
        PositionChanged?.Invoke(Left, Top);
        Render();
    }

    public void ShowPet(PetDescriptor descriptor, double width, (double Left, double Top)? savedPosition)
    {
        atlas?.Dispose();
        atlas = SpriteAtlas.Load(descriptor.SpritesheetPath, descriptor.Version);
        pet = descriptor;
        playback.Start(AnimationState.Idle);
        motion = null;
        CancelAutonomy();
        lastPointerScreenPosition = null;
        lastPointerMovementTime = double.NegativeInfinity;
        SetWidth(width);
        if (!IsVisible) Show();
        if (savedPosition is { } saved)
        {
            Left = saved.Left;
            Top = saved.Top;
        }
        else
        {
            var area = ScreenBounds.WorkingArea(this);
            Left = area.X + area.Width - Width - 32;
            Top = area.Y + area.Height - Height - 32;
        }
        ClampToScreen();
        Render();
    }

    public void HidePet()
    {
        Hide();
        atlas?.Dispose();
        atlas = null;
        pet = null;
        motion = null;
        CancelAutonomy();
    }

    public void SetPetVisible(bool visible)
    {
        if (visible)
        {
            if (atlas is null) return;
            Show();
        }
        else
        {
            Hide();
        }
    }

    public bool HasLoadedPet => atlas is not null;

    private double SpriteHeight => Width * SpriteAtlas.CellHeight / SpriteAtlas.CellWidth;

    private static double QuotaBarsHeight(int count) =>
        count <= 0 ? 0 : count * QuotaBarHeight + (count - 1) * QuotaBarSpacing + 4;

    public void SetQuotaBarSegments(IReadOnlyList<QuotaBarSegment> segments)
    {
        quotaSegments = segments;
        ApplyLayout(preserveTop: true);
        DrawQuotaBars();
    }

    public void SetWidth(double requestedWidth)
    {
        CancelAutonomy();
        var oldRight = Left + Width;
        var oldTop = Top;
        Width = Math.Clamp(requestedWidth, 80, 224);
        ApplyLayout(preserveTop: false);
        if (IsVisible)
        {
            Left = oldRight - Width;
            Top = oldTop;
            ClampToScreen();
        }
        DrawQuotaBars();
    }

    private void ApplyLayout(bool preserveTop)
    {
        var barHeight = QuotaBarsHeight(quotaSegments.Count);
        var spriteHeight = SpriteHeight;
        var total = spriteHeight + barHeight;
        if (preserveTop && IsVisible)
        {
            var bottom = Top + Height;
            Height = total;
            Top = bottom - total;
        }
        else
        {
            Height = total;
        }
        quotaCanvas.Height = barHeight;
        quotaCanvas.Width = Width;
        sprite.Height = spriteHeight;
        sprite.Width = Width;
    }

    private void DrawQuotaBars()
    {
        quotaCanvas.Children.Clear();
        if (quotaSegments.Count == 0 || Width <= 0) return;
        const double unit = 2;
        var y = 2.0;
        foreach (var segment in quotaSegments)
        {
            DrawPixelHeart(quotaCanvas, left: 4, top: y + 1, unit: unit);

            var heartWidth = unit * 7;
            var trackX = 4 + heartWidth + unit;
            const int innerH = 4;
            var innerW = Math.Max(8, (int)Math.Floor((Width - trackX - 4) / unit));
            var trackHeight = innerH * unit;
            var trackY = y + (QuotaBarHeight - trackHeight) / 2;

            // 8-bit black outline (stepped capsule), then white track interior.
            FillPixelCapsule(quotaCanvas, trackX - unit, trackY - unit, innerW + 2, innerH + 2, unit, Brushes.Black);
            FillPixelCapsule(quotaCanvas, trackX, trackY, innerW, innerH, unit, Brushes.White);

            var remaining = Math.Clamp(segment.RemainingPercent / 100.0, 0, 1);
            var fillUnits = (int)Math.Floor(remaining * innerW);
            if (fillUnits > 0)
            {
                var (light, dark, shadow) = FillPalette(segment.RemainingPercent);
                DrawPixelFill(quotaCanvas, trackX, trackY, fillUnits, innerH, innerW, unit, light, dark, shadow);
            }
            y += QuotaBarHeight + QuotaBarSpacing;
        }
    }

    private static void FillPixelCapsule(
        Canvas canvas,
        double left,
        double top,
        int widthUnits,
        int heightUnits,
        double unit,
        Brush brush)
    {
        if (widthUnits <= 0 || heightUnits <= 0) return;
        for (var py = 0; py < heightUnits; py++)
        {
            for (var px = 0; px < widthUnits; px++)
            {
                if (!IsInsidePixelCapsule(px, py, widthUnits, heightUnits)) continue;
                AddPixel(canvas, left, top, px, py, unit, brush);
            }
        }
    }

    /// Dual-tone fill + 1px top inner shadow, clipped to the capsule silhouette.
    private static void DrawPixelFill(
        Canvas canvas,
        double left,
        double top,
        int fillUnits,
        int heightUnits,
        int fullWidthUnits,
        double unit,
        Brush light,
        Brush dark,
        Brush shadow)
    {
        var mid = heightUnits / 2;
        for (var py = 0; py < heightUnits; py++)
        {
            // WPF y-down: py 0 = top. Top interior row is the inner shadow.
            Brush brush;
            if (py == 0) brush = shadow;
            else if (py < mid) brush = light;
            else brush = dark;

            for (var px = 0; px < fillUnits; px++)
            {
                if (!IsInsidePixelCapsule(px, py, fullWidthUnits, heightUnits)) continue;
                AddPixel(canvas, left, top, px, py, unit, brush);
            }
        }
    }

    /// Discrete capsule: flat middle, stepped semicircle caps (no antialias).
    private static bool IsInsidePixelCapsule(int px, int py, int width, int height)
    {
        if (width <= 0 || height <= 0 || px < 0 || py < 0 || px >= width || py >= height) return false;
        var radius = Math.Max(1, height / 2);
        if (px >= radius && px < width - radius) return true;
        var centerY = (height - 1) / 2.0;
        var centerX = px < radius ? radius - 0.5 : width - radius - 0.5;
        var dx = px - centerX;
        var dy = py - centerY;
        return dx * dx + dy * dy <= radius * radius;
    }

    private static void AddPixel(Canvas canvas, double left, double top, int px, int py, double unit, Brush brush)
    {
        var pixel = new System.Windows.Shapes.Rectangle
        {
            Width = unit,
            Height = unit,
            Fill = brush,
            SnapsToDevicePixels = true,
        };
        Canvas.SetLeft(pixel, left + px * unit);
        Canvas.SetTop(pixel, top + py * unit);
        canvas.Children.Add(pixel);
    }

    /// Classic 7×6 pixel heart (row 0 = top for WPF canvas).
    private static void DrawPixelHeart(Canvas canvas, double left, double top, double unit)
    {
        var outline = Brushes.Black;
        var fill = new SolidColorBrush(Color.FromRgb(0xEB, 0x2E, 0x38));
        var shade = new SolidColorBrush(Color.FromRgb(0xAD, 0x14, 0x24));
        var highlight = Brushes.White;
        HashSet<(int X, int Y)> cells =
        [
            (1, 0), (2, 0), (4, 0), (5, 0),
            (0, 1), (1, 1), (2, 1), (4, 1), (5, 1), (6, 1),
            (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (5, 2), (6, 2),
            (1, 3), (2, 3), (3, 3), (4, 3), (5, 3),
            (2, 4), (3, 4), (4, 4),
            (3, 5),
        ];
        // Darker red along bottom-right for depth (y-down coordinates).
        HashSet<(int X, int Y)> shaded =
        [
            (4, 4), (5, 3), (5, 2), (6, 2), (6, 1), (4, 3), (3, 5), (3, 4),
        ];

        var border = new HashSet<(int X, int Y)>();
        foreach (var (cx, cy) in cells)
        {
            foreach (var (dx, dy) in new[] { (-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1) })
            {
                var n = (cx + dx, cy + dy);
                if (!cells.Contains(n)) border.Add(n);
            }
        }

        foreach (var (cx, cy) in border)
            AddPixel(canvas, left, top, cx, cy, unit, outline);
        foreach (var cell in cells)
            AddPixel(canvas, left, top, cell.X, cell.Y, unit, shaded.Contains(cell) ? shade : fill);
        // White glint upper-left (2px).
        AddPixel(canvas, left, top, 1, 0, unit, highlight);
        AddPixel(canvas, left, top, 1, 1, unit, highlight);
    }

    private static (Brush Light, Brush Dark, Brush Shadow) FillPalette(double remaining) => remaining switch
    {
        > 60 => (
            new SolidColorBrush(Color.FromRgb(0x61, 0xEB, 0x52)),
            new SolidColorBrush(Color.FromRgb(0x29, 0x9E, 0x38)),
            new SolidColorBrush(Color.FromRgb(0x1A, 0x6B, 0x24))),
        > 40 => (
            new SolidColorBrush(Color.FromRgb(0xFA, 0xD1, 0x2E)),
            new SolidColorBrush(Color.FromRgb(0xDB, 0x85, 0x1A)),
            new SolidColorBrush(Color.FromRgb(0xB8, 0x61, 0x0F))),
        > 20 => (
            new SolidColorBrush(Color.FromRgb(0xFA, 0x8C, 0x29)),
            new SolidColorBrush(Color.FromRgb(0xD1, 0x47, 0x1A)),
            new SolidColorBrush(Color.FromRgb(0x9E, 0x29, 0x0F))),
        _ => (
            new SolidColorBrush(Color.FromRgb(0xF2, 0x47, 0x47)),
            new SolidColorBrush(Color.FromRgb(0xAD, 0x1F, 0x29)),
            new SolidColorBrush(Color.FromRgb(0x7A, 0x0F, 0x1A))),
    };

    private void OnPointerDown(object sender, MouseButtonEventArgs args)
    {
        motion = null;
        CancelAutonomy();
        interacting = true;
        moved = false;
        var local = args.GetPosition(this);
        resizing = local.X >= ActualWidth - 18 && local.Y >= ActualHeight - 18;
        pointerStart = PointerInDips();
        previousPointer = pointerStart;
        dragStartLeft = Left;
        dragStartTop = Top;
        resizeStartWidth = Width;
        previousMoveTime = clock.Elapsed.TotalSeconds;
        velocityX = 0;
        velocityY = 0;
        CaptureMouse();
        args.Handled = true;
    }

    private void OnPointerMove(object sender, System.Windows.Input.MouseEventArgs args)
    {
        var local = args.GetPosition(this);
        if (!IsMouseCaptured)
        {
            Cursor = local.X >= ActualWidth - 18 && local.Y >= ActualHeight - 18
                ? System.Windows.Input.Cursors.SizeNWSE
                : System.Windows.Input.Cursors.Hand;
            return;
        }

        var pointer = PointerInDips();
        var dx = pointer.X - pointerStart.X;
        var dy = pointer.Y - pointerStart.Y;
        moved = moved || Math.Sqrt(dx * dx + dy * dy) >= 3;
        if (resizing)
        {
            SetWidth(resizeStartWidth + dx);
            return;
        }

        Left = dragStartLeft + dx;
        Top = dragStartTop + dy;
        ClampToScreen();
        var now = clock.Elapsed.TotalSeconds;
        var elapsed = now - previousMoveTime;
        if (elapsed > 0)
        {
            velocityX = (pointer.X - previousPointer.X) / elapsed;
            velocityY = (pointer.Y - previousPointer.Y) / elapsed;
        }
        previousPointer = pointer;
        previousMoveTime = now;
        UpdateMovementAnimation(pointer.X - previousPointer.X, velocityX);
        Render();
    }

    private void OnPointerEnter(object sender, System.Windows.Input.MouseEventArgs args)
    {
        CancelAutonomy();
        if (!autonomyEnabled || interacting || motion is not null || playback.State != AnimationState.Idle) return;
        if (autonomy.StartAction() is not { } action) return;
        PerformAutonomousAction(action);
        Render();
    }

    private void OnPointerLeave(object sender, System.Windows.Input.MouseEventArgs args)
    {
        CancelAutonomy();
        if (interacting || motion is not null) return;
        playback.Start(AnimationState.Idle);
        Render();
    }

    private void OnPointerUp(object sender, MouseButtonEventArgs args)
    {
        CancelAutonomy();
        ReleaseMouseCapture();
        interacting = false;
        if (resizing)
        {
            resizing = false;
            PositionChanged?.Invoke(Left, Top);
            return;
        }

        if (!moved)
        {
            playback.Start(AnimationState.Jumping);
        }
        else if (Math.Sqrt(velocityX * velocityX + velocityY * velocityY) >= 120)
        {
            motion = new MotionState(Left, Top, velocityX, velocityY);
            UpdateMovementAnimation(velocityX, velocityX);
        }
        else
        {
            playback.Start(AnimationState.Idle);
            PositionChanged?.Invoke(Left, Top);
        }
        Render();
    }

    private void Tick()
    {
        if (atlas is null || !IsVisible) return;
        var now = clock.Elapsed.TotalSeconds;
        var delta = Math.Clamp(now - previousTick, 0, 0.05);
        previousTick = now;
        playback.Advance(delta);

        if (motion is { } current)
        {
            var bounce = PhysicsEngine.Step(
                ref current,
                new SizeD(Width, SpriteHeight),
                ScreenBounds.WorkingArea(this),
                delta);
            Left = current.X;
            Top = current.Y;
            if (current.VelocityX == 0 && current.VelocityY == 0)
            {
                motion = null;
                playback.Start(AnimationState.Idle);
                PositionChanged?.Invoke(Left, Top);
            }
            else
            {
                motion = current;
                UpdateMovementAnimation(current.VelocityX, current.VelocityX);
                if (bounce.Horizontal) Render();
            }
        }
        AdvanceAutonomy(now, delta);
        Render();
    }

    private void AdvanceAutonomy(double now, double delta)
    {
        if (autonomousWalk is { } walk)
        {
            walk.Elapsed = Math.Min(walk.Duration, walk.Elapsed + delta);
            var progress = walk.Duration == 0 ? 1 : walk.Elapsed / walk.Duration;
            Left = walk.StartX + (walk.TargetX - walk.StartX) * progress;
            Top = walk.StartY;
            ClampToScreen();
            if (walk.Elapsed >= walk.Duration)
            {
                autonomousWalk = null;
                autonomy.Finish();
                playback.Start(AnimationState.Idle);
                PositionChanged?.Invoke(Left, Top);
            }
            else
            {
                autonomousWalk = walk;
            }
            return;
        }

        if (autonomousAnimationActive && playback.State == AnimationState.Idle)
        {
            autonomousAnimationActive = false;
            autonomy.Finish();
        }
        if (!IsAutonomyEligible) return;
        var action = autonomy.Tick(now, true);
        if (action is null) return;

        PerformAutonomousAction(action.Value);
    }

    private void PerformAutonomousAction(AutonomousAction action)
    {
        switch (action.Kind)
        {
            case AutonomousActionKind.Walk:
                StartAutonomousWalk(action.Duration);
                break;
            case AutonomousActionKind.Wave:
                autonomousAnimationActive = true;
                playback.Start(AnimationState.Waving);
                break;
            case AutonomousActionKind.Jump:
                autonomousAnimationActive = true;
                playback.Start(AnimationState.Jumping);
                break;
            case AutonomousActionKind.Cry:
                autonomousAnimationActive = true;
                playback.Start(AnimationState.Failed);
                break;
        }
    }

    private bool IsAutonomyEligible =>
        IsVisible && autonomyEnabled && !interacting && !resizing && motion is null && autonomousWalk is null &&
        !autonomousAnimationActive && playback.State == AnimationState.Idle;

    private void StartAutonomousWalk(double duration)
    {
        var bounds = ScreenBounds.WorkingArea(this);
        var leftSpace = Left - bounds.X;
        var rightSpace = bounds.X + bounds.Width - (Left + Width);
        var direction = rightSpace >= leftSpace ? 1d : -1d;
        var available = Math.Max(0, direction > 0 ? rightSpace : leftSpace);
        var distance = Math.Min(available, Math.Max(Width * .75, 96 * duration));
        if (distance < 8)
        {
            autonomy.Finish();
            return;
        }
        autonomousWalk = new AutonomousWalk(Left, Left + direction * distance, Top, duration);
        playback.Start(direction < 0 ? AnimationState.RunningLeft : AnimationState.RunningRight);
    }

    private void CancelAutonomy()
    {
        autonomy.Cancel();
        autonomousWalk = null;
        autonomousAnimationActive = false;
    }

    private void UpdateMovementAnimation(double horizontalDelta, double fallbackVelocity)
    {
        var horizontal = Math.Abs(horizontalDelta) >= 0.5 ? horizontalDelta : fallbackVelocity;
        var state = horizontal < 0 ? AnimationState.RunningLeft : AnimationState.RunningRight;
        if (playback.State != state) playback.Start(state);
    }

    private void Render()
    {
        if (atlas is null || pet is null) return;
        var address = RecentPointerLookAddress() ?? playback.Address;
        sprite.Source = Bitmap(atlas.FramePng(address));
    }

    private AtlasAddress? RecentPointerLookAddress()
    {
        if (pet?.Version != SpriteVersion.V2 ||
            playback.State != AnimationState.Idle ||
            interacting ||
            motion is not null) return null;

        var pointerScreenPosition = Forms.Cursor.Position;
        if (lastPointerScreenPosition is null || !pointerScreenPosition.Equals(lastPointerScreenPosition.Value))
        {
            lastPointerScreenPosition = pointerScreenPosition;
            lastPointerMovementTime = clock.Elapsed.TotalSeconds;
        }
        if (clock.Elapsed.TotalSeconds - lastPointerMovementTime > PhysicalPointerLookDuration) return null;

        var pointer = PointerInDips();
        var direction = LookDirection.FrameIndex(
            pointer.X - (Left + Width / 2),
            (Top + SpriteHeight / 2) - pointer.Y);
        return direction is null ? null : LookDirection.Address(direction.Value);
    }

    private static BitmapImage Bitmap(byte[] png)
    {
        using var stream = new MemoryStream(png);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private System.Windows.Point PointerInDips()
    {
        var pixel = Forms.Cursor.Position;
        return PointFromScreen(new System.Windows.Point(pixel.X, pixel.Y)) + new Vector(Left, Top);
    }

    private void ClampToScreen()
    {
        if (!IsVisible) return;
        var clamped = PhysicsEngine.Clamp(Left, Top, new SizeD(Width, Height), ScreenBounds.WorkingArea(this));
        Left = clamped.X;
        Top = clamped.Y;
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs args)
    {
        Dispatcher.BeginInvoke(() =>
        {
            CancelAutonomy();
            ClampToScreen();
        });
    }

    public void Dispose()
    {
        timer.Stop();
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        atlas?.Dispose();
        Close();
    }

    private struct AutonomousWalk(double startX, double targetX, double startY, double duration)
    {
        public double StartX = startX;
        public double TargetX = targetX;
        public double StartY = startY;
        public double Duration = duration;
        public double Elapsed;
    }
}
