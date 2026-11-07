using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Data;
using System.Windows.Threading;
using ClipDiary.Core;
using Microsoft.Win32;

namespace ClipDiary.Windows.UI;

internal sealed class SnippetEditorWindow : Window
{
    private bool saving;
    public SnippetEditorWindow(ClipRecord? item, Func<string, string, bool, Task> save)
    {
        Title = item == null ? "New Snippet" : "Edit Snippet";
        Width = 528; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; UiTheme.Configure(this);
        var root = new StackPanel { Margin = new Thickness(24) };
        root.Children.Add(UiTheme.Text(item == null ? "New snippet" : "Edit snippet", 20));
        var title = new TextBox { Text = item?.Title ?? "", Margin = new Thickness(0, 16, 0, 12), ToolTip = "Title (optional)" };
        System.Windows.Automation.AutomationProperties.SetName(title, "Title (optional)");
        root.Children.Add(title);
        var text = new TextBox
        {
            Text = item?.Text ?? "", Height = 230, AcceptsReturn = true, AcceptsTab = true,
            TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new FontFamily("Consolas"), IsUndoEnabled = true, UndoLimit = 1000
        };
        System.Windows.Automation.AutomationProperties.SetName(text, "Snippet text");
        var parameterized = new CheckBox { Content = "Parameterized — prompt for <parameter_name> values", IsChecked = item?.IsParameterized == true, Margin = new Thickness(0, 12, 0, 0) };
        if (item?.Kind != ClipKind.Image)
        {
            root.Children.Add(text);
            if (item != null) root.Children.Add(parameterized);
        }
        root.Children.Add(new TextBlock { Text = "Snippets remain until you delete them.", FontSize = 11, Foreground = UiTheme.Muted, Margin = new Thickness(0, 14, 0, 8) });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        var submit = new Button { Content = "Save", IsDefault = true };
        buttons.Children.Add(cancel); buttons.Children.Add(submit); root.Children.Add(buttons); Content = root;
        void Validate() => submit.IsEnabled = !saving && (item?.Kind == ClipKind.Image || text.Text.Length > 0);
        text.TextChanged += (_, _) => Validate(); Validate();
        submit.Click += async (_, _) =>
        {
            if (saving) return;
            saving = true; submit.IsEnabled = false; cancel.IsEnabled = false;
            try { await save(title.Text, text.Text, parameterized.IsChecked == true); saving = false; DialogResult = true; }
            catch (Exception error) { UiTheme.Error(this, error); }
            finally { saving = false; cancel.IsEnabled = true; Validate(); }
        };
        Closing += (_, e) => { if (saving) e.Cancel = true; };
        Loaded += (_, _) => title.Focus();
        Closed += (_, _) => { text.IsUndoEnabled = false; text.Clear(); title.IsUndoEnabled = false; title.Clear(); Content = null; };
    }
}

internal sealed class ParameterWindow : Window
{
    private bool copying;
    public bool Copied { get; private set; }
    public ParameterWindow(IReadOnlyList<string> names, Func<IReadOnlyDictionary<string, string>, Task> copy)
    {
        Title = "Snippet parameters"; Width = 450; SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; UiTheme.Configure(this);
        var root = new StackPanel { Margin = new Thickness(22) };
        root.Children.Add(UiTheme.Text("Parameter values", 18));
        root.Children.Add(new TextBlock { Text = "Leave a value blank to keep its <placeholder>.", Foreground = UiTheme.Muted, FontSize = 11, Margin = new Thickness(0, 10, 0, 14) });
        var fields = names.Select(name => new ParameterField(name)).ToArray();
        // A finite viewport is necessary even inside this size-to-content window.
        // Only visible editors exist; the models retain values while containers recycle.
        var form = new ListBox
        {
            ItemsSource = fields, Height = Math.Min(350, fields.Length * 66d),
            BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            Padding = new Thickness(0), IsTabStop = false,
            ItemTemplate = new DataTemplate { VisualTree = new FrameworkElementFactory(typeof(ParameterFieldRow)) },
            ItemsPanel = new ItemsPanelTemplate(new FrameworkElementFactory(typeof(VirtualizingStackPanel)))
        };
        VirtualizingPanel.SetIsVirtualizing(form, true);
        VirtualizingPanel.SetVirtualizationMode(form, VirtualizationMode.Recycling);
        ScrollViewer.SetCanContentScroll(form, true);
        ScrollViewer.SetVerticalScrollBarVisibility(form, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollBarVisibility(form, ScrollBarVisibility.Disabled);
        var itemStyle = new Style(typeof(ListBoxItem));
        itemStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        itemStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        itemStyle.Setters.Add(new Setter(UIElement.FocusableProperty, false));
        itemStyle.Setters.Add(new Setter(Control.IsTabStopProperty, false));
        var itemTemplate = new ControlTemplate(typeof(ListBoxItem));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetBinding(ContentPresenter.ContentProperty, new Binding("Content") { RelativeSource = RelativeSource.TemplatedParent });
        presenter.SetBinding(ContentPresenter.ContentTemplateProperty, new Binding("ContentTemplate") { RelativeSource = RelativeSource.TemplatedParent });
        itemTemplate.VisualTree = presenter;
        itemStyle.Setters.Add(new Setter(Control.TemplateProperty, itemTemplate));
        form.ItemContainerStyle = itemStyle;
        root.Children.Add(form);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        var submit = new Button { Content = "Copy", IsDefault = true };
        buttons.Children.Add(cancel); buttons.Children.Add(submit); root.Children.Add(buttons); Content = root;
        submit.Click += async (_, _) =>
        {
            if (copying) return;
            copying = true; submit.IsEnabled = false; cancel.IsEnabled = false;
            try
            {
                await copy(fields.ToDictionary(p => p.Name, p => p.Value, StringComparer.Ordinal));
                copying = false; Copied = true; DialogResult = true;
            }
            catch (Exception error) { UiTheme.Error(this, error); }
            finally { copying = false; submit.IsEnabled = true; cancel.IsEnabled = true; }
        };
        Closing += (_, e) => { if (copying) e.Cancel = true; };
        Loaded += (_, _) => Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            if (fields.Length == 0) return;
            form.ScrollIntoView(fields[0]); form.UpdateLayout();
            if (form.ItemContainerGenerator.ContainerFromIndex(0) is DependencyObject first)
                FindParameterRow(first)?.FocusEditor();
        }));
        Closed += (_, _) =>
        {
            foreach (var field in fields) field.Value = "";
            form.ItemsSource = null; Content = null;
        };
    }

    private static ParameterFieldRow? FindParameterRow(DependencyObject root)
    {
        if (root is ParameterFieldRow row) return row;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            if (FindParameterRow(VisualTreeHelper.GetChild(root, i)) is { } found) return found;
        return null;
    }
}

internal sealed class ParameterField(string name)
{
    public string Name { get; } = name;
    public string Value { get; set; } = "";
}

/// <summary>A recycled editor never carries undo text into a different parameter.</summary>
public sealed class ParameterFieldRow : StackPanel
{
    private readonly TextBlock label = new() { FontFamily = new FontFamily("Consolas"), Margin = new Thickness(0, 0, 0, 4) };
    private readonly TextBox editor = new() { Margin = new Thickness(0, 0, 0, 12), IsUndoEnabled = true };
    private ParameterField? field;
    private bool updating;

    public ParameterFieldRow()
    {
        Children.Add(label); Children.Add(editor);
        editor.TextChanged += (_, _) => { if (!updating && field != null) field.Value = editor.Text; };
        DataContextChanged += (_, _) => LoadField();
        Loaded += (_, _) => LoadField();
        Unloaded += (_, _) => ClearEditor();
    }

    private void LoadField()
    {
        ClearEditor(); field = DataContext as ParameterField;
        updating = true;
        label.Text = field == null ? "" : "<" + field.Name + ">";
        editor.Text = field?.Value ?? "";
        System.Windows.Automation.AutomationProperties.SetName(editor, field == null ? "Parameter value" : "Value for " + field.Name);
        editor.IsUndoEnabled = true; updating = false;
    }

    private void ClearEditor()
    {
        updating = true; field = null;
        editor.IsUndoEnabled = false; editor.Clear(); label.Text = "";
        updating = false;
    }

    internal void FocusEditor() => editor.Focus();
}

internal sealed class SettingsWindow : Window
{
    private bool saving;
    private bool recording;
    public SettingsWindow(IClipDiaryActions actions, UiSettings initial)
    {
        Title = "ClipDiary Settings"; Width = 580; Height = 740; MinWidth = 480; MinHeight = 520;
        ShowInTaskbar = false; UiTheme.Configure(this);
        int hotKey = initial.HotKeyVirtualKey, modifiers = initial.HotKeyModifiers;
        string? screenshotFolder = initial.ScreenshotFolder;
        var root = new DockPanel { Margin = new Thickness(22) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        var save = new Button { Content = "Save", IsDefault = true };
        buttons.Children.Add(cancel); buttons.Children.Add(save); DockPanel.SetDock(buttons, Dock.Bottom); root.Children.Add(buttons);
        var sections = new StackPanel(); root.Children.Add(new ScrollViewer { Content = sections, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        void Heading(string text) => sections.Children.Add(new TextBlock { Text = text, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = UiTheme.Teal, Margin = new Thickness(0, 20, 0, 10) });
        void Explain(string text) => sections.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 11, Foreground = UiTheme.Muted, Margin = new Thickness(0, 4, 0, 8) });
        sections.Children.Add(UiTheme.Text("▣  ClipDiary", 22, UiTheme.Teal));
        Explain("Your clipboard, kept on this PC. Text and images stay for up to four days. Save anything important as a snippet to keep it.");
        Heading("Everyday access");
        var startup = new CheckBox { Content = "Start automatically at login", IsChecked = initial.StartAtLogin, Margin = new Thickness(0, 2, 0, 10) }; sections.Children.Add(startup);
        var chordRow = new DockPanel(); chordRow.Children.Add(UiTheme.Text("Open history"));
        var shortcut = new Button { Content = UiTheme.Shortcut(hotKey, modifiers), HorizontalAlignment = HorizontalAlignment.Right };
        var reset = new Button { Content = "Reset" };
        DockPanel.SetDock(reset, Dock.Right); chordRow.Children.Add(reset); chordRow.Children.Add(shortcut); sections.Children.Add(chordRow);
        var recordingHint = new TextBlock { Text = "Use Control, Alt or Windows with a key. Escape cancels recording.", Foreground = UiTheme.Muted, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 10) }; sections.Children.Add(recordingHint);
        shortcut.Click += (_, _) => { recording = true; shortcut.Content = "Press a shortcut…"; shortcut.Focus(); };
        reset.Click += (_, _) => { recording = false; hotKey = KeyInterop.VirtualKeyFromKey(Key.D); modifiers = 3; shortcut.Content = UiTheme.Shortcut(hotKey, modifiers); };
        PreviewKeyDown += (_, e) =>
        {
            if (!recording) return;
            e.Handled = true;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key == Key.Escape) { recording = false; shortcut.Content = UiTheme.Shortcut(hotKey, modifiers); return; }
            if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
            var flags = Keyboard.Modifiers;
            if ((flags & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) == 0) { System.Media.SystemSounds.Beep.Play(); return; }
            hotKey = KeyInterop.VirtualKeyFromKey(key); modifiers = 0;
            if (flags.HasFlag(ModifierKeys.Alt)) modifiers |= 1;
            if (flags.HasFlag(ModifierKeys.Control)) modifiers |= 2;
            if (flags.HasFlag(ModifierKeys.Shift)) modifiers |= 4;
            if (flags.HasFlag(ModifierKeys.Windows)) modifiers |= 8;
            recording = false; shortcut.Content = UiTheme.Shortcut(hotKey, modifiers);
        };
        var paused = new CheckBox { Content = "Pause automatic capture", IsChecked = initial.Paused, Margin = new Thickness(0, 4, 0, 0) }; sections.Children.Add(paused);
        Heading("Automatic screenshots");
        var screenshotsEnabled = new CheckBox { Content = "Watch the screenshots folder", IsChecked = initial.ScreenshotsEnabled }; sections.Children.Add(screenshotsEnabled);
        var folderLabel = UiTheme.Text(screenshotFolder ?? "Automatic screenshot folder", 11, UiTheme.Muted); folderLabel.Margin = new Thickness(0, 8, 0, 5); sections.Children.Add(folderLabel);
        var folderButtons = new StackPanel { Orientation = Orientation.Horizontal };
        folderButtons.Children.Add(UiTheme.Button("Choose Screenshot Folder…", (_, _) =>
        {
            var chooser = new OpenFolderDialog { Title = "Choose the folder used for saved screenshots", Multiselect = false };
            if (chooser.ShowDialog(this) == true) { screenshotFolder = chooser.FolderName; folderLabel.Text = screenshotFolder; screenshotsEnabled.IsChecked = true; }
        }));
        folderButtons.Children.Add(UiTheme.Button("Disconnect", (_, _) => { screenshotsEnabled.IsChecked = false; screenshotFolder = null; folderLabel.Text = "Automatic screenshot folder"; })); sections.Children.Add(folderButtons);
        Heading("Privacy");
        Explain("Excluded application executable names (one per line)");
        var excluded = new TextBox { Text = string.Join(Environment.NewLine, initial.ExcludedApplications), AcceptsReturn = true, Height = 78, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, IsUndoEnabled = true }; sections.Children.Add(excluded);
        Explain("Sensitive clipboard markers are skipped when provided. Saved screenshots cannot reliably identify sensitive content or the applications inside them; pause automatic capture when needed.");
        Heading("Storage");
        Explain("History: rolling 96 hours. Snippets: kept until deletion. Everything stays local. No accounts, cloud sync, analytics or remote services.");
        var deleteAll = UiTheme.Button("Delete All Local Data…", async (_, _) =>
        {
            if (saving || MessageBox.Show(this, "This permanently removes history AND saved snippets from ClipDiary. Original screenshot files are kept.", "Delete all ClipDiary data?", MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
            saving = true; save.IsEnabled = false; cancel.IsEnabled = false;
            try { await actions.DeleteAllAsync(); }
            catch (Exception error) { UiTheme.Error(this, error); }
            finally { saving = false; save.IsEnabled = true; cancel.IsEnabled = true; }
        }); sections.Children.Add(deleteAll);
        save.Click += async (_, _) =>
        {
            if (saving || recording) return;
            saving = true; save.IsEnabled = false; cancel.IsEnabled = false;
            try
            {
                var exclusions = excluded.Text.Split(['\r', '\n', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
                await actions.ApplySettingsAsync(new UiSettings(startup.IsChecked == true, paused.IsChecked == true, exclusions, hotKey, modifiers, screenshotFolder, screenshotsEnabled.IsChecked == true));
                saving = false; DialogResult = true;
            }
            catch (Exception error) { UiTheme.Error(this, error); }
            finally { saving = false; save.IsEnabled = true; cancel.IsEnabled = true; }
        };
        Closing += (_, e) => { if (saving) e.Cancel = true; };
        Content = root;
        Closed += (_, _) => { excluded.IsUndoEnabled = false; excluded.Clear(); Content = null; };
    }
}
