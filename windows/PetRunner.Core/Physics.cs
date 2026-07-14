namespace PetRunner.Core;

public struct MotionState(double x, double y, double velocityX, double velocityY)
{
    public double X = x;
    public double Y = y;
    public double VelocityX = velocityX;
    public double VelocityY = velocityY;
}

public readonly record struct BounceResult(bool Horizontal, bool Vertical);

public static class PhysicsEngine
{
    public static BounceResult Step(ref MotionState motion, SizeD size, RectD bounds, double deltaTime, double velocityRetentionPerSecond = 0.18, double restitution = 0.72, double stopSpeed = 8, double maximumDeltaTime = 1)
    {
        var native = new RustMotionState { X = motion.X, Y = motion.Y, VelocityX = motion.VelocityX, VelocityY = motion.VelocityY };
        RustNative.Require(RustNative.PhysicsStep(ref native, new RustSize { Width = size.Width, Height = size.Height }, new RustRect { X = bounds.X, Y = bounds.Y, Width = bounds.Width, Height = bounds.Height }, velocityRetentionPerSecond, restitution, stopSpeed, maximumDeltaTime, deltaTime, out var bounce));
        motion.X = native.X; motion.Y = native.Y; motion.VelocityX = native.VelocityX; motion.VelocityY = native.VelocityY;
        return new BounceResult(bounce.Horizontal, bounce.Vertical);
    }

    public static (double X, double Y) Clamp(double x, double y, SizeD size, RectD bounds)
    {
        RustNative.Require(RustNative.PhysicsClamp(x, y, new RustSize { Width = size.Width, Height = size.Height }, new RustRect { X = bounds.X, Y = bounds.Y, Width = bounds.Width, Height = bounds.Height }, out var result));
        return (result.X, result.Y);
    }
}
