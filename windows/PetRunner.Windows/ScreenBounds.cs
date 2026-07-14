using System.Windows;
using System.Windows.Forms;
using PetRunner.Core;

namespace PetRunner.Windows;

internal static class ScreenBounds
{
    public static RectD WorkingArea(Window window)
    {
        var center = window.PointToScreen(new System.Windows.Point(window.ActualWidth / 2, window.ActualHeight / 2));
        var screen = Screen.FromPoint(new System.Drawing.Point((int)center.X, (int)center.Y));
        var topLeft = window.PointFromScreen(new System.Windows.Point(screen.WorkingArea.Left, screen.WorkingArea.Top));
        var bottomRight = window.PointFromScreen(new System.Windows.Point(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
        return new RectD(
            window.Left + topLeft.X,
            window.Top + topLeft.Y,
            bottomRight.X - topLeft.X,
            bottomRight.Y - topLeft.Y);
    }
}
