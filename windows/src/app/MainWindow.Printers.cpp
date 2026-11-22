// The setup group of the top bar (printer, filament, quality), the panels
// over the window, and the pairing with a printer or a printdeck.
//
// See MainWindow.Printers.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.Printers.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Media = Microsoft::UI::Xaml::Media;
namespace Automation = Microsoft::UI::Xaml::Automation;
using Windows::System::VirtualKey;

namespace winrt::ZSlice::implementation
{
    void FillNozzleChoices(Microsoft::UI::Xaml::Controls::ComboBox const &box, int nozzles, int current);
    int NozzleChoice(Microsoft::UI::Xaml::Controls::ComboBox const &box);

    namespace ui
    {
        Media::Brush ThemeBrush(wchar_t const *key)
        {
            // The theme of Preferences can differ from the theme of the app.
            if (auto brush = PreferenceBrush(key))
                return brush;
            return Application::Current().Resources().Lookup(box_value(key)).as<Media::Brush>();
        }

        TextBlock Label(std::wstring const &text, double size, bool bold, bool dim)
        {
            TextBlock t;
            t.Text(text);
            t.FontSize(size);
            t.TextWrapping(TextWrapping::Wrap);
            if (bold)
                t.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
            if (dim)
                t.Foreground(ThemeBrush(L"TextFillColorSecondaryBrush"));
            return t;
        }

        Button TextButton(std::wstring const &text, bool accent)
        {
            Button b;
            b.Content(box_value(text));
            if (accent)
                b.Style(Application::Current().Resources().Lookup(box_value(L"AccentButtonStyle")).as<Style>());
            return b;
        }

        StackPanel Row(double spacing)
        {
            StackPanel p;
            p.Orientation(Orientation::Horizontal);
            p.Spacing(spacing);
            return p;
        }

        StackPanel Column(double spacing)
        {
            StackPanel p;
            p.Spacing(spacing);
            return p;
        }

        Media::SolidColorBrush ColorBrush(std::string const &hex)
        {
            if (hex.size() != 7 || hex[0] != '#')
                return nullptr;
            unsigned v = 0;
            if (sscanf_s(hex.c_str() + 1, "%x", &v) != 1)
                return nullptr;
            return Media::SolidColorBrush(Windows::UI::Color{ 255, (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v });
        }

        void Name(UIElement const &element, std::wstring const &name)
        {
            Automation::AutomationProperties::SetName(element, name);
        }
    }

    using namespace ui;

    MainWindow::PrintersUi::PrintersUi(MainWindow &window) : w(window), setup(*window.model)
    {
        poster.weak = window.get_weak();
        poster.queue = window.queue;
    }

    // The controls need the model, so EnsureView calls this after its start.
    void MainWindow::WirePrinters()
    {
        if (printers != nullptr || model == nullptr)
            return;
        printers = std::make_shared<PrintersUi>(*this);
        printers->Start();
    }

    void MainWindow::ClosePrinters()
    {
        if (printers == nullptr)
            return;
        printers->Close();
        printers = nullptr;
    }

    void MainWindow::PrintersOnSliced()
    {
        if (printers != nullptr)
            printers->OnSliced();
    }

    void MainWindow::PrintersOnFailed()
    {
        if (printers != nullptr)
            printers->OnFailed();
    }

    void MainWindow::PrintersNoteChange()
    {
        if (printers != nullptr)
            printers->AfterSettings();
    }

    // Another plate has its own filament and quality.
    void MainWindow::PrintersOnPlate()
    {
        if (printers != nullptr)
            printers->RefreshBar();
    }

    void MainWindow::PrintersUi::Start()
    {
        setup.Start();
        w.RestoreSearchPlace();
        started = true;
        BuildTopBar();
        BuildPage();
        save_timer = w.queue.CreateTimer();
        save_timer.IsRepeating(false);
        save_timer.Interval(std::chrono::milliseconds(800));
        save_timer.Tick([this](auto &&, auto &&) {
            setup.SaveState();
            RefreshBar();
        });
        RefreshBar();
        w.RefreshSettingValues();
        // ZSLICE_PRINTER starts on a library printer, for tests.
        wchar_t hook[8];
        bool hooked = ::GetEnvironmentVariableW(L"ZSLICE_PRINTER", hook, ARRAYSIZE(hook)) > 0;
        if (hooked)
            zs::Printers().SetFirstStart(false);
        if (zs::Printers().FirstStart())
            ShowPicker(true);
        StartPlatesHook();
    }

    void MainWindow::PrintersUi::Close()
    {
        save_timer.Stop();
        if (plates_timer != nullptr)
            plates_timer.Stop();
        setup.SaveState();
        if (send_cancel != nullptr)
            send_cancel->Stop();
        StopTiles();
        if (page_timer != nullptr)
            page_timer.Stop();
        for (auto const &panel : panels)
        {
            // Moved out first: a handler can hold its own panel.
            auto closed = std::move(panel->closed);
            panel->closed = nullptr;
            if (closed)
                closed();
        }
        panels.clear();
    }

    // A setting changed: the files follow it soon.
    void MainWindow::PrintersUi::AfterSettings()
    {
        save_timer.Stop();
        save_timer.Start();
    }

    void MainWindow::PrintersUi::Note(std::wstring const &text)
    {
        w.ShowToast(text);
    }

    void MainWindow::PrintersUi::SavePin(zs::link::Target const &target)
    {
        if (!target.pin_changed)
            return;
        if (zs::SavedPrinter *p = zs::Printers().Find(target.id))
        {
            p->tls_pin = target.tls_pin;
            p->tls_since = target.tls_since;
            zs::Printers().Save();
        }
    }

    // ---- the top bar ----

    void MainWindow::PrintersUi::BuildTopBar()
    {
        // The setup group of the header: three parts with a line between.
        StackPanel group = w.SetupRow();
        auto resources = Application::Current().Resources();
        auto menu_button = [&](wchar_t const *name, wchar_t const *tip) {
            Button b;
            b.Style(resources.Lookup(box_value(group.Children().Size() > 0 ? L"ZsSetupPartNext" : L"ZsSetupPart")).as<Microsoft::UI::Xaml::Style>());
            b.Content(box_value(name));
            b.MaxWidth(190);
            Name(b, name);
            ToolTipService::SetToolTip(b, box_value(tip));
            group.Children().Append(b);
            return b;
        };
        printer_button = menu_button(L"Printer", L"The printer");
        filament_button = menu_button(L"Filament", L"The filament");
        quality_button = menu_button(L"Quality", L"The quality");
        // The arrow beside the main button of the bottom bar.
        send_button = w.SendMenuButton();

        printer_menu = MenuFlyout();
        printer_menu.Placement(Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        printer_menu.Opening([this](auto &&, auto &&) { FillPrinterMenu(); });
        printer_button.Flyout(printer_menu);

        send_menu = MenuFlyout();
        send_menu.Placement(Primitives::FlyoutPlacementMode::TopEdgeAlignedRight);
        send_menu.Opening([this](auto &&, auto &&) { FillSendMenu(); });
        send_button.Flyout(send_menu);

        auto panel_flyout = [&](StackPanel &panel) {
            Flyout fly;
            ScrollViewer scroll;
            scroll.MaxHeight(560);
            scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
            panel = Column(4);
            panel.MinWidth(320);
            panel.MaxWidth(440);
            panel.Padding(ThicknessHelper::FromLengths(0, 0, 14, 0));
            scroll.Content(panel);
            fly.Content(scroll);
            fly.Placement(Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
            return fly;
        };
        filament_flyout = panel_flyout(filament_panel);
        filament_flyout.Opening([this](auto &&, auto &&) { FillFilament(); });
        filament_button.Flyout(filament_flyout);
        quality_flyout = panel_flyout(quality_panel);
        quality_flyout.Opening([this](auto &&, auto &&) { FillQuality(); });
        quality_button.Flyout(quality_flyout);

        page_button = Primitives::ToggleButton();
        page_button.Width(34);
        page_button.Height(32);
        page_button.Padding(ThicknessHelper::FromUniformLength(0));
        page_button.CornerRadius(CornerRadiusHelper::FromUniformRadius(6));
        page_button.Content(Markup::XamlReader::Load(L"<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='16' Height='16' Stroke='{ThemeResource ZsFg}' StrokeThickness='1.3' StrokeLineJoin='Round' Data='M4.5 6V2.5h7V6M4.5 11.5h-2v-5.5h11v5.5h-2M4.5 9.5h7v4h-7z'/>"));
        Name(page_button, L"Printers");
        ToolTipService::SetToolTip(page_button, box_value(L"Printers: your printers, their jobs, and the plates to print"));
        page_button.Click([this](auto &&, auto &&) { ShowPage(page_button.IsChecked().GetBoolean()); });
        w.PrintersHost().Children().Append(page_button);
    }

    // The main button of the bottom bar. A printer that takes files gets an
    // upload. This app never starts a print.
    void MainWindow::PrintersUi::RefreshPrimary()
    {
        zs::SavedPrinter const &printer = zs::Printers().Current();
        bool can_send = printer.kind != zs::LinkKind::None && printer.kind != zs::LinkKind::Bambu;
        w.ExportButton().Content(box_value(sending ? std::wstring(L"Sending…") : can_send ? L"Upload to " + zs::ToWide(printer.name) : std::wstring(L"Export G-code…")));
        if (sending)
            w.ExportButton().IsEnabled(false);
        // The arrow has the other ways to send, for a printer that takes files.
        w.SendMenuButton().Visibility(can_send ? Visibility::Visible : Visibility::Collapsed);
        w.SendMenuButton().IsEnabled(zs_app_state(w.model->Active()) == ZS_STATE_DONE && !w.model->IsDraft() && !sending);
        w.ExportButton().CornerRadius(can_send ? CornerRadius{ 6, 0, 0, 6 } : CornerRadiusHelper::FromUniformRadius(6));
    }

    void MainWindow::PrintersUi::PrimaryAction()
    {
        zs::SavedPrinter const &printer = zs::Printers().Current();
        if (printer.kind != zs::LinkKind::None && printer.kind != zs::LinkKind::Bambu)
            SendPlate(printer.id, (size_t)-1);
        else
            ExportGcode();
    }

    void MainWindow::PrintersUi::RefreshBar()
    {
        if (printer_button == nullptr)
            return;
        std::wstring printer = zs::ToWide(zs::Printers().Current().name);
        printer_button.Content(box_value(printer));
        Name(printer_button, L"Printer: " + printer);

        zs_app *app = w.model->Active();
        size_t n = zs_app_filament_count(app);
        std::wstring filament;
        if (n > 1)
            filament = std::to_wstring(n) + L" filaments";
        else
        {
            filament = zs::ToWide(w.model->GetSetting("filament.name"));
            if (filament.empty())
                filament = L"Filament";
        }
        filament_button.Content(box_value(filament));
        Name(filament_button, L"Filament: " + filament);

        std::wstring quality = zs::ToWide(setup.QualityLabel());
        // The group shows the name alone, as in the other apps.
        if (quality.rfind(L"Quality: ", 0) == 0)
            quality = quality.substr(9);
        quality_button.Content(box_value(quality));
        Name(quality_button, quality);
    }

    void MainWindow::PrintersUi::FillPrinterMenu()
    {
        printer_menu.Items().Clear();
        zs::PrinterStore &store = zs::Printers();
        std::string current = store.Current().id;
        for (size_t i = 0; i < store.Count(); i++)
        {
            std::string id = store.At(i).id;
            ToggleMenuFlyoutItem item;
            item.Text(zs::ToWide(store.At(i).name));
            item.IsChecked(id == current);
            item.Click([this, id](auto &&, auto &&) {
                std::string message;
                if (!setup.UsePrinter(id, message))
                    w.ShowError(zs::ToWide(message));
                w.RefreshSettingValues();
                w.ShowPlate();
                RefreshBar();
                RefreshTiles();
            });
            printer_menu.Items().Append(item);
        }
        printer_menu.Items().Append(MenuFlyoutSeparator());
        auto add = [&](wchar_t const *text, std::function<void()> run) {
            MenuFlyoutItem item;
            item.Text(text);
            item.Click([run](auto &&, auto &&) { run(); });
            printer_menu.Items().Append(item);
        };
        add(L"Printer settings and G-code…", [this] {
            w.ShowSettingsPane(true);
            w.ShowDetail("machine.start_gcode");
        });
        add(L"Manage printers…", [this] { ShowManage(); });
        add(L"Connect a printdeck…", [this] { ShowConnectDeck(); });
        add(L"Import a profile…", [this] { w.PickProfile(); });
        ToolTipService::SetToolTip(printer_menu.Items().GetAt(printer_menu.Items().Size() - 1).as<DependencyObject>(),
                                   box_value(L"Read the settings of a PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura profile."));
        add(L"Add a printer…", [this] { ShowPicker(false); });
    }

    void MainWindow::PrintersUi::FillQuality()
    {
        quality_panel.Children().Clear();
        char const *now = zs_app_quality_name(w.model->Active());
        std::string current = now != nullptr ? now : "";
        auto add = [&](std::string const &name, std::string const &detail) {
            Button b;
            b.HorizontalAlignment(HorizontalAlignment::Stretch);
            b.HorizontalContentAlignment(HorizontalAlignment::Left);
            b.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            b.BorderThickness(ThicknessHelper::FromUniformLength(0));
            StackPanel text = Column(0);
            std::wstring title = zs::ToWide(zs::PrinterSetup::QualityTitle(name));
            text.Children().Append(Label((name == current ? L"✓ " : L"") + title, 13, name == current));
            if (!detail.empty())
                text.Children().Append(Label(zs::ToWide(detail), 11, false, true));
            b.Content(text);
            Name(b, title);
            b.Click([this, name](auto &&, auto &&) {
                quality_flyout.Hide();
                std::string message;
                if (!setup.SetQuality(name, true, message))
                    w.ShowError(zs::ToWide(message));
                w.RefreshSettingValues();
                RefreshBar();
            });
            quality_panel.Children().Append(b);
        };
        auto mine = setup.UserProfiles(ZS_GROUP_PROJECT);
        if (!mine.empty())
        {
            quality_panel.Children().Append(Label(L"Your profiles", 12, true, true));
            for (auto const &name : mine)
                add(name, {});
        }
        quality_panel.Children().Append(Label(L"Built-in", 12, true, true));
        for (size_t i = 0; i < zs_builtin_profile_count(ZS_GROUP_PROJECT); i++)
        {
            std::string name = zs_builtin_profile_name(ZS_GROUP_PROJECT, i);
            add(name, zs::PrinterSetup::QualitySummary(name));
        }
        Button save = TextButton(L"Save as profile…");
        save.HorizontalAlignment(HorizontalAlignment::Stretch);
        save.Click([this](auto &&, auto &&) {
            quality_flyout.Hide();
            AskProfileName(ZS_GROUP_PROJECT);
        });
        quality_panel.Children().Append(save);
        Button import_button = TextButton(L"Import a profile…");
        import_button.HorizontalAlignment(HorizontalAlignment::Stretch);
        ToolTipService::SetToolTip(import_button, box_value(L"Read the settings of a PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura profile."));
        import_button.Click([this](auto &&, auto &&) {
            quality_flyout.Hide();
            w.PickProfile();
        });
        quality_panel.Children().Append(import_button);
    }

    void MainWindow::PrintersUi::AskProfileName(int group)
    {
        StackPanel body = Column(10);
        body.Padding(ThicknessHelper::FromUniformLength(16));
        body.Children().Append(Label(L"The name of the profile:"));
        TextBox name;
        name.Text(zs::ToWide(setup.GroupProfile(group)));
        Name(name, L"The name of the profile");
        body.Children().Append(name);
        TextBlock error = Label(L"", 12);
        body.Children().Append(error);
        StackPanel buttons = Row();
        buttons.HorizontalAlignment(HorizontalAlignment::Right);
        Button cancel = TextButton(L"Cancel");
        Button ok = TextButton(L"Save", true);
        buttons.Children().Append(cancel);
        buttons.Children().Append(ok);
        body.Children().Append(buttons);
        wchar_t const *titles[] = { L"Save the printer settings", L"Save the filament settings", L"Save the quality settings" };
        auto panel = OpenPanel(titles[group], 380, 0, body);
        cancel.Click([this, panel](auto &&, auto &&) { ClosePanel(panel); });
        ok.Click([this, panel, name, error, group](auto &&, auto &&) {
            std::string message;
            if (!setup.SaveProfile(group, zs::ToUtf8(std::wstring(name.Text())), message))
            {
                error.Text(zs::ToWide(message));
                return;
            }
            ClosePanel(panel);
            w.RefreshSettingValues();
            RefreshBar();
        });
    }

    void MainWindow::PrintersUi::FillFilament()
    {
        filament_panel.Children().Clear();
        zs_app *app = w.model->Active();
        size_t n = zs_app_filament_count(app);
        double grams[16]{};
        uint32_t changes = 0;
        double flush = 0;
        bool has_grams = zs_app_filament_stats(app, grams, 16, &changes, &flush) == ZS_OK;
        std::wstring head = n > 1 ? std::to_wstring(n) + L" filaments" : L"Filament";
        if (has_grams && changes > 0)
        {
            head += L" · " + std::to_wstring(changes) + (changes == 1 ? L" change" : L" changes");
            if (flush > 0.05)
            {
                wchar_t text[32];
                swprintf_s(text, L" · flush %.1f g", flush);
                head += text;
            }
        }
        filament_panel.Children().Append(Label(head, 13, true));

        auto changed = [this] {
            w.model->RequestSlice();
            w.RefreshSettingValues();
            AfterSettings();
            RefreshBar();
        };
        auto read = [app](size_t i, char const *name) {
            char value[128] = "";
            size_t len = 0;
            if (zs_app_filament_get(app, i, name, value, sizeof value, &len) != ZS_OK)
                value[0] = 0;
            return std::string(value);
        };
        int nozzles = setup.NozzleCount();
        for (size_t i = 0; i < n; i++)
        {
            StackPanel row = Row(6);
            std::string color = read(i, "filament.color");
            Button swatch;
            swatch.Width(28);
            swatch.Height(28);
            swatch.Padding(ThicknessHelper::FromUniformLength(0));
            if (auto brush = ColorBrush(color); brush != nullptr)
                swatch.Background(brush);
            std::wstring swatch_name = L"The color of filament " + std::to_wstring(i + 1);
            Name(swatch, swatch_name);
            ToolTipService::SetToolTip(swatch, box_value(swatch_name));
            Flyout pick;
            ColorPicker picker;
            picker.IsAlphaEnabled(false);
            if (auto brush = ColorBrush(color); brush != nullptr)
                picker.Color(brush.Color());
            picker.ColorChanged([this, app, i, swatch, changed](ColorPicker const &, ColorChangedEventArgs const &e) {
                auto c = e.NewColor();
                char hex[8];
                snprintf(hex, sizeof hex, "#%02x%02x%02x", c.R, c.G, c.B);
                if (zs_app_filament_set(app, i, "filament.color", hex) == ZS_OK)
                {
                    swatch.Background(Media::SolidColorBrush(c));
                    changed();
                }
            });
            pick.Content(picker);
            swatch.Flyout(pick);
            row.Children().Append(swatch);
            TextBlock number = Label(std::to_wstring(i + 1));
            number.VerticalAlignment(VerticalAlignment::Center);
            row.Children().Append(number);

            ComboBox material;
            material.MinWidth(96);
            Name(material, L"The material of filament " + std::to_wstring(i + 1));
            std::string now = read(i, "filament.material");
            if (now.empty())
                now = "PLA";
            std::vector<std::string> list{ "PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA" };
            if (std::find(list.begin(), list.end(), now) == list.end())
                list.insert(list.begin(), now);
            for (auto const &m : list)
                material.Items().Append(box_value(zs::ToWide(m)));
            material.SelectedIndex((int)(std::find(list.begin(), list.end(), now) - list.begin()));
            material.SelectionChanged([app, i, list, changed](IInspectable const &sender, auto &&) {
                int at = sender.as<ComboBox>().SelectedIndex();
                if (at >= 0 && zs_app_filament_set(app, i, "filament.material", list[(size_t)at].c_str()) == ZS_OK)
                    changed();
            });
            row.Children().Append(material);

            if (nozzles >= 2)
            {
                ComboBox nozzle;
                Name(nozzle, L"The nozzle of filament " + std::to_wstring(i + 1));
                FillNozzleChoices(nozzle, nozzles, std::max(0, atoi(read(i, "filament.nozzle").c_str())));
                nozzle.SelectionChanged([app, i, changed](IInspectable const &sender, auto &&) {
                    int want = NozzleChoice(sender.as<ComboBox>());
                    if (want >= 0 && zs_app_filament_set(app, i, "filament.nozzle", std::to_string(want).c_str()) == ZS_OK)
                        changed();
                });
                row.Children().Append(nozzle);
            }
            if (has_grams && i < 16 && grams[i] > 0)
            {
                wchar_t text[32];
                swprintf_s(text, L"%.1f g", grams[i]);
                TextBlock g = Label(text, 12, false, true);
                g.VerticalAlignment(VerticalAlignment::Center);
                row.Children().Append(g);
            }
            if (i > 0)
            {
                Button remove = TextButton(L"×");
                std::wstring tip = L"Remove filament " + std::to_wstring(i + 1) + L". Its parts and layers print with filament 1.";
                Name(remove, L"Remove filament " + std::to_wstring(i + 1));
                ToolTipService::SetToolTip(remove, box_value(tip));
                remove.Click([this, app, i, changed](auto &&, auto &&) {
                    if (zs_app_filament_remove(app, i) == ZS_OK)
                    {
                        changed();
                        FillFilament();
                    }
                });
                row.Children().Append(remove);
            }
            filament_panel.Children().Append(row);
        }
        if (n < 16)
        {
            Button more = TextButton(L"+ Add a filament");
            more.Click([this, app, changed](auto &&, auto &&) {
                size_t index = 0;
                if (zs_app_filament_add(app, &index) == ZS_OK)
                {
                    changed();
                    FillFilament();
                }
            });
            filament_panel.Children().Append(more);
        }

        // The spools that a printdeck printer has loaded.
        zs::SavedPrinter const &printer = zs::Printers().Current();
        if (printer.kind == zs::LinkKind::Printdeck)
        {
            Button use = TextButton(reading_filaments ? L"Reading the printer…" : L"Use the filaments of " + zs::ToWide(printer.name));
            use.IsEnabled(!reading_filaments);
            ToolTipService::SetToolTip(use, box_value(L"Read the spools that the printer has loaded, and make the filaments of the plate the same: count, material, and color"));
            use.Click([this](auto &&, auto &&) {
                if (reading_filaments)
                    return;
                reading_filaments = true;
                filament_note.clear();
                FillFilament();
                zs::link::Target target = zs::link::TargetOf(zs::Printers().Current());
                bool two_nozzles = setup.TwoNozzles();
                struct Result
                {
                    bool ok = false;
                    zs::DeckFilaments spools;
                    std::string message;
                };
                Async(
                    [target, two_nozzles] {
                        Result r;
                        std::string body;
                        if (!zs::link::ReadLoadedFilaments(target, nullptr, body, r.message))
                            return r;
                        r.ok = zs::ParseDeckFilaments(body, two_nozzles, target.name, r.spools, r.message);
                        if (r.ok)
                            r.message = zs::DeckFilamentsMessage(r.spools, two_nozzles, target.name);
                        return r;
                    },
                    [two_nozzles](PrintersUi &ui, Result &r) {
                        ui.reading_filaments = false;
                        if (r.ok)
                        {
                            ui.setup.ApplySpools(r.spools, two_nozzles);
                            ui.w.RefreshSettingValues();
                            ui.RefreshBar();
                        }
                        ui.filament_note = zs::ToWide(r.message);
                        ui.Note(ui.filament_note);
                        if (ui.filament_flyout.IsOpen())
                            ui.FillFilament();
                    });
            });
            filament_panel.Children().Append(use);
            if (!filament_note.empty())
                filament_panel.Children().Append(Label(filament_note, 12, false, true));
        }

        // The rolls that the printer told in its last status.
        std::string material_now = w.model->GetSetting("filament.material");
        bool any_roll = false;
        for (auto const &roll : rolls)
        {
            if (roll.id.empty() || (!roll.material.empty() && _stricmp(roll.material.c_str(), material_now.c_str()) != 0))
                continue;
            if (!any_roll)
                filament_panel.Children().Append(Label(L"Rolls of " + zs::ToWide(material_now), 12, true, true));
            any_roll = true;
            std::wstring label = zs::ToWide(roll.name.empty() ? "?" : roll.name);
            if (roll.left > 0)
                label += L" · " + std::to_wstring((int)std::lround(roll.left)) + L" g";
            Button b = TextButton(label);
            std::string name = roll.name, color = roll.color;
            b.Click([this, app, name, color, changed](auto &&, auto &&) {
                if (!name.empty())
                    zs_app_setting_set(app, "filament.name", name.c_str());
                if (!color.empty())
                    zs_app_setting_set(app, "filament.color", color.c_str());
                changed();
                filament_flyout.Hide();
            });
            filament_panel.Children().Append(b);
        }

        // The profiles of filament 1.
        filament_panel.Children().Append(Label(L"Material", 12, true, true));
        StackPanel mats = Row(4);
        int in_row = 0;
        StackPanel lines = Column(4);
        for (size_t i = 0; i < zs_builtin_profile_count(ZS_GROUP_FILAMENT); i++)
        {
            std::string profile = zs_builtin_profile_name(ZS_GROUP_FILAMENT, i);
            if (profile.rfind("generic-", 0) != 0)
                continue;
            std::string upper = profile.substr(8);
            std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) { return (char)toupper(c); });
            bool now = _stricmp(upper.c_str(), material_now.c_str()) == 0;
            Button b = TextButton((now ? L"✓ " : L"") + zs::ToWide(upper));
            b.Click([this, upper](auto &&, auto &&) {
                filament_flyout.Hide();
                std::string message;
                if (!setup.UseMaterial(upper, message))
                    w.ShowError(zs::ToWide(message));
                w.RefreshSettingValues();
                RefreshBar();
            });
            mats.Children().Append(b);
            if (++in_row == 4)
            {
                lines.Children().Append(mats);
                mats = Row(4);
                in_row = 0;
            }
        }
        if (in_row > 0)
            lines.Children().Append(mats);
        filament_panel.Children().Append(lines);
        auto mine = setup.UserProfiles(ZS_GROUP_FILAMENT);
        if (!mine.empty())
        {
            filament_panel.Children().Append(Label(L"Your profiles", 12, true, true));
            for (auto const &name : mine)
            {
                Button b = TextButton(zs::ToWide(name));
                b.Click([this, name](auto &&, auto &&) {
                    filament_flyout.Hide();
                    std::string message;
                    if (!setup.LoadUserProfile(ZS_GROUP_FILAMENT, name, message))
                        w.ShowError(zs::ToWide(message));
                    w.RefreshSettingValues();
                    RefreshBar();
                });
                filament_panel.Children().Append(b);
            }
        }
        Button save = TextButton(L"Save as profile…");
        save.Click([this](auto &&, auto &&) {
            filament_flyout.Hide();
            AskProfileName(ZS_GROUP_FILAMENT);
        });
        filament_panel.Children().Append(save);
    }

    // ---- panels over the window ----

    std::shared_ptr<OverlayPanel> MainWindow::PrintersUi::OpenPanel(std::wstring const &title, double width, double height, UIElement const &content)
    {
        auto panel = std::make_shared<OverlayPanel>();
        panel->root = Grid();
        Grid::SetRowSpan(panel->root, 3);
        panel->root.Background(Media::SolidColorBrush(Windows::UI::Color{ 110, 0, 0, 0 }));
        panel->card = Border();
        panel->card.Width(width);
        if (height > 0)
            panel->card.Height(height);
        panel->card.MaxHeight(860);
        panel->card.HorizontalAlignment(HorizontalAlignment::Center);
        panel->card.VerticalAlignment(VerticalAlignment::Center);
        panel->card.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
        panel->card.BorderThickness(ThicknessHelper::FromUniformLength(1));
        panel->card.BorderBrush(ThemeBrush(L"SurfaceStrokeColorFlyoutBrush"));
        panel->card.Background(ThemeBrush(L"SolidBackgroundFillColorBaseBrush"));
        Grid inner;
        RowDefinition head_row, body_row;
        head_row.Height(GridLengthHelper::Auto());
        body_row.Height(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        inner.RowDefinitions().Append(head_row);
        inner.RowDefinitions().Append(body_row);
        Grid head;
        head.Padding(ThicknessHelper::FromLengths(16, 12, 8, 4));
        TextBlock heading = Label(title, 16, true);
        heading.VerticalAlignment(VerticalAlignment::Center);
        // A long title wraps before the close button.
        heading.Margin(ThicknessHelper::FromLengths(0, 0, 36, 0));
        head.Children().Append(heading);
        Button close;
        close.HorizontalAlignment(HorizontalAlignment::Right);
        close.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        close.BorderThickness(ThicknessHelper::FromUniformLength(0));
        FontIcon glyph;
        glyph.Glyph(L"\xE711");
        glyph.FontSize(12);
        close.Content(glyph);
        Name(close, L"Close");
        std::weak_ptr<OverlayPanel> weak = panel;
        close.Click([this, weak](auto &&, auto &&) {
            if (auto p = weak.lock())
                ClosePanel(p);
        });
        head.Children().Append(close);
        inner.Children().Append(head);
        Grid::SetRow(content.as<FrameworkElement>(), 1);
        inner.Children().Append(content);
        panel->card.Child(inner);
        panel->root.Children().Append(panel->card);
        panel->root.KeyDown([this, weak](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() != VirtualKey::Escape)
                return;
            if (auto p = weak.lock())
                ClosePanel(p);
            e.Handled(true);
        });
        w.Root().Children().Append(panel->root);
        panels.push_back(panel);
        return panel;
    }

    void MainWindow::PrintersUi::ClosePanel(std::shared_ptr<OverlayPanel> const &panel)
    {
        auto it = std::find(panels.begin(), panels.end(), panel);
        if (it == panels.end())
            return;
        panels.erase(it);
        uint32_t index = 0;
        if (w.Root().Children().IndexOf(panel->root, index))
            w.Root().Children().RemoveAt(index);
        if (panel->closed)
        {
            auto closed = std::move(panel->closed);
            panel->closed = nullptr;
            closed();
        }
        PreferencesPanelClosed(panel);
    }

    // ---- pairing ----

    // Asks the printer for a key. It asks its user "Allow zslice?". A deck
    // with more printers then lists them, to add the ones to keep.
    void MainWindow::PrintersUi::ShowPair(std::string const &printer_id, bool fresh, std::function<void(bool)> done)
    {
        zs::SavedPrinter *printer = zs::Printers().Find(printer_id);
        if (printer == nullptr || (printer->kind != zs::LinkKind::Printdeck && printer->kind != zs::LinkKind::OctoPrint && printer->kind != zs::LinkKind::PrusaLink))
        {
            if (done)
                done(false);
            return;
        }
        struct State
        {
            std::string id;
            std::string key;
            bool ok = false;
            bool fresh = false;
            zs::http::CancelPtr cancel;
            zs::link::DeckList list;
            std::vector<std::pair<CheckBox, size_t>> boxes;
            std::function<void(bool)> done;
            std::function<void()> run;
        };
        auto state = std::make_shared<State>();
        state->id = printer_id;
        state->fresh = fresh;
        state->done = std::move(done);

        StackPanel body = Column(10);
        body.Padding(ThicknessHelper::FromLengths(16, 4, 16, 16));
        TextBlock text = Label(L"", 14);
        TextBlock count = Label(L"", 12, false, true);
        StackPanel list = Column(4);
        list.Visibility(Visibility::Collapsed);
        StackPanel buttons = Row();
        buttons.HorizontalAlignment(HorizontalAlignment::Right);
        Button again = TextButton(L"Try again");
        again.Visibility(Visibility::Collapsed);
        Button close = TextButton(L"Cancel");
        Button add = TextButton(L"Add", true);
        add.Visibility(Visibility::Collapsed);
        buttons.Children().Append(again);
        buttons.Children().Append(close);
        buttons.Children().Append(add);
        body.Children().Append(text);
        body.Children().Append(count);
        body.Children().Append(list);
        body.Children().Append(buttons);
        auto panel = OpenPanel(L"Connect to " + zs::ToWide(printer->name), 480, 0, body);
        panel->closed = [state] {
            if (state->cancel != nullptr)
                state->cancel->Stop();
            zs::state::Wipe(state->key);
            // `run` holds the state: this ends the cycle.
            state->run = nullptr;
            if (state->done)
            {
                auto finish = std::move(state->done);
                state->done = nullptr;
                finish(state->ok);
            }
        };
        close.Click([this, panel](auto &&, auto &&) { ClosePanel(panel); });
        again.Click([state](auto &&, auto &&) {
            if (state->run)
                state->run();
        });
        add.Click([this, state, panel](auto &&, auto &&) {
            AddDeckPrinters(state->id, state->key, state->list, state->boxes, state->fresh);
            ClosePanel(panel);
        });

        state->run = [this, state, text, count, list, again, close, add] {
            zs::SavedPrinter *p = zs::Printers().Find(state->id);
            if (p == nullptr)
                return;
            again.Visibility(Visibility::Collapsed);
            bool deck = p->kind == zs::LinkKind::Printdeck;
            std::wstring key_id = deck ? zs::ToWide(zs::signing::KeyId()) : L"";
            text.Text(deck ? (key_id.empty() ? L"Tap Allow on the screen of the printdeck."
                                             : L"Tap Allow on the screen of the printdeck, and check that it shows the key " + key_id + L".")
                           : L"Allow zslice in the web page of the printer: it shows a request for zslice.");
            count.Text(L"Waiting for Allow: 120 s left.");
            if (state->cancel != nullptr)
                state->cancel->Stop();
            state->cancel = std::make_shared<zs::http::Cancel>();
            zs::link::Target target = zs::link::TargetOf(*p);
            auto cancel = state->cancel;
            Poster post = poster;
            struct Result
            {
                zs::link::KeyResult key;
                zs::link::Target target;
                bool has_list = false;
                bool list_ok = false;
                std::string list_error;
                zs::link::DeckList list;
            };
            Async(
                [target, cancel, post, count]() mutable {
                    Result r;
                    r.key = zs::link::RequestKey(target, cancel, [post, count](int seconds) {
                        post.Post([count, seconds](PrintersUi &) {
                            count.Text(L"Waiting for Allow: " + std::to_wstring(std::max(0, 120 - seconds)) + L" s left.");
                        });
                    });
                    if (r.key.ok && target.kind == zs::LinkKind::Printdeck)
                    {
                        zs::link::Target with_key = target;
                        with_key.api_key = r.key.key;
                        r.has_list = true;
                        r.list_ok = zs::link::ReadDeck(with_key, cancel, r.list, r.list_error);
                    }
                    r.target = target;
                    return r;
                },
                [state, text, count, list, again, close, add](PrintersUi &ui, Result &r) {
                    if (r.key.cancelled)
                        return;
                    count.Text(L"");
                    zs::SavedPrinter *saved = zs::Printers().Find(state->id);
                    if (!r.key.ok || saved == nullptr)
                    {
                        text.Text(r.key.message.empty() ? L"No key came." : zs::ToWide(r.key.message));
                        again.Visibility(Visibility::Visible);
                        return;
                    }
                    state->ok = true;
                    state->key = r.key.key;
                    saved->api_key = r.key.key;
                    zs::state::Wipe(r.key.key);
                    r.target.id = saved->id;
                    ui.SavePin(r.target);
                    zs::Printers().Save();
                    text.Text(L"Connected to " + zs::ToWide(saved->name) + L".");
                    close.Content(box_value(L"Close"));
                    if (r.has_list && !r.list_ok)
                    {
                        text.Text(L"Connected to " + zs::ToWide(saved->name) + L", but the list of its printers did not come: " + zs::ToWide(r.list_error));
                        return;
                    }
                    if (!r.has_list)
                        return;
                    state->list = r.list;
                    std::wstring base_name = r.list.name.empty() ? zs::ToWide(saved->name) : zs::ToWide(r.list.name);
                    std::string base = zs::link::DeckRoot(zs::link::BaseUrl(saved->url));
                    size_t usable = 0;
                    for (size_t i = 0; i < r.list.printers.size(); i++)
                    {
                        auto const &d = r.list.printers[i];
                        // Resin is not sliced here. A path must stay on the
                        // deck: the key goes there.
                        if (d.kind == "resin" || (!d.path.empty() && zs::link::DeckAddress(base, d.path).empty()))
                            continue;
                        usable++;
                        std::string label = !d.label.empty() && d.label != d.name ? d.name + " (" + d.label + ")" : d.name;
                        bool have = false;
                        for (size_t k = 0; k < zs::Printers().Count(); k++)
                            have = have || zs::Printers().At(k).name == label;
                        CheckBox box;
                        box.Content(box_value(zs::ToWide(d.path.empty() ? label + ", at the address of the deck" : label)));
                        box.IsChecked(state->fresh ? true : (!have && !d.path.empty()));
                        list.Children().Append(box);
                        state->boxes.emplace_back(box, i);
                    }
                    if (usable > 1 || (state->fresh && usable > 0))
                    {
                        text.Text(usable > 1 ? L"Connected to " + base_name + L". It drives " + std::to_wstring(usable) + L" printers: pick the ones to add."
                                             : L"Connected to " + base_name + L".");
                        list.Visibility(Visibility::Visible);
                        add.Visibility(Visibility::Visible);
                    }
                });
        };
        state->run();
    }

    void MainWindow::PrintersUi::AddDeckPrinters(std::string const &deck_id, std::string const &key, zs::link::DeckList const &list,
                                                 std::vector<std::pair<CheckBox, size_t>> const &boxes, bool fresh)
    {
        zs::PrinterStore &store = zs::Printers();
        zs::SavedPrinter *deck = store.Find(deck_id);
        if (deck == nullptr)
            return;
        std::string base = zs::link::DeckRoot(zs::link::BaseUrl(deck->url));
        std::string deck_profile;
        zs::state::ReadBytes(zs::PrinterStore::ProfilePath(*deck), deck_profile);
        zs_printers *lib = w.model->Printers();
        std::string first_id;
        bool kept_entry = false;
        for (auto const &[box, index] : boxes)
        {
            if (box.IsChecked() == nullptr || !box.IsChecked().Value())
                continue;
            auto const &d = list.printers[index];
            std::string address = d.path.empty() ? base : zs::link::DeckAddress(base, d.path);
            if (address.empty())
                continue;
            std::string label = !d.label.empty() && d.label != d.name ? d.name + " (" + d.label + ")" : d.name;
            zs::SavedPrinter *entry = nullptr;
            if (fresh && !kept_entry)
            {
                // The entry that held the address of the deck becomes the
                // first printer that the user picked.
                entry = store.Find(deck_id);
                entry->name = label;
                kept_entry = true;
            }
            else
            {
                for (size_t k = 0; k < store.Count() && entry == nullptr; k++)
                    if (store.At(k).name == label)
                        entry = &store.At(k);
                if (entry == nullptr)
                    entry = &store.Add(label);
            }
            entry->kind = zs::LinkKind::Printdeck;
            entry->url = address;
            entry->api_key = key;
            entry->deck_name = d.name;
            if (first_id.empty())
                first_id = entry->id;
            // The profile of the model of the printer, else that of the deck.
            ptrdiff_t model = -1;
            if (lib != nullptr)
                for (std::string const *hint : { &d.model, &d.name, &d.label })
                    if (model < 0 && !hint->empty())
                        model = zs_printers_match(lib, hint->c_str(), 0, 0, 0);
            std::string profile = deck_profile;
            if (model >= 0)
            {
                size_t n = 0;
                if (zs_printers_profile(lib, (size_t)model, 0, nullptr, 0, &n) == ZS_OK)
                {
                    std::string text(n + 1, '\0');
                    if (zs_printers_profile(lib, (size_t)model, 0, text.data(), text.size(), &n) == ZS_OK)
                    {
                        text.resize(n);
                        profile = std::move(text);
                    }
                }
            }
            if (!profile.empty() && !(entry->id == store.Current().id))
                zs::state::WriteBytes(zs::PrinterStore::ProfilePath(*entry), profile);
        }
        store.Save();
        if (fresh && !first_id.empty())
        {
            std::string message;
            if (first_id == store.Current().id)
            {
                // The current printer: its profile applies to the plate.
                zs::SavedPrinter *p = store.Find(first_id);
                std::string text;
                ptrdiff_t model = lib != nullptr ? zs_printers_match(lib, (p->deck_name).c_str(), 0, 0, 0) : -1;
                if (model >= 0)
                {
                    size_t n = 0;
                    if (zs_printers_profile(lib, (size_t)model, 0, nullptr, 0, &n) == ZS_OK)
                    {
                        text.resize(n + 1);
                        if (zs_printers_profile(lib, (size_t)model, 0, text.data(), text.size(), &n) == ZS_OK)
                        {
                            text.resize(n);
                            setup.LoadProfile(ZS_GROUP_MACHINE, p->name, text, message);
                        }
                    }
                }
            }
            else
                setup.UsePrinter(first_id, message);
            w.RefreshSettingValues();
            w.ShowPlate();
        }
        RefreshBar();
        RebuildTiles();
    }

    // Connects to a printdeck by its address, with no printer first.
    void MainWindow::PrintersUi::ShowConnectDeck()
    {
        StackPanel body = Column(10);
        body.Padding(ThicknessHelper::FromLengths(16, 4, 16, 16));
        body.Children().Append(Label(L"The address of the printdeck: on its System page. For example https://….d.printdeck.beetlebug.org or http://printdeck.local"));
        TextBox url;
        url.PlaceholderText(L"http://printdeck.local");
        Name(url, L"The address of the printdeck");
        body.Children().Append(url);
        TextBlock message = Label(L"", 12, false, true);
        body.Children().Append(message);
        StackPanel buttons = Row();
        buttons.HorizontalAlignment(HorizontalAlignment::Right);
        Button cancel = TextButton(L"Cancel");
        Button go = TextButton(L"Connect", true);
        buttons.Children().Append(cancel);
        buttons.Children().Append(go);
        body.Children().Append(buttons);
        auto panel = OpenPanel(L"Connect a printdeck", 480, 0, body);
        auto stop = std::make_shared<zs::http::Cancel>();
        panel->closed = [stop] { stop->Stop(); };
        cancel.Click([this, panel](auto &&, auto &&) { ClosePanel(panel); });
        auto connect = [this, panel, url, message, go, stop] {
            std::string address = zs::ToUtf8(std::wstring(url.Text()));
            std::string base = zs::link::BaseUrl(address);
            if (base.empty())
            {
                message.Text(L"Type the address of the printdeck.");
                return;
            }
            go.IsEnabled(false);
            message.Text(L"Looking for the printdeck…");
            struct Result
            {
                bool ok = false;
                zs::LinkKind kind = zs::LinkKind::None;
                std::string error;
            };
            Async(
                [base, stop] {
                    Result r;
                    r.ok = zs::link::DetectKind(base, stop, r.kind, r.error);
                    return r;
                },
                [panel, message, go, base](PrintersUi &ui, Result &r) {
                    if (std::find(ui.panels.begin(), ui.panels.end(), panel) == ui.panels.end())
                        return;
                    go.IsEnabled(true);
                    if (!r.ok)
                    {
                        message.Text(zs::ToWide(r.error));
                        return;
                    }
                    if (r.kind != zs::LinkKind::Printdeck)
                    {
                        message.Text(std::wstring(L"This address is ") + zs::ToWide(zs::LinkTitle(r.kind)) + L", not a printdeck. Add it with Add a printer…");
                        return;
                    }
                    // A name for the entry while it pairs: the host.
                    std::string host = base.substr(base.find("://") + 3);
                    host = host.substr(0, host.find_first_of(":/"));
                    zs::PrinterStore &store = zs::Printers();
                    zs::SavedPrinter *entry = nullptr;
                    // On a first start, the default printer becomes the deck.
                    if (store.FirstStart())
                        entry = &store.Current();
                    else
                        entry = &store.Add(host.empty() ? "printdeck" : host);
                    if (store.FirstStart())
                        entry->name = host.empty() ? "printdeck" : host;
                    entry->kind = zs::LinkKind::Printdeck;
                    entry->url = zs::link::DeckRoot(base);
                    store.SetFirstStart(false);
                    store.Save();
                    std::string id = entry->id;
                    ui.ClosePanel(panel);
                    ui.RefreshBar();
                    ui.ShowPair(id, true, [](bool) {});
                });
        };
        go.Click([connect](auto &&, auto &&) { connect(); });
        url.KeyDown([connect](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() == VirtualKey::Enter)
            {
                connect();
                e.Handled(true);
            }
        });
        url.Focus(FocusState::Programmatic);
    }
}
