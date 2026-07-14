using PetRunner.Core;

namespace PetRunner.Tests;

internal static class PhysicsTests
{
    public static void Run()
    {
        var motion = new MotionState(95, 40, 200, 0);
        var bounced = PhysicsEngine.Step(
            ref motion,
            new SizeD(10, 10),
            new RectD(0, 0, 100, 100),
            0.1);
        Check.True(bounced.Horizontal, "Expected a horizontal bounce");
        Check.Equal(90d, motion.X);
        Check.True(motion.VelocityX < 0, "Bounce must reverse horizontal velocity");

        var slow = new MotionState(10, 10, 1, 1);
        PhysicsEngine.Step(ref slow, new SizeD(10, 10), new RectD(0, 0, 100, 100), 0.1);
        Check.Equal(0d, slow.VelocityX);
        Check.Equal(0d, slow.VelocityY);
    }
}
