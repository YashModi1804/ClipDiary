using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Input;

namespace ClipDiary.Windows.UI;

internal static class UiTheme
{
    public static readonly Brush Teal = new SolidColorBrush(Color.FromRgb(19, 125, 122));
    public static readonly Brush Muted = new SolidColorBrush(Color.FromRgb(108, 113, 117));
    public static readonly Brush Line = new SolidColorBrush(Color.FromRgb(227, 230, 231));
    public static readonly Brush Canvas = new SolidColorBrush(Color.FromRgb(248, 249, 249));

    public static void Configure(Window window)
    {
        window.FontFamily = new FontFamily("Segoe UI");
        window.FontSize = 13;
        window.Background = Canvas;
        window.Foreground = new SolidColorBrush(Color.FromRgb(33, 39, 42));
        window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var buttonStyle = new Style(typeof(Button));
        buttonStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10, 6, 10, 6)));
        buttonStyle.Setters.Add(new Setter(Control.MarginProperty, new Thickness(3)));
        window.Resources.Add(typeof(Button), buttonStyle);
        var textStyle = new Style(typeof(TextBox));
        textStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(7, 5, 7, 5)));
        textStyle.Setters.Add(new Setter(Control.BorderBrushProperty, Line));
        window.Resources.Add(typeof(TextBox), textStyle);
    }

    public static TextBlock Text(string text, double size = 13, Brush? color = null) => new()
    {
        Text = text, FontSize = size, Foreground = color ?? Brushes.Black,
        TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center
    };

    public static Button Button(string text, RoutedEventHandler click)
    {
        var button = new Button { Content = text };
        button.Click += click;
        return button;
    }

    public static void Error(Window? owner, Exception error)
    {
        if (owner is { IsVisible: true })
            MessageBox.Show(owner, error.Message, "ClipDiary", MessageBoxButton.OK, MessageBoxImage.Warning);
        else MessageBox.Show(error.Message, "ClipDiary", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    public static string Prefix(string text, int scalars)
        => string.Concat(text.EnumerateRunes().Take(scalars).Select(r => r.ToString()));

    public static string Excerpt(string text)
    {
        var bounded = Prefix(text, 601);
        var lines = bounded.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var clipped = Prefix(string.Join("\n", lines.Take(12)), 600);
        return clipped + (bounded.EnumerateRunes().Count() > 600 || lines.Length > 12 ? "\n…" : "");
    }

    public static string Bytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        double value = bytes;
        int unit = 0;
        while (value >= 1024 && unit < units.Length - 1) { value /= 1024; unit++; }
        return value.ToString(unit == 0 ? "0" : "0.#", CultureInfo.CurrentCulture) + " " + units[unit];
    }

    public static string Shortcut(int key, int modifiers)
    {
        var parts = new List<string>();
        if ((modifiers & 2) != 0) parts.Add("Ctrl");
        if ((modifiers & 1) != 0) parts.Add("Alt");
        if ((modifiers & 4) != 0) parts.Add("Shift");
        if ((modifiers & 8) != 0) parts.Add("Win");
        parts.Add(KeyInterop.KeyFromVirtualKey(key).ToString());
        return string.Join("+", parts);
    }
}
