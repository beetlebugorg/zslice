// Calibration prints. A test goes on a new plate with the settings of the
// active plate (src/app/calibrate.zig). A dialog then says how to read the
// print, and has a button for each value. A button sets the value on each
// plate. A test makes a plate and a slice, and it never sends a file to a
// printer.
//
// The behavior follows win.calibrate in linux/src/ui/window.c,
// zg_model_calibrate and zg_model_calibration_use in
// linux/src/model/app-model.c, and calibrate in web/app/app.js. The user
// guide is docs/user/calibrate.md.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#include <cmath>
#include <limits>

#ifdef ZS_DEV_HOOKS
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#endif

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace
{
    struct Test
    {
        int kind;
        wchar_t const *menu, *search, *hint, *tip;
    };

    // The order of enum zs_calibration.
    Test const tests[] = {
        { ZS_CALIB_TEMPERATURE, L"Temperature tower", L"Calibrate: temperature tower", L"a block for each nozzle temperature, on a new plate",
          L"A block for each nozzle temperature of the material, on a new plate" },
        { ZS_CALIB_RETRACTION, L"Retraction test", L"Calibrate: retraction test", L"a retraction length for each band, on a new plate",
          L"Two pillars: a retraction length for each band, on a new plate" },
        { ZS_CALIB_FLOW, L"Flow test", L"Calibrate: flow test", L"a row of cubes, each with its own flow, on a new plate",
          L"A row of cubes, each with its own flow, on a new plate" },
        { ZS_CALIB_PRESSURE_ADVANCE, L"Pressure advance tower", L"Calibrate: pressure advance tower", L"a pressure advance for each band, on a new plate",
          L"Thin walls with sharp corners: a pressure advance for each band, on a new plate" },
    };

    wchar_t const *const use_text = L"Use a value of this test…";

    struct Plan
    {
        std::string name, setting, note;
        std::vector<std::pair<std::string, std::string>> steps;
    };

    // The text of zs_app_calibration_get, or false for a plate with no test.
    bool ReadPlan(zs_app *app, Plan &plan)
    {
        size_t len = 0;
        if (zs_app_calibration_get(app, nullptr, 0, &len) != ZS_OK)
            return false;
        std::string text(len + 1, '\0');
        if (zs_app_calibration_get(app, text.data(), text.size(), &len) != ZS_OK)
            return false;
        text.resize(len);
        size_t from = 0;
        while (from < text.size())
        {
            size_t to = text.find('\n', from);
            if (to == std::string::npos)
                to = text.size();
            std::string line = text.substr(from, to - from);
            from = to + 1;
            size_t tab = line.find('\t');
            if (tab == std::string::npos)
                continue;
            std::string key = line.substr(0, tab), rest = line.substr(tab + 1);
            if (key == "name")
                plan.name = rest;
            else if (key == "setting")
                plan.setting = rest;
            else if (key == "note")
                plan.note = rest;
            else if (key == "step")
            {
                size_t second = rest.find('\t');
                if (second != std::string::npos)
                    plan.steps.emplace_back(rest.substr(0, second), rest.substr(second + 1));
            }
        }
        return true;
    }
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::AddCalibrateMenu()
    {
        MenuFlyoutSubItem menu;
        menu.Text(L"Calibrate");
        for (Test const &test : tests)
        {
            MenuFlyoutItem item;
            item.Text(test.menu);
            ToolTipService::SetToolTip(item, box_value(test.tip));
            item.Click([this, kind = test.kind](auto &&, auto &&) { Calibrate(kind); });
            menu.Items().Append(item);
        }
        menu.Items().Append(MenuFlyoutSeparator{});
        MenuFlyoutItem use;
        use.Text(use_text);
        ToolTipService::SetToolTip(use, box_value(L"How to read the test of this plate, and a button for each of its values"));
        use.Click([this](auto &&, auto &&) { ShowCalibration(); });
        menu.Items().Append(use);
        MainMenu().Items().Append(menu);
    }

    void MainWindow::AddCalibrateActions(std::vector<SearchAction> &out)
    {
        for (Test const &test : tests)
            out.push_back({ test.search, L"", test.hint, [this, kind = test.kind] { Calibrate(kind); } });
        out.push_back({ L"Calibrate: use a value of this test…", L"", L"how to read the test, and its values", [this] { ShowCalibration(); } });
    }

    void MainWindow::Calibrate(int kind)
    {
        if (model == nullptr || view == nullptr)
            return;
        // An edit of this plate ends here: the timer commits on the active
        // plate, and that is the new plate after the switch.
        if (history_timer.IsRunning())
        {
            history_timer.Stop();
            model->HistoryCommit();
        }
        size_t from = model->ActivePlate();
        if (!model->AddPlate())
        {
            ShowError(L"The test did not load. No new plate.");
            return;
        }
        zs_app *app = model->Active();
        int rc = zs_app_calibration_add(app, kind);
        if (rc != ZS_OK)
        {
            // As in GTK: the exact slice of a draft starts before the remove.
            model->Settle();
            model->RemovePlate(model->ActivePlate());
            model->SelectPlate(from);
            ShowPlate();
            ShowError(rc == ZS_INVALID_SETTINGS ? L"The test did not load. The printer has no retraction (machine.retract_length is 0)."
                                                : L"The test did not load.");
            return;
        }
        Plan plan;
        if (ReadPlan(app, plan) && !plan.name.empty())
            zs_set_name(model->Set(), model->ActivePlate(), plan.name.c_str());
        model->HistoryCommit();
        ShowPlate();
        FramePlate(model->ActivePlate());
        // A draft on the plate before gets its exact slice in this call. The
        // new plate has no slice yet, so it slices exact at once.
        model->RequestSlice();
        ShowCalibration();
    }

    // How to read the test of the active plate, and a button for each value.
    void MainWindow::ShowCalibration()
    {
        if (model == nullptr || printers == nullptr)
            return;
        Plan plan;
        if (!ReadPlan(model->Active(), plan))
        {
            ShowAlert(L"This plate has no calibration test", L"Open Calibrate in the main menu to make one.");
            return;
        }
        StackPanel body = ui::Column(12);
        body.Padding(ThicknessHelper::FromLengths(16, 4, 16, 14));
        body.Children().Append(ui::Label(zs::ToWide(plan.note), 13));

        // Equal cells, as wide as the longest label.
        double widest = 0;
        for (auto const &step : plan.steps)
        {
            TextBlock probe;
            probe.Text(L"Use " + zs::ToWide(step.first));
            probe.Measure(Windows::Foundation::Size{ std::numeric_limits<float>::infinity(), std::numeric_limits<float>::infinity() });
            widest = std::max(widest, (double)probe.DesiredSize().Width);
        }
        VariableSizedWrapGrid values;
        values.Orientation(Orientation::Horizontal);
        values.ItemWidth(std::ceil(widest) + 34);
        values.ItemHeight(38);
        for (auto const &step : plan.steps)
        {
            std::wstring text = L"Use " + zs::ToWide(step.first);
            Button b = ui::TextButton(text);
            b.HorizontalAlignment(HorizontalAlignment::Stretch);
            b.VerticalAlignment(VerticalAlignment::Stretch);
            b.Margin(ThicknessHelper::FromLengths(0, 0, 6, 6));
            ui::Name(b, text);
            ToolTipService::SetToolTip(b, box_value(L"Set " + zs::ToWide(plan.setting) + L" to " + zs::ToWide(step.second) + L" on each plate"));
            b.Click([this, setting = plan.setting, value = step.second](auto &&, auto &&) { UseCalibrationValue(setting, value); });
            values.Children().Append(b);
        }
        body.Children().Append(values);
        Button close = ui::TextButton(L"Close");
        close.HorizontalAlignment(HorizontalAlignment::Right);
        body.Children().Append(close);

        ScrollViewer scroll;
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        scroll.Content(body);
        auto panel = printers->ShowInfoPanel(plan.name.empty() ? L"Calibration" : zs::ToWide(plan.name), 560, scroll, close);
        std::weak_ptr<OverlayPanel> weak = panel;
        close.Click([this, weak](auto &&, auto &&) {
            if (auto p = weak.lock(); p != nullptr && printers != nullptr)
                printers->ClosePanel(p);
        });
    }

    // The value goes on each plate, so the filament of each plate has it.
    void MainWindow::UseCalibrationValue(std::string const &setting, std::string const &value)
    {
        if (model == nullptr)
            return;
        if (history_timer.IsRunning())
        {
            history_timer.Stop();
            model->HistoryCommit();
        }
        bool ok = true;
        size_t active = model->ActivePlate();
        for (size_t i = 0; i < model->PlateCount(); i++)
        {
            if (zs_app_setting_set(zs_set_app(model->Set(), i), setting.c_str(), value.c_str()) != ZS_OK)
                ok = false;
            else if (i != active)
                zs_set_changed(model->Set(), i);
        }
        model->HistoryCommit();
        RefreshSettingValues();
        RefreshHistoryButtons();
        PrintersNoteChange();
        CheckFall();
        model->RequestSlice();
        if (printers != nullptr)
            if (auto open = printers->info_panel)
                printers->ClosePanel(open);
        ShowToast(ok ? zs::ToWide(setting) + L" is " + zs::ToWide(value) + L" now." : std::wstring(L"The value was not set. A plate refused the value."));
    }

#ifdef ZS_DEV_HOOKS
    // calmenu            writes the items of the Calibrate menu
    // calopen, calsub    opens the main menu, then the Calibrate menu
    // calrun NAME        runs an item of the menu ('_' is a space)
    // calfind NAME       runs the search action with this label
    // calshow            the dialog of the active plate
    // caluse i           presses the button of step i
    // calclose           closes the dialog
    // callog             writes the plates, the plan, and the value of each plate
    bool MainWindow::RunCalibrateStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        namespace Peers = Microsoft::UI::Xaml::Automation::Peers;
        namespace Provider = Microsoft::UI::Xaml::Automation::Provider;
        auto submenu = [this]() -> MenuFlyoutSubItem {
            for (auto const &item : MainMenu().Items())
                if (auto sub = item.try_as<MenuFlyoutSubItem>(); sub != nullptr && sub.Text() == L"Calibrate")
                    return sub;
            return nullptr;
        };
        if (verb == L"calmenu")
        {
            std::string names;
            if (auto sub = submenu())
                for (auto const &item : sub.Items())
                {
                    if (auto text = item.try_as<MenuFlyoutItem>())
                        names += zs::ToUtf8(std::wstring(text.Text())) + " | ";
                    else
                        names += "--- | ";
                }
            zs::Log("dev: calibrate menu: %s\n", names.c_str());
        }
        else if (verb == L"calopen")
        {
            MainMenu().ShowAt(MainMenuButton());
        }
        else if (verb == L"calsub")
        {
            if (auto sub = submenu())
                Peers::FrameworkElementAutomationPeer::CreatePeerForElement(sub).as<Provider::IExpandCollapseProvider>().Expand();
        }
        else if (verb == L"calrun" && !words.empty())
        {
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            bool ran = false;
            if (auto sub = submenu())
                for (auto const &item : sub.Items())
                    if (auto text = item.try_as<MenuFlyoutItem>(); text != nullptr && text.Text() == want)
                    {
                        Peers::MenuFlyoutItemAutomationPeer(text).as<Provider::IInvokeProvider>().Invoke();
                        ran = true;
                    }
            zs::Log("dev: calibrate item %s\n", ran ? "ran" : "not found");
        }
        else if (verb == L"calfind" && !words.empty())
        {
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            bool ran = false;
            for (auto const &action : SearchActions())
                if (action.label == want)
                {
                    action.run();
                    ran = true;
                }
            zs::Log("dev: calibrate action %s\n", ran ? "ran" : "not found");
        }
        else if (verb == L"calshow")
        {
            ShowCalibration();
        }
        else if (verb == L"caluse" && !words.empty())
        {
            Plan plan;
            size_t i = (size_t)_wtoi(words[0].c_str());
            bool pressed = ReadPlan(model->Active(), plan) && i < plan.steps.size() && PressNamed(L"Use " + zs::ToWide(plan.steps[i].first));
            zs::Log("dev: calibrate use %zu pressed %d\n", i, pressed ? 1 : 0);
        }
        else if (verb == L"calclose")
        {
            if (auto open = printers->info_panel)
                printers->ClosePanel(open);
        }
        else if (verb == L"callog")
        {
            Plan plan;
            bool has = ReadPlan(model->Active(), plan);
            zs_plate_info info{};
            zs_set_plate_info(model->Set(), model->ActivePlate(), &info);
            zs::Log("dev: calibrate plates %zu active %zu name '%s' test %d '%s' setting %s steps %zu parts %zu state %d draft %d slicing draft %d dialog %d sending %d\n", model->PlateCount(),
                    model->ActivePlate(), info.name != nullptr ? info.name : "", has ? 1 : 0, plan.name.c_str(), plan.setting.c_str(), plan.steps.size(), zs_app_part_count(model->Active()),
                    zs_app_state(model->Active()), model->IsDraft() ? 1 : 0, model->SlicesDraft() ? 1 : 0, printers->info_panel != nullptr ? 1 : 0, printers->sending ? 1 : 0);
            if (has)
                for (size_t i = 0; i < model->PlateCount(); i++)
                {
                    char value[64] = "";
                    size_t n = 0;
                    zs_app_setting_get(zs_set_app(model->Set(), i), plan.setting.c_str(), value, sizeof value, &n);
                    zs::Log("dev: plate %zu %s = %s, state %d, history %zu pending %d\n", i, plan.setting.c_str(), value, zs_app_state(zs_set_app(model->Set(), i)),
                            zs_app_history_count(zs_set_app(model->Set(), i)), zs_app_history_pending(zs_set_app(model->Set(), i)));
                }
        }
        else
        {
            return false;
        }
        return true;
    }
#endif
}
