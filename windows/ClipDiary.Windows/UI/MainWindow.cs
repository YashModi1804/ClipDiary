using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ClipDiary.Core;

namespace ClipDiary.Windows.UI;

/// <summary>Keyboard-first history surface. The controller owns capture and previous-app tracking.</summary>
public sealed class MainWindow : Window
{
    private readonly IClipDiaryActions actions;
    private readonly TextBox search = new() { ToolTip = "Search your clipboard" };
    private readonly ListBox list = new();
    private readonly TextBlock empty = UiTheme.Text("No items", 12, UiTheme.Muted);
    private readonly TextBlock status = UiTheme.Text("Starting…", 10, UiTheme.Muted);
    private readonly TextBlock shortcut = UiTheme.Text("", 10, UiTheme.Muted);
    private readonly Button historyButton;
    private readonly Button snippetsButton;
    private readonly Button addButton;
    private readonly Button pauseButton;
    private readonly ComboBox filter = new() { Width = 82, Margin = new Thickness(5, 3, 0, 3) };
    private readonly Popup hover = new() { AllowsTransparency = true, StaysOpen = true, Placement = PlacementMode.Right, HorizontalOffset = 5 };
    private readonly DispatcherTimer searchTimer = new() { Interval = TimeSpan.FromMilliseconds(90) };
    private readonly DispatcherTimer scrollTimer = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private IReadOnlyList<ClipRecord> records = Array.Empty<ClipRecord>();
    private string? hoveredId;
    private bool snippets;
    private bool busy;
    private bool auxiliaryOpen;
    private bool modalMessage;
    private bool changingCollection;
    private int reloadVersion;
    private int visibilityVersion;
    private CancellationTokenSource? reloadCancellation;
    private UiSettings? settings;
    public bool AllowClose { get; set; }

    public MainWindow(IClipDiaryActions actions)
    {
        this.actions = actions;
        Title = "ClipDiary"; Width = 440; Height = 696; MinWidth = 360; MinHeight = 520;
        ShowInTaskbar = false;
        UiTheme.Configure(this);
        var root = new DockPanel();
        var top = new StackPanel { Margin = new Thickness(16, 12, 16, 0) };
        DockPanel.SetDock(top, Dock.Top); root.Children.Add(top);
        var heading = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var controls = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(controls, Dock.Right); heading.Children.Add(controls);
        controls.Children.Add(shortcut);
        pauseButton = UiTheme.Button("Ⅱ", async (_, _) => await TogglePauseAsync());
        pauseButton.ToolTip = "Pause automatic capture"; controls.Children.Add(pauseButton);
        var settingsButton = UiTheme.Button("⚙", (_, _) => OpenSettings());
        settingsButton.ToolTip = "Settings"; controls.Children.Add(settingsButton);
        var name = UiTheme.Text("▣  ClipDiary", 16, UiTheme.Teal); name.FontWeight = FontWeights.SemiBold;
        heading.Children.Add(name); top.Children.Add(heading);
        search.Margin = new Thickness(0, 0, 0, 10); search.FontSize = 13;
        System.Windows.Automation.AutomationProperties.SetName(search, "Search your clipboard");
        top.Children.Add(search);
        var collection = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        filter.Items.Add("All"); filter.Items.Add("Text"); filter.Items.Add("Images"); filter.SelectedIndex = 0;
        DockPanel.SetDock(filter, Dock.Right); collection.Children.Add(filter);
        addButton = UiTheme.Button("+", (_, _) => OpenEditor(null)); addButton.ToolTip = "New text snippet";
        DockPanel.SetDock(addButton, Dock.Right); collection.Children.Add(addButton);
        var tabs = new UniformGrid { Rows = 1, Columns = 2 };
        historyButton = UiTheme.Button("History", (_, _) => SwitchCollection(false));
        snippetsButton = UiTheme.Button("Snippets", (_, _) => SwitchCollection(true));
        tabs.Children.Add(historyButton); tabs.Children.Add(snippetsButton); collection.Children.Add(tabs); top.Children.Add(collection);
        var footer = new Border { BorderBrush = UiTheme.Line, BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(16, 10, 16, 10), Child = status };
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var body = new Grid(); root.Children.Add(body);
        list.Background = Brushes.Transparent; list.BorderThickness = new Thickness(0); list.Padding = new Thickness(8);
        list.SelectionMode = SelectionMode.Single;
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
        ScrollViewer.SetCanContentScroll(list, true);
        var containerStyle = new Style(typeof(ListBoxItem));
        containerStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        containerStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        containerStyle.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(0, 3, 0, 3)));
        containerStyle.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.Transparent));
        containerStyle.Setters.Add(new Setter(Control.BorderBrushProperty, Brushes.Transparent));
        var rowTemplate = new ControlTemplate(typeof(ListBoxItem));
        var rowBorder = new FrameworkElementFactory(typeof(Border));
        rowBorder.SetValue(Border.CornerRadiusProperty, new CornerRadius(9));
        rowBorder.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        rowBorder.SetBinding(Border.BackgroundProperty, new Binding("Background") { RelativeSource = RelativeSource.TemplatedParent });
        rowBorder.SetBinding(Border.BorderBrushProperty, new Binding("BorderBrush") { RelativeSource = RelativeSource.TemplatedParent });
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Stretch);
        presenter.SetBinding(ContentPresenter.ContentProperty, new Binding("Content") { RelativeSource = RelativeSource.TemplatedParent });
        presenter.SetBinding(ContentPresenter.ContentTemplateProperty, new Binding("ContentTemplate") { RelativeSource = RelativeSource.TemplatedParent });
        rowBorder.AppendChild(presenter); rowTemplate.VisualTree = rowBorder;
        containerStyle.Setters.Add(new Setter(Control.TemplateProperty, rowTemplate));
        var hoverTrigger = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hoverTrigger.Setters.Add(new Setter(Control.BackgroundProperty, new SolidColorBrush(Color.FromArgb(12, 0, 0, 0))));
        containerStyle.Triggers.Add(hoverTrigger);
        var selectedTrigger = new Trigger { Property = ListBoxItem.IsSelectedProperty, Value = true };
        selectedTrigger.Setters.Add(new Setter(Control.BackgroundProperty, new SolidColorBrush(Color.FromArgb(33, 19, 125, 122))));
        selectedTrigger.Setters.Add(new Setter(Control.BorderBrushProperty, new SolidColorBrush(Color.FromArgb(77, 19, 125, 122))));
        containerStyle.Triggers.Add(selectedTrigger);
        list.ItemContainerStyle = containerStyle;
        list.ItemTemplate = new DataTemplate { VisualTree = new FrameworkElementFactory(typeof(ClipRow)) };
        body.Children.Add(list);
        empty.HorizontalAlignment = HorizontalAlignment.Center; empty.VerticalAlignment = VerticalAlignment.Center;
        empty.IsHitTestVisible = false; body.Children.Add(empty);
        Content = root;
        UpdateTabs();
        search.TextChanged += (_, _) => { HideHover(); if (changingCollection) return; CancelPendingReload(); searchTimer.Stop(); searchTimer.Start(); };
        searchTimer.Tick += async (_, _) => { searchTimer.Stop(); await ReloadAsync(false); };
        filter.SelectionChanged += async (_, _) => { HideHover(); await ReloadAsync(true); };
        list.SelectionChanged += (_, _) => HideHover();
        list.PreviewMouseLeftButtonUp += async (_, e) =>
        {
            if (FindItem(e.OriginalSource as DependencyObject) is { DataContext: ClipRecord item })
            { list.SelectedItem = item; e.Handled = true; await CopySelectedAsync(); }
        };
        list.PreviewMouseRightButtonDown += (_, e) =>
        {
            if (FindItem(e.OriginalSource as DependencyObject) is { DataContext: ClipRecord item } row)
            {
                list.SelectedItem = item; HideHover();
                row.ContextMenu = BuildContextMenu(item);
            }
        };
        list.MouseMove += (_, e) => { if (!scrollTimer.IsEnabled) ShowHover(FindItem(e.OriginalSource as DependencyObject)); };
        list.MouseLeave += (_, _) => HideHover();
        list.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, e) =>
        {
            if (e.VerticalChange == 0 && e.HorizontalChange == 0) return;
            HideHover(); scrollTimer.Stop(); scrollTimer.Start();
        }));
        scrollTimer.Tick += (_, _) => { scrollTimer.Stop(); if (IsVisible && list.IsMouseOver) ShowHover(FindItem(Mouse.DirectlyOver as DependencyObject)); };
        PreviewKeyDown += HandleKeyDown;
        Deactivated += (_, _) => { if (!auxiliaryOpen && !modalMessage) HideHistory(false); };
        Closing += OnClosing;
        Closed += (_, _) => { actions.Changed -= OnChanged; CancelPendingReload(); searchTimer.Stop(); scrollTimer.Stop(); };
        actions.Changed += OnChanged;
    }

    public async void ShowHistory()
    {
        if (auxiliaryOpen) return;
        int request = ++visibilityVersion;
        try
        {
            settings = await actions.GetSettingsAsync();
            if (request != visibilityVersion || AllowClose) return;
            UpdateStatus();
            await ReloadAsync(true, true);
            if (request != visibilityVersion || AllowClose) return;
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
            Show(); Activate(); search.Focus(); search.SelectAll();
            ScrollSelected();
        }
        catch (Exception error) { ShowError(error); }
    }

    public void HideHistory(bool restorePreviousApplication)
    {
        visibilityVersion++; CancelPendingReload(); searchTimer.Stop(); scrollTimer.Stop(); HideHover();
        Hide(); list.ItemsSource = null; records = Array.Empty<ClipRecord>();
        if (restorePreviousApplication) actions.RestorePreviousApplication();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (AllowClose) return;
        e.Cancel = true; HideHistory(true);
    }

    private void OnChanged()
    {
        _ = Dispatcher.BeginInvoke(new Action(async () =>
        {
            try
            {
                settings = await actions.GetSettingsAsync(); UpdateStatus();
                if (IsVisible && !auxiliaryOpen && !modalMessage) await ReloadAsync(false);
            }
            catch (Exception error) { if (IsVisible) ShowError(error); }
        }));
    }

    private void CancelPendingReload()
    {
        reloadVersion++;
        reloadCancellation?.Cancel(); reloadCancellation?.Dispose(); reloadCancellation = null;
    }

    private async Task ReloadAsync(bool latest, bool opening = false)
    {
        if (modalMessage || (!opening && !IsVisible)) return;
        CancelPendingReload();
        var version = reloadVersion;
        reloadCancellation = new CancellationTokenSource();
        var cancellationToken = reloadCancellation.Token;
        var selectedId = (list.SelectedItem as ClipRecord)?.Id;
        bool followLatest = selectedId == null || selectedId == records.LastOrDefault()?.Id;
        try
        {
            var result = await actions.GetRecordsAsync(search.Text, snippets, filter.SelectedIndex == 1 ? ClipKind.Text : filter.SelectedIndex == 2 ? ClipKind.Image : null, cancellationToken);
            if (version != reloadVersion || (!opening && !IsVisible)) return;
            HideHover(); records = result; list.ItemsSource = records;
            list.SelectedItem = latest || followLatest ? records.LastOrDefault() : records.FirstOrDefault(r => r.Id == selectedId) ?? records.LastOrDefault();
            empty.Text = search.Text.Length == 0 ? "No items" : "No matches";
            empty.Visibility = result.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            ScrollSelected(); UpdateStatus();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception error) { if (version == reloadVersion) ShowError(error); }
    }

    private void SwitchCollection(bool useSnippets)
    {
        if (snippets == useSnippets) return;
        snippets = useSnippets; changingCollection = true; search.Clear(); changingCollection = false;
        UpdateTabs(); HideHover(); _ = ReloadAsync(true);
    }

    private void UpdateTabs()
    {
        historyButton.Foreground = !snippets ? UiTheme.Teal : UiTheme.Muted;
        snippetsButton.Foreground = snippets ? UiTheme.Teal : UiTheme.Muted;
        historyButton.FontWeight = !snippets ? FontWeights.SemiBold : FontWeights.Normal;
        snippetsButton.FontWeight = snippets ? FontWeights.SemiBold : FontWeights.Normal;
        addButton.Visibility = snippets ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateStatus()
    {
        status.Text = settings?.Paused == true ? "●  Paused" : "●  " + actions.CaptureStatus;
        pauseButton.Content = settings?.Paused == true ? "▶" : "Ⅱ";
        pauseButton.ToolTip = settings?.Paused == true ? "Resume automatic capture" : "Pause automatic capture";
        if (settings != null) shortcut.Text = UiTheme.Shortcut(settings.HotKeyVirtualKey, settings.HotKeyModifiers);
    }

    private async Task TogglePauseAsync()
    {
        try { settings = await actions.GetSettingsAsync(); settings = settings with { Paused = !settings.Paused }; await actions.ApplySettingsAsync(settings); UpdateStatus(); }
        catch (Exception error) { ShowError(error); }
    }

    private void HandleKeyDown(object sender, KeyEventArgs e)
    {
        if (e.ImeProcessedKey != Key.None && e.Key == Key.ImeProcessed) return;
        var modifiers = Keyboard.Modifiers;
        if (e.Key == Key.Escape && modifiers == ModifierKeys.None) { e.Handled = true; HideHistory(true); }
        else if (modifiers == ModifierKeys.Control && e.Key == Key.C)
        {
            if (search.IsKeyboardFocusWithin && search.SelectionLength > 0) return;
            e.Handled = true; _ = CopySelectedAsync();
        }
        else if (modifiers == ModifierKeys.Control && e.Key == Key.F) { e.Handled = true; search.Focus(); search.SelectAll(); }
        else if (modifiers == ModifierKeys.Control && e.Key is Key.D1 or Key.D2) { e.Handled = true; SwitchCollection(e.Key == Key.D2); }
        else if (modifiers == ModifierKeys.Control && e.Key == Key.S && list.SelectedItem is ClipRecord { IsSnippet: false } item)
        { e.Handled = true; _ = RunActionAsync(() => actions.SaveSnippetAsync(item.Id)); }
        else if (modifiers == ModifierKeys.None && e.Key is Key.Up or Key.Down)
        {
            if (records.Count == 0) return;
            e.Handled = true;
            list.SelectedIndex = Math.Clamp((list.SelectedIndex < 0 ? records.Count - 1 : list.SelectedIndex) + (e.Key == Key.Down ? 1 : -1), 0, records.Count - 1);
            ScrollSelected();
        }
    }

    private void ScrollSelected() { if (list.SelectedItem != null) list.ScrollIntoView(list.SelectedItem); }

    private async Task CopySelectedAsync()
    {
        if (busy || list.SelectedItem is not ClipRecord selected) return;
        busy = true; HideHover();
        try
        {
            var item = await actions.GetRecordAsync(selected.Id) ?? throw new InvalidOperationException("That item has expired or was removed.");
            var names = item.IsSnippet && item.IsParameterized && item.Kind == ClipKind.Text
                ? Regex.Matches(item.Text ?? "", @"<([\p{L}\p{N}_-]+)>").Select(m => m.Groups[1].Value).Distinct(StringComparer.Ordinal).ToArray() : [];
            if (names.Length > 0)
            {
                auxiliaryOpen = true; HideHistory(false);
                var dialog = new ParameterWindow(names, async values =>
                {
                    var current = await actions.GetRecordAsync(item.Id);
                    if (current == null || !current.IsSnippet || current.IsParameterized != item.IsParameterized || current.Text != item.Text)
                        throw new InvalidOperationException("This snippet changed. Cancel and select it again to copy.");
                    await actions.CopyAsync(item.Id, values);
                });
                dialog.ShowDialog(); auxiliaryOpen = false;
                if (dialog.Copied) actions.RestorePreviousApplication(); else ShowHistory();
            }
            else { await actions.CopyAsync(item.Id); HideHistory(true); }
        }
        catch (Exception error) { auxiliaryOpen = false; ShowError(error); }
        finally { busy = false; }
    }

    private ContextMenu BuildContextMenu(ClipRecord item)
    {
        var menu = new ContextMenu();
        void Add(string title, Func<Task> action)
        {
            var entry = new MenuItem { Header = title };
            entry.Click += async (_, _) => await RunActionAsync(action);
            menu.Items.Add(entry);
        }
        if (!item.IsSnippet) Add("Save as Snippet", () => actions.SaveSnippetAsync(item.Id));
        else
        {
            var edit = new MenuItem { Header = "Edit Snippet" }; edit.Click += (_, _) => OpenEditor(item.Id); menu.Items.Add(edit);
            if (item.Kind == ClipKind.Text) Add(item.IsParameterized ? "Disable Parameters" : "Make Parameterized", () => actions.SetParameterizedAsync(item.Id, !item.IsParameterized));
        }
        menu.Items.Add(new Separator());
        Add("Delete", async () => { if (Confirm("Delete this item?", "This permanently removes the selected item from ClipDiary.")) await actions.DeleteAsync(item.Id); });
        if (!snippets)
        {
            menu.Items.Add(new Separator());
            Add("Clear History…", async () => { if (Confirm("Clear clipboard history?", "Your saved snippets and original screenshot files are kept.")) await actions.ClearHistoryAsync(); });
        }
        menu.Opened += (_, _) => HideHover();
        return menu;
    }

    private bool Confirm(string title, string text)
    {
        HideHover(); modalMessage = true;
        try { return MessageBox.Show(this, text, title, MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) == MessageBoxResult.OK; }
        finally { modalMessage = false; }
    }
    private void ShowError(Exception error)
    {
        if (modalMessage) return;
        HideHover(); modalMessage = true;
        try { UiTheme.Error(IsVisible ? this : null, error); }
        finally { modalMessage = false; }
    }
    private async Task RunActionAsync(Func<Task> action)
    {
        if (busy) return;
        busy = true; HideHover();
        try { await action(); await ReloadAsync(false); }
        catch (Exception error) { ShowError(error); }
        finally { busy = false; }
    }

    private async void OpenEditor(string? id)
    {
        if (auxiliaryOpen || busy) return;
        auxiliaryOpen = true;
        try
        {
            var item = id == null ? null : await actions.GetRecordAsync(id) ?? throw new InvalidOperationException("This snippet is no longer available.");
            HideHistory(false);
            new SnippetEditorWindow(item, (title, text, parameterized) => actions.UpsertSnippetAsync(id, title, text, parameterized)).ShowDialog();
        }
        catch (Exception error) { ShowError(error); }
        finally { auxiliaryOpen = false; ShowHistory(); }
    }

    public async void OpenSettings()
    {
        if (auxiliaryOpen || busy) return;
        auxiliaryOpen = true;
        try
        {
            settings = await actions.GetSettingsAsync(); HideHistory(false);
            new SettingsWindow(actions, settings).ShowDialog();
            settings = await actions.GetSettingsAsync();
        }
        catch (Exception error) { ShowError(error); }
        finally { auxiliaryOpen = false; }
    }

    private void HideHover() { hover.IsOpen = false; hover.Child = null; hoveredId = null; }
    private void ShowHover(ListBoxItem? row)
    {
        if (!IsActive || auxiliaryOpen || modalMessage || row?.DataContext is not ClipRecord item || row.ContextMenu?.IsOpen == true) { HideHover(); return; }
        if (hoveredId == item.Id && hover.IsOpen) return;
        HideHover(); hoveredId = item.Id;
        var stack = new StackPanel { Width = 304 };
        if (item.Kind == ClipKind.Text) stack.Children.Add(UiTheme.Text(UiTheme.Excerpt(item.Text ?? ""), 12));
        else if (item.ThumbnailPath != null)
        {
            var image = new Image { MaxHeight = 210, Width = 304, Stretch = Stretch.Uniform };
            stack.Children.Add(image); _ = ClipRow.LoadImageAsync(image, item.ThumbnailPath);
        }
        stack.Children.Add(new Separator { Margin = new Thickness(0, 9, 0, 9) });
        stack.Children.Add(UiTheme.Text(item.Source + "\n" + item.CapturedAt.ToLocalTime().ToString("g") + "\n" + UiTheme.Bytes(item.ByteCount), 10, UiTheme.Muted));
        hover.Child = new Border { Background = Brushes.White, BorderBrush = UiTheme.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(13), Child = stack, MaxHeight = 420 };
        hover.PlacementTarget = row; hover.IsOpen = true;
    }

    private static ListBoxItem? FindItem(DependencyObject? element)
    {
        while (element != null)
        {
            if (element is ListBoxItem item) return item;
            element = element is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element);
        }
        return null;
    }
}

public sealed class ClipRow : Border
{
    private static readonly object cacheLock = new();
    private static readonly Dictionary<string, BitmapSource> imageCache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Queue<string> cacheOrder = new();
    private static long cachedBytes;
    private int imageVersion;
    public ClipRow()
    {
        CornerRadius = new CornerRadius(9); Padding = new Thickness(12); Background = Brushes.Transparent;
        DataContextChanged += (_, _) => Render();
    }
    private void Render()
    {
        var version = ++imageVersion;
        if (DataContext is not ClipRecord item) { Child = null; return; }
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (item.Kind == ClipKind.Image && item.ThumbnailPath != null)
        {
            var image = new Image { Width = 84, Height = 68, Stretch = Stretch.Uniform, Margin = new Thickness(0, 0, 11, 0) };
            grid.Children.Add(image); _ = LoadImageAsync(image, item.ThumbnailPath, () => version == imageVersion);
        }
        else { var symbol = UiTheme.Text("≡", 18, UiTheme.Teal); symbol.Width = 23; symbol.Margin = new Thickness(0, 0, 11, 0); grid.Children.Add(symbol); }
        var title = UiTheme.Text(item.IsSnippet && item.Title.Length > 0 ? item.Title : item.Kind == ClipKind.Image ? "Image" : UiTheme.Prefix(item.Text ?? item.Title, 240).Replace('\n', ' ').Replace('\r', ' '));
        title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis;
        Grid.SetColumn(title, 1); grid.Children.Add(title);
        if (item.IsSnippet) { var marker = UiTheme.Text(item.IsParameterized ? "{ }  ◆" : "◆", 10, UiTheme.Teal); marker.Margin = new Thickness(8, 0, 0, 0); Grid.SetColumn(marker, 2); grid.Children.Add(marker); }
        Child = grid;
        System.Windows.Automation.AutomationProperties.SetName(this, item.Kind == ClipKind.Image ? "Image: " + item.Title : item.Text ?? item.Title);
    }
    internal static async Task LoadImageAsync(Image target, string path, Func<bool>? current = null)
    {
        try
        {
            var bitmap = await Task.Run(() =>
            {
                lock (cacheLock) { if (imageCache.TryGetValue(path, out var cached)) return cached; }
                using var stream = File.OpenRead(path);
                var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.DecodePixelWidth = 608; image.StreamSource = stream; image.EndInit(); image.Freeze();
                lock (cacheLock)
                {
                    if (imageCache.TryGetValue(path, out var cached)) return cached;
                    long bytes = (long)image.PixelWidth * image.PixelHeight * 4;
                    if (bytes <= 24 * 1024 * 1024)
                    {
                        while (imageCache.Count > 0 && (imageCache.Count >= 64 || cachedBytes + bytes > 24 * 1024 * 1024))
                        {
                            var key = cacheOrder.Dequeue(); var old = imageCache[key];
                            cachedBytes -= (long)old.PixelWidth * old.PixelHeight * 4; imageCache.Remove(key);
                        }
                        imageCache.Add(path, image); cacheOrder.Enqueue(path); cachedBytes += bytes;
                    }
                }
                return (BitmapSource)image;
            });
            if (current?.Invoke() != false) target.Source = bitmap;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException or System.IO.FileFormatException or ArgumentException) { /* Missing/expired images keep the row usable. */ }
    }
}
