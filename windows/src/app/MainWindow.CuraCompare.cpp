// The "Compare with Cura" window, as in linux/src/ui/cura-compare.c.
//
// It lists the zslice settings next to the settings of the active printer of
// Cura (zs_cura_stack.h and zs_app_cura_compare): by default the settings
// that differ, or all settings that map to Cura. "Use" sets the value of Cura
// in zslice, and "Use all" sets all values that differ, except the names and
// the start and end G-code. The changes go through the model, so Undo works.
//
// The window reads the Cura stack again at each refresh, so a change in Cura
// shows after "Reload". A change in zslice refreshes the rows at once. It is
// a window of its own, owned by the main window, so the settings pane and
// Undo stay in reach while it is open.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "zs_cura_stack.h"

#include <cmath>
#include <string_view>
#include <unordered_map>

#include <winrt/Microsoft.UI.Xaml.Documents.h>
#ifdef ZS_DEV_HOOKS
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#endif

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Media = Microsoft::UI::Xaml::Media;

namespace
{
    // The GTK labels wrap at 34 characters.
    double const cell_max_width = 240;

    char const *GroupLabel(std::string_view name)
    {
        if (name.starts_with("machine."))
            return "Printer";
        if (name.starts_with("filament."))
            return "Filament";
        if (name.starts_with("project."))
            return "This print";
        return "";
    }

    std::string Format(char const *format, double value)
    {
        char text[64];
        snprintf(text, sizeof text, format, value);
        return text;
    }

    // A value for people: with its unit, a ratio as a percentage, a speed
    // ratio with its mm/s, and the first line of a long text.
    std::string DisplayValue(zs_app const *app, zs_setting_info const *info, char const *name, char const *value)
    {
        if (char const *newline = strchr(value, '\n'))
        {
            unsigned lines = 1;
            for (char const *p = value; *p != 0; p++)
                lines += *p == '\n' && p[1] != 0;
            return std::string(value, newline - value) + " \xE2\x80\xA6 (" + std::to_string(lines) + " lines)";
        }
        if (info == nullptr || info->unit == nullptr || info->unit[0] == 0)
            return value[0] != 0 ? value : "(empty)";
        char *end = nullptr;
        double v = strtod(value, &end);
        if (end == value)
            return value;
        if (strcmp(info->unit, "%") == 0)
        {
            std::string percent = Format("%.4g", v * 100);
            double mm_s = 0;
            if (zs_app_ratio_speed(app, name, value, &mm_s) == ZS_OK)
            {
                std::string speed = Format("%.1f", mm_s);
                if (speed.ends_with(".0"))
                    speed.resize(speed.size() - 2);
                return percent + " % (" + speed + " mm/s)";
            }
            return percent + " %";
        }
        return std::string(value) + " " + info->unit;
    }

    std::string BaseName(std::string const &path)
    {
        size_t at = path.find_last_of("/\\");
        return at == std::string::npos ? path : path.substr(at + 1);
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    struct MainWindow::CuraCompare : std::enable_shared_from_this<MainWindow::CuraCompare>
    {
        explicit CuraCompare(MainWindow &owner) : w(owner) {}

        MainWindow &w;
        Window window{ nullptr };
        Grid root{ nullptr };
        Border line{ nullptr };
        TextBlock title{ nullptr }, summary{ nullptr };
        CheckBox show_all{ nullptr };
        Button reload{ nullptr }, use_all{ nullptr };
        ScrollViewer scroll{ nullptr };
        bool refresh_queued = false;
        // "Use all" runs: one refresh at the end.
        bool applying = false;
        // The last error of a "Use", or empty.
        std::string error;
#ifdef ZS_DEV_HOOKS
        std::vector<Button> use_buttons;
        std::vector<std::string> row_names;
#endif

        TextBlock CellLabel(std::wstring const &text, bool dim)
        {
            TextBlock l;
            l.Text(text);
            l.TextWrapping(TextWrapping::Wrap);
            l.MaxWidth(cell_max_width);
            l.HorizontalAlignment(HorizontalAlignment::Left);
            l.FontSize(dim ? 11 : 13);
            l.Foreground(TokenBrush(root, dim ? L"ZsDim" : L"ZsFg"));
            return l;
        }

        // A value and a line under it.
        StackPanel CellTwo(std::string const &text, std::string const &under, std::string const &tooltip, bool accent = false)
        {
            StackPanel box;
            box.Spacing(1);
            box.VerticalAlignment(VerticalAlignment::Center);
            TextBlock top = CellLabel(zs::ToWide(text), false);
            Documents::Typography::SetNumeralAlignment(top, FontNumeralAlignment::Tabular);
            if (accent)
                top.Foreground(TokenBrush(root, L"ZsAccentText"));
            box.Children().Append(top);
            if (!under.empty())
                box.Children().Append(CellLabel(zs::ToWide(under), true));
            if (!tooltip.empty())
                ToolTipService::SetToolTip(box, box_value(zs::ToWide(tooltip)));
            return box;
        }

        // Sets one value of Cura. False with `error` set if the core refuses
        // it.
        bool UseValue(char const *name, char const *value)
        {
            std::string message;
            if (w.model->SetSetting(name, value, message))
                return true;
            error = std::string(name) + ": " + (message.empty() ? "zslice refuses the value" : message);
            return false;
        }

        void OnUse(std::string const &name, std::string const &value)
        {
            error.clear();
            applying = true;
            if (UseValue(name.c_str(), value.c_str()))
                w.NoteChange();
            w.RefreshSettingValues();
            applying = false;
            Refresh();
        }

        // Runs a comparison. nullptr with a message in `failure` on an error.
        zs_cura_compare *Run(std::string &stack_title, std::string &failure)
        {
            auto stack = zs::cura::Stack::Find(failure);
            if (stack == nullptr)
                return nullptr;
            stack_title = stack->Title();
            zs_cura_compare *cc = nullptr;
            char message[512] = "";
            int rc = zs_app_cura_compare(w.model->Active(), zs::cura::Stack::Read, stack.get(), &cc, message, sizeof message);
            if (rc != ZS_OK)
            {
                failure = std::string("zslice cannot read the Cura stack: ") + (message[0] != 0 ? message : "error");
                return nullptr;
            }
            return cc;
        }

        // "Use all": the max speed first, because the speed ratios of Cura
        // relate to it. Then a new comparison, and each value that differs.
        void OnUseAll()
        {
            error.clear();
            applying = true;
            bool changed = false;
            for (int pass = 0; pass < 2; pass++)
            {
                std::string stack_title, failure;
                zs_cura_compare *cc = Run(stack_title, failure);
                if (cc == nullptr)
                {
                    error = failure;
                    break;
                }
                size_t n = zs_cura_compare_count(cc);
                for (size_t i = 0; i < n; i++)
                {
                    zs_cura_row r{};
                    if (zs_cura_compare_get(cc, i, &r) != ZS_OK || r.in_use_all == 0)
                        continue;
                    bool max_speed = strcmp(r.name, "machine.max_speed") == 0;
                    if (pass == 0 && !max_speed)
                        continue;
                    changed = UseValue(r.name, r.cura_value) || changed;
                }
                zs_cura_compare_free(cc);
            }
            if (changed)
                w.NoteChange();
            w.RefreshSettingValues();
            applying = false;
            Refresh();
        }

        void AddHeader(Grid const &grid, int column, wchar_t const *text)
        {
            TextBlock l;
            l.Text(text);
            l.FontSize(13);
            l.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            l.Foreground(TokenBrush(root, L"ZsFg"));
            Grid::SetColumn(l, column);
            grid.Children().Append(l);
        }

        void Place(Grid const &grid, FrameworkElement const &cell, int column, int row)
        {
            Grid::SetColumn(cell, column);
            Grid::SetRow(cell, row);
            grid.Children().Append(cell);
        }

        void Refresh()
        {
            std::string stack_title, failure;
            zs_cura_compare *cc = Run(stack_title, failure);
            title.Text(stack_title.empty() ? hstring(L"Cura") : hstring(zs::ToWide(stack_title)));
#ifdef ZS_DEV_HOOKS
            use_buttons.clear();
            row_names.clear();
#endif
            if (cc == nullptr)
            {
                summary.Text(zs::ToWide(failure));
                scroll.Content(nullptr);
                use_all.IsEnabled(false);
                return;
            }
            bool all = show_all.IsChecked() != nullptr && show_all.IsChecked().Value();

            std::unordered_map<std::string_view, zs_setting_info> infos;
            for (size_t i = 0, count = zs_setting_count(); i < count; i++)
            {
                zs_setting_info info{};
                if (zs_setting_get_info(i, &info) == ZS_OK)
                    infos.emplace(info.name, info);
            }

            Grid grid;
            grid.RowSpacing(8);
            grid.ColumnSpacing(18);
            grid.Margin(ThicknessHelper::FromLengths(16, 10, 16, 16));
            for (int c = 0; c < 5; c++)
            {
                ColumnDefinition column;
                column.Width(c == 0 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                grid.ColumnDefinitions().Append(column);
            }
            RowDefinition head;
            head.Height(GridLengthHelper::Auto());
            grid.RowDefinitions().Append(head);
            AddHeader(grid, 0, L"Setting");
            AddHeader(grid, 1, L"Group");
            AddHeader(grid, 2, L"zslice");
            AddHeader(grid, 3, L"Cura");

            size_t n = zs_cura_compare_count(cc), differ = 0, take = 0, formulas = 0;
            int row = 1;
            for (size_t i = 0; i < n; i++)
            {
                zs_cura_row r{};
                if (zs_cura_compare_get(cc, i, &r) != ZS_OK)
                    continue;
                differ += r.differs != 0;
                take += r.in_use_all != 0;
                formulas += r.formula != 0;
                if (!all && r.differs == 0)
                    continue;
                auto found = infos.find(r.name);
                zs_setting_info const *info = found != infos.end() ? &found->second : nullptr;

                RowDefinition definition;
                definition.Height(GridLengthHelper::Auto());
                grid.RowDefinitions().Append(definition);

                std::string keys = r.cura_keys[0] != 0 ? std::string("Cura: ") + r.cura_keys : std::string();
                Place(grid, CellTwo(info != nullptr ? info->label : r.name, keys, r.name), 0, row);

                TextBlock group = CellLabel(zs::ToWide(GroupLabel(r.name)), false);
                group.VerticalAlignment(VerticalAlignment::Center);
                Place(grid, group, 1, row);

                zs_app const *app = w.model->Active();
                std::string zv = DisplayValue(app, info, r.name, r.zslice_value);
                Place(grid, CellTwo(zv, {}, strchr(r.zslice_value, '\n') != nullptr ? r.zslice_value : ""), 2, row);

                std::string cv = r.formula != 0 ? std::string(r.cura_value) : DisplayValue(app, info, r.name, r.cura_value);
                std::string under = r.formula != 0                       ? "A formula: zslice cannot take it."
                                    : (r.differs != 0 && r.in_use_all == 0) ? "Not in \"Use all\"."
                                                                            : r.note;
                bool long_text = strchr(r.cura_value, '\n') != nullptr;
                std::string tip = std::string(long_text ? r.cura_value : "") + (long_text ? "\n\n" : "") + r.note +
                                  (r.note[0] != 0 ? ".\n" : "") + "From " + BaseName(r.from);
                Place(grid, CellTwo(cv, under, tip, r.differs != 0), 3, row);

                Button use;
                use.Content(box_value(L"Use"));
                use.VerticalAlignment(VerticalAlignment::Center);
                use.IsEnabled(r.differs != 0 && r.formula == 0);
                ToolTipService::SetToolTip(use, box_value(L"Set the value of Cura in zslice."));
                Automation::AutomationProperties::SetName(use, zs::ToWide(std::string("Use ") + r.name));
                use.Click([this, name = std::string(r.name), value = std::string(r.cura_value)](auto &&, auto &&) { OnUse(name, value); });
                Place(grid, use, 4, row);
#ifdef ZS_DEV_HOOKS
                use_buttons.push_back(use);
                row_names.push_back(r.name);
#endif
                row++;
            }
            zs_cura_compare_free(cc);
            if (row == 1)
            {
                RowDefinition definition;
                definition.Height(GridLengthHelper::Auto());
                grid.RowDefinitions().Append(definition);
                TextBlock same;
                same.Text(L"zslice and Cura have the same values for all mapped settings.");
                same.FontSize(13);
                same.Foreground(TokenBrush(root, L"ZsDim"));
                same.Margin(ThicknessHelper::FromLengths(0, 24, 0, 0));
                // With no rows, the columns stay together at the left.
                grid.ColumnDefinitions().GetAt(0).Width(GridLengthHelper::Auto());
                grid.HorizontalAlignment(HorizontalAlignment::Left);
                Grid::SetColumnSpan(same, 5);
                Place(grid, same, 0, 1);
            }
            // The list stays where it is after a "Use".
            double offset = scroll.VerticalOffset();
            scroll.Content(grid);
            scroll.UpdateLayout();
            scroll.ChangeView(nullptr, box_value(offset).as<Windows::Foundation::IReference<double>>(), nullptr, true);

            std::wstring text = std::to_wstring(differ) + L" of " + std::to_wstring(n - formulas) + L" mapped settings differ.";
            if (formulas > 0)
                text += L" " + std::to_wstring(formulas) + L" Cura values are formulas.";
            if (!error.empty())
                text += L"\n" + zs::ToWide(error);
            summary.Text(text);
            use_all.Content(box_value(L"Use all (" + std::to_wstring(take) + L")"));
            use_all.IsEnabled(take > 0);
        }

        // A setting changed (here, in the panel, or by Undo).
        void Schedule()
        {
            if (applying || refresh_queued)
                return;
            refresh_queued = true;
            std::weak_ptr<CuraCompare> weak = weak_from_this();
            w.queue.TryEnqueue(Microsoft::UI::Dispatching::DispatcherQueuePriority::Low, [weak] {
                if (auto self = weak.lock())
                {
                    self->refresh_queued = false;
                    self->Refresh();
                }
            });
        }

        void ApplyTheme()
        {
            root.Background(TokenBrush(root, L"ZsBg"));
            line.Background(TokenBrush(root, L"ZsLine"));
            title.Foreground(TokenBrush(root, L"ZsFg"));
            summary.Foreground(TokenBrush(root, L"ZsDim"));
        }

        void Open()
        {
            window = Window();
            window.Title(L"Compare with Cura");

            root = Grid();
            for (int i = 0; i < 3; i++)
            {
                RowDefinition definition;
                definition.Height(i == 2 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                root.RowDefinitions().Append(definition);
            }

            StackPanel top;
            top.Spacing(6);
            top.Margin(ThicknessHelper::FromLengths(16, 12, 16, 10));
            title = TextBlock();
            title.TextWrapping(TextWrapping::Wrap);
            title.FontSize(15);
            title.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            summary = TextBlock();
            summary.TextWrapping(TextWrapping::Wrap);
            summary.FontSize(13);

            Grid bar;
            bar.ColumnSpacing(8);
            for (int c = 0; c < 3; c++)
            {
                ColumnDefinition column;
                column.Width(c == 0 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                bar.ColumnDefinitions().Append(column);
            }
            show_all = CheckBox();
            show_all.Content(box_value(L"Show all mapped settings"));
            reload = Button();
            reload.Content(box_value(L"Reload"));
            ToolTipService::SetToolTip(reload, box_value(L"Read the settings of Cura again."));
            Grid::SetColumn(reload, 1);
            use_all = Button();
            use_all.Content(box_value(L"Use all"));
            use_all.Style(Application::Current().Resources().Lookup(box_value(L"ZsSuggested")).as<Style>());
            ToolTipService::SetToolTip(use_all, box_value(L"Set each value of Cura that differs in zslice. The names and the start and end G-code stay as they are."));
            Grid::SetColumn(use_all, 2);
            bar.Children().Append(show_all);
            bar.Children().Append(reload);
            bar.Children().Append(use_all);

            top.Children().Append(title);
            top.Children().Append(summary);
            top.Children().Append(bar);
            root.Children().Append(top);

            line = Border();
            line.Height(1);
            Grid::SetRow(line, 1);
            root.Children().Append(line);

            scroll = ScrollViewer();
            scroll.HorizontalScrollMode(ScrollMode::Disabled);
            scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
            scroll.VerticalScrollBarVisibility(ScrollBarVisibility::Auto);
            Grid::SetRow(scroll, 2);
            root.Children().Append(scroll);
            window.Content(root);

            auto refresh = [this](auto &&, auto &&) { Refresh(); };
            show_all.Checked(refresh);
            show_all.Unchecked(refresh);
            reload.Click([this](auto &&, auto &&) {
                error.clear();
                Refresh();
            });
            use_all.Click([this](auto &&, auto &&) { OnUseAll(); });
            root.ActualThemeChanged([this](auto &&, auto &&) {
                ApplyTheme();
                Refresh();
            });
            window.Closed([this](auto &&, auto &&) {
                // The struct stays alive to the end of this handler.
                auto keep = w.cura;
                w.cura = nullptr;
            });

            ApplyTheme();
            Refresh();
            PlaceWindow();
            window.Activate();
        }

        // 980 by 680 points over the main window, as a window that it owns.
        void PlaceWindow()
        {
            auto app_window = window.AppWindow();
            HWND own = nullptr;
            window.try_as<::IWindowNative>()->get_WindowHandle(&own);
            ::SetWindowLongPtrW(own, GWLP_HWNDPARENT, (LONG_PTR)w.hwnd);
            double scale = ::GetDpiForWindow(own) / 96.0;
            int32_t width = (int32_t)std::lround(980 * scale), height = (int32_t)std::lround(680 * scale);
            auto main_at = w.AppWindow().Position();
            auto main_size = w.AppWindow().Size();
            auto area = Microsoft::UI::Windowing::DisplayArea::GetFromWindowId(w.AppWindow().Id(), Microsoft::UI::Windowing::DisplayAreaFallback::Nearest).WorkArea();
            width = std::min(width, area.Width);
            height = std::min(height, area.Height);
            int32_t x = main_at.X + (main_size.Width - width) / 2;
            int32_t y = main_at.Y + (main_size.Height - height) / 2;
            x = std::clamp(x, area.X, area.X + area.Width - width);
            y = std::clamp(y, area.Y, area.Y + area.Height - height);
            app_window.MoveAndResize({ x, y, width, height });
            // The five columns need this width: the cells do not shrink.
            if (auto presenter = app_window.Presenter().try_as<Microsoft::UI::Windowing::OverlappedPresenter>())
            {
                presenter.PreferredMinimumWidth((int32_t)std::lround(std::min(880.0, area.Width / scale) * scale));
                presenter.PreferredMinimumHeight((int32_t)std::lround(std::min(400.0, area.Height / scale) * scale));
            }
        }
    };

    void MainWindow::ShowCuraCompare()
    {
        if (model == nullptr)
            return;
        if (cura != nullptr)
        {
            cura->Refresh();
            cura->window.Activate();
            return;
        }
        cura = std::make_shared<CuraCompare>(*this);
        cura->Open();
    }

    void MainWindow::CuraSettingsChanged()
    {
        if (cura != nullptr)
            cura->Schedule();
    }

    void MainWindow::CloseCuraCompare()
    {
        if (auto keep = cura)
            keep->window.Close();
        cura = nullptr;
    }

#ifdef ZS_DEV_HOOKS
    UIElement MainWindow::CuraDevRoot()
    {
        return cura != nullptr ? UIElement(cura->root) : UIElement(nullptr);
    }

    // curaopen [all], curaclose, curamenu (opens the main menu), curamenupress
    // (its item), curaall 0|1, curareload, curause i, curauseall, curascroll y,
    // curasize w h, curatheme light|dark, curalog. The buttons go through
    // their automation peers, so no real input moves.
    bool MainWindow::CuraDevStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        namespace Peers = Microsoft::UI::Xaml::Automation::Peers;
        namespace Provider = Microsoft::UI::Xaml::Automation::Provider;
        auto press = [](Button const &button) {
            if (button.IsEnabled())
                Peers::ButtonAutomationPeer(button).as<Provider::IInvokeProvider>().Invoke();
        };
        if (verb == L"curaopen")
        {
            ShowCuraCompare();
            if (cura != nullptr && !words.empty() && words[0] == L"all")
                cura->show_all.IsChecked(true);
        }
        else if (verb == L"curaclose")
        {
            CloseCuraCompare();
        }
        else if (verb == L"curamenu")
        {
            MainMenu().ShowAt(MainMenuButton());
        }
        else if (verb == L"curamenupress")
        {
            for (auto const &entry : MainMenu().Items())
                if (auto item = entry.try_as<MenuFlyoutItem>(); item != nullptr && item.Text() == L"Compare with Cura…")
                    Peers::MenuFlyoutItemAutomationPeer(item).as<Provider::IInvokeProvider>().Invoke();
        }
        else if (!verb.starts_with(L"cura") || verb == L"curashot")
        {
            return false;
        }
        else if (cura == nullptr)
        {
            zs::Log("dev: cura window is closed\n");
        }
        else if (verb == L"curaall")
        {
            bool on = !words.empty() && words[0] == L"1";
            bool now = cura->show_all.IsChecked() != nullptr && cura->show_all.IsChecked().Value();
            if (on != now)
                Peers::CheckBoxAutomationPeer(cura->show_all).as<Provider::IToggleProvider>().Toggle();
        }
        else if (verb == L"curareload")
        {
            press(cura->reload);
        }
        else if (verb == L"curause")
        {
            size_t i = words.empty() ? 0 : (size_t)_wtoi(words[0].c_str());
            if (i < cura->use_buttons.size())
            {
                zs::Log("dev: cura use %s\n", cura->row_names[i].c_str());
                press(cura->use_buttons[i]);
            }
        }
        else if (verb == L"curauseall")
        {
            press(cura->use_all);
        }
        else if (verb == L"curascroll")
        {
            double y = words.empty() ? 0 : _wtof(words[0].c_str());
            cura->scroll.ChangeView(nullptr, box_value(y).as<Windows::Foundation::IReference<double>>(), nullptr, true);
        }
        else if (verb == L"curasize" && words.size() >= 2)
        {
            cura->window.AppWindow().Resize({ _wtoi(words[0].c_str()), _wtoi(words[1].c_str()) });
        }
        else if (verb == L"curatheme")
        {
            cura->root.RequestedTheme(!words.empty() && words[0] == L"dark" ? ElementTheme::Dark : ElementTheme::Light);
        }
        else if (verb == L"curalog")
        {
            size_t enabled = 0;
            for (auto const &button : cura->use_buttons)
                enabled += button.IsEnabled();
            auto label = unbox_value_or<hstring>(cura->use_all.Content(), L"");
            auto size = cura->window.AppWindow().Size();
            zs::Log("dev: cura window %dx%d\n", size.Width, size.Height);
            zs::Log("dev: cura title '%s' | summary '%s' | '%s' enabled %d | rows %zu, use on %zu | offset %.0f | history %zu now %zu pending %d\n",
                    to_string(cura->title.Text()).c_str(), to_string(cura->summary.Text()).c_str(), to_string(label).c_str(), cura->use_all.IsEnabled() ? 1 : 0,
                    cura->use_buttons.size(), enabled, cura->scroll.VerticalOffset(), zs_app_history_count(model->Active()),
                    zs_app_history_current(model->Active()), zs_app_history_pending(model->Active()));
            for (size_t i = 0; i < cura->row_names.size() && i < 80; i++)
                zs::Log("dev: cura row %zu %s use %d now '%s'\n", i, cura->row_names[i].c_str(), cura->use_buttons[i].IsEnabled() ? 1 : 0,
                        cura->row_names[i].find("gcode") != std::string::npos ? "(text)" : model->GetSetting(cura->row_names[i].c_str()).c_str());
        }
        else
        {
            return false;
        }
        return true;
    }
#endif
}
