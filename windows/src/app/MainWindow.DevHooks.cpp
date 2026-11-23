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
// lturn deg, lwheel n, lswheel n, ldrag dx dy, lsdrag dx dy, laltdrag dx dy
// (with Alt), lhold dx dy (stays pressed), lrelease, lscale k (a corner
// handle), lsscale kx ky (with Shift), lturnh deg (the turn handle),
// lsturnh deg (with Shift), lhandleclick, lcursor, lsvg path, ldropsvg path
// dx dz, ldropsvg path away|card, lmode ink|raised|cut [mm], ldraw i, linfo,
// lflush, llog.
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
//   chrome path     writes the XAML chrome to a BMP file
//   search words, searchplace header|card|left|right, searchclose
//   searchkey down|up|left|right|v|enter|esc, searchlog
//   open file-or-link, linkok, plates
//   sumopen, sumshot path, sumlog, tipapply
//   dockw width, histsaved, histopen, histshot path, histrevert i,
//   histclear i, histlog, worklog, draftset name value, draftgo,
//   exportall, draftremove
//   ringview front|back|above, ringdrag axis degrees
//   curaopen [all], curaclose, curamenu, curamenupress, curaall 0|1,
//   curareload, curause i, curauseall, curascroll y, curasize w h,
//   curatheme light|dark, curashot path, curashot menu path, curalog
// Preferences, in MainWindow.Preferences.cpp:
//   prefmenu        opens the main menu, and writes its items
//   prefmenurun     runs its item Preferences
//   prefopen, prefclose, prefpage printers|general, preflog
//   prefpick i      selects printer i of the list
//   prefset name|url|serial|key value   an entry ('_' is a space)
//   prefkind i, preftheme i, prefview i, prefthreads n
//   prefdialog      opens the Keyboard shortcuts dialog
//   preflist NAME i selects row i of the list with this automation name
//   prefpopups      writes the theme of each open popup
// The project, in MainWindow.Project.cpp (plates and parts count from 1):
//   pjshow, pjhide, pjfolder path, pjgithub text, pjplate n, pjstatus n key,
//   pjcount n value, pjcheck n on|off, pjclose, pjscroll y, pjfile path,
//   pjmenu, pjactions, pjsum, pjlog
// The import of a profile, in MainWindow.Import.cpp (ZSLICE_IMPORT_FILE=path
// replaces the file dialog):
//   importmenu, importrun quality|printer|search, importfile path, importlog
// Calibration, in MainWindow.Calibrate.cpp ('_' is a space):
//   calmenu, calopen, calsub, calrun NAME, calfind LABEL, calshow, caluse i,
//   calclose, callog
//   popupshot i path   writes open popup i to a BMP file
//   qualityshot path   writes the open quality menu to a BMP file
// The range of layers, in MainWindow.Range.cpp (key K shift grows it):
//   rangelog, rangeclose, rangeadd, rangeset name value, rangereset name,
//   rangechip k, rangebody k, rangescope name, rangeshot path
// The Filament row of the line card: linefil k, lineext 1|-1, linefillog.
// The Speed section: speedshow, speedswitch, speedtry value, speedlog.
// Preferences:
// prefdraft 0// The layer profiles: profnew 1|-1, profopen i, profset name value,
// profclear name, profrename text, profdelete, profdone, profmark i, proflog.
|1, prefsimulate 0|1.
// A part that does not fit: fitlog, fitexport, fitissue.
// Spools of the printer: spoolread, spoolfollow file, spoollog, followlog.
// Test print: testprint 1|0. A run and the part card: runlog.
// What a setting changes: effectopen name, effectfeature f, effectlog.
// Import: miask [text], migo, mizip path, micheck i 0|1, miok, micancel, milog.
// Settings for: scopeset n, scopeedit name value, scopereset name, scopelog name.
// The print order of the part card: orderlog.
// Two nozzles: nozzleset i n, partfilament i k, settingspane 0|1, nozzlelog.
// Each step writes the state to the log (ZSLICE_LOG).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#ifdef ZS_DEV_HOOKS

#include <cmath>
#include <sstream>

#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Windows.Storage.Streams.h>
#include "Layer2D.h"

using namespace winrt;
using Windows::System::VirtualKey;

namespace
{
    // The text of a step for the log. A key of a test never goes there.
    std::string StepForLog(std::wstring const &step)
    {
        std::string text = zs::ToUtf8(step);
        return text.rfind("prefset key", 0) == 0 ? std::string("prefset key (hidden)") : text;
    }

    // Writes the XAML chrome to a BMP file. This works when the desktop does
    // not compose the window. The core's swapchains are not in the picture.
    winrt::fire_and_forget SaveChrome(Microsoft::UI::Xaml::UIElement root, std::wstring path)
    {
        Microsoft::UI::Xaml::Media::Imaging::RenderTargetBitmap bitmap;
        co_await bitmap.RenderAsync(root);
        auto pixels = co_await bitmap.GetPixelsAsync();
        int32_t w = bitmap.PixelWidth(), h = bitmap.PixelHeight();
        BITMAPINFOHEADER info{};
        info.biSize = sizeof info;
        info.biWidth = w;
        info.biHeight = -h;
        info.biPlanes = 1;
        info.biBitCount = 32;
        info.biCompression = BI_RGB;
        BITMAPFILEHEADER file{};
        file.bfType = 0x4D42;
        file.bfOffBits = sizeof file + sizeof info;
        file.bfSize = file.bfOffBits + pixels.Length();
        HANDLE out = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (out == INVALID_HANDLE_VALUE)
            co_return;
        DWORD written = 0;
        ::WriteFile(out, &file, sizeof file, &written, nullptr);
        ::WriteFile(out, &info, sizeof info, &written, nullptr);
        // The pixels have premultiplied alpha: they go over white.
        std::vector<uint8_t> flat(pixels.data(), pixels.data() + pixels.Length());
        for (size_t i = 0; i + 3 < flat.size(); i += 4)
        {
            int rest = 255 - flat[i + 3];
            for (int c = 0; c < 3; c++)
                flat[i + c] = (uint8_t)std::min(255, flat[i + c] + rest);
            flat[i + 3] = 255;
        }
        ::WriteFile(out, flat.data(), (DWORD)flat.size(), &written, nullptr);
        ::CloseHandle(out);
        zs::Log("dev: chrome %dx%d written\n", w, h);
    }
}

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
        zs::Log("dev: %s | tool %d path %lld seg %lld parts", StepForLog(step).c_str(), (int)tool,
                (long long)SelectedPath(), (long long)SelectedSegment());
        for (int64_t i : SelectedParts())
            zs::Log(" %lld", (long long)i);
        size_t count = zs_app_part_count(app);
        zs::Log(" | %zu part(s):", count);
        for (size_t i = 0; i < count && i < 4; i++)
        {
            zs_part p{};
            if (zs_app_part_get(app, i, &p) == ZS_OK)
                zs::Log(" (%.1f,%.1f rot %.0f size %.1fx%.1fx%.1f)", p.x, p.y, p.rotation, p.size_x, p.size_y, p.size_z);
        }
        zs::Log(" | falling %d measure %d | line card %d part card %d | layer %.0f | state %d\n", falling ? 1 : 0,
                measure_count, LineCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0,
                PartCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, LayerSlider().Value(), zs_app_state(app));
        if (MeasureCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible)
            zs::Log("dev: measure: %s\n", to_string(MeasureText().Text()).c_str());
    }

    // The steps of the printer dialogs. RunDevStep is at the limit of the
    // compiler for one chain of else-if.
    bool MainWindow::RunDialogStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb == L"pressbutton" && !words.empty())
        {
            // pressbutton Some_text: the first button with this text, in the
            // window or an open dialog, through its automation peer.
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::Button found{ nullptr };
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (found != nullptr)
                    return;
                if (auto b = at.try_as<Microsoft::UI::Xaml::Controls::Button>())
                {
                    auto text = b.Content().try_as<winrt::Windows::Foundation::IPropertyValue>();
                    if (text != nullptr && text.Type() == winrt::Windows::Foundation::PropertyType::String && std::wstring(text.GetString()) == want)
                        found = b;
                }
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n; i++)
                    walk(Tree::GetChild(at, i));
            };
            for (auto const &popup : Tree::GetOpenPopupsForXamlRoot(Content().XamlRoot()))
                if (popup.Child() != nullptr)
                    walk(popup.Child());
            walk(Root());
            // The peer throws for a disabled button.
            bool enabled = found != nullptr && found.IsEnabled();
            if (enabled)
                Microsoft::UI::Xaml::Automation::Peers::ButtonAutomationPeer(found).Invoke();
            zs::Log("dev: press '%s' %s\n", zs::ToUtf8(want).c_str(), enabled ? "done" : found != nullptr ? "disabled" : "not found");
        }
        else if (verb == L"appkey" && !words.empty())
        {
            VirtualKey key = words[0] == L"s" ? VirtualKey::S : words[0] == L"e" ? VirtualKey::E : words[0] == L"q" ? VirtualKey::Q : VirtualKey::F10;
            RunAppKey(key);
        }
        else if (verb == L"platemenu")
        {
            ShowPlateNameMenu();
        }
        else if (verb == L"placefail")
        {
            ShowPlaceFailed();
        }
        else if (verb == L"menulog")
        {
            for (auto const &entry : MainMenu().Items())
            {
                if (auto item = entry.try_as<Microsoft::UI::Xaml::Controls::MenuFlyoutItem>())
                    zs::Log("dev: menu '%s' [%s]\n", zs::ToUtf8(std::wstring(item.Text())).c_str(), zs::ToUtf8(std::wstring(item.KeyboardAcceleratorTextOverride())).c_str());
                else if (auto sub = entry.try_as<Microsoft::UI::Xaml::Controls::MenuFlyoutSubItem>())
                    zs::Log("dev: menu '%s' >\n", zs::ToUtf8(std::wstring(sub.Text())).c_str());
                else if (entry.try_as<Microsoft::UI::Xaml::Controls::MenuFlyoutSeparator>() != nullptr)
                    zs::Log("dev: menu ---\n");
            }
        }
        else if ((verb == L"dialogtype" || verb == L"dialoglog"))
        {
            // dialogtype text: into the first text box of the open dialog.
            // dialoglog: how many text blocks it shows, and one word to find.
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::TextBox box{ nullptr };
            size_t blocks = 0;
            bool none = false;
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (box == nullptr)
                    box = at.try_as<Microsoft::UI::Xaml::Controls::TextBox>();
                if (auto text = at.try_as<Microsoft::UI::Xaml::Controls::TextBlock>())
                {
                    blocks++;
                    none = none || std::wstring(text.Text()) == L"No shortcut matches.";
                }
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n; i++)
                    walk(Tree::GetChild(at, i));
            };
            for (auto const &popup : Tree::GetOpenPopupsForXamlRoot(Content().XamlRoot()))
                if (popup.Child() != nullptr)
                    walk(popup.Child());
            if (verb == L"dialoglog")
                zs::Log("dev: dialog blocks %zu no-match %d filter '%s'\n", blocks, none ? 1 : 0, box != nullptr ? zs::ToUtf8(std::wstring(box.Text())).c_str() : "-");
            else if (box != nullptr)
            {
                std::wstring value = words.empty() ? std::wstring{} : words[0];
                std::replace(value.begin(), value.end(), L'_', L' ');
                box.Text(value);
            }
        }
        else if (verb == L"keysheet")
        {
            ShowShortcuts();
        }
        else if (verb == L"pickeropen" && !words.empty())
        {
            printers->ShowPicker(words[0] == L"1");
        }
        else if (verb == L"panelesc")
        {
            if (!printers->panels.empty())
                printers->EscapePanel(printers->panels.back());
            zs::Log("dev: panels open %zu\n", printers->panels.size());
        }
        else if (verb == L"numberset" && words.size() >= 2)
        {
            // numberset Bed_width 220.6: a number box by its name.
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::NumberBox found{ nullptr };
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (found != nullptr)
                    return;
                auto b = at.try_as<Microsoft::UI::Xaml::Controls::NumberBox>();
                if (b != nullptr && std::wstring(Microsoft::UI::Xaml::Automation::AutomationProperties::GetName(b)) == want)
                    found = b;
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n; i++)
                    walk(Tree::GetChild(at, i));
            };
            walk(Root());
            if (found != nullptr)
            {
                found.Value(_wtof(words[1].c_str()));
                zs::Log("dev: number '%s' %.3f\n", zs::ToUtf8(want).c_str(), found.Value());
            }
            else
                zs::Log("dev: number '%s' not found\n", zs::ToUtf8(want).c_str());
        }
        else if (verb == L"listpick" && words.size() >= 2)
        {
            // listpick Name 3: the row of a list by the name of the list.
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::ListView found{ nullptr };
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (found != nullptr)
                    return;
                auto l = at.try_as<Microsoft::UI::Xaml::Controls::ListView>();
                if (l != nullptr && std::wstring(Microsoft::UI::Xaml::Automation::AutomationProperties::GetName(l)) == want)
                    found = l;
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n; i++)
                    walk(Tree::GetChild(at, i));
            };
            walk(Root());
            int row = _wtoi(words[1].c_str());
            if (found != nullptr && row >= 0 && (uint32_t)row < found.Items().Size())
                found.SelectedIndex(row);
            zs::Log("dev: list '%s' %s, %u rows\n", zs::ToUtf8(want).c_str(), found != nullptr ? "found" : "not found", found != nullptr ? found.Items().Size() : 0);
        }
        else if (verb == L"lostep" && !words.empty())
        {
            int n = _wtoi(words[0].c_str());
            for (int i = 0; i < std::abs(n); i++)
                StepLayerLo(n > 0 ? 1 : -1);
            zs::Log("dev: layer lo %zu of %zu\n", layer_lo, layer_count);
        }
        else if (verb == L"actionrun" && !words.empty())
        {
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            bool done = false;
            for (auto const &a : SearchActions())
                if (a.label == want)
                {
                    a.run();
                    done = true;
                    break;
                }
            zs::Log("dev: action '%s' %s\n", zs::ToUtf8(want).c_str(), done ? "ran" : "not found");
        }
        else if (verb == L"actionlog")
        {
            std::string all;
            for (auto const &a : SearchActions())
                all += zs::ToUtf8(a.label) + " | ";
            zs::Log("dev: actions %s\n", all.c_str());
        }
        else if (verb == L"viewlog")
        {
            zs::Log("dev: view 2d %d colors %d simulated %d item '%s' tool %d pref '%s'\n", show_2d ? 1 : 0, color_mode, simulated ? 1 : 0,
                    zs::ToUtf8(std::wstring(sim_item.Text())).c_str(), (int)tool, zs::Printers().Pref("colors", "-").c_str());
        }
        else if (verb == L"colorchoose" && !words.empty())
        {
            ChooseColorMode(_wtoi(words[0].c_str()));
        }
        else if (verb == L"panemode" && !words.empty())
        {
            SetPanelMode(static_cast<PanelMode>(_wtoi(words[0].c_str())));
        }
        else if (verb == L"panedrag" && !words.empty())
        {
            PanelDragTo(Root().ActualWidth() - _wtof(words[0].c_str()));
            PanelDragEnd();
        }
        else if (verb == L"paneesc")
        {
            zs::Log("dev: pane esc %d\n", PanelEscape() ? 1 : 0);
        }
        else if (verb == L"panestate")
        {
            zs::Log("dev: pane mode %d width %.0f actual %.0f view %.0f of %.0f visible %d pin %d | prefs %s %s %s\n", (int)panel_mode, SettingsPane().Width(), SettingsPane().ActualWidth(),
                    ViewPanel().ActualWidth(), Root().ActualWidth(), SettingsPane().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, SettingsPin().IsChecked().GetBoolean() ? 1 : 0,
                    zs::Printers().Pref("panel", "-").c_str(), zs::Printers().Pref("panel_pinned", "-").c_str(), zs::Printers().Pref("panel_width", "-").c_str());
        }
        else if (verb == L"sellog")
        {
            std::string ids, indices;
            if (sel != nullptr)
                for (size_t k = 0; k < zs_sel_count(sel.get()); k++)
                    ids += std::to_string(zs_sel_get(sel.get(), k)) + " ";
            for (int64_t i : SelectedParts())
                indices += std::to_string(i) + " ";
            zs_app *app = model->Active();
            std::string table;
            for (size_t i = 0, n = zs_app_part_count(app); i < n; i++)
                table += std::to_string(zs_app_part_id(app, i)) + " ";
            zs::Log("dev: sel ids [%s] indices [%s] primary %lld | parts [%s] plate %zu sel plate %zu tool %d\n", ids.c_str(), indices.c_str(), (long long)PrimaryPart(), table.c_str(),
                    model->ActivePlate(), sel != nullptr ? zs_sel_plate(sel.get()) : 0, sel != nullptr ? zs_sel_tool(sel.get()) : -1);
        }
        else if (verb == L"partremove" && !words.empty())
        {
            zs_app_part_remove(model->Active(), (size_t)_wtoi(words[0].c_str()));
            PlateEdited();
        }
        else if (verb == L"pickat" && words.size() >= 2)
        {
            int64_t part = PartAt(_wtof(words[0].c_str()), _wtof(words[1].c_str()), nullptr, nullptr);
            zs::Log("dev: pick at %s %s: part %lld\n", zs::ToUtf8(words[0]).c_str(), zs::ToUtf8(words[1]).c_str(), (long long)part);
            if (words.size() >= 3)
                SelectPart(part);
        }
        else if (verb == L"linelog")
        {
            uint64_t key = LineKeyForLog();
            int64_t path = SelectedPath();
            uint64_t now = path >= 0 ? zs_app_path_key(model->Active(), (size_t)path) : 0;
            zs::Log("dev: line path %lld seg %lld key %llu key of path %llu same %d line card %d\n", (long long)path, (long long)SelectedSegment(), (unsigned long long)key,
                    (unsigned long long)now, key != 0 && key == now ? 1 : 0, LineCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0);
        }
        else if (verb == L"gizdrag" && words.size() >= 2)
        {
            // gizdrag handle amount [shift]: a drag of a handle (0-2 ring, 3-5
            // arrow) from a point on it, in 12 steps. The amount is mm along
            // the arrow, or degrees for a ring.
            zs_part p{};
            int64_t part = PrimaryPart();
            if (part >= 0 && zs_app_part_get(model->Active(), (size_t)part, &p) == ZS_OK)
            {
                int handle = _wtoi(words[0].c_str());
                double amount = _wtof(words[1].c_str()), s = Scale();
                bool free = words.size() >= 3 && words[2] == L"shift";
                double radius = 0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4;
                double c[3] = { p.x, p.y, std::max(p.z, 0.0) + p.size_z / 2 };
                auto point_at = [&](double t, double &x, double &y) {
                    double q[3] = { c[0], c[1], c[2] };
                    if (handle >= 3)
                        q[handle - 3] += radius * 1.28 + amount * t;
                    else
                    {
                        double a = (33 + amount * t) * 3.14159265358979 / 180, u = radius * std::cos(a), v = radius * std::sin(a);
                        if (handle == 0) { q[1] += u; q[2] += v; }
                        else if (handle == 1) { q[0] += u; q[2] -= v; }
                        else { q[0] += u; q[1] += v; }
                    }
                    float px = 0, py = 0;
                    zs_view_pixel_of(view, q[0], q[1], q[2], &px, &py);
                    x = px / s;
                    y = py / s;
                };
                double x, y;
                point_at(0, x, y);
                press_x = last_x = x;
                press_y = last_y = y;
                int found = HandleAt(x, y);
                if (ToolPress(x, y, false))
                {
                    for (int k = 1; k <= 12; k++)
                    {
                        point_at(k / 12.0, x, y);
                        ToolDrag(x, y, free);
                    }
                    zs::Log("dev: gizmo handle %d found %d target %.2f %.2f %.2f want %.0f label '%s'\n", handle, found, live_target[0], live_target[1], live_target[2], turn_want,
                            zs::ToUtf8(std::wstring(DragLabelText().Text())).c_str());
                    ToolRelease();
                }
                else
                    zs::Log("dev: gizmo handle %d found %d: no press\n", handle, found);
            }
        }
        else if (verb == L"partdrag" && words.size() >= 3)
        {
            // partdrag i dx dy [shift]: a drag of part i by mm on the bed,
            // from the middle of its top. The log has what a pick finds at
            // the old and the new place during the drag.
            zs_app *app = model->Active();
            size_t index = (size_t)_wtoi(words[0].c_str());
            double dx = _wtof(words[1].c_str()), dy = _wtof(words[2].c_str()), s = Scale();
            bool free = words.size() >= 4 && words[3] == L"shift";
            zs_part p{};
            if (zs_app_part_get(app, index, &p) == ZS_OK)
            {
                double z = std::max(p.z, 0.0) + p.size_z * 0.6;
                auto at = [&](double t, double &x, double &y) {
                    float px = 0, py = 0;
                    zs_view_pixel_of(view, p.x + dx * t, p.y + dy * t, z, &px, &py);
                    x = px / s;
                    y = py / s;
                };
                double x0, y0, x, y;
                at(0, x0, y0);
                press_x = last_x = x0;
                press_y = last_y = y0;
                if (ToolPress(x0, y0, true))
                {
                    for (int k = 1; k <= 12; k++)
                    {
                        at(k / 12.0, x, y);
                        ToolDrag(x, y, free);
                    }
                    uint64_t at_old = zs_sel_pick(sel.get(), view, (float)(x0 * s), (float)(y0 * s));
                    uint64_t at_new = zs_sel_pick(sel.get(), view, (float)(x * s), (float)(y * s));
                    zs::Log("dev: body part id %llu target %.2f %.2f live %d group %zu | pick old place %llu new place %llu\n", (unsigned long long)zs_app_part_id(app, index), live_target[0],
                            live_target[1], live_on ? 1 : 0, move_group.size(), (unsigned long long)at_old, (unsigned long long)at_new);
                    ToolRelease();
                }
                else
                    zs::Log("dev: body: no press\n");
            }
        }
        else if (verb == L"handleclick" && words.size() >= 1)
        {
            // handleclick h: a press and a release on a handle of the
            // selected part. The click goes to the part under the pointer.
            zs_part p{};
            int64_t part = PrimaryPart();
            if (part >= 0 && zs_app_part_get(model->Active(), (size_t)part, &p) == ZS_OK)
            {
                int handle = _wtoi(words[0].c_str());
                double radius = 0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4, s = Scale();
                double q[3] = { p.x, p.y, std::max(p.z, 0.0) + p.size_z / 2 };
                q[handle - 3] += radius * 1.28;
                float px = 0, py = 0;
                zs_view_pixel_of(view, q[0], q[1], q[2], &px, &py);
                double x = px / s, y = py / s;
                press_x = last_x = x;
                press_y = last_y = y;
                int found = HandleAt(x, y);
                bool took = ToolPress(x, y, false);
                if (took)
                    ToolRelease();
                ToolClick(x, y, false, false);
                zs::Log("dev: handle click found %d took %d, under it part %lld, now primary %lld, turn %d live %d\n", found, took ? 1 : 0, (long long)PartAt(x, y, nullptr, nullptr),
                        (long long)PrimaryPart(), turn_axis, live_on ? 1 : 0);
            }
        }
        else if (verb == L"poselog")
        {
            zs_app *app = model->Active();
            std::string all;
            for (size_t i = 0, n = zs_app_part_count(app); i < n; i++)
            {
                zs_part p{};
                if (zs_app_part_get(app, i, &p) != ZS_OK)
                    continue;
                char row[120];
                snprintf(row, sizeof row, "[%llu: %.2f %.2f z %.2f rot %.0f a %.0f %.0f %.0f] ", (unsigned long long)zs_app_part_id(app, i), p.x, p.y, p.z, p.rotation, p.angle_x, p.angle_y, p.angle_z);
                all += row;
            }
            zs::Log("dev: pose %s falling %d live %d\n", all.c_str(), falling ? 1 : 0, live_on ? 1 : 0);
        }
        else if (verb == L"poseset" && words.size() >= 2)
        {
            int field = _wtoi(words[0].c_str());
            PoseBox(field).Text(words[1]);
            ApplyPose(field);
        }
        else if (verb == L"poseshow")
        {
            std::string all;
            for (int field = 0; field < 6; field++)
                all += zs::ToUtf8(std::wstring(PoseBox(field).Text())) + " ";
            zs::Log("dev: pose fields %s\n", all.c_str());
        }
        else if (verb == L"mirror" && !words.empty())
        {
            int64_t part = PrimaryPart();
            if (part >= 0 && zs_app_part_mirror(model->Active(), (size_t)part, _wtoi(words[0].c_str())) == ZS_OK)
                PlateEdited();
        }
        else if (verb == L"baselog")
        {
            double angle = 2 * std::acos(std::clamp(base_q[3], -1.0, 1.0)) * 180 / 3.14159265358979;
            zs::Log("dev: base on %d press %d angle %.1f gen %lld shown %lld fall shown %d\n", base_on ? 1 : 0, press_on ? 1 : 0, angle, (long long)base_gen, (long long)model->ShownGen(),
                    fall_shown ? 1 : 0);
        }
        else if (verb == L"twoturns" && words.size() >= 2)
        {
            // Two drags of the ring in one step: the slice of the first has
            // not come when the second starts.
            RunDialogStep(L"gizdrag", { words[0], words[1] });
            RunDialogStep(L"baselog", {});
            RunDialogStep(L"gizdrag", { words[0], words[1] });
            RunDialogStep(L"baselog", {});
        }
        else if (verb == L"manageopen")
        {
            printers->ShowManage();
        }
        else if (verb == L"filswitch" && !words.empty())
        {
            std::string material = zs::ToUtf8(words[0]);
            printers->AskSwitch(ZS_GROUP_FILAMENT, words[0], [this, material] {
                std::string message;
                printers->setup.UseMaterial(material, message);
                RefreshSettingValues();
                printers->RefreshBar();
            });
        }
        else if (verb == L"keylog")
        {
            // Whether a key is there. Its text never goes to a log.
            zs::SavedPrinter const &p = zs::Printers().Current();
            std::wstring file = zs::PrinterStore::SecretPath(p);
            zs::Log("dev: key kind %d url '%s' in memory %d on disk %d | material %s temp %s changed %d\n", (int)p.kind, p.url.c_str(), p.api_key.empty() ? 0 : 1,
                    !file.empty() && ::GetFileAttributesW(file.c_str()) != INVALID_FILE_ATTRIBUTES ? 1 : 0, model->GetSetting("filament.material").c_str(), model->GetSetting("filament.nozzle_temp").c_str(),
                    printers->setup.GroupChanged(ZS_GROUP_FILAMENT) ? 1 : 0);
        }
        else
        {
            return false;
        }
        return true;
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

        if (SupportDevStep(verb, words) || CuraDevStep(verb, words))
        {
        }
        else if (verb == L"curashot")
        {
            // curashot path, or curashot menu path for the open main menu.
            if (words.size() >= 2 && words[0] == L"menu")
            {
                auto popups = Microsoft::UI::Xaml::Media::VisualTreeHelper::GetOpenPopupsForXamlRoot(Content().XamlRoot());
                if (popups.Size() > 0)
                    SaveChrome(popups.GetAt(0).Child(), words[1]);
            }
            else if (auto root = CuraDevRoot(); root != nullptr && !words.empty())
            {
                SaveChrome(root, words[0]);
            }
        }
        else if (RunImportStep(verb, words) || RunCalibrateStep(verb, words))
        {
        }
        else if (verb == L"popupshot" && words.size() >= 2)
        {
            auto popups = Microsoft::UI::Xaml::Media::VisualTreeHelper::GetOpenPopupsForXamlRoot(Content().XamlRoot());
            uint32_t i = (uint32_t)number(0);
            zs::Log("dev: popups %u\n", popups.Size());
            if (i < popups.Size())
                SaveChrome(popups.GetAt(i).Child(), words[1]);
        }
        else if (verb == L"qualityshot" && !words.empty())
        {
            SaveChrome(printers->quality_flyout.Content(), words[0]);
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
            ToolClick(x, y, has(L"shift"), has(L"ctrl"));
        }
        else if (verb == L"drag")
        {
            double x0 = number(0), y0 = number(1), x1 = number(2), y1 = number(3);
            bool took = ToolPress(x0, y0, has(L"ctrl"));
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
            if (!SelectedParts().empty() && zs_app_part_get(model->Active(), (size_t)PrimaryPart(), &p) == ZS_OK)
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
        else if (verb == L"ringview" && !words.empty())
        {
            // The camera on the selected part: front, back, or above, a
            // little to the side, so that no ring shows as a line.
            zs_part p{};
            if (SelectedParts().empty())
                SelectPart(0);
            if (!SelectedParts().empty() && zs_app_part_get(model->Active(), (size_t)PrimaryPart(), &p) == ZS_OK)
            {
                float n[3] = { 0.40f, -0.80f, 0.45f };
                if (words[0] == L"back")
                {
                    n[0] = -0.36f;
                    n[1] = 0.80f;
                    n[2] = 0.48f;
                }
                else if (words[0] == L"above")
                {
                    n[0] = 0.15f;
                    n[1] = -0.30f;
                    n[2] = 0.94f;
                }
                double size = std::max({ p.size_x, p.size_y, p.size_z });
                zs_view_look_at(view, (float)p.x, (float)p.y, (float)(p.size_z / 2), n[0], n[1], n[2], (float)(size * 4 + 40));
                RequestDraw();
            }
        }
        else if (verb == L"ringdrag" && words.size() >= 2)
        {
            // ringdrag axis degrees: a drag on a ring along the path that
            // a point of the part takes in a right-hand turn of that many
            // degrees, as Plate.turn makes it. The log has the angle.
            zs_part p{};
            if (!SelectedParts().empty() && zs_app_part_get(model->Active(), (size_t)PrimaryPart(), &p) == ZS_OK)
            {
                int axis = (int)number(0);
                double degrees = number(1), s = Scale();
                double radius = 0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4, cz = p.size_z / 2;
                auto at = [&](double angle, double &x, double &y) {
                    float px = 0, py = 0;
                    double a = angle * 3.14159265358979 / 180, u = radius * std::cos(a), v = radius * std::sin(a);
                    if (axis == 0)
                        zs_view_pixel_of(view, p.x, p.y + u, cz + v, &px, &py);
                    else if (axis == 1)
                        zs_view_pixel_of(view, p.x + u, p.y, cz - v, &px, &py);
                    else
                        zs_view_pixel_of(view, p.x + u, p.y + v, cz, &px, &py);
                    x = px / s;
                    y = py / s;
                };
                double x = 0, y = 0;
                at(33, x, y);
                if (ToolPress(x, y, false) && pending_handle >= 0 && pending_handle < 3)
                {
                    press_x = x;
                    press_y = y;
                    int asked_handle = pending_handle;
                    pending_handle = -1;
                    GizmoStart(asked_handle, x, y);
                    int picked = turn_axis;
                    for (int k = 1; k <= 12; k++)
                    {
                        at(33 + degrees * k / 12, x, y);
                        ToolDrag(x, y, false);
                    }
                    zs::Log("dev: ring asked %d picked %d, drag %+.0f shows %+.0f, part rotation %.0f\n", axis, picked, degrees, turn_want, p.rotation);
                    ToolRelease();
                }
                else
                {
                    zs::Log("dev: ring asked %d, no ring at the point\n", axis);
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
        else if (verb == L"gapscan")
        {
            // The layer with the most gaps.
            size_t best = 0, most = 0, total = 0;
            for (size_t k = 0; k < layer_count; k++)
            {
                zs_gap const *found = nullptr;
                size_t n = 0;
                if (zs_app_layer_gaps(model->Active(), k, &found, &n, nullptr, nullptr) != ZS_OK)
                    continue;
                total += n;
                if (n > most)
                {
                    most = n;
                    best = k;
                }
            }
            zs::Log("dev: gapscan %zu gaps in all, most on layer %zu (%zu)\n", total, best + 1, most);
            if (most > 0)
                LayerSlider().Value((double)best + 1);
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
        else if (verb == L"2d")
        {
            Set2D(number(0) != 0);
        }
        else if (verb == L"pan2d" && layer2d != nullptr)
        {
            layer2d->Pan(number(0), number(1));
            RequestDraw();
        }
        else if (verb == L"zoom2d" && layer2d != nullptr)
        {
            layer2d->Zoom(number(0), number(1), number(2));
            RequestDraw();
        }
        else if (verb == L"time2d" && layer2d != nullptr)
        {
            // The cost of a frame, over 120 frames of a slow pan.
            LARGE_INTEGER freq, t0, t1;
            ::QueryPerformanceFrequency(&freq);
            ::QueryPerformanceCounter(&t0);
            for (int k = 0; k < 120; k++)
            {
                layer2d->Pan(k % 2 == 0 ? 1 : -1, 0);
                Draw2D();
            }
            ::QueryPerformanceCounter(&t1);
            zs::Log("dev: 2d frame %.2f ms\n", 1000.0 * (t1.QuadPart - t0.QuadPart) / freq.QuadPart / 120);
        }
        else if (verb == L"shot2d" && layer2d != nullptr && !words.empty())
        {
            layer2d->save_path = words[0];
            RequestDraw();
        }
        else if (verb == L"measurelog")
        {
            zs::Log("dev: tape %d points, card %d at %.0f,%.0f size %.0fx%.0f '%s'\n", measure_count, MeasureCard().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, Microsoft::UI::Xaml::Controls::Canvas::GetLeft(MeasureCard()),
                    Microsoft::UI::Xaml::Controls::Canvas::GetTop(MeasureCard()), MeasureCard().ActualWidth(), MeasureCard().ActualHeight(), to_string(MeasureText().Text()).c_str());
        }
        else if (verb == L"click2d")
        {
            Click2D(number(0), number(1), number(2) != 0);
        }
        else if (verb == L"theme")
        {
            // 0 follows the system, 1 light, 2 dark.
            int choice = (int)number(0);
            Root().RequestedTheme(choice == 2 ? Microsoft::UI::Xaml::ElementTheme::Dark : choice == 1 ? Microsoft::UI::Xaml::ElementTheme::Light : Microsoft::UI::Xaml::ElementTheme::Default);
        }
        else if (verb == L"chrome")
        {
            // chrome path.bmp: the XAML chrome alone, with no 3D view.
            if (!words.empty())
                SaveChrome(Root(), words[0]);
        }
        else if (verb == L"orderlog")
        {
            zs::Log("dev: part order shown %d '%s' earlier %d later %d, sequence %s\n", PartOrderRow().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0,
                    to_string(PartOrderText().Text()).c_str(), PartEarlier().IsEnabled() ? 1 : 0, PartLater().IsEnabled() ? 1 : 0,
                    model->GetSetting("project.print_sequence").c_str());
        }
        else if (verb == L"nozzleset" && words.size() >= 2)
        {
            // nozzleset i n: filament i prints with nozzle n (0 main, 1 second).
            int rc = zs_app_filament_set(model->Active(), (size_t)number(0), "filament.nozzle", zs::ToUtf8(words[1]).c_str());
            zs::Log("dev: nozzle of filament %d set: %d\n", (int)number(0), rc);
            model->RequestSlice();
        }
        else if (verb == L"partfilament" && words.size() >= 2)
        {
            // partfilament i k: part i prints with filament k.
            int rc = zs_app_part_setting_set(model->Active(), (size_t)number(0), "project.filament", zs::ToUtf8(words[1]).c_str());
            zs::Log("dev: nozzle test: part filament set: %d\n", rc);
            model->RequestSlice();
        }
        else if (verb == L"nozzlelog")
        {
            // The sections of the pane, and the title and limits of the line card.
            std::string sections;
            for (auto const &child : SettingsList().Children())
                if (auto row = child.try_as<Microsoft::UI::Xaml::Controls::Button>())
                {
                    std::wstring text{ unbox_value_or<hstring>(row.Content(), L"") };
                    if (text.find(L" nozzle (T") != std::wstring::npos)
                        sections += zs::ToUtf8(text) + "; ";
                }
            zs::Log("dev: nozzle count %s, sections page %d, nozzle sections '%s', filaments %s, line title '%s', limits '%s'\n", model->GetSetting("machine.nozzles").c_str(),
                    settings_page == SettingsPage::Sections ? 1 : 0, sections.c_str(), FilamentNozzleLog().c_str(), to_string(LineTitle().Text()).c_str(), to_string(LineNozzle().Text()).c_str());
        }
        else if (verb == L"settingspane")
        {
            ShowSettingsPane(number(0) != 0);
        }
        else if (verb == L"speedshow")
        {
            ShowSettingsPane(true);
            ShowSection("speed", "Speed");
        }
        else if (verb == L"speedswitch")
        {
            if (speed_toggle != nullptr)
                speed_toggle.IsOn(!speed_toggle.IsOn());
        }
        else if (verb == L"speedtry" && !words.empty())
        {
            // A change, and whether its slice is a draft.
            CommitSetting("project.infill_density", zs::ToUtf8(words[0]));
            zs::Log("dev: speed try: is draft %d\n", zs_app_is_draft(model->Active()));
        }
        else if (verb == L"speedlog")
        {
            std::string values;
            for (size_t i = 0, n = zs_speed_count(); i < n; i++)
            {
                zs_speed_option option{};
                if (zs_speed_get(i, &option) == ZS_OK)
                    values += std::string(option.name) + "=" + model->GetSetting(option.name) + " ";
            }
            zs::Log("dev: speed state %d, is draft %d, switch %d, rows %u, draft '%s' pref '%s', simulate '%s' pref '%s', history %zu pending %d | %s\n", zs_app_speed_state(model->Active()), zs_app_is_draft(model->Active()),
                    speed_toggle != nullptr && speed_toggle.IsOn() ? 1 : 0, SettingsList().Children().Size(), model->GetSetting("engine.draft_slices").c_str(),
                    zs::Printers().Pref("engine.draft_slices").c_str(), model->GetSetting("engine.auto_simulate").c_str(), zs::Printers().Pref("engine.auto_simulate").c_str(),
                    zs_app_history_current(model->Active()), zs_app_history_pending(model->Active()), values.c_str());
        }
        else if (verb == L"rangeshot")
        {
            // rangeshot path.bmp: the card of the range alone.
            if (!words.empty())
                SaveChrome(RangeDevRoot(), words[0]);
        }
        else if (verb == L"search")
        {
            // search <words>: types them in the search. No words opens it.
            std::wstring text;
            for (auto const &w : words)
                text += (text.empty() ? L"" : L" ") + w;
            OpenSearch(true);
            ActiveSearchEntry().Text(text);
        }
        else if (verb == L"searchplace")
        {
            std::wstring at = words.empty() ? L"header" : words[0];
            SetSearchPlace(at == L"card" ? SearchPlace::Card : at == L"left" ? SearchPlace::Left : at == L"right" ? SearchPlace::Right : SearchPlace::Header);
        }
        else if (verb == L"draftset" && words.size() >= 2)
        {
            // draftset name value: a change, and the timer of the exact
            // slice stops, so the view keeps the draft for a look.
            std::string error;
            model->SetSetting(zs::ToUtf8(words[0]).c_str(), zs::ToUtf8(words[1]), error);
            settle_timer.Stop();
        }
        else if (verb == L"spoolread")
        {
            printers->ReadSpools();
        }
        else if (verb == L"spoolfollow" && !words.empty())
        {
            // spoolfollow file: a status of the printer with these spools.
            std::string json, message;
            if (zs::Model::ReadFile(words[0], json))
            {
                bool changed = printers->setup.FilamentsFromPrinter("Test printer", json, 2, message);
                if (changed)
                {
                    FilamentsChanged();
                    PlateEdited();
                    RefreshSettingValues();
                }
                zs::Log("dev: spool follow changed %d '%s'\n", changed ? 1 : 0, message.c_str());
            }
        }
        else if (verb == L"effectopen" && !words.empty())
        {
            ShowSettingsPane(true);
            detail_from = SettingsPage::Sections;
            ShowDetail(zs::ToUtf8(words[0]).c_str());
        }
        else if (verb == L"fieldtype" || verb == L"fieldfocus" || verb == L"fieldkey" || verb == L"fieldlog" || verb == L"fieldleave")
        {
            // The first field of the open setting page.
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::TextBox found{ nullptr };
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (auto box = at.try_as<Microsoft::UI::Xaml::Controls::TextBox>(); box != nullptr && found == nullptr)
                    found = box;
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n && found == nullptr; i++)
                    walk(Tree::GetChild(at, i));
            };
            walk(SettingsList());
            if (found == nullptr)
                zs::Log("dev: field none\n");
            else if (verb == L"fieldfocus")
                found.Focus(Microsoft::UI::Xaml::FocusState::Programmatic);
            else if (verb == L"fieldleave")
                ViewPanel().Focus(Microsoft::UI::Xaml::FocusState::Programmatic);
            else if (verb == L"fieldtype")
                found.Text(words.empty() ? L"" : words[0]);
            else if (verb == L"fieldlog" && !words.empty())
            {
                auto tip = Microsoft::UI::Xaml::Controls::ToolTipService::GetToolTip(found).try_as<winrt::Windows::Foundation::IPropertyValue>();
                std::wstring text = tip != nullptr ? std::wstring(tip.GetString()) : L"";
                std::replace(text.begin(), text.end(), L'\n', L' ');
                zs::Log("dev: field shows '%s' core '%s' formula '%s' history %zu tip '%s'\n", to_string(found.Text()).c_str(), model->GetSetting(zs::ToUtf8(words[0]).c_str()).c_str(), model->Formula(zs::ToUtf8(words[0]).c_str()).c_str(),
                        zs_app_history_count(model->Active()), zs::ToUtf8(text.substr(0, 62)).c_str());
            }
        }
        else if (verb == L"fieldstep" && words.size() >= 2 && made_field != nullptr)
        {
            // fieldstep name steps [fine]: as the arrow keys do.
            zs_setting_info info{};
            bool known = false;
            for (size_t i = 0, n = zs_setting_count(); i < n && !known; i++)
                known = zs_setting_get_info(i, &info) == ZS_OK && zs::ToUtf8(words[0]) == info.name;
            if (known)
                StepField(*made_field, info, std::wstring(made_field->box.Text()), _wtof(words[1].c_str()), words.size() > 2, 150);
        }
        else if (verb == L"fieldslide" && !words.empty())
        {
            // fieldslide v: the slider of the page moves to v.
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::Slider found{ nullptr };
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (auto slider = at.try_as<Microsoft::UI::Xaml::Controls::Slider>(); slider != nullptr && found == nullptr)
                    found = slider;
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n && found == nullptr; i++)
                    walk(Tree::GetChild(at, i));
            };
            walk(SettingsList());
            if (found != nullptr)
                found.Value(_wtof(words[0].c_str()));
            zs::Log("dev: field slider %d value %.3f of %.3f to %.3f step %.3f\n", found != nullptr ? 1 : 0, found != nullptr ? found.Value() : 0.0, found != nullptr ? found.Minimum() : 0.0, found != nullptr ? found.Maximum() : 0.0,
                    found != nullptr ? found.StepFrequency() : 0.0);
        }
        else if (verb == L"textround")
        {
            // A multi-line field goes back to the core with no edit.
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::TextBox found{ nullptr };
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (auto box = at.try_as<Microsoft::UI::Xaml::Controls::TextBox>(); box != nullptr && box.AcceptsReturn() && found == nullptr)
                    found = box;
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n; i++)
                    walk(Tree::GetChild(at, i));
            };
            walk(SettingsList());
            zs_setting_info info{};
            bool known = false;
            for (size_t i = 0, n = zs_setting_count(); !words.empty() && i < n && !known; i++)
                known = zs_setting_get_info(i, &info) == ZS_OK && zs::ToUtf8(words[0]) == info.name;
            if (found != nullptr && known)
            {
                std::wstring shown{ found.Text() };
                std::string before = model->GetSetting(info.name);
                size_t steps = zs_app_history_count(model->Active());
                CommitSettingText(info, shown, PaneTarget().get());
                std::string after = model->GetSetting(info.name);
                zs::Log("dev: textround field CR %zu LF %zu | core before LF %zu CR %zu, after LF %zu CR %zu, same %d, history +%zu\n", std::count(shown.begin(), shown.end(), L'\r'), std::count(shown.begin(), shown.end(), L'\n'),
                        std::count(before.begin(), before.end(), '\n'), std::count(before.begin(), before.end(), '\r'), std::count(after.begin(), after.end(), '\n'), std::count(after.begin(), after.end(), '\r'), before == after ? 1 : 0,
                        zs_app_history_count(model->Active()) - steps);
            }
            else
                zs::Log("dev: textround found no field\n");
        }
        else if (verb == L"panehistory")
        {
            PaneHistoryBack();
        }
        else if (verb == L"panescroll")
        {
            if (!words.empty())
                SettingsScroll().ChangeView(nullptr, box_value(number(0)).as<winrt::Windows::Foundation::IReference<double>>(), nullptr, true);
        }
        else if (verb == L"panelog")
        {
            std::wstring path{ SettingsCrumbs().Text() };
            zs::Log("dev: pane path '%s' page %d back %d scroll %.0f history %zu rows %u\n", zs::ToUtf8(path).c_str(), (int)settings_page, SettingsBack().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0,
                    SettingsScroll().VerticalOffset(), pane_history.size(), SettingsList().Children().Size());
        }
        else if (verb == L"partsel")
        {
            // partsel i j: these parts are the selection.
            SetSelectedLine(-1, -1);
            std::vector<int64_t> chosen;
            for (size_t k = 0; k < words.size(); k++)
                chosen.push_back(_wtoi(words[k].c_str()));
            SetSelectedParts(chosen);
            FillPartCard();
        }
        else if (verb == L"scalefocus")
        {
            PartScale().Focus(Microsoft::UI::Xaml::FocusState::Programmatic);
        }
        else if (verb == L"scaletype" && !words.empty())
        {
            PartScale().Text(words[0]);
        }
        else if (verb == L"scaleleave")
        {
            ViewPanel().Focus(Microsoft::UI::Xaml::FocusState::Programmatic);
        }
        else if (verb == L"partslog")
        {
            std::string text;
            for (size_t i = 0, n = zs_app_part_count(model->Active()); i < n; i++)
            {
                zs_part p{};
                if (zs_app_part_get(model->Active(), i, &p) == ZS_OK)
                {
                    char one[64];
                    snprintf(one, sizeof one, " %zu:%.3f", i, p.scale_x);
                    text += one;
                }
            }
            zs::Log("dev: parts plates %zu active %zu scales%s | shown '%s' edits %zu marks %zu areas %zu history %zu\n", model->PlateCount(), model->ActivePlate(), text.c_str(), to_string(PartScale().Text()).c_str(),
                    zs_app_edit_count(model->Active()), zs_app_mark_count(model->Active()), zs_app_support_area_count(model->Active()), zs_app_history_count(model->Active()));
        }
        else if (verb == L"plateask")
        {
            AskRemovePlate();
        }
        else if (verb == L"plategone")
        {
            RemovePlateAt(model->ActivePlate());
        }
        else if (verb == L"plateclear")
        {
            ClearPlate();
        }
        else if (verb == L"addfiles" && !words.empty())
        {
            // addfiles a;b is not possible in a step: each word is a path.
            LoadPaths(std::vector<std::wstring>(words.begin(), words.end()));
        }
        else if (verb == L"platelog")
        {
            std::string ids;
            for (auto const &id : refine_ids)
                ids += (ids.empty() ? "" : ",") + (id.empty() ? std::string("-") : id.substr(0, 4));
            zs_plate_info info{};
            zs_set_plate_info(model->Set(), model->ActivePlate(), &info);
            zs::Log("dev: plates %zu active %zu parts %zu name '%s' title '%s' refine [%s] history %zu of %zu\n", model->PlateCount(), model->ActivePlate(), zs_app_part_count(model->Active()), info.name != nullptr ? info.name : "",
                    to_string(FileName().Text()).c_str(), ids.c_str(), zs_app_history_current(model->Active()), zs_app_history_count(model->Active()));
        }
        else if (verb == L"paneback")
        {
            SettingsGoBack();
        }
        else if (verb == L"panetext" && !words.empty())
        {
            // As typing in the search of the pane.
            SettingsSearch().Text(words[0]);
        }
        else if (verb == L"rowmore" && !words.empty())
        {
            // A press on the arrow of row i, through its automation peer.
            int want = _wtoi(words[0].c_str()), seen = 0;
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            Microsoft::UI::Xaml::Controls::Button found{ nullptr };
            std::function<void(Node const &)> walk = [&](Node const &at) {
                if (auto b = at.try_as<Microsoft::UI::Xaml::Controls::Button>(); b != nullptr && b.Content().try_as<Microsoft::UI::Xaml::Controls::FontIcon>() != nullptr && seen++ == want)
                    found = b;
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n && found == nullptr; i++)
                    walk(Tree::GetChild(at, i));
            };
            walk(SettingsList());
            if (found != nullptr)
                Microsoft::UI::Xaml::Automation::Peers::ButtonAutomationPeer(found).Invoke();
            zs::Log("dev: rowmore %d\n", found != nullptr ? 1 : 0);
        }
        else if (verb == L"panesection" && !words.empty())
        {
            // The first section of a group, in the settings pane.
            std::string group = zs::ToUtf8(words[0]);
            ShowSettingsPane(true);
            for (size_t i = 0, n = zs_setting_count(); i < n; i++)
            {
                zs_setting_info info{};
                if (zs_setting_get_info(i, &info) == ZS_OK && group == info.group)
                {
                    ShowSection(info.group, info.section);
                    break;
                }
            }
        }
        else if (verb == L"panesearch" && !words.empty())
        {
            ShowSettingsPane(true);
            settings_query = words[0];
            ShowSearch(words[0]);
        }
        else if (verb == L"effectfeature" && !words.empty())
        {
            ShowFeature(_wtoi(words[0].c_str()));
        }
        else if (verb == L"effectlog")
        {
            zs::Log("dev: effect hint %d lines %u page %d crumb '%s' rows %u focus %u first %d on %d\n", EmptyHint().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, effect_box != nullptr ? effect_box.Children().Size() : 0, (int)settings_page, to_string(SettingsCrumb().Text()).c_str(), SettingsList().Children().Size(), pane_focus,
                    pane_focus_first ? 1 : 0, pane_focus_on ? 1 : 0);
        }
        else if (verb == L"testprint")
        {
            printers->ExportTestPrint(number(0) != 0);
        }
        else if (verb == L"runlog")
        {
            zs::Log("dev: run edits %zu lit %d others %zu path %lld key %d layer %zu | float '%s' | file box %d '%s'\n", zs_app_edit_count(model->Active()), run_lit ? 1 : 0, run_others, (long long)SelectedPath(), LineKeyForLog() != 0 ? 1 : 0, line_key_layer,
                    to_string(PartFloatNote().Text()).c_str(), PartFileBox().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, to_string(PartFileText().Text()).substr(0, 70).c_str());
        }
        else if (verb == L"followlog")
        {
            zs::Log("dev: follow links %zu closing %zu reading %d asleep %d timer %d current kind %d\n", printers->bambu_links.size(), printers->bambu_closing.size(),
                    printers->follow_reading ? 1 : 0, printers->follow_asleep ? 1 : 0, printers->follow_timer != nullptr && printers->follow_timer.IsRunning() ? 1 : 0,
                    (int)zs::Printers().Current().kind);
        }
        else if (verb == L"spoollog")
        {
            std::string list;
            zs_app *app = model->Active();
            for (size_t i = 0, n = zs_app_filament_count(app); i < n; i++)
            {
                char hand[8] = "", slot[16] = "";
                zs_app_filament_get(app, i, "source.hand", hand, sizeof hand, nullptr);
                zs_app_filament_get(app, i, "source.slot", slot, sizeof slot, nullptr);
                list += "[" + FilamentValue(i, "filament.material") + " " + FilamentValue(i, "filament.color") + " slot " + slot + " hand " + hand + "] ";
            }
            zs::Log("dev: spools %s| note '%s' reading %d nozzle %s %s\n", list.c_str(), zs::ToUtf8(printers->filament_note).c_str(), printers->reading_filaments ? 1 : 0,
                    model->GetSetting("machine.nozzle_type").c_str(), model->GetSetting("machine.nozzle_flow").c_str());
        }
        else if (verb == L"fitexport")
        {
            printers->ExportGcode();
        }
        else if (verb == L"fitissue")
        {
            zs_issue const *issues = nullptr;
            size_t n = 0;
            char const *text = nullptr;
            if (zs_app_checks(model->Active(), &issues, &n, &text) == ZS_OK)
                for (size_t i = 0; i < n; i++)
                    if (issues[i].kind == ZS_ISSUE_FIT)
                    {
                        GoToIssue(zs_issue(issues[i]));
                        break;
                    }
        }
        else if (verb == L"fitlog")
        {
            zs_app *app = model->Active();
            uint8_t const *g = nullptr;
            size_t len = 0;
            int gcode = zs_app_gcode(app, &g, &len);
            zs_issue const *issues = nullptr;
            size_t n = 0, fit = 0;
            char const *text = nullptr;
            int checks = zs_app_checks(app, &issues, &n, &text);
            if (checks == ZS_OK)
                for (size_t i = 0; i < n; i++)
                    fit += issues[i].kind == ZS_ISSUE_FIT ? 1 : 0;
            printers->FillSendMenu();
            std::string menu;
            for (auto const &item : printers->send_menu.Items())
                if (auto entry = item.try_as<Microsoft::UI::Xaml::Controls::MenuFlyoutItem>())
                    menu += to_string(entry.Text()) + (entry.IsEnabled() ? "=on " : "=off ");
            zs::Log("dev: fit refusal '%s' | state %d gcode rc %d len %zu | export on %d | fit issues %zu of %zu | parts selected %zu | menu %s\n", zs::ToUtf8(PlateRefusal(app)).c_str(),
                    zs_app_state(app), gcode, gcode == ZS_OK ? len : 0, ExportButton().IsEnabled() ? 1 : 0, fit, n, SelectedParts().size(), menu.c_str());
        }
        else if (verb == L"exportall")
        {
            printers->ExportAll();
        }
        else if (verb == L"draftremove")
        {
            // A change, and its plate goes before the timer of the exact
            // slice ends.
            std::string error;
            model->SetSetting("project.wall_count", "5", error);
            if (model->RemovePlate(model->ActivePlate()))
                ShowPlate();
        }
        else if (verb == L"draftgo")
        {
            model->Settle();
        }
        else if (verb == L"worklog")
        {
            zs::Log("dev: work kind %d, draft %d, slicing draft %d, bar %.2f value %.2f, text '%s' %.1f, export %d\n", work_kind, model->IsDraft() ? 1 : 0, model->SlicesDraft() ? 1 : 0,
                    WorkBar().Opacity(), WorkBar().Value(), to_string(WorkText().Text()).c_str(), WorkText().Opacity(), ExportButton().IsEnabled() ? 1 : 0);
        }
        else if (verb == L"dockw")
        {
            LayoutDock(number(0));
        }
        else if (verb == L"histsaved")
        {
            MarkHistorySaved();
        }
        else if (verb == L"histopen")
        {
            HistoryFlyout().ShowAt(HistoryButton());
        }
        else if (verb == L"histshot")
        {
            if (!words.empty())
                SaveChrome(HistoryFlyout().Content(), words[0]);
        }
        else if (verb == L"histrevert")
        {
            // histrevert i: undoes the first change of step i alone.
            zs_history_step step{};
            if (zs_app_history_step(model->Active(), (size_t)number(0), &step) == ZS_OK && step.changes != nullptr)
            {
                std::string all(step.changes, step.changes_len);
                RevertChange(all.substr(0, all.find('\n')));
            }
        }
        else if (verb == L"histchange")
        {
            // histchange i: opens the first change of step i.
            zs_history_step step{};
            if (zs_app_history_step(model->Active(), (size_t)number(0), &step) == ZS_OK && step.changes != nullptr)
            {
                std::string all(step.changes, step.changes_len);
                std::string line = all.substr(0, all.find('\n'));
                zs::Log("dev: histchange line '%s'\n", line.substr(0, 60).c_str());
                OpenHistoryChange((size_t)number(0), line);
            }
            zs::Log("dev: histchange page %d crumb '%s' scope %lld profile %d %.2f %.2f detail '%s'\n", (int)settings_page, to_string(SettingsCrumb().Text()).c_str(), (long long)settings_scope, in_profile ? 1 : 0,
                    profile_min, profile_max, settings_detail.c_str());
        }
        else if (verb == L"histclear")
        {
            ClearHistoryAfter((size_t)number(0));
        }
        else if (verb == L"histlog")
        {
            zs_app *app = model->Active();
            zs_history_step step{};
            size_t now = zs_app_history_current(app);
            std::string words_now;
            if (zs_app_history_step(app, now, &step) == ZS_OK && step.text != nullptr)
                words_now.assign(step.text, step.text_len);
            std::replace(words_now.begin(), words_now.end(), '\t', ':');
            std::replace(words_now.begin(), words_now.end(), '\n', '|');
            zs::Log("dev: history %zu steps, now %zu '%s', unsaved %zu, badge '%s' shown %d, dock h %.0f view h %.0f, list rows %u, walls %s\n", zs_app_history_count(app), now,
                    words_now.c_str(), UnsavedChanges(), to_string(HistoryCountText().Text()).c_str(), HistoryCount().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, Dock().ActualHeight(), ViewPanel().ActualHeight(), HistoryList().Children().Size(),
                    model->GetSetting("project.wall_count").c_str());
        }
        else if (verb == L"sumopen")
        {
            SummaryFlyout().ShowAt(SummaryButton());
        }
        else if (verb == L"sumclose")
        {
            SummaryFlyout().Hide();
        }
        else if (verb == L"sumshot")
        {
            // sumshot path.bmp: the open details of the print.
            if (!words.empty())
                SaveChrome(SummaryFlyout().Content(), words[0]);
        }
        else if (verb == L"sumlog")
        {
            zs::Log("dev: details rows %u, badge '%s' shown %d, took '%s', warn %d '%s', buttons %u, tips %zu\n", SummaryFacts().Children().Size(),
                    to_string(SummaryBadgeText().Text()).c_str(), SummaryBadge().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0,
                    to_string(SummaryTook().Text()).c_str(), SummaryWarnBox().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0,
                    to_string(SummaryWarn().Text()).c_str(), SummaryWarnButtons().Children().Size(), refine_tips.size());
            for (auto const &tip : refine_tips)
                zs::Log("dev: tip %s: %s (%d)\n", zs::ToUtf8(tip.where).c_str(), zs::ToUtf8(tip.what).c_str(), tip.count);
        }
        else if (verb == L"tipapply")
        {
            if (!refine_tips.empty())
                ApplyRefine(RefineTip(refine_tips[0]));
        }
        else if (verb == L"open")
        {
            // open <file or zslice link>: as if Windows started the app.
            if (!words.empty())
                OpenExternal(words[0]);
        }
        else if (verb == L"linkok")
        {
            zs::Log("dev: link answer %d\n", PressNamed(L"Download and open") ? 1 : 0);
        }
        else if (verb == L"plates")
        {
            zs::Log("dev: plates %zu active %zu parts %zu state %d\n", model->PlateCount(), model->ActivePlate(),
                    zs_app_part_count(model->Active()), (int)zs_app_state(model->Active()));
        }
        else if (verb == L"searchclose")
        {
            CloseSearch();
        }
        else if (verb == L"searchkey")
        {
            // searchkey down|up|left|right|v|enter|esc: the key on a row.
            std::wstring k = words.empty() ? L"" : words[0];
            auto key = k == L"down" ? VirtualKey::Down : k == L"up" ? VirtualKey::Up : k == L"left" ? VirtualKey::Left : k == L"right" ? VirtualKey::Right : k == L"v" ? VirtualKey::V : k == L"enter" ? VirtualKey::Enter : VirtualKey::Escape;
            SearchKeyPress(key, false);
        }
        else if (verb == L"searchlog")
        {
            // The settings of the later nozzles in the list, and the last one.
            size_t nozzle_rows = 0;
            int last_nozzle = 0;
            for (auto const &row : search_rows)
                if (row.name.rfind("machine.nozzle.", 0) == 0)
                {
                    nozzle_rows++;
                    last_nozzle = std::max(last_nozzle, atoi(row.name.c_str() + 15));
                }
            zs::Log("dev: search nozzle rows %zu, last nozzle %d\n", nozzle_rows, last_nozzle);
            auto box = SearchBox();
            zs::Log("dev: search open %d place %d rows %zu index %d eye '%s' text '%s' box %.0f,%.0f %.0fx%.0f header field %d button %d\n",
                    search_open ? 1 : 0, (int)search_place, search_rows.size(), search_index, search_eye.c_str(), zs::ToUtf8(search_text).c_str(),
                    Microsoft::UI::Xaml::Controls::Canvas::GetLeft(box), Microsoft::UI::Xaml::Controls::Canvas::GetTop(box), box.ActualWidth(), box.ActualHeight(),
                    SearchField().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0,
                    SearchOpen().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0);
            if (search_index >= 0 && (size_t)search_index < search_rows.size() && !search_rows[(size_t)search_index].name.empty())
                zs::Log("dev: search row %s = %s\n", search_rows[(size_t)search_index].name.c_str(), model->GetSetting(search_rows[(size_t)search_index].name.c_str()).c_str());
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
        else if (verb == L"clipprivate")
        {
            clip_private = true;
        }
        else if (verb == L"pointer")
        {
            pointer_x = number(0);
            pointer_y = number(1);
        }
        else if (verb == L"focusedit")
        {
            // The first switch of the settings list gets the focus.
            using Node = Microsoft::UI::Xaml::DependencyObject;
            using Tree = Microsoft::UI::Xaml::Media::VisualTreeHelper;
            std::function<bool(Node const &)> focus_first = [&](Node const &at) -> bool {
                if (auto toggle = at.try_as<Microsoft::UI::Xaml::Controls::ToggleSwitch>())
                    return toggle.Focus(Microsoft::UI::Xaml::FocusState::Programmatic);
                for (int32_t i = 0, n = Tree::GetChildrenCount(at); i < n; i++)
                    if (focus_first(Tree::GetChild(at, i)))
                        return true;
                return false;
            };
            zs::Log("dev: clip focused a switch %d\n", focus_first(SettingsList()) ? 1 : 0);
        }
        else if (verb == L"camlog")
        {
            auto image = SummaryCameraBox().Child().try_as<Microsoft::UI::Xaml::Controls::Image>();
            zs::Log("dev: details camera shown %d picture %d (%.0fx%.0f) note %d line '%s'\n", SummaryCamera().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, image != nullptr && image.Source() != nullptr ? 1 : 0, image != nullptr ? image.ActualWidth() : 0.0,
                    image != nullptr ? image.ActualHeight() : 0.0, SummaryCameraNote().Visibility() == Microsoft::UI::Xaml::Visibility::Visible ? 1 : 0, to_string(SummaryCameraLine().Text()).c_str());
        }
        else if (verb == L"cliplog")
        {
            zs_app *clip_app = model->Active();
            size_t label_chars = 0;
            std::string label_json;
            if (zs_app_part_count(clip_app) > 0 && zs_app_part_labels_get(clip_app, 0, nullptr, 0, &label_chars) == ZS_OK && label_chars > 0)
            {
                label_json.resize(label_chars + 1);
                zs_app_part_labels_get(clip_app, 0, label_json.data(), label_json.size(), &label_chars);
            }
            size_t labels = 0;
            for (size_t at = label_json.find("\"origin\""); at != std::string::npos; at = label_json.find("\"origin\"", at + 1))
                labels++;
            zs::Log("dev: clip kind %d sel %d range %zu label chars %zu value '%s' editor '%s' now '%s' | areas %zu labels %zu overrides %zu parts %zu\n", (int)ClipNow(), (int)ClipSelection(), clip_range.size(), clip_label.size(), clip_value.c_str(),
                    FocusedEditor() ? focused_editor->name.c_str() : "", FocusedEditor() ? focused_editor->get().c_str() : "", zs_app_support_area_count(clip_app), labels, zs_app_override_count(clip_app), zs_app_part_count(clip_app));
        }
        else if (verb == L"bed")
        {
            ToggleBed();
        }
        else if (verb == L"hover")
        {
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
            else if (name == L"PageUp")
                key = VirtualKey::PageUp;
            else if (name == L"PageDown")
                key = VirtualKey::PageDown;
            OnToolKey(key, has(L"shift"), has(L"ctrl"));
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
        else if (!RunSelectedStep(verb, words) && !RunDialogStep(verb, words) && !RunPaintStep(verb, words) && !RunLabelStep(verb, words) && !RunFilamentStep(verb, words) &&
                 !RunPreferencesStep(verb, words) && !RunProjectStep(verb, words) && !RunRangeStep(verb, words) && !RunProfileStep(verb, words) && !RunScopeStep(verb, words) && !RunModelImportStep(verb, words) && verb != L"log")
        {
            zs::Log("dev: a bad step: %s\n", StepForLog(step).c_str());
        }
        LogDevState(step);
        SupportDevLog();
    }
}

#endif
