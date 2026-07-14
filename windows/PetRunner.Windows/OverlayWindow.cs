using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PetRunner.Core;
using Forms = System.Windows.Forms;

namespace PetRunner.Windows;

internal sealed class OverlayWindow : Window, IDisposable
{
    private readonly System.Windows.Controls.Image sprite = new() { Stretch = Stretch.Fill };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private AnimationPlayback playback = new();
    private SpriteAtlas? atlas;
    private PetDescriptor? pet;
    private MotionState? motion;
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

    private const double PhysicalPointerLookDuration = 0.6;

    public OverlayWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        Content = sprite;
        MouseLeftButtonDown += OnPointerDown;
        MouseMove += OnPointerMove;
        MouseLeftButtonUp += OnPointerUp;
        MouseEnter += OnPointerEnter;
        MouseLeave += OnPointerLeave;
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    public Action<double, double>? PositionChanged { get; set; }

    public void ShowPet(PetDescriptor descriptor, double width, (double Left, double Top)? savedPosition)
    {
        atlas?.Dispose();
        atlas = SpriteAtlas.Load(descriptor.SpritesheetPath, descriptor.Version);
        pet = descriptor;
        playback.Start(AnimationState.Idle);
        motion = null;
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
    }

    public void SetWidth(double requestedWidth)
    {
        var oldRight = Left + Width;
        var oldTop = Top;
        Width = Math.Clamp(requestedWidth, 80, 224);
        Height = Width * SpriteAtlas.CellHeight / SpriteAtlas.CellWidth;
        if (IsVisible)
        {
            Left = oldRight - Width;
            Top = oldTop;
            ClampToScreen();
        }
    }

    private void OnPointerDown(object sender, MouseButtonEventArgs args)
    {
        motion = null;
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
        if (interacting || motion is not null || playback.State != AnimationState.Idle) return;
        playback.Start(AnimationState.Jumping);
        Render();
    }

    private void OnPointerLeave(object sender, System.Windows.Input.MouseEventArgs args)
    {
        if (interacting || motion is not null || playback.State != AnimationState.Jumping) return;
        playback.Start(AnimationState.Idle);
        Render();
    }

    private void OnPointerUp(object sender, MouseButtonEventArgs args)
    {
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
                new SizeD(Width, Height),
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
        Render();
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
            (Top + Height / 2) - pointer.Y);
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

    public void Dispose()
    {
        timer.Stop();
        atlas?.Dispose();
        Close();
    }
}
