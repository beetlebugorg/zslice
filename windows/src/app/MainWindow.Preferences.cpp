// Preferences (Ctrl+, or the main menu). It follows
// linux/src/ui/preferences.c.
//
// Printers: a list on the left, and the form of the selected printer on the
// right: its name, its connection, a test of the connection, and what the
// printer tells (the bed, the nozzle, the filament in it). "+" opens the
// printer picker, and "Get a key" the pairing panel. Both are the panels of
// the Printers page. A saved key never shows. A new key replaces it.
//
// General: the theme, the first view, the slicer threads, and the folder of
// the settings files. app.ini keeps them as theme, view, and engine.threads.
// The core keeps no thread count across a restart and copies none to a new
// plate, so the shell gives the preference to each plate.
//
// The app never starts a print. The test here only reads the printer.
//
// See MainWindow.Printers.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.Printers.h"

#include <dwmapi.h>

#include <cmath>

#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>

#pragma comment(lib, "dwmapi.lib")

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Media = Microsoft::UI::Xaml::Media;
namespace Markup = Microsoft::UI::Xaml::Markup;
using Windows::Foundation::IInspectable;
using Windows::System::VirtualKey;

namespace winrt::ZSlice::implementation
{
    using namespace ui;

    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    namespace
    {
        // ---- the theme of the brushes that the code looks up ----

        ElementTheme brush_theme = ElementTheme::Default;

        // The WinUI brushes that the printer panels look up, and the color
        // token of App.xaml for each. A lookup in the application resources
        // always has the system theme, and the tokens exist for both themes.
        wchar_t const *TokenOf(std::wstring_view key)
        {
            if (key == L"TextFillColorSecondaryBrush")
                return L"ZsDim";
            if (key == L"SolidBackgroundFillColorBaseBrush")
                return L"ZsBg";
            if (key == L"CardBackgroundFillColorDefaultBrush")
                return L"ZsCard";
            if (key == L"CardStrokeColorDefaultBrush")
                return L"ZsLine";
            if (key == L"SurfaceStrokeColorFlyoutBrush")
                return L"ZsPopoverBorder";
            if (key == L"AccentFillColorDisabledBrush")
                return L"ZsButton";
            return nullptr;
        }

        // ---- the page ----

        constexpr wchar_t page_head[] = LR"xaml(<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Grid.Resources>
    <Style TargetType="TextBlock"><Setter Property="FontSize" Value="13" /></Style>
    <Style x:Key="FormLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13" />
      <Setter Property="HorizontalAlignment" Value="Right" />
      <Setter Property="VerticalAlignment" Value="Center" />
      <Setter Property="Foreground" Value="{ThemeResource ZsDim}" />
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12" />
      <Setter Property="TextWrapping" Value="Wrap" />
      <Setter Property="Foreground" Value="{ThemeResource ZsDim}" />
    </Style>
  </Grid.Resources>)xaml";

        constexpr wchar_t page_printers[] = LR"xaml(
  <Grid x:Name="PrintersPage">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="220" /><ColumnDefinition Width="1" /><ColumnDefinition Width="*" />
    </Grid.ColumnDefinitions>
    <Grid Padding="6,0,6,6" RowSpacing="4">
      <Grid.RowDefinitions><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
      <ListView x:Name="PrinterList" SelectionMode="Single" AutomationProperties.Name="Printers">
        <ListView.Resources>
          <SolidColorBrush x:Key="ListViewItemSelectionIndicatorBrush" Color="Transparent" />
          <SolidColorBrush x:Key="ListViewItemSelectionIndicatorPointerOverBrush" Color="Transparent" />
          <SolidColorBrush x:Key="ListViewItemSelectionIndicatorPressedBrush" Color="Transparent" />
          <SolidColorBrush x:Key="ListViewItemSelectionIndicatorDisabledBrush" Color="Transparent" />
        </ListView.Resources>
      </ListView>
      <StackPanel Grid.Row="1" Orientation="Horizontal" Spacing="4">
        <Button x:Name="AddPrinter" Width="34" Height="30" Padding="0" AutomationProperties.Name="Add a printer" ToolTipService.ToolTip="Add a printer"><FontIcon Glyph="&#xE710;" FontSize="12" /></Button>
        <Button x:Name="RemovePrinter" Width="34" Height="30" Padding="0" AutomationProperties.Name="Remove the selected printer" ToolTipService.ToolTip="Remove the selected printer and its machine settings"><FontIcon Glyph="&#xE738;" FontSize="12" /></Button>
      </StackPanel>
    </Grid>
    <Rectangle Grid.Column="1" Fill="{ThemeResource ZsLine}" />
    <ScrollViewer Grid.Column="2" HorizontalScrollBarVisibility="Disabled">
      <Grid Margin="18,18,22,18" ColumnSpacing="12" RowSpacing="8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" />
          <RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <TextBlock Text="Name" Style="{StaticResource FormLabel}" />
        <TextBox x:Name="FormName" Grid.Column="1" FontSize="13" AutomationProperties.Name="Name" />
        <TextBlock Grid.Row="1" Text="Connection" Style="{StaticResource FormLabel}" />
        <ComboBox x:Name="FormKind" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Stretch" FontSize="13" AutomationProperties.Name="Connection" />
        <TextBlock x:Name="FormTrust" Grid.Row="2" Grid.Column="1" Style="{StaticResource Caption}" />
        <TextBlock x:Name="UrlLabel" Grid.Row="3" Text="Address" Style="{StaticResource FormLabel}" />
        <TextBox x:Name="FormUrl" Grid.Row="3" Grid.Column="1" FontSize="13" AutomationProperties.Name="Address" />
        <TextBlock x:Name="SerialLabel" Grid.Row="4" Text="Serial number" Style="{StaticResource FormLabel}" />
        <Grid x:Name="SerialBox" Grid.Row="4" Grid.Column="1" ColumnSpacing="6">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
          <TextBox x:Name="FormSerial" FontSize="13" PlaceholderText="On the screen of the printer, or Read" AutomationProperties.Name="Serial number" />
          <Button x:Name="FormRead" Grid.Column="1" FontSize="13" Content="Read" />
        </Grid>
        <TextBlock x:Name="KeyLabel" Grid.Row="5" Text="API key" Style="{StaticResource FormLabel}" />
        <Grid x:Name="KeyBox" Grid.Row="5" Grid.Column="1" ColumnSpacing="6">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
          <PasswordBox x:Name="FormKey" FontSize="13" AutomationProperties.Name="The key of the printer" />
          <Button x:Name="FormGetKey" Grid.Column="1" FontSize="13" Content="Get a key" />
        </Grid>
        <StackPanel Grid.Row="6" Grid.Column="1" Orientation="Horizontal" Spacing="8">
          <Button x:Name="FormTest" FontSize="13" Content="Test the connection" />
          <Button x:Name="FormUse" FontSize="13" Content="Use this printer" Style="{StaticResource ZsSuggested}" />
        </StackPanel>
        <TextBlock x:Name="FormResult" Grid.Row="7" Grid.Column="1" TextWrapping="Wrap" IsTextSelectionEnabled="True" />
        <StackPanel Grid.Row="8" Grid.Column="1" Orientation="Horizontal" Spacing="8">
          <Button x:Name="UseMachine" FontSize="13" Content="Use the printer's bed, nozzle, and motion" Visibility="Collapsed"
                  ToolTipService.ToolTip="Copies the bed size, the height, and the nozzle that the printer tells to the machine settings of this printer." />
          <Button x:Name="UseFilament" FontSize="13" Content="Use the filament in the printer" Visibility="Collapsed"
                  ToolTipService.ToolTip="Sets the filament settings from the filament in the printer: the built-in profile of its material, its name, diameter, and color." />
        </StackPanel>
        <TextBlock Grid.Row="9" Grid.Column="1" Margin="0,12,0,0" TextWrapping="Wrap" Foreground="{ThemeResource ZsDim}"
                   Text="The machine settings of the current printer (bed, nozzle, speeds, start and end G-code) are in the Settings page, under Printer, and in the printer list of the header bar (Printer settings and G-code). Each printer keeps its own." />
      </Grid>
    </ScrollViewer>
  </Grid>)xaml";

        constexpr wchar_t page_general[] = LR"xaml(
  <ScrollViewer x:Name="GeneralPage" Visibility="Collapsed" HorizontalScrollBarVisibility="Disabled">
    <Grid Margin="18,18,22,18" ColumnSpacing="12" RowSpacing="10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" />
      </Grid.RowDefinitions>
      <TextBlock Text="Theme" Style="{StaticResource FormLabel}" />
      <ComboBox x:Name="GeneralTheme" Grid.Column="1" HorizontalAlignment="Stretch" FontSize="13" AutomationProperties.Name="Theme" />
      <TextBlock Grid.Row="1" Text="First view" Style="{StaticResource FormLabel}" />
      <ComboBox x:Name="GeneralView" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Stretch" FontSize="13" AutomationProperties.Name="First view" />
      <TextBlock Grid.Row="2" Text="Slicer threads" Style="{StaticResource FormLabel}" />
      <NumberBox x:Name="GeneralThreads" Grid.Row="2" Grid.Column="1" Minimum="0" Maximum="256" SmallChange="1" LargeChange="10" SpinButtonPlacementMode="Inline"
                 FontSize="13" AutomationProperties.Name="Slicer threads" ToolTipService.ToolTip="The threads of the slicer. 0: one for each processor core." />
      <TextBlock Grid.Row="3" Text="Settings files" Style="{StaticResource FormLabel}" />
      <Grid Grid.Row="3" Grid.Column="1" ColumnSpacing="8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
        <TextBlock x:Name="GeneralFolder" VerticalAlignment="Center" TextWrapping="Wrap" IsTextSelectionEnabled="True" />
        <Button x:Name="GeneralOpen" Grid.Column="1" FontSize="13" Content="Open" />
      </Grid>
      <TextBlock Grid.Row="4" Grid.Column="1" TextWrapping="Wrap" Foreground="{ThemeResource ZsDim}"
                 Text="The defaults of all prints are in the Settings page of the main window. The app saves them here: filament.toml, project.toml, and printers/ for the machine settings of each printer." />
    </Grid>
  </ScrollViewer>
</Grid>)xaml";

        constexpr wchar_t list_row[] = LR"xaml(<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" ColumnSpacing="8" Padding="2,4,2,4">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
  <StackPanel>
    <TextBlock x:Name="RowName" FontSize="13" TextWrapping="Wrap" />
    <TextBlock x:Name="RowKind" FontSize="11.5" Foreground="{ThemeResource ZsDim}" />
  </StackPanel>
  <FontIcon x:Name="RowCurrent" Grid.Column="1" Glyph="&#xE73E;" FontSize="12" Visibility="Collapsed" ToolTipService.ToolTip="The current printer" />
</Grid>)xaml";

        template <typename T>
        T Get(FrameworkElement const &root, wchar_t const *name)
        {
            return root.FindName(name).as<T>();
        }

        void Show(UIElement const &element, bool on)
        {
            element.Visibility(on ? Visibility::Visible : Visibility::Collapsed);
        }

        std::string Utf8(hstring const &text)
        {
            return zs::ToUtf8(std::wstring(text));
        }

        bool UsesKey(zs::LinkKind kind)
        {
            return kind == zs::LinkKind::Printdeck || kind == zs::LinkKind::OctoPrint || kind == zs::LinkKind::PrusaLink ||
                   kind == zs::LinkKind::Bambu;
        }

        // Why a printer is or is not verified. The words are of the GTK
        // shell, with the place of the secrets on Windows.
        wchar_t const *TrustWords(zs::SavedPrinter const &p)
        {
            switch (p.kind)
            {
            case zs::LinkKind::Printdeck:
                if (p.url.rfind("https://", 0) == 0)
                    return L"Verified: zslice checks the certificate of the deck, and signs each print. "
                           L"Turn on Settings › Signed prints on the deck to stop prints from other apps.";
                return L"zslice signs each print, and the deck can check it (Settings › Signed prints). "
                       L"The address is http, so zslice cannot verify the deck: use its https address (on the System page of the deck).";
            case zs::LinkKind::OctoPrint:
            case zs::LinkKind::Moonraker:
            case zs::LinkKind::PrusaLink:
                return L"Not verified: this printer does not check the signatures of prints. Anyone with its key can send it a file.";
            case zs::LinkKind::Bambu:
                return L"Read only: zslice reads the status and the camera of the printer, and sends it nothing. Turn on LAN Only Mode on the printer "
                       L"(and LAN Only Liveview for the camera). The access code is on its screen; zslice keeps it in the folder bambu of its "
                       L"settings, encrypted for your Windows user.";
            default:
                return nullptr;
            }
        }

        std::wstring Format(wchar_t const *format, double a, double b = 0, double c = 0)
        {
            wchar_t text[128];
            swprintf_s(text, format, a, b, c);
            return text;
        }
    }

    namespace ui
    {
        void SetPreferenceTheme(ElementTheme theme)
        {
            brush_theme = theme;
        }

        Media::Brush PreferenceBrush(wchar_t const *key)
        {
            wchar_t const *token = brush_theme == ElementTheme::Default ? nullptr : TokenOf(key);
            if (token == nullptr)
                return nullptr;
            wchar_t const *theme = brush_theme == ElementTheme::Dark ? L"Dark" : L"Light";
            auto dictionary = Application::Current().Resources().MergedDictionaries().GetAt(1).ThemeDictionaries().Lookup(box_value(theme)).as<ResourceDictionary>();
            return dictionary.Lookup(box_value(token)).as<Media::Brush>();
        }
    }

    struct MainWindow::PrintersUi::PrefsPage : std::enable_shared_from_this<MainWindow::PrintersUi::PrefsPage>
    {
        explicit PrefsPage(PrintersUi &owner) : ui(owner) {}

        PrintersUi &ui;
        std::shared_ptr<OverlayPanel> panel;
        std::string id;
        std::vector<std::string> ids;
        size_t known = 0;
        bool filling = false;
        bool result_error = false;

        Primitives::ToggleButton tab_printers{ nullptr }, tab_general{ nullptr };
        FrameworkElement printers_page{ nullptr }, general_page{ nullptr };
        ListView list{ nullptr };
        Button add{ nullptr }, remove{ nullptr }, read{ nullptr }, get_key{ nullptr }, test{ nullptr }, use{ nullptr }, use_machine{ nullptr }, use_filament{ nullptr }, open{ nullptr };
        TextBox name{ nullptr }, url{ nullptr }, serial{ nullptr };
        PasswordBox key{ nullptr };
        ComboBox kind{ nullptr }, theme{ nullptr }, first_view{ nullptr };
        NumberBox threads{ nullptr };
        TextBlock trust{ nullptr }, url_label{ nullptr }, serial_label{ nullptr }, key_label{ nullptr }, result{ nullptr }, folder{ nullptr };
        FrameworkElement serial_box{ nullptr };
        Grid key_box{ nullptr };

        // The test in flight, and the status for the two Use buttons.
        zs::http::CancelPtr cancel;
        std::shared_ptr<zs::BambuWatch> bambu;
        std::shared_ptr<zs_printer_status> core;

        zs::SavedPrinter *Printer() { return zs::Printers().Find(id); }

        void Build(FrameworkElement const &root);
        void Wire();
        void Tint();
        void ShowTab(bool general);
        void FillList();
        void FillForm();
        void ShowRows();
        void Reload();
        void ClearInfo();
        void Commit();
        void ShowRowName(std::string const &text);
        void SetResult(std::wstring const &text, bool error);
        void Test();
        void BambuDone(zs::link::Snapshot const *status, std::string const &error);
        void ShowInfo(zs::link::Snapshot const &status);
        void Apply(int what);
        void ReadSerial();
        void UsePrinter();
        void RemovePrinter();
        void KindChanged();
    };

    void MainWindow::PrintersUi::PrefsPage::Build(FrameworkElement const &root)
    {
        printers_page = Get<FrameworkElement>(root, L"PrintersPage");
        general_page = Get<FrameworkElement>(root, L"GeneralPage");
        list = Get<ListView>(root, L"PrinterList");
        add = Get<Button>(root, L"AddPrinter");
        remove = Get<Button>(root, L"RemovePrinter");
        name = Get<TextBox>(root, L"FormName");
        kind = Get<ComboBox>(root, L"FormKind");
        trust = Get<TextBlock>(root, L"FormTrust");
        url_label = Get<TextBlock>(root, L"UrlLabel");
        url = Get<TextBox>(root, L"FormUrl");
        serial_label = Get<TextBlock>(root, L"SerialLabel");
        serial_box = Get<FrameworkElement>(root, L"SerialBox");
        serial = Get<TextBox>(root, L"FormSerial");
        read = Get<Button>(root, L"FormRead");
        key_label = Get<TextBlock>(root, L"KeyLabel");
        key_box = Get<Grid>(root, L"KeyBox");
        key = Get<PasswordBox>(root, L"FormKey");
        get_key = Get<Button>(root, L"FormGetKey");
        test = Get<Button>(root, L"FormTest");
        use = Get<Button>(root, L"FormUse");
        result = Get<TextBlock>(root, L"FormResult");
        use_machine = Get<Button>(root, L"UseMachine");
        use_filament = Get<Button>(root, L"UseFilament");
        theme = Get<ComboBox>(root, L"GeneralTheme");
        first_view = Get<ComboBox>(root, L"GeneralView");
        threads = Get<NumberBox>(root, L"GeneralThreads");
        folder = Get<TextBlock>(root, L"GeneralFolder");
        open = Get<Button>(root, L"GeneralOpen");

        ToolTipService::SetToolTip(read, box_value(L"Read the serial number from the printer at the address (from its certificate, with no login)."));
        ToolTipService::SetToolTip(get_key, box_value(L"Ask the printer for a key of its own for zslice. The printer asks \"Allow zslice?\" on its touch screen (printdeck), or in its web page (OctoPrint, with the App Keys plugin). Allow it within 2 minutes."));
        ToolTipService::SetToolTip(key, box_value(L"The API key of the printer (in OctoPrint: Settings › API, or an application key; printdeck: its System page). It is kept encrypted for your Windows user."));

        for (int k = 0; k < (int)zs::LinkKind::Count; k++)
            kind.Items().Append(box_value(zs::ToWide(zs::LinkTitle((zs::LinkKind)k))));
        for (wchar_t const *text : { L"The system style", L"Light", L"Dark" })
            theme.Items().Append(box_value(text));
        for (wchar_t const *text : { L"2D (one layer)", L"3D" })
            first_view.Items().Append(box_value(text));

        zs::PrinterStore &store = zs::Printers();
        std::string now = store.Pref("theme", "system");
        theme.SelectedIndex(now == "light" ? 1 : now == "dark" ? 2 : 0);
        first_view.SelectedIndex(store.Pref("view", "3d") == "2d" ? 0 : 1);
        threads.Value(atof(ui.w.model->GetSetting("engine.threads").c_str()));
        folder.Text(zs::StateDir());
    }

    void MainWindow::PrintersUi::PrefsPage::Wire()
    {
        std::weak_ptr<PrefsPage> weak = weak_from_this();
        auto on = [weak](void (PrefsPage::*method)()) {
            return [weak, method](auto &&, auto &&) {
                if (auto s = weak.lock())
                    ((*s).*method)();
            };
        };
        list.SelectionChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            int at = s->list.SelectedIndex();
            if (at < 0 || at >= (int)s->ids.size() || s->ids[(size_t)at] == s->id)
                return;
            s->Commit();
            s->id = s->ids[(size_t)at];
            s->FillForm();
        });
        add.Click([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
            {
                s->Commit();
                s->known = zs::Printers().Count();
                s->ui.ShowPicker(false);
            }
        });
        remove.Click(on(&PrefsPage::RemovePrinter));
        kind.SelectionChanged(on(&PrefsPage::KindChanged));
        // The list shows the new name while it is typed.
        name.TextChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            s->ShowRowName(Utf8(s->name.Text()));
        });
        auto clear = [weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s != nullptr && !s->filling)
                s->ClearInfo();
        };
        url.TextChanged(clear);
        serial.TextChanged(clear);
        key.PasswordChanged(clear);
        auto commit = on(&PrefsPage::Commit);
        name.LostFocus(commit);
        url.LostFocus(commit);
        serial.LostFocus(commit);
        key.LostFocus(commit);
        test.Click(on(&PrefsPage::Test));
        use.Click(on(&PrefsPage::UsePrinter));
        read.Click(on(&PrefsPage::ReadSerial));
        get_key.Click([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
            {
                s->Commit();
                s->ClearInfo();
                s->known = zs::Printers().Count();
                s->ui.ShowPair(s->id, false, [](bool) {});
            }
        });
        use_machine.Click([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
                s->Apply(1);
        });
        use_filament.Click([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
                s->Apply(2);
        });

        theme.SelectionChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            int at = s->theme.SelectedIndex();
            zs::Printers().SetPref("theme", at == 1 ? "light" : at == 2 ? "dark" : "system");
            s->ui.w.ApplyThemePref();
        });
        first_view.SelectionChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s != nullptr && !s->filling)
                zs::Printers().SetPref("view", s->first_view.SelectedIndex() == 1 ? "3d" : "2d");
        });
        threads.ValueChanged([weak](NumberBox const &, NumberBoxValueChangedEventArgs const &e) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            // An empty entry has no value.
            if (std::isnan(e.NewValue()))
            {
                s->filling = true;
                s->threads.Value(e.OldValue());
                s->filling = false;
                return;
            }
            std::string value = std::to_string((int)std::lround(e.NewValue()));
            if (value == s->ui.w.model->GetSetting("engine.threads") && value == zs::Printers().Pref("engine.threads"))
                return;
            zs::Printers().SetPref("engine.threads", value);
            std::string error;
            if (!s->ui.w.model->SetSetting("engine.threads", value, error))
                s->ui.w.ShowToast(zs::ToWide(error));
            s->ui.w.ApplyThreadsPref();
            s->ui.w.RefreshSettingValues();
        });
        open.Click([](auto &&, auto &&) {
            std::wstring dir = zs::StateDir();
            ::ShellExecuteW(nullptr, L"open", dir.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        });
        tab_printers.Click([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
                s->ShowTab(false);
        });
        tab_general.Click([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
                s->ShowTab(true);
        });
    }

    void MainWindow::PrintersUi::PrefsPage::Tint()
    {
        auto root = ui.w.Root();
        panel->card.Background(TokenBrush(root, L"ZsBg"));
        panel->card.BorderBrush(TokenBrush(root, L"ZsPopoverBorder"));
        if (result_error)
            result.Foreground(TokenBrush(root, L"ZsError"));
    }

    void MainWindow::PrintersUi::PrefsPage::ShowTab(bool general)
    {
        tab_printers.IsChecked(!general);
        tab_general.IsChecked(general);
        Show(printers_page, !general);
        Show(general_page, general);
    }

    void MainWindow::PrintersUi::PrefsPage::FillList()
    {
        bool was = filling;
        filling = true;
        list.Items().Clear();
        ids.clear();
        zs::PrinterStore &store = zs::Printers();
        std::string current = store.Current().id;
        int selected = -1;
        for (size_t i = 0; i < store.Count(); i++)
        {
            zs::SavedPrinter const &p = store.At(i);
            auto row = Markup::XamlReader::Load(list_row).as<Grid>();
            Get<TextBlock>(row, L"RowName").Text(zs::ToWide(p.name));
            bool unverified = p.kind == zs::LinkKind::OctoPrint || p.kind == zs::LinkKind::Moonraker || p.kind == zs::LinkKind::PrusaLink;
            Get<TextBlock>(row, L"RowKind").Text(zs::ToWide(zs::LinkTitle(p.kind)) + (unverified ? L" · not verified" : L""));
            Show(Get<FontIcon>(row, L"RowCurrent"), p.id == current);
            ListViewItem item;
            item.Content(row);
            item.HorizontalContentAlignment(HorizontalAlignment::Stretch);
            Name(item, zs::ToWide(p.name));
            list.Items().Append(item);
            ids.push_back(p.id);
            if (p.id == id)
                selected = (int)i;
        }
        list.SelectedIndex(selected);
        remove.IsEnabled(store.Count() > 1);
        filling = was;
    }

    void MainWindow::PrintersUi::PrefsPage::FillForm()
    {
        zs::SavedPrinter *p = Printer();
        if (p == nullptr)
            return;
        filling = true;
        ClearInfo();
        name.Text(zs::ToWide(p->name));
        kind.SelectedIndex((int)p->kind);
        url.Text(zs::ToWide(p->url));
        serial.Text(zs::ToWide(p->serial));
        key.Password(L"");
        ShowRows();
        filling = false;
    }

    void MainWindow::PrintersUi::PrefsPage::ShowRows()
    {
        zs::SavedPrinter *p = Printer();
        if (p == nullptr)
            return;
        zs::LinkKind k = p->kind;
        bool is_bambu = k == zs::LinkKind::Bambu, net = k != zs::LinkKind::None, keyed = UsesKey(k);
        wchar_t const *words = TrustWords(*p);
        trust.Text(words != nullptr ? words : L"");
        Show(trust, words != nullptr);
        Show(url_label, net);
        Show(url, net);
        Show(serial_label, is_bambu);
        Show(serial_box, is_bambu);
        Show(key_label, keyed);
        Show(key_box, keyed);
        Show(get_key, !is_bambu);
        key_box.ColumnSpacing(is_bambu ? 0 : 6);
        key_label.Text(is_bambu ? L"Access code" : L"API key");
        key.PlaceholderText(!p->api_key.empty() ? L"A key is saved" : is_bambu ? L"Access code" : L"API key");
        url.PlaceholderText(is_bambu ? L"The IP address of the printer, for example 192.168.1.50" : L"http://printdeck.local or http://192.168.1.20:5000");
        test.IsEnabled(net);
        Show(use, id != zs::Printers().Current().id);
    }

    // A panel over this page closed: the printers can be new.
    void MainWindow::PrintersUi::PrefsPage::Reload()
    {
        zs::PrinterStore &store = zs::Printers();
        if (Printer() == nullptr || store.Count() != known)
            id = store.Current().id;
        known = store.Count();
        FillList();
        FillForm();
        name.Focus(FocusState::Programmatic);
    }

    void MainWindow::PrintersUi::PrefsPage::SetResult(std::wstring const &text, bool error)
    {
        result_error = error;
        result.Text(text);
        if (error)
            result.Foreground(TokenBrush(ui.w.Root(), L"ZsError"));
        else
            result.ClearValue(TextBlock::ForegroundProperty());
    }

    void MainWindow::PrintersUi::PrefsPage::ClearInfo()
    {
        if (cancel != nullptr)
            cancel->Stop();
        cancel = nullptr;
        Retire(bambu);
        core = nullptr;
        SetResult(L"", false);
        Show(use_machine, false);
        Show(use_filament, false);
        zs::SavedPrinter *p = Printer();
        test.IsEnabled(p != nullptr && p->kind != zs::LinkKind::None);
        read.IsEnabled(true);
    }

    // Writes the entries to the printer. The list and the top bar follow.
    void MainWindow::PrintersUi::PrefsPage::Commit()
    {
        zs::SavedPrinter *p = Printer();
        if (p == nullptr || filling)
            return;
        zs::PrinterStore &store = zs::Printers();
        bool changed = false;
        std::string to = Utf8(name.Text());
        if (to.empty())
        {
            // A printer keeps a name.
            filling = true;
            name.Text(zs::ToWide(p->name));
            filling = false;
            ShowRowName(p->name);
        }
        else if (to != p->name)
        {
            p->name = to;
            // This write is direct: the panel can close with the window,
            // after the save timer stopped.
            if (p->id == store.Current().id)
            {
                zs_app_setting_set(ui.w.model->Active(), "machine.name", to.c_str());
                ui.setup.SaveState();
            }
            changed = true;
        }
        to = Utf8(url.Text());
        if (to != p->url)
        {
            p->url = to;
            changed = true;
        }
        to = Utf8(serial.Text());
        if (to != p->serial)
        {
            // The code file has the serial number in its name.
            std::string code = p->api_key;
            p->api_key.clear();
            store.Save();
            p->serial = to;
            p->api_key = code;
            zs::state::Wipe(code);
            changed = true;
        }
        std::string typed = Utf8(key.Password());
        if (!typed.empty())
        {
            p->api_key = typed;
            zs::state::Wipe(typed);
            filling = true;
            key.Password(L"");
            filling = false;
            changed = true;
        }
        if (!changed)
            return;
        store.Save();
        ui.RefreshBar();
        // The list stays: a click on one of its rows can be the reason for
        // this commit.
        ShowRowName(p->name);
        ShowRows();
    }

    void MainWindow::PrintersUi::PrefsPage::ShowRowName(std::string const &text)
    {
        auto at = std::find(ids.begin(), ids.end(), id);
        if (at == ids.end())
            return;
        auto index = (uint32_t)(at - ids.begin());
        if (index >= list.Items().Size())
            return;
        if (auto item = list.Items().GetAt(index).try_as<ListViewItem>())
        {
            Get<TextBlock>(item.Content().as<FrameworkElement>(), L"RowName").Text(zs::ToWide(text));
            Name(item, zs::ToWide(text));
        }
    }

    void MainWindow::PrintersUi::PrefsPage::KindChanged()
    {
        zs::SavedPrinter *p = Printer();
        int at = kind.SelectedIndex();
        if (filling || p == nullptr || at < 0 || (zs::LinkKind)at == p->kind)
            return;
        Commit();
        zs::LinkKind next = (zs::LinkKind)at;
        // An API key is no access code, and the other way round: a key does
        // not go to the other kind of device.
        if ((p->kind == zs::LinkKind::Bambu) != (next == zs::LinkKind::Bambu))
        {
            zs::state::Wipe(p->api_key);
            zs::Printers().Save();
        }
        p->kind = next;
        // Moonraker listens on 7125.
        if (next == zs::LinkKind::Moonraker && p->url.empty())
        {
            p->url = "http://";
            filling = true;
            url.Text(L"http://");
            filling = false;
        }
        zs::Printers().Save();
        ClearInfo();
        filling = true;
        FillList();
        ShowRows();
        filling = false;
        ui.RefreshBar();
    }

    void MainWindow::PrintersUi::PrefsPage::UsePrinter()
    {
        Commit();
        std::string message;
        if (!ui.setup.UsePrinter(id, message))
            ui.w.ShowError(zs::ToWide(message));
        ui.w.RefreshSettingValues();
        ui.w.ShowPlate();
        ui.RefreshBar();
        ui.RefreshTiles();
        filling = true;
        FillList();
        ShowRows();
        filling = false;
    }

    void MainWindow::PrintersUi::PrefsPage::RemovePrinter()
    {
        zs::PrinterStore &store = zs::Printers();
        if (Printer() == nullptr || store.Count() <= 1)
            return;
        ClearInfo();
        if (id == store.Current().id)
        {
            std::string next;
            for (size_t k = 0; k < store.Count() && next.empty(); k++)
                if (store.At(k).id != id)
                    next = store.At(k).id;
            std::string message;
            ui.setup.UsePrinter(next, message);
        }
        store.Remove(id);
        ui.w.RefreshSettingValues();
        ui.w.ShowPlate();
        ui.RefreshBar();
        ui.RebuildTiles();
        id = store.Current().id;
        known = store.Count();
        FillList();
        FillForm();
    }

    // ---- the test, and what the printer tells ----

    void MainWindow::PrintersUi::PrefsPage::Test()
    {
        Commit();
        zs::SavedPrinter *p = Printer();
        if (p == nullptr || p->kind == zs::LinkKind::None)
            return;
        ClearInfo();
        cancel = std::make_shared<zs::http::Cancel>();
        auto token = cancel;
        std::weak_ptr<PrefsPage> weak = weak_from_this();
        zs::link::Target target = zs::link::TargetOf(*p);
        SetResult(L"Connecting…", false);
        test.IsEnabled(false);
        if (p->kind == zs::LinkKind::Bambu)
        {
            // The first report over MQTT, then the link closes.
            char const *why = p->url.empty() ? "Set the IP address of the printer."
                              : p->serial.empty() ? "Set the serial number of the printer."
                              : p->api_key.empty() ? "Set the access code of the printer."
                                                   : nullptr;
            if (why != nullptr)
            {
                BambuDone(nullptr, why);
                return;
            }
            Poster post = ui.poster;
            std::string printer_id = p->id;
            bambu = std::make_shared<zs::BambuWatch>(
                target, p->serial,
                [post, weak, token](zs::link::Snapshot const &status) {
                    post.Post([weak, token, status](PrintersUi &) {
                        if (auto s = weak.lock(); s != nullptr && !token->Stopped())
                            s->BambuDone(&status, {});
                    });
                },
                [post, weak, token](std::string const &error) {
                    post.Post([weak, token, error](PrintersUi &) {
                        if (auto s = weak.lock(); s != nullptr && !token->Stopped())
                            s->BambuDone(nullptr, error);
                    });
                },
                [post, printer_id](std::string const &pin) {
                    post.Post([printer_id, pin](PrintersUi &) {
                        zs::SavedPrinter *saved = zs::Printers().Find(printer_id);
                        if (saved != nullptr && saved->kind == zs::LinkKind::Bambu && saved->tls_pin.empty())
                        {
                            saved->tls_pin = pin;
                            zs::Printers().Save();
                        }
                    });
                });
            return;
        }
        struct Reply
        {
            bool ok = false;
            zs::link::Snapshot status;
            std::string error;
        };
        ui.Async(
            [target, token] {
                Reply r;
                r.ok = zs::link::ReadStatus(target, token, r.status, r.error);
                return r;
            },
            [weak, token](PrintersUi &, Reply &r) {
                auto s = weak.lock();
                if (s == nullptr || token->Stopped())
                    return;
                s->test.IsEnabled(true);
                if (!r.ok)
                {
                    s->SetResult(L"No connection: " + zs::ToWide(r.error), true);
                    return;
                }
                s->ShowInfo(r.status);
            });
    }

    void MainWindow::PrintersUi::PrefsPage::BambuDone(zs::link::Snapshot const *status, std::string const &error)
    {
        if (cancel != nullptr)
            cancel->Stop();
        cancel = nullptr;
        Retire(bambu);
        test.IsEnabled(true);
        if (status == nullptr)
        {
            SetResult(error.empty() ? L"No answer." : zs::ToWide(error), true);
            return;
        }
        std::wstring text = L"Connected. The printer reports";
        if (!status->state.empty())
            text += L": " + zs::ToWide(status->state);
        if (!status->job.empty())
            text += L", " + zs::ToWide(status->job);
        SetResult(text + L".", false);
    }

    void MainWindow::PrintersUi::PrefsPage::ShowInfo(zs::link::Snapshot const &st)
    {
        core = st.core;
        zs_printer_info in{};
        bool has_info = st.core != nullptr && zs_printer_status_get(st.core.get(), &in) == ZS_OK;
        double max_accel = has_info ? in.max_accel : 0;
        std::wstring s = L"Connected";
        if (!st.state.empty())
            s += L": " + zs::ToWide(st.state);
        s += L".";
        if (st.bed_x > 0)
            s += Format(L"\nBed %.0f × %.0f × %.0f mm.", st.bed_x, st.bed_y, st.height);
        if (st.nozzle > 0)
            s += Format(L" Nozzle %.2f mm.", st.nozzle);
        if (max_accel > 0)
        {
            s += Format(L"\nMotion limits: %.0f mm/s, %.0f mm/s², corner %.0f mm/s", in.max_velocity, in.max_accel, in.corner_velocity);
            if (in.max_z_velocity > 0)
                s += Format(L", Z %.0f mm/s at %.0f mm/s²", in.max_z_velocity, in.max_z_accel);
            s += L".";
            // A note when zslice plans with other limits.
            double mine = atof(ui.w.model->GetSetting("machine.max_accel").c_str());
            if (mine > 0 && std::abs(mine - max_accel) > 1)
                s += Format(L" zslice plans with %.0f mm/s² now: \"Use the printer's bed, nozzle, and motion\" takes the printer's limits.", mine);
        }
        if (!st.material.empty() || !st.spool_name.empty())
        {
            s += L"\nFilament in the printer:";
            if (!st.spool_name.empty())
                s += L" " + zs::ToWide(st.spool_name);
            if (!st.material.empty())
                s += L" (" + zs::ToWide(st.material);
            if (st.diameter > 0)
                s += Format(L", %.2f mm", st.diameter);
            if (!st.material.empty())
                s += L")";
            if (st.spool_left > 0)
                s += Format(L", %.0f g left", st.spool_left);
            s += L".";
        }
        if (!st.rolls.empty())
        {
            s += L"\nSpools:";
            bool first = true;
            for (auto const &roll : st.rolls)
            {
                std::wstring roll_name = zs::ToWide(roll.name.empty() ? "?" : roll.name);
                s += (first ? L" " : L", ") + (roll.material.empty() ? roll_name : roll_name + L" (" + zs::ToWide(roll.material) + L")");
                first = false;
            }
            s += L".";
        }
        if (!st.job.empty())
        {
            s += L"\nPrinting " + zs::ToWide(st.job) + Format(L": %.0f %%", st.progress * 100);
            if (st.time_left > 0)
            {
                wchar_t left[32];
                swprintf_s(left, L", %d:%02d left", (int)st.time_left / 3600, (int)st.time_left / 60 % 60);
                s += left;
            }
            s += L".";
        }
        SetResult(s, false);
        bool current = id == zs::Printers().Current().id;
        Show(use_machine, current && (st.bed_x > 0 || st.nozzle > 0 || max_accel > 0));
        Show(use_filament, current && (!st.material.empty() || st.diameter > 0));
    }

    // The rules of both buttons are in the core (zs_app_apply_printer_status).
    void MainWindow::PrintersUi::PrefsPage::Apply(int what)
    {
        if (core == nullptr || zs_app_apply_printer_status(ui.w.model->Active(), core.get(), what) != ZS_OK)
            return;
        ui.w.model->RequestSlice();
        ui.w.NoteChange();
        ui.w.RefreshSettingValues();
        if ((what & 1) != 0)
            ui.w.ShowPlate();
        ui.RefreshBar();
        Show(what == 1 ? use_machine : use_filament, false);
    }

    // "Read": the serial number from the certificate of the printer.
    void MainWindow::PrintersUi::PrefsPage::ReadSerial()
    {
        Commit();
        zs::SavedPrinter *p = Printer();
        if (p == nullptr || p->url.empty())
        {
            SetResult(L"Set the IP address of the printer first.", false);
            return;
        }
        read.IsEnabled(false);
        std::string address = p->url, printer_id = p->id;
        std::weak_ptr<PrefsPage> weak = weak_from_this();
        struct Reply
        {
            bool ok = false;
            std::string serial, pin, error;
        };
        ui.Async(
            [address] {
                Reply r;
                r.ok = zs::ReadBambuSerial(address, r.serial, r.pin, r.error);
                return r;
            },
            [weak, printer_id](PrintersUi &, Reply &r) {
                auto s = weak.lock();
                if (s == nullptr)
                    return;
                s->read.IsEnabled(true);
                if (!r.ok)
                {
                    s->SetResult(L"The serial number did not read (" + (r.error.empty() ? std::wstring(L"no reason") : zs::ToWide(r.error)) + L").", true);
                    return;
                }
                if (s->id != printer_id)
                    return;
                s->serial.Text(zs::ToWide(r.serial));
                s->Commit();
                // The user trusts the certificate of this printer now.
                zs::SavedPrinter *saved = s->Printer();
                if (saved != nullptr && saved->kind == zs::LinkKind::Bambu && !r.pin.empty())
                {
                    saved->tls_pin = r.pin;
                    zs::Printers().Save();
                }
            });
    }

    // ---- the panel ----

    void MainWindow::PrintersUi::ShowPreferences()
    {
        if (prefs != nullptr)
        {
            prefs->name.Focus(FocusState::Programmatic);
            return;
        }
        auto page = std::make_shared<PrefsPage>(*this);
        page->id = zs::Printers().Current().id;
        page->known = zs::Printers().Count();
        std::wstring text = std::wstring(page_head) + page_printers + page_general;
        auto body = Markup::XamlReader::Load(text).as<FrameworkElement>();
        page->Build(body);
        page->panel = OpenPanel(L"", 820, 560, body);
        Name(page->panel->card, L"Preferences");

        // The header has the two pages, as the header bar of the GTK window.
        auto head = page->panel->card.Child().as<Grid>().Children().GetAt(0).as<Grid>();
        StackPanel tabs = Row(0);
        tabs.HorizontalAlignment(HorizontalAlignment::Center);
        auto tab = [&](wchar_t const *title, CornerRadius corners) {
            Primitives::ToggleButton b;
            b.Content(box_value(title));
            b.MinHeight(30);
            b.Padding(ThicknessHelper::FromLengths(16, 4, 16, 4));
            b.CornerRadius(corners);
            tabs.Children().Append(b);
            return b;
        };
        page->tab_printers = tab(L"Printers", CornerRadius{ 6, 0, 0, 6 });
        page->tab_general = tab(L"General", CornerRadius{ 0, 6, 6, 0 });
        head.Children().InsertAt(1, tabs);

        prefs = page;
        page->Tint();
        page->filling = true;
        page->FillList();
        page->filling = false;
        page->FillForm();
        page->ShowTab(false);
        page->Wire();
        page->panel->closed = [this, page] {
            page->Commit();
            page->ClearInfo();
            prefs = nullptr;
        };
        page->name.Focus(FocusState::Programmatic);
    }

    void MainWindow::PrintersUi::PreferencesPanelClosed(std::shared_ptr<OverlayPanel> const &panel)
    {
        if (prefs != nullptr && prefs->panel != panel)
            prefs->Reload();
    }

    // The Printers page and the panel have brushes from the code.
    void MainWindow::PrintersUi::PreferencesThemeChanged()
    {
        if (page != nullptr)
        {
            bool shown = page.Visibility() == Visibility::Visible;
            page_timer.Stop();
            StopTiles();
            auto children = w.Root().Children();
            uint32_t at = 0;
            bool found = children.IndexOf(page, at);
            if (found)
                children.RemoveAt(at);
            BuildPage();
            // The new page goes at the place of the old one, under the
            // panels.
            if (found)
            {
                children.RemoveAtEnd();
                children.InsertAt(at, page);
            }
            if (shown)
                ShowPage(true);
        }
        if (prefs != nullptr)
            prefs->Tint();
    }

    void MainWindow::ShowPreferences()
    {
        if (printers != nullptr)
            printers->ShowPreferences();
    }

    bool MainWindow::PreferencesOpen()
    {
        return printers != nullptr && printers->prefs != nullptr;
    }

    void MainWindow::WirePreferences()
    {
        // Also from a text field, as in the GTK app.
        Input::KeyboardAccelerator keys;
        keys.Modifiers(Windows::System::VirtualKeyModifiers::Control);
        keys.Key(static_cast<VirtualKey>(188)); // the comma key
        keys.Invoked([this](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
            ShowPreferences();
            e.Handled(true);
        });
        Root().KeyboardAccelerators().Append(keys);
        Root().KeyboardAcceleratorPlacementMode(Input::KeyboardAcceleratorPlacementMode::Hidden);
    }

    void MainWindow::ApplyThemePref()
    {
        std::string choice = zs::Printers().Pref("theme", "system");
        ElementTheme next = choice == "light" ? ElementTheme::Light : choice == "dark" ? ElementTheme::Dark : ElementTheme::Default;
        ui::SetPreferenceTheme(next);
        Root().RequestedTheme(next);
        BOOL dark = Root().ActualTheme() == ElementTheme::Dark;
        ::DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark);
    }

    void MainWindow::PreferencesThemeChanged()
    {
        BOOL dark = Root().ActualTheme() == ElementTheme::Dark;
        ::DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark);
        if (printers != nullptr)
            printers->PreferencesThemeChanged();
    }

    // A dialog is outside the root element, so it gets the theme here. With
    // RequestedTheme alone its background stays in the system theme, so it
    // also gets the token of the chosen theme.
    void MainWindow::ThemeDialog(ContentDialog const &dialog)
    {
        ElementTheme theme = Root().RequestedTheme();
        if (theme == ElementTheme::Default)
            return;
        dialog.RequestedTheme(theme);
        dialog.Background(TokenBrush(Root(), L"ZsBg"));
        dialog.BorderBrush(TokenBrush(Root(), L"ZsPopoverBorder"));
    }

    void MainWindow::ApplyFirstViewPref()
    {
        if (zs::Printers().Pref("view", "3d") == "2d")
            Set2D(true);
    }

    // Gives the thread count of Preferences to each plate. A plate that
    // waits for a slice or slices gets it at its next status. The active
    // plate is on this thread, so it gets it at once.
    void MainWindow::ApplyThreadsPref(bool idle)
    {
        if (model == nullptr)
            return;
        std::string want = zs::Printers().Pref("engine.threads");
        if (want.empty())
            return;
        zs_set *set = model->Set();
        size_t active = zs_set_active(set);
        for (size_t i = 0; i < zs_set_count(set); i++)
        {
            zs_app *app = zs_set_app(set, i);
            if (app == nullptr)
                continue;
            zs_plate_info info{};
            if (!idle && i != active &&
                (zs_set_plate_info(set, i, &info) != ZS_OK || info.status == ZS_PLATE_STATUS_STALE || info.status == ZS_PLATE_STATUS_SLICING))
                continue;
            char now[32] = "";
            size_t len = 0;
            if (zs_app_setting_get(app, "engine.threads", now, sizeof now, &len) == ZS_OK && want == now)
                continue;
            zs_app_setting_set(app, "engine.threads", want.c_str());
        }
    }

#ifdef ZS_DEV_HOOKS
    bool MainWindow::RunPreferencesStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        namespace Peers = Microsoft::UI::Xaml::Automation::Peers;
        namespace Provider = Microsoft::UI::Xaml::Automation::Provider;
        if (verb.rfind(L"pref", 0) != 0)
            return false;
        auto page = printers != nullptr ? printers->prefs : nullptr;
        double number = words.empty() ? 0 : _wtof(words[0].c_str());
        if (verb == L"prefmenu")
        {
            MainMenu().ShowAt(MainMenuButton());
            std::string names;
            for (auto const &item : MainMenu().Items())
                if (auto text = item.try_as<MenuFlyoutItem>())
                    names += zs::ToUtf8(std::wstring(text.Text())) + " | ";
            zs::Log("dev: main menu: %s\n", names.c_str());
        }
        else if (verb == L"prefmenurun")
        {
            for (auto const &item : MainMenu().Items())
                if (auto text = item.try_as<MenuFlyoutItem>(); text != nullptr && text.Text() == L"Preferences")
                {
                    zs::Log("dev: menu keys '%s'\n", zs::ToUtf8(std::wstring(text.KeyboardAcceleratorTextOverride())).c_str());
                    Peers::MenuFlyoutItemAutomationPeer(text).as<Provider::IInvokeProvider>().Invoke();
                }
        }
        else if (verb == L"prefopen")
            ShowPreferences();
        else if (verb == L"prefdialog")
            ShowShortcuts();
        else if (verb == L"prefpopups")
        {
            // The theme that each open popup resolves to (1 light, 2 dark).
            auto open = Media::VisualTreeHelper::GetOpenPopupsForXamlRoot(Content().XamlRoot());
            zs::Log("dev: prefs popups %u, root theme %d\n", open.Size(), (int)Root().ActualTheme());
            for (auto const &popup : open)
                if (auto child = popup.Child().try_as<FrameworkElement>())
                    zs::Log("dev: prefs popup theme %d, %.0fx%.0f\n", (int)child.ActualTheme(), child.ActualWidth(), child.ActualHeight());
        }
        else if (verb == L"preflist" && words.size() >= 2)
        {
            // preflist NAME i: selects row i of the list with this
            // automation name, in any panel ('_' is a space).
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            std::function<bool(DependencyObject const &)> walk = [&](DependencyObject const &at) {
                if (auto selector = at.try_as<Primitives::Selector>();
                    selector != nullptr && std::wstring(Automation::AutomationProperties::GetName(selector)) == want)
                {
                    selector.SelectedIndex(_wtoi(words[1].c_str()));
                    return true;
                }
                // The last child is on top: the newest panel comes first.
                for (int k = Media::VisualTreeHelper::GetChildrenCount(at) - 1; k >= 0; k--)
                    if (walk(Media::VisualTreeHelper::GetChild(at, k)))
                        return true;
                return false;
            };
            zs::Log("dev: list %s %s\n", zs::ToUtf8(want).c_str(), walk(Content()) ? "set" : "not found");
        }
        else if (page == nullptr)
            zs::Log("dev: Preferences are closed\n");
        else if (verb == L"prefclose")
            printers->ClosePanel(page->panel);
        else if (verb == L"prefpage")
            page->ShowTab(!words.empty() && words[0] == L"general");
        else if (verb == L"prefpick")
            page->list.SelectedIndex((int)number);
        else if (verb == L"prefkind")
            page->kind.SelectedIndex((int)number);
        else if (verb == L"preftheme")
            page->theme.SelectedIndex((int)number);
        else if (verb == L"prefview")
            page->first_view.SelectedIndex((int)number);
        else if (verb == L"prefthreads")
            page->threads.Value(number);
        else if (verb == L"prefset" && words.size() >= 2)
        {
            std::wstring value = words[1];
            std::replace(value.begin(), value.end(), L'_', L' ');
            if (words[0] == L"name")
                page->name.Text(value);
            else if (words[0] == L"url")
                page->url.Text(value);
            else if (words[0] == L"serial")
                page->serial.Text(value);
            else if (words[0] == L"key")
                page->key.Password(value);
            page->Commit();
        }
        else if (verb != L"preflog")
            return false;
        zs::PrinterStore &store = zs::Printers();
        zs::Log("dev: prefs open %d | theme '%s' requested %d actual %d | view '%s' 2d %d | threads pref '%s' plate '%s' | history pending %d | %zu printers, current '%s'\n",
                PreferencesOpen() ? 1 : 0, store.Pref("theme", "system").c_str(), (int)Root().RequestedTheme(), (int)Root().ActualTheme(),
                store.Pref("view", "3d").c_str(), show_2d ? 1 : 0, store.Pref("engine.threads").c_str(), model->GetSetting("engine.threads").c_str(),
                zs_app_history_pending(model->Active()), store.Count(), store.Current().name.c_str());
        if (auto now = printers != nullptr ? printers->prefs : nullptr)
        {
            zs::SavedPrinter *p = now->Printer();
            zs::Log("dev: prefs form '%s' kind %d url '%s' serial '%s' has key %d | rows %u | general %d | url %d serial %d key %d getkey %d use %d test %d | label '%s' | trust %zu chars | result '%s'\n",
                    p != nullptr ? p->name.c_str() : "", p != nullptr ? (int)p->kind : -1, p != nullptr ? p->url.c_str() : "", p != nullptr ? p->serial.c_str() : "",
                    p != nullptr && !p->api_key.empty() ? 1 : 0, now->list.Items().Size(), now->general_page.Visibility() == Visibility::Visible ? 1 : 0,
                    now->url.Visibility() == Visibility::Visible ? 1 : 0, now->serial_box.Visibility() == Visibility::Visible ? 1 : 0,
                    now->key_box.Visibility() == Visibility::Visible ? 1 : 0, now->get_key.Visibility() == Visibility::Visible ? 1 : 0,
                    now->use.Visibility() == Visibility::Visible ? 1 : 0, now->test.IsEnabled() ? 1 : 0, zs::ToUtf8(std::wstring(now->key_label.Text())).c_str(),
                    (size_t)now->trust.Text().size(), zs::ToUtf8(std::wstring(now->result.Text())).c_str());
        }
        return true;
    }
#endif
}
