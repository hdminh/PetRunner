using System.Reflection;
using System.Runtime.InteropServices;

namespace PetRunner.Core;

[StructLayout(LayoutKind.Sequential)]
internal struct RustBuffer
{
    public IntPtr Data;
    public nuint Length;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RustAtlasAddress { public int Row; public int Column; }
[StructLayout(LayoutKind.Sequential)]
internal struct RustMotionState { public double X; public double Y; public double VelocityX; public double VelocityY; }
[StructLayout(LayoutKind.Sequential)]
internal struct RustSize { public double Width; public double Height; }
[StructLayout(LayoutKind.Sequential)]
internal struct RustRect { public double X; public double Y; public double Width; public double Height; }
[StructLayout(LayoutKind.Sequential)]
internal struct RustPhysicsResult { [MarshalAs(UnmanagedType.I1)] public bool Horizontal; [MarshalAs(UnmanagedType.I1)] public bool Vertical; }
[StructLayout(LayoutKind.Sequential)]
internal struct RustAnimationSnapshot { public int State; public int FrameIndex; public double ElapsedInFrame; public int Row; public int Column; }

internal static partial class RustNative
{
    private const string Library = "petrunner_bridge";

    static RustNative()
    {
        NativeLibrary.SetDllImportResolver(typeof(RustNative).Assembly, Resolve);
    }

    private static IntPtr Resolve(string name, Assembly _, DllImportSearchPath? __)
    {
        if (name != Library) return IntPtr.Zero;
        foreach (var candidate in LibraryCandidates().Where(File.Exists))
        {
            if (NativeLibrary.TryLoad(candidate, out var handle)) return handle;
        }
        return IntPtr.Zero;
    }

    internal static void EnsureAvailable()
    {
        if (Resolve(Library, typeof(RustNative).Assembly, null) != IntPtr.Zero) return;
        throw new InvalidOperationException(
            $"PetRunner Rust core could not be loaded. Expected petrunner_bridge.dll in the app directory. " +
            $"Reinstall PetRunner or set PETRUNNER_RUST_LIBRARY. Checked: {string.Join("; ", LibraryCandidates())}");
    }

    private static IEnumerable<string> LibraryCandidates()
    {
        var explicitPath = Environment.GetEnvironmentVariable("PETRUNNER_RUST_LIBRARY");
        if (!string.IsNullOrWhiteSpace(explicitPath)) yield return explicitPath;
        yield return Path.Combine(AppContext.BaseDirectory, "petrunner_bridge.dll");
        yield return Path.Combine(Environment.CurrentDirectory, "target", "x86_64-pc-windows-msvc", "debug", "petrunner_bridge.dll");
        yield return Path.Combine(Environment.CurrentDirectory, "target", "x86_64-pc-windows-msvc", "release", "petrunner_bridge.dll");
    }

    [LibraryImport(Library, EntryPoint = "petrunner_buffer_free")]
    internal static partial void BufferFree(RustBuffer buffer);

    [LibraryImport(Library, EntryPoint = "petrunner_scan_pets", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int ScanPets(string path, out RustBuffer output);

    [LibraryImport(Library, EntryPoint = "petrunner_atlas_create", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int AtlasCreate(string path, int version, out IntPtr handle);
    [LibraryImport(Library, EntryPoint = "petrunner_atlas_destroy")]
    internal static partial void AtlasDestroy(IntPtr handle);
    [LibraryImport(Library, EntryPoint = "petrunner_atlas_frame_png")]
    internal static partial int AtlasFramePng(IntPtr handle, int row, int column, out RustBuffer output);

    [LibraryImport(Library, EntryPoint = "petrunner_animation_create")]
    internal static partial int AnimationCreate(int state, out IntPtr handle);
    [LibraryImport(Library, EntryPoint = "petrunner_animation_destroy")]
    internal static partial void AnimationDestroy(IntPtr handle);
    [LibraryImport(Library, EntryPoint = "petrunner_animation_start")]
    internal static partial int AnimationStart(IntPtr handle, int state);
    [LibraryImport(Library, EntryPoint = "petrunner_animation_advance")]
    internal static partial int AnimationAdvance(IntPtr handle, double deltaTime);
    [LibraryImport(Library, EntryPoint = "petrunner_animation_snapshot")]
    internal static partial int AnimationSnapshot(IntPtr handle, out RustAnimationSnapshot snapshot);
    [LibraryImport(Library, EntryPoint = "petrunner_animation_frame_count")]
    internal static partial int AnimationFrameCount(int state);
    [LibraryImport(Library, EntryPoint = "petrunner_animation_frame_duration")]
    internal static partial double AnimationFrameDuration(int state, int index);
    [LibraryImport(Library, EntryPoint = "petrunner_animation_cycles_before_idle")]
    internal static partial int AnimationCyclesBeforeIdle(int state);
    [LibraryImport(Library, EntryPoint = "petrunner_look_direction")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static partial bool LookDirection(double dx, double dy, double deadzone, out RustAtlasAddress address);

    [LibraryImport(Library, EntryPoint = "petrunner_physics_step")]
    internal static partial int PhysicsStep(ref RustMotionState motion, RustSize size, RustRect bounds, double retention, double restitution, double stopSpeed, double maximumDelta, double deltaTime, out RustPhysicsResult result);
    [LibraryImport(Library, EntryPoint = "petrunner_physics_clamp")]
    internal static partial int PhysicsClamp(double x, double y, RustSize size, RustRect bounds, out RustMotionState result);

    internal static byte[] TakeBuffer(RustBuffer buffer)
    {
        if (buffer.Data == IntPtr.Zero) throw new InvalidOperationException("Rust returned an empty buffer");
        try
        {
            var result = new byte[checked((int)buffer.Length)];
            Marshal.Copy(buffer.Data, result, 0, result.Length);
            return result;
        }
        finally { BufferFree(buffer); }
    }

    internal static void Require(int result)
    {
        if (result != 0) throw new InvalidOperationException($"PetRunner Rust core operation failed (code {result})");
    }
}

public static class RustCore
{
    public static void EnsureAvailable() => RustNative.EnsureAvailable();
}
