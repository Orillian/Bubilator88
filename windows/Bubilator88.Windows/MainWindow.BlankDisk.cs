using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Bubilator88.Windows;

public sealed partial class MainWindow
{
    private bool _creatingBlankDisk;
    private async void OnCreateBlankDisk(object sender, RoutedEventArgs e) => await CreateBlankDiskAsync();

    private async Task CreateBlankDiskAsync()
    {
        if (_host is null || _automationClosing || _creatingBlankDisk) return;
        _creatingBlankDisk = true;
        try { await ChooseAndCreateBlankDiskAsync(); }
        catch (Exception error) { ShowError($"Cannot create blank disk: {error.Message}"); }
        finally { _creatingBlankDisk = false; }
    }

    private async Task ChooseAndCreateBlankDiskAsync()
    {
        var type = new ComboBox { Header = "Disk Type", HorizontalAlignment = HorizontalAlignment.Stretch };
        type.Items.Add(new ComboBoxItem { Content = "2D (320 KB)", Tag = BlankDiskType.TwoD });
        type.Items.Add(new ComboBoxItem { Content = "2DD (640 KB)", Tag = BlankDiskType.TwoDD });
        type.Items.Add(new ComboBoxItem { Content = "2HD (1.2 MB)", Tag = BlankDiskType.TwoHD });
        type.SelectedIndex = 1;
        var basic = new CheckBox { Content = "Initialize as N88-BASIC disk", IsChecked = true };
        var content = new StackPanel { Spacing = 16, MinWidth = 320 };
        content.Children.Add(type);
        content.Children.Add(basic);
        content.Children.Add(new TextBlock
        {
            Text = "The new disk will be mounted in the first empty drive, or Drive 1 if both drives are occupied.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
        });
        var result = await ShowDialogAsync(new ContentDialog
        {
            Title = "Create Blank Disk",
            Content = content,
            PrimaryButtonText = "Create…",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Root.XamlRoot,
        });
        if (result != ContentDialogResult.Primary || _automationClosing) return;

        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = "Blank",
        };
        picker.FileTypeChoices.Add("D88 disk image", new List<string> { ".d88" });
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file is null || _host is null || _automationClosing) return;
        var selected = (BlankDiskType)((ComboBoxItem)type.SelectedItem).Tag;
        var created = BlankDiskCreation.Save(file.Path, selected, basic.IsChecked == true, _drives);
        try { MountDiskFile(created.Drive, created.Path); }
        catch (Exception error) { ShowError($"Disk saved to {created.Path}, but could not be mounted: {error.Message}"); }
    }
}
