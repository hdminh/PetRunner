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
    public static BounceResult Step(
        ref MotionState motion,
        SizeD size,
        RectD bounds,
        double deltaTime,
        double velocityRetentionPerSecond = 0.18,
        double restitution = 0.72,
        double stopSpeed = 8,
        double maximumDeltaTime = 1)
    {
        var dt = Math.Clamp(deltaTime, 0, maximumDeltaTime);
        if (dt <= 0) return default;

        motion.X += motion.VelocityX * dt;
        motion.Y += motion.VelocityY * dt;
        var maxX = Math.Max(bounds.X, bounds.X + bounds.Width - size.Width);
        var maxY = Math.Max(bounds.Y, bounds.Y + bounds.Height - size.Height);
        var horizontal = false;
        var vertical = false;

        if (motion.X < bounds.X)
        {
            motion.X = bounds.X;
            motion.VelocityX = Math.Abs(motion.VelocityX) * restitution;
            horizontal = true;
        }
        else if (motion.X > maxX)
        {
            motion.X = maxX;
            motion.VelocityX = -Math.Abs(motion.VelocityX) * restitution;
            horizontal = true;
        }
        if (motion.Y < bounds.Y)
        {
            motion.Y = bounds.Y;
            motion.VelocityY = Math.Abs(motion.VelocityY) * restitution;
            vertical = true;
        }
        else if (motion.Y > maxY)
        {
            motion.Y = maxY;
            motion.VelocityY = -Math.Abs(motion.VelocityY) * restitution;
            vertical = true;
        }

        var retention = Math.Pow(velocityRetentionPerSecond, dt);
        motion.VelocityX *= retention;
        motion.VelocityY *= retention;
        if (Math.Sqrt(
                motion.VelocityX * motion.VelocityX + motion.VelocityY * motion.VelocityY) < stopSpeed)
        {
            motion.VelocityX = 0;
            motion.VelocityY = 0;
        }
        return new BounceResult(horizontal, vertical);
    }

    public static (double X, double Y) Clamp(double x, double y, SizeD size, RectD bounds) =>
        (
            Math.Clamp(x, bounds.X, Math.Max(bounds.X, bounds.X + bounds.Width - size.Width)),
            Math.Clamp(y, bounds.Y, Math.Max(bounds.Y, bounds.Y + bounds.Height - size.Height))
        );

    public static (double X, double Y) CenteredOrigin(SizeD size, RectD bounds)
    {
        var origin = (bounds.X + (bounds.Width - size.Width) / 2, bounds.Y + (bounds.Height - size.Height) / 2);
        return Clamp(origin.Item1, origin.Item2, size, bounds);
    }
}
