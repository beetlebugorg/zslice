// Test hooks of the Windows shell, in a build with -p:ZsDevHooks=true.
//
// ZSLICE_DO=steps runs the steps after the first slice, one each 600 ms, on
// the same code that the pointer and the keys call. A test then needs no
// real input, which would move the pointer of the user. x and y are points
// of the view. The steps, with ; between them:
//   tool V          a tool by its key
//   click x y [shift] [ctrl]
//   drag x0 y0 x1 y1 [ctrl]
//   turnz n         drags the Z ring of the selected part by n degrees
//   hover x y       the pointer moves (for the hand)
//   key NAME        V M R G T H L K J Up Down Left Right Delete Escape
//   layer n         the layer slider
//   log             writes the state
//   shot NAME, wait a line in the log for a script, and no step
//   press NAME      the button with this name or text ('_' is a space)
//   newplate, plate n   part 0 to a new plate, and the active plate
//   fopen, fclose, fmaterial i NAME, fcoloropen i, fcolorset i #hex, flog
//                   the list of the filaments
//   undo, redo      the history
//   look nx ny nz d the camera looks at the middle of part 0 from n
//   orbit dx dy, zoom f
// The Paint tool: pclick [shift] and pstroke dx dy (at the point of the mesh
// nearest to the middle of the part), pmode smart|brush, psize mm,
// pfilament n, paddfilament, pclear, phover x y, pselect n, plog. The Label
// tool: lface dx dz (a click on the
// front face of part 0), ltext T ('_' is a space), lset i field value,
// lshape i kind, ladd kind, lremove i, lfilament n, laddfilament, ldepth mm,
// lturn deg, lwheel n, lswheel n, ldrag dx dy, lsdrag dx dy, lscale k,
// ldraw i, linfo, lflush, llog.
// The Support tool adds, in MainWindow.Support.cpp:
//   orbit dx dy     turns the view
//   zoom f          zooms toward part 0 (under 1 zooms in)
//   alt x y         a click with Alt
//   findover [click]  the first overhang in the view, and a click on it
//   sdrag i j dx dy   drags point j of area i
//   sclick i        a click on the outline of area i
//   dclick k        a click on point k of the draft
//   tclick k, tdrag k dx dy, tseg k dx dy, tmenu k   node k of the first tree
//   tbig            selects the widest node of the first tree
//   tring dx        drags the ring of the selected node
//   tadd fx fy tx ty  Add a branch: the foot, then the tip
//   tdel, treset, kind k, see 0|1, undo, redo
//   set name value  a setting
//   plate add, plate i
//   pickline        the Select tool: a click on the first support line
// Each step writes the state to the log (ZSLICE_LOG).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#ifdef ZS_DEV_HOOKS

#include <cmath>
#include <sstream>

#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>

using namespace winrt;
using Windows::System::VirtualKey;

namespace winrt::ZSlice::implementation
{
    void MainWindow::StartDevHooks()
    {
        if (dev_started)
            return;
        dev_started = true;
        wchar_t text[4096];
        DWORD n = ::GetEnvironmentVariableW(L"ZSLICE_DO", text, ARRAYSIZE(text));
        if (n == 0 || n >= ARRAYSIZE(text))
            return;
        std::wstringstream all{ std::wstring(text, n) };
        std::wstring step;
        while (std::getline(all, step, L';'))
            if (step.find_first_not_of(L" ") != std::wstring::npos)
                dev_steps.push_back(step);
        dev_timer = queue.CreateTimer();
        dev_timer.Interval(std::chrono::milliseconds(600));
        dev_timer.Tick([this](auto &&, auto &&) {
            if (dev_next >= dev_steps.size() || model == nullptr || view == nullptr)
            {
                dev_timer.Stop();
                zs::Log("dev: done\n");
                return;
            }
            RunDevStep(dev_steps[dev_next++]);
        });
        dev_timer.Start();
    }

    // Presses the visible button with this automation name or text, also in
    // an open flyout, through its automation peer. No real input moves.
    bool MainWindow::PressNamed(std::wstring const &name)
    {
        namespace Peers = Microsoft::UI::Xaml::Automation::Peers;
        namespace Provider = Microsoft::UI::Xaml::Automation::Provider;
        using namespace Microsoft::UI::Xaml;
        using namespace Microsoft::UI::Xaml::Controls;
        std::function<bool(DependencyObject const &)> walk = [&](DependencyObject const &at) {
            if (auto element = at.try_as<UIElement>(); element != nullptr && element.Visibility() != Visibility::Collapsed)
            {
                if (auto base = at.try_as<Primitives::ButtonBase>())
                {
                    std::wstring text{ Automation::AutomationProperties::GetName(base) };
                    if (text.empty())
                        text = std::wstring(unbox_value_or<hstring>(base.Content(), L""));
                    if (text == name && base.IsEnabled())
                    {
                        if (auto toggle = at.try_as<Primitives::ToggleButton>())
                            Peers::ToggleButtonAutomationPeer(toggle).as<Provider::IToggleProvider>().Toggle();
                        else if (auto button = at.try_as<Button>())
                            Peers::ButtonAutomationPeer(button).as<Provider::IInvokeProvider>().Invoke();
                        return true;
                    }
                }
                int n = Media::VisualTreeHelper::GetChildrenCount(at);
                for (int k = 0; k < n; k++)
                    if (walk(Media::VisualTreeHelper::GetChild(at, k)))
                        return true;
            }
            return false;
        };
        auto popups = Media::VisualTreeHelper::GetOpenPopupsForXamlRoot(Content().XamlRoot());
        for (uint32_t i = 0; i < popups.Size(); i++)
            if (popups.GetAt(i).Child() != nullptr && walk(popups.GetAt(i).Child()))
                return true;
        return walk(Content());
    }

    void MainWindow::LogDevState(std::wstring const &step)
    {
        zs_app *app = model->Active();
        zs::Log("dev: %s | tool %d path %lld seg %lld parts", zs::ToUtf8(step).c_str(), (int)tool,
                (long long)selected_path, (long long)selected_segment);
        for (int64_t i : selected_parts)
            zs::Log(" %lld", (long long)i);
        size_t count = zs_app_part_count(app);
        zs::Log(" | %zu part(s):", count);
        for (size_t i = 0; i < count && i < 4; i++)
        {
            zs_part p{};
            if (zs_app_part_get(app, i, &p) == ZS_OK)
                zs::Log(" (%.1f,%.1f rot %.0f size %.1fx%.1fx%.1f)", p.x, p.y, p.rotation, p.size_x, p.size_y, p.size_z);
        }
        zs::Log(" | hand %d falling %d measure %d | line card %d part card %d | layer %.0f | state %d\n", hand ? 1 : 0, falling ? 1 : 0,
                measure_count, LineCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0,
                PartCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, LayerSlider().Value(), zs_app_state(app));
        if (MeasureCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible)
            zs::Log("dev: measure: %s\n", to_string(MeasureText().Text()).c_str());
    }

    void MainWindow::RunDevStep(std::wstring const &step)
    {
        std::wstringstream in{ step };
        std::wstring verb;
        in >> verb;
        std::vector<std::wstring> words;
        std::wstring word;
        while (in >> word)
            words.push_back(word);
        // "part" in place of x y: the middle of part 0 on the screen. A drag
        // from there takes dx dy.
        if (!words.empty() && words[0] == L"part")
        {
            zs_part p{};
            float cx = 0, cy = 0;
            if (zs_app_part_get(model->Active(), 0, &p) == ZS_OK)
                zs_view_pixel_of(view, p.x, p.y, p.size_z / 2, &cx, &cy);
            double x = cx / Scale(), y = cy / Scale();
            words.erase(words.begin());
            if (verb == L"drag" && words.size() >= 2)
            {
                words[0] = std::to_wstring(x + _wtof(words[0].c_str()));
                words[1] = std::to_wstring(y + _wtof(words[1].c_str()));
            }
            words.insert(words.begin(), std::to_wstring(y));
            words.insert(words.begin(), std::to_wstring(x));
        }
        auto number = [&](size_t i) { return i < words.size() ? _wtof(words[i].c_str()) : 0.0; };
        auto has = [&](wchar_t const *flag) { return std::find(words.begin(), words.end(), flag) != words.end(); };

        if (SupportDevStep(verb, words))
        {
        }
        else if (verb == L"tool" && !words.empty())
        {
            OnToolKey(static_cast<VirtualKey>(towupper(words[0][0])), false, false);
        }
        else if (verb == L"click")
        {
            double x = number(0), y = number(1);
            press_shift = has(L"shift");
            bool took = ToolPress(x, y, has(L"ctrl"));
            press_shift = false;
            if (took)
                ToolRelease();
            if (hand_click)
                hand_click = false;
            else
                ToolClick(x, y, has(L"shift"), has(L"ctrl"));
        }
        else if (verb == L"drag")
        {
            double x0 = number(0), y0 = number(1), x1 = number(2), y1 = number(3);
            bool took = ToolPress(x0, y0, has(L"ctrl"));
            hand_click = false;
            double lx = x0, ly = y0;
            for (int k = 1; k <= 12; k++)
            {
                double x = x0 + (x1 - x0) * k / 12, y = y0 + (y1 - y0) * k / 12;
                if (took)
                    ToolDrag(x, y, false);
                else
                    zs_view_orbit(view, (float)(x - lx), (float)(y - ly));
                lx = x;
                ly = y;
            }
            if (took)
                ToolRelease();
            RequestDraw();
        }
        else if (verb == L"probe")
        {
            // What the view has at a point, and where part 0 is.
            float px = (float)(number(0) * Scale()), py = (float)(number(1) * Scale());
            double bx = 0, by = 0, sp[3] = {};
            int bed = zs_view_bed_point(view, px, py, &bx, &by);
            int surface = zs_view_surface_point(view, px, py, 0, sp);
            size_t pick = zs_view_pick(view, px, py);
            zs_part p{};
            float cx = 0, cy = 0;
            if (zs_app_part_get(model->Active(), 0, &p) == ZS_OK)
                zs_view_pixel_of(view, p.x, p.y, p.size_z / 2, &cx, &cy);
            zs::Log("dev: probe scale %.2f panel %.0fx%.0f | bed %d (%.1f,%.1f) surface %d (%.1f,%.1f,%.1f) pick %lld | part 0 center at points (%.0f,%.0f)\n",
                    Scale(), ViewPanel().ActualWidth(), ViewPanel().ActualHeight(), bed, bx, by, surface, sp[0], sp[1], sp[2],
                    pick == (size_t)-1 ? -1LL : (long long)pick, cx / Scale(), cy / Scale());
        }
        else if (verb == L"turnz")
        {
            // A drag along the Z ring of the selected part, by n degrees.
            zs_part p{};
            if (!selected_parts.empty() && zs_app_part_get(model->Active(), (size_t)selected_parts[0], &p) == ZS_OK)
            {
                double radius = 0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4, degrees = number(0), s = Scale();
                auto at = [&](double angle, double &x, double &y) {
                    float px = 0, py = 0;
                    double a = angle * 3.14159265358979 / 180;
                    zs_view_pixel_of(view, p.x + radius * std::cos(a), p.y + radius * std::sin(a), p.size_z / 2, &px, &py);
                    x = px / s;
                    y = py / s;
                };
                double x = 0, y = 0;
                at(45, x, y);
                if (ToolPress(x, y, false))
                {
                    for (int k = 1; k <= 12; k++)
                    {
                        at(45 + degrees * k / 12, x, y);
                        ToolDrag(x, y, false);
                    }
                    ToolRelease();
                }
                else
                {
                    zs::Log("dev: no ring at the point\n");
                }
            }
        }
        else if (verb == L"colors")
        {
            SetColorMode((int)number(0));
        }
        else if (verb == L"sim")
        {
            ToggleSimulated();
        }
        else if (verb == L"gaps")
        {
            SetGaps(number(0) != 0);
            zs::Log("dev: legend: %s\n", to_string(LegendText().Text()).c_str());
        }
        else if (verb == L"play")
        {
            TogglePlay();
        }
        else if (verb == L"scrub")
        {
            ScrubSlider().Value(number(0));
            zs::Log("dev: scrub: %s\n", to_string(ScrubText().Text()).c_str());
        }
        else if (verb == L"check")
        {
            FillCheck();
            zs::Log("dev: check rows %u\n", check_list.Children().Size());
            zs_issue const *issues = nullptr;
            size_t n = 0;
            char const *text = nullptr;
            if (zs_app_checks(model->Active(), &issues, &n, &text) == ZS_OK && n > 0)
            {
                zs::Log("dev: first issue: %.*s\n", (int)issues[0].text_len, text + issues[0].text_start);
                GoToIssue(issues[0]);
            }
        }
        else if (verb == L"dialog" && !words.empty())
        {
            if (words[0] == L"keys")
                ShowShortcuts();
            else if (words[0] == L"licenses")
                ShowLicenses();
            else
                ShowAbout();
        }
        else if (verb == L"menu")
        {
            // Opens the menu at x y and writes its items. With a third word
            // (_ for a space) it runs that item.
            ShowContextMenu(number(0), number(1));
            std::string names;
            for (auto const &item : context_actions)
                names += zs::ToUtf8(item.first) + " | ";
            zs::Log("dev: menu: %s\n", names.c_str());
            if (words.size() > 2)
            {
                std::wstring want = words[2];
                std::replace(want.begin(), want.end(), L'_', L' ');
                bool ran = false;
                for (auto const &item : context_actions)
                    if (item.first == want)
                    {
                        auto action = item.second;
                        action();
                        ran = true;
                        break;
                    }
                zs::Log("dev: menu item %s\n", ran ? "ran" : "not found");
            }
        }
        else if (verb == L"popups")
        {
            auto open = Microsoft::UI::Xaml::Media::VisualTreeHelper::GetOpenPopupsForXamlRoot(Content().XamlRoot());
            zs::Log("dev: open popups %u at %lu ms\n", open.Size(), ::GetTickCount());
            for (auto const &popup : open)
            {
                auto child = popup.Child().try_as<Microsoft::UI::Xaml::FrameworkElement>();
                zs::Log("dev: popup at %.0f,%.0f constrained %d child %.0fx%.0f opacity %.2f\n", popup.HorizontalOffset(),
                        popup.VerticalOffset(), popup.ShouldConstrainToRootBounds() ? 1 : 0, child ? child.ActualWidth() : -1.0,
                        child ? child.ActualHeight() : -1.0, child ? child.Opacity() : -1.0);
            }
        }
        else if (verb == L"copy" || verb == L"cut" || verb == L"paste" || verb == L"dup")
        {
            ClipKey(verb == L"copy" ? VirtualKey::C : verb == L"cut" ? VirtualKey::X : verb == L"paste" ? VirtualKey::V : VirtualKey::D, has(L"shift"));
        }
        else if (verb == L"bed")
        {
            ToggleBed();
        }
        else if (verb == L"hover")
        {
            if (hand)
                HandMove(number(0), number(1), false, false);
            else
                SupportPointer(number(0), number(1));
        }
        else if (verb == L"key" && !words.empty())
        {
            std::wstring const &name = words[0];
            VirtualKey key = static_cast<VirtualKey>(towupper(name[0]));
            if (name == L"Up")
                key = VirtualKey::Up;
            else if (name == L"Down")
                key = VirtualKey::Down;
            else if (name == L"Left")
                key = VirtualKey::Left;
            else if (name == L"Right")
                key = VirtualKey::Right;
            else if (name == L"Delete")
                key = VirtualKey::Delete;
            else if (name == L"Escape")
                key = VirtualKey::Escape;
            else if (name == L"Enter")
                key = VirtualKey::Enter;
            else if (name == L"Back")
                key = VirtualKey::Back;
            OnToolKey(key, has(L"shift"), false);
        }
        else if (verb == L"layer")
        {
            LayerSlider().Value(number(0));
        }
        else if (verb == L"shot" || verb == L"wait")
        {
            // A script outside waits for this line, and takes the picture.
        }
        else if (verb == L"undo")
        {
            AfterRestore(model->Undo());
        }
        else if (verb == L"redo")
        {
            AfterRestore(model->Redo());
        }
        else if (verb == L"orbit")
        {
            zs_view_orbit(view, (float)number(0), (float)number(1));
            RequestDraw();
        }
        else if (verb == L"zoom")
        {
            zs_view_zoom(view, (float)number(0));
            RequestDraw();
        }
        else if (verb == L"look" && words.size() >= 4)
        {
            zs_part p{};
            if (zs_app_part_get(model->Active(), 0, &p) == ZS_OK)
            {
                zs_view_look_at(view, (float)p.x, (float)p.y, (float)(p.size_z / 2), (float)number(0), (float)number(1), (float)number(2), (float)number(3));
                for (int k = 0; k < 200 && zs_view_animate(view, 0.05); k++)
                {
                }
                RequestDraw();
            }
        }
        else if (verb == L"press" && !words.empty())
        {
            std::wstring name = words[0];
            std::replace(name.begin(), name.end(), L'_', L' ');
            if (!PressNamed(name))
                zs::Log("dev: no button %s\n", zs::ToUtf8(name).c_str());
        }
        else if (verb == L"newplate")
        {
            // Part 0 goes to a new plate, and that plate becomes active.
            if (zs_set_part_move(model->Set(), model->ActivePlate(), 0, -1) >= 0)
            {
                PlateEdited();
                SelectPlate(model->PlateCount() - 1);
            }
        }
        else if (verb == L"plate")
        {
            SelectPlate((size_t)number(0));
        }
        else if (!RunPaintStep(verb, words) && !RunLabelStep(verb, words) && !RunFilamentStep(verb, words) && verb != L"log")
        {
            zs::Log("dev: a bad step: %s\n", zs::ToUtf8(step).c_str());
        }
        LogDevState(step);
        SupportDevLog();
    }
}

#endif
