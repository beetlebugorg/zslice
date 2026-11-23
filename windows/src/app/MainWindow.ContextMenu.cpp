// The menu of the view, and copy, cut, paste, and duplicate of parts.
//
// The menu fits what is under the pointer: a support line, a line of a part,
// or the bed. Its items and their order follow the GTK shell
// (linux/src/ui/view3d.c). The clipboard of parts is in the core, so a paste
// works on each plate.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#include <algorithm>
#include <cstdio>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using Windows::System::VirtualKey;

namespace winrt::ZSlice::implementation
{
    // The place of the selected segment, in mm.
    bool MainWindow::MenuPlace(double &x, double &y, double &z)
    {
        zs_toolpaths tp{};
        if (SelectedPath() < 0 || zs_app_toolpaths(model->Active(), &tp) != ZS_OK || (size_t)SelectedPath() >= tp.path_count)
            return false;
        uint32_t a = SelectedPath() == 0 ? 0 : tp.path_ends[SelectedPath() - 1], b = tp.path_ends[SelectedPath()];
        if (b <= a)
            return false;
        uint32_t i = SelectedSegment() >= 0 && a + (uint32_t)SelectedSegment() + 1 < b
                         ? a + (uint32_t)SelectedSegment()
                         : a + (b - a) / 2 - ((b - a) > 1 ? 1 : 0);
        uint32_t j = i + 1 < b ? i + 1 : i;
        x = (tp.points[2 * i] + tp.points[2 * j]) / 2;
        y = (tp.points[2 * i + 1] + tp.points[2 * j + 1]) / 2;
        size_t layer = 0;
        while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)SelectedPath())
            layer++;
        z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
        return true;
    }

    void MainWindow::SupportEdited()
    {
        NoteChange();
        model->RequestSlice();
        // The Support tool keeps a copy of the areas.
        SupportReload();
    }

    // A block area over the overhang that the support line holds up, and no
    // marks of the user near the line.
    void MainWindow::RemoveSupportHere()
    {
        zs_app *app = model->Active();
        double x, y, z;
        if (!MenuPlace(x, y, z))
            return;
        bool changed = zs_app_mark_remove_near(app, x, y, z, 3) > 0;
        zs_toolpaths tp{};
        double top = zs_app_toolpaths(app, &tp) == ZS_OK && tp.layer_count > 0 ? tp.layer_z[tp.layer_count - 1] : z;
        constexpr size_t max_points = 256;
        std::vector<double> points(3 * max_points);
        double lo = 0, hi = 0;
        size_t n = 0;
        for (double up = z; up <= top + 0.5; up += 0.5)
        {
            if (zs_app_support_pick(app, x, y, up, 2, points.data(), max_points, &n, &lo, &hi) >= 0 && n >= 3)
            {
                if (zs_app_support_area_add(app, 3, points.data(), n, lo, hi) >= 0)
                    changed = true;
                break;
            }
        }
        if (changed)
            SupportEdited();
        else
            ShowToast(L"Found no overhang over this support.");
    }

    // The G-code to a file, and a report of the line to the clipboard, to
    // paste into an AI chat.
    void MainWindow::CopyForAi(wchar_t const *done)
    {
        zs_app *app = model->Active();
        uint8_t const *gcode = nullptr;
        size_t gcode_len = 0;
        if (SelectedPath() >= 0 && model->IsDraft())
        {
            ShowToast(L"The exact slice runs. Try again when it is done.");
            return;
        }
        if (SelectedPath() < 0)
            return;
        if (zs_app_gcode(app, &gcode, &gcode_len) != ZS_OK)
        {
            std::wstring refusal = PlateRefusal(app);
            if (!refusal.empty())
                ShowToast(refusal);
            return;
        }
        std::wstring file = zs::StateDir() + L"\\last-slice.gcode";
        FILE *out = nullptr;
        if (_wfopen_s(&out, file.c_str(), L"wb") == 0 && out != nullptr)
        {
            if (fwrite(gcode, 1, gcode_len, out) != gcode_len)
                zs::Log("shell: the G-code was not saved for the report\n");
            fclose(out);
        }
        char const *report = nullptr;
        size_t report_len = 0;
        if (zs_app_line_report(app, (size_t)SelectedPath(), zs::ToUtf8(file).c_str(), &report, &report_len) != ZS_OK)
            return;
        Windows::ApplicationModel::DataTransfer::DataPackage package;
        package.SetText(zs::ToWide(std::string(report, report_len)));
        if (!clip_private)
            Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(package);
        ShowToast(done);
    }

    void MainWindow::NewProfile(int direction)
    {
        zs_inspect info{};
        if (SelectedPath() < 0 || zs_app_inspect(model->Active(), (size_t)SelectedPath(), &info) != ZS_OK)
            return;
        double z_min = direction > 0 ? info.z : -1e6, z_max = direction > 0 ? 1e6 : info.z;
        char name[64];
        snprintf(name, sizeof name, direction > 0 ? "Layers %zu and up" : "Layers 1 to %zu", (size_t)info.layer + 1);
        if (zs_app_profile_set(model->Active(), z_min, z_max, name) != ZS_OK)
            return;
        NoteChange();
        OpenProfile(z_min, z_max);
        RefreshSettingValues();
    }

    // ---- copy and paste ----

    // The part of the selected line becomes the selection.
    bool MainWindow::SelectLinePart()
    {
        if (SelectedPath() < 0)
            return !SelectedParts().empty();
        ptrdiff_t part = zs_app_part_of_path(model->Active(), (size_t)SelectedPath());
        if (part < 0)
            return false;
        SelectPart(part);
        return true;
    }

    void MainWindow::CopyParts()
    {
        if (!SelectLinePart())
        {
            ShowToast(L"Select a part first.");
            return;
        }
        std::vector<int64_t> chosen = SelectedParts();
        std::vector<size_t> parts(chosen.begin(), chosen.end());
        if (zs_app_parts_copy(model->Active(), parts.data(), parts.size(), 0) == ZS_OK)
        {
            clip_kind = ClipKind::Parts;
            ShowToast(parts.size() == 1 ? std::wstring(L"Copied the part.") : L"Copied " + std::to_wstring(parts.size()) + L" parts.");
        }
    }

    void MainWindow::CutParts()
    {
        if (!SelectLinePart())
        {
            ShowToast(L"Select a part first.");
            return;
        }
        zs_app *app = model->Active();
        std::vector<int64_t> chosen = SelectedParts();
        std::vector<size_t> parts(chosen.begin(), chosen.end());
        if (zs_app_parts_copy(app, parts.data(), parts.size(), 0) != ZS_OK)
            return;
        clip_kind = ClipKind::Parts;
        ShowToast(parts.size() == 1 ? std::wstring(L"Cut the part. Ctrl+V pastes it.") : L"Cut " + std::to_wstring(parts.size()) + L" parts. Ctrl+V pastes them.");
        // The last index first: a removal moves the parts after it.
        std::sort(parts.rbegin(), parts.rend());
        for (size_t part : parts)
            zs_app_part_remove(app, part);
        SetSelectedParts({});
        HideCards();
        PlateEdited();
    }

    void MainWindow::DuplicateParts()
    {
        if (!SelectLinePart())
        {
            ShowToast(L"Select a part first.");
            return;
        }
        zs_app *app = model->Active();
        std::vector<int64_t> copies;
        for (int64_t part : SelectedParts())
        {
            ptrdiff_t copy = zs_app_part_duplicate(app, (size_t)part);
            if (copy >= 0)
                copies.push_back(copy);
        }
        if (copies.empty())
            return;
        SetSelectedLine(-1, -1);
        SetSelectedParts(copies);
        PlateEdited();
    }

    void MainWindow::PasteParts(bool here, double x, double y)
    {
        if (zs_clipboard_parts() == 0)
        {
            ShowToast(L"The clipboard is empty: copy a part first.");
            return;
        }
        zs_app *app = model->Active();
        double bed_x = 0, bed_y = 0;
        bool point = (here || SelectedParts().empty()) &&
                     zs_view_bed_point(view, (float)(x * Scale()), (float)(y * Scale()), &bed_x, &bed_y) != 0;
        ptrdiff_t first = zs_app_parts_paste(app, point ? 1 : 0, bed_x, bed_y);
        if (first < 0)
        {
            ShowToast(L"The parts did not paste.");
            return;
        }
        SetSelectedLine(-1, -1);
        std::vector<int64_t> pasted;
        for (size_t k = 0; k < zs_clipboard_parts(); k++)
            pasted.push_back(first + (int64_t)k);
        SetSelectedParts(pasted);
        PlateEdited();
        if (zs_app_plate_fits(app) != 1)
            ShowToast(L"The parts do not all fit on the bed. Move some to another plate.");
    }

    // A new plate with a copy of `from`, or with the clipboard.
    bool MainWindow::NewPlateFrom(zs_app *from)
    {
        if (from == nullptr ? zs_clipboard_parts() == 0 : zs_app_part_count(from) == 0)
            return false;
        if (!model->AddPlate())
            return false;
        zs_app *app = model->Active();
        ptrdiff_t first = from != nullptr ? zs_app_plate_copy_to(from, app) : zs_app_parts_paste(app, 0, 0, 0);
        ShowPlate();
        if (first < 0)
            return false;
        PlateEdited();
        return true;
    }

    // The kind of the last copy. Parts can be in the core from a copy of
    // the plate.
    MainWindow::ClipKind MainWindow::ClipNow() const
    {
        return clip_kind == ClipKind::Empty && zs_clipboard_parts() > 0 ? ClipKind::Parts : clip_kind;
    }

    bool MainWindow::FocusedEditor()
    {
        if (!focused_editor.has_value())
            return false;
        auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
        if (focused == focused_editor->element)
            return true;
        focused_editor.reset();
        return false;
    }

    // What a copy takes now, as in web/app/clipboard.js.
    MainWindow::ClipSel MainWindow::ClipSelection()
    {
        if (FocusedEditor())
            return ClipSel::Value;
        if (tool == Tool::Label && LabelHasSelection())
            return ClipSel::Label;
        if (tool == Tool::Support && SupportHasArea())
            return ClipSel::Area;
        if (RangeOpen())
            return ClipSel::Range;
        if (!SelectedParts().empty())
            return ClipSel::Parts;
        return SelectedPath() >= 0 ? ClipSel::Line : ClipSel::None;
    }

    bool MainWindow::ClipCopy(ClipSel sel)
    {
        switch (sel)
        {
        case ClipSel::Value:
        {
            clip_value = focused_editor->get();
            clip_kind = ClipKind::Value;
            if (!clip_private)
            {
                Windows::ApplicationModel::DataTransfer::DataPackage package;
                package.SetText(zs::ToWide(clip_value));
                Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(package);
            }
            ShowToast(L"Copied the value.");
            return true;
        }
        case ClipSel::Label:
        {
            std::string json = LabelCopyJson();
            if (json.empty())
                return false;
            clip_label = std::move(json);
            clip_kind = ClipKind::Label;
            ShowToast(L"Copied the label.");
            return true;
        }
        case ClipSel::Area:
            if (!SupportCopyArea(clip_area))
                return false;
            clip_kind = ClipKind::Area;
            ShowToast(L"Copied the support area.");
            return true;
        case ClipSel::Range:
        {
            auto changes = RangeChangesNow();
            if (changes.empty())
            {
                ShowToast(L"These layers have no changes to copy.");
                return false;
            }
            ShowToast(L"Copied " + std::to_wstring(changes.size()) + (changes.size() == 1 ? L" change" : L" changes") + L" of the layers.");
            clip_range = std::move(changes);
            clip_kind = ClipKind::Range;
            return true;
        }
        case ClipSel::Parts:
            CopyParts();
            return true;
        case ClipSel::Line:
            CopyForAi(L"The report of the line is on the clipboard.");
            return true;
        default:
            ShowToast(L"Select a part, a label, a support area, or layers to copy.");
            return false;
        }
    }

    // A copy, then the selection goes. A setting and a line stay.
    void MainWindow::ClipCut()
    {
        ClipSel sel = ClipSelection();
        switch (sel)
        {
        case ClipSel::Label:
            if (ClipCopy(sel))
                LabelRemoveSelected();
            break;
        case ClipSel::Area:
            if (ClipCopy(sel))
                SupportRemoveArea();
            break;
        case ClipSel::Range:
            if (ClipCopy(sel))
                RangeClearChanges(clip_range);
            break;
        case ClipSel::Parts:
            CutParts();
            break;
        default:
            ClipCopy(sel);
            break;
        }
    }

    // A copy next to the selection. The clipboard stays.
    void MainWindow::ClipDuplicate()
    {
        ClipSel sel = ClipSelection();
        if (sel == ClipSel::Parts)
        {
            DuplicateParts();
        }
        else if (sel == ClipSel::Label)
        {
            std::string json = LabelCopyJson();
            if (!json.empty())
                LabelPaste(json, false, 0, 0);
        }
        else
        {
            ShowToast(L"Ctrl+D duplicates parts and labels.");
        }
    }

    // The text of the system clipboard goes into the setting with the
    // focus. A copy of a value put it there too.
    winrt::fire_and_forget MainWindow::PasteValue()
    {
        if (!FocusedEditor())
            co_return;
        ClipEditor editor = *focused_editor;
        auto keep = get_strong();
        std::wstring text;
        if (clip_private)
        {
            text = zs::ToWide(clip_value);
        }
        else
        {
            try
            {
                auto clip = Windows::ApplicationModel::DataTransfer::Clipboard::GetContent();
                if (!clip.Contains(Windows::ApplicationModel::DataTransfer::StandardDataFormats::Text()))
                    co_return;
                hstring got = co_await clip.GetTextAsync();
                text = got;
            }
            catch (winrt::hresult_error const &)
            {
                co_return;
            }
        }
        size_t from = text.find_first_not_of(L" \t\r\n");
        if (from == std::wstring::npos)
            co_return;
        text = text.substr(from, text.find_last_not_of(L" \t\r\n") - from + 1);
        std::string value = zs::ToUtf8(text);
        // The core rules. A text that is not a number goes as it is, and
        // the core refuses it with its own message.
        size_t len = 0;
        if (zs_setting_parse(editor.name.c_str(), value.c_str(), nullptr, 0, &len) == ZS_OK)
        {
            std::string parsed(len + 1, '\0');
            if (zs_setting_parse(editor.name.c_str(), value.c_str(), parsed.data(), parsed.size(), &len) == ZS_OK)
            {
                parsed.resize(len);
                value = std::move(parsed);
            }
        }
        editor.set(value);
        RefreshSettingValues();
    }

    // at: x, y is a place for it (the pointer, or the right click). here:
    // at x, y also with parts selected. as_plate: parts go on a new plate.
    void MainWindow::ClipPaste(bool at, double x, double y, bool here, bool as_plate)
    {
        bool in_view = at && !show_2d && x >= 0 && y >= 0 && x < ViewPanel().ActualWidth() && y < ViewPanel().ActualHeight();
        switch (ClipNow())
        {
        case ClipKind::Parts:
            if (as_plate)
            {
                if (!NewPlateFrom(nullptr))
                    ShowToast(L"The plate did not paste.");
            }
            else
            {
                PasteParts(here, x, y);
            }
            break;
        case ClipKind::Label:
            if (show_2d)
                ShowToast(L"Paste a label in the 3D view.");
            else
                LabelPaste(clip_label, in_view, x, y);
            break;
        case ClipKind::Area:
            if (!in_view || !SupportPasteArea(clip_area, x, y))
                ShowToast(L"Point at a part to paste the support area there.");
            else
                ShowToast(L"Pasted the support area.");
            break;
        case ClipKind::Range:
            if (!RangeOpen())
                ShowToast(L"Select layers first (drag up or down over the print), then paste the changes.");
            else
                RangePaste(clip_range);
            break;
        case ClipKind::Value:
            ShowToast(L"Click a setting, then paste the value into it.");
            break;
        default:
            ShowToast(L"The clipboard is empty: copy a part, a label, a support area, or layers first.");
            break;
        }
    }

    bool MainWindow::ClipKey(VirtualKey key, bool shift)
    {
        if (key == VirtualKey::V)
        {
            if (FocusedEditor())
                PasteValue();
            else
                ClipPaste(true, pointer_x, pointer_y, false, shift);
            return true;
        }
        if (shift)
            return false;
        if (key == VirtualKey::C)
            ClipCopy(ClipSelection());
        else if (key == VirtualKey::X)
            ClipCut();
        else if (key == VirtualKey::D)
            ClipDuplicate();
        else
            return false;
        return true;
    }

    // ---- the menu ----

    void MainWindow::ShowContextMenu(double x, double y)
    {
        if (model == nullptr || view == nullptr)
            return;
        zs_app *app = model->Active();
        size_t segment = 0;
        size_t picked = zs_view_pick_segment(view, (float)(x * Scale()), (float)(y * Scale()), &segment);
        // The menu is for what is under the pointer. The bed clears the
        // selection.
        if (picked != (size_t)-1)
            SelectLine((int64_t)picked, (int64_t)segment);
        else
            ClearSelection();

        bool on_support = false;
        zs_toolpaths tp{};
        if (picked != (size_t)-1 && zs_app_toolpaths(app, &tp) == ZS_OK && picked < tp.path_count)
            on_support = tp.path_features[picked] == ZS_FEATURE_SUPPORT || tp.path_features[picked] == ZS_FEATURE_SUPPORT_INTERFACE;
        bool on_part = picked != (size_t)-1 && !on_support;
        bool marks = zs_app_mark_count(app) > 0;
        bool cut = layer_count > 0 && LayerSlider().Value() < LayerSlider().Maximum();
        ClipKind clip = ClipNow();

        MenuFlyout menu;
        using Items = Windows::Foundation::Collections::IVector<MenuFlyoutItemBase>;
#ifdef ZS_DEV_HOOKS
        context_actions.clear();
#endif
        auto add = [this](Items const &items, hstring const &text, std::function<void()> action, hstring const &keys = L"") {
            MenuFlyoutItem item;
            item.Text(text);
            if (!keys.empty())
                item.KeyboardAcceleratorTextOverride(keys);
            item.Click([action](auto &&, auto &&) { action(); });
            items.Append(item);
#ifdef ZS_DEV_HOOKS
            context_actions.emplace_back(std::wstring(text), action);
#endif
        };
        // A line goes between two groups of items.
        auto section = [&menu] {
            if (menu.Items().Size() > 0)
                menu.Items().Append(MenuFlyoutSeparator{});
        };
        auto mark = [this](int kind) {
            double px, py, pz;
            if (MenuPlace(px, py, pz) && zs_app_mark_add(model->Active(), px, py, pz, 3, kind) == ZS_OK)
                SupportEdited();
        };
        auto remove_marks = [this] {
            double px, py, pz;
            if (MenuPlace(px, py, pz) && zs_app_mark_remove_near(model->Active(), px, py, pz, 3) > 0)
                SupportEdited();
        };
        auto line_part = [this]() -> ptrdiff_t {
            return SelectedPath() >= 0 ? zs_app_part_of_path(model->Active(), (size_t)SelectedPath()) : -1;
        };
        auto place = [this, line_part](int mode, int axis) {
            ptrdiff_t part = line_part();
            if (part >= 0 && zs_app_part_place(model->Active(), (size_t)part, mode, axis) == ZS_OK)
                PlateEdited();
        };

        if (clip != ClipKind::Empty)
            add(menu.Items(), L"Paste here", [this, x, y] { ClipPaste(true, x, y, true, false); }, L"Ctrl+V");
        if (on_support)
        {
            section();
            add(menu.Items(), L"Remove this support", [this] { RemoveSupportHere(); });
            if (marks)
                add(menu.Items(), L"Remove the support marks here", remove_marks);
        }
        if (picked != (size_t)-1)
        {
            section();
            add(menu.Items(), L"Preview to this layer", [this] { PreviewToLine(); }, L"C");
            add(menu.Items(), L"Copy for AI", [this] { CopyForAi(); });
        }
        if (on_part)
        {
            section();
            MenuFlyoutSubItem kinds;
            kinds.Text(L"Add support here");
            add(kinds.Items(), L"Grid", [mark] { mark(0); });
            add(kinds.Items(), L"Tree", [mark] { mark(1); });
            add(kinds.Items(), L"Bridge (a pad)", [mark] { mark(2); });
            menu.Items().Append(kinds);
            add(menu.Items(), L"Block support here", [mark] { mark(3); });
            if (marks)
                add(menu.Items(), L"Remove the support marks here", remove_marks);
            add(menu.Items(), L"Add a drop of plastic here", [this, x, y] {
                double point[3];
                zs_app *now = model->Active();
                ptrdiff_t layer = SelectedPath() >= 0 ? zs_app_path_layer(now, (size_t)SelectedPath()) : -1;
                if (layer < 0 || !zs_view_surface_point(view, (float)(x * Scale()), (float)(y * Scale()), 0, point))
                    return;
                if (zs_app_edit_add_dot(now, (size_t)layer, point[0], point[1], 1.0) == ZS_OK)
                {
                    ClearSelection();
                    PlateEdited();
                }
            });
            section();
            add(menu.Items(), L"New profile from here up", [this] { NewProfile(1); });
            add(menu.Items(), L"New profile from here down", [this] { NewProfile(-1); });
            section();
            add(menu.Items(), L"Copy the part", [this] { CopyParts(); }, L"Ctrl+C");
            add(menu.Items(), L"Cut the part", [this] { CutParts(); }, L"Ctrl+X");
            add(menu.Items(), L"Duplicate the part", [this] { DuplicateParts(); }, L"Ctrl+D");
            section();
            add(menu.Items(), L"Put this side on the bed", [this, line_part] {
                double px, py, pz;
                ptrdiff_t part = line_part();
                if (part >= 0 && MenuPlace(px, py, pz) && zs_app_part_put_down_at(model->Active(), (size_t)part, px, py, pz) == ZS_OK)
                    PlateEdited();
            });
            MenuFlyoutSubItem modes;
            modes.Text(L"Placement");
            add(modes.Items(), L"Smart placement", [place] { place(ZS_PLACE_SMART, 0); });
            add(modes.Items(), L"Less support", [place] { place(ZS_PLACE_LESS_SUPPORT, 0); });
            add(modes.Items(), L"Strong along X of the part", [place] { place(ZS_PLACE_STRENGTH, 0); });
            add(modes.Items(), L"Strong along Y of the part", [place] { place(ZS_PLACE_STRENGTH, 1); });
            add(modes.Items(), L"Strong along Z of the part", [place] { place(ZS_PLACE_STRENGTH, 2); });
            menu.Items().Append(modes);
        }
        if (picked == (size_t)-1)
        {
            section();
            add(menu.Items(), L"Smart placement", [this] {
                if (zs_app_part_count(model->Active()) == 0)
                    return;
                if (!zs_app_plate_smart_place(model->Active()))
                    ShowPlaceFailed();
                PlateEdited();
            });
            add(menu.Items(), L"Arrange the plate", [this] {
                if (zs_app_part_count(model->Active()) == 0)
                    return;
                if (!zs_app_plate_arrange(model->Active()))
                    ShowPlaceFailed();
                PlateEdited();
            });
            add(menu.Items(), L"Add models…", [this] { PickFile(); });
            add(menu.Items(), L"Import from a model page…", [this] { AskImport({}); });
            add(menu.Items(), L"Clear the plate", [this] { ClearPlate(); });
            add(menu.Items(), L"Remove this plate", [this] { AskRemovePlate(); });
            section();
            add(menu.Items(), L"Copy the plate", [this] {
                if (zs_app_part_count(model->Active()) == 0)
                    ShowToast(L"The plate has no parts to copy.");
                else if (zs_app_parts_copy(model->Active(), nullptr, 0, 1) == ZS_OK)
                {
                    clip_kind = ClipKind::Parts;
                    ShowToast(L"Copied the plate.");
                }
            });
            add(menu.Items(), L"Duplicate the plate", [this] {
                if (!NewPlateFrom(model->Active()))
                    ShowToast(L"The plate has no parts to duplicate.");
            });
            if (clip == ClipKind::Parts)
                add(menu.Items(), L"Paste as a new plate", [this] {
                    if (!NewPlateFrom(nullptr))
                        ShowToast(L"The plate did not paste.");
                }, L"Ctrl+Shift+V");
        }
        section();
        if (marks)
            add(menu.Items(), L"Clear all support marks", [this] {
                zs_app_marks_clear(model->Active());
                SupportEdited();
            });
        if (cut)
            add(menu.Items(), L"Show all layers", [this] { ShowAllLayers(); }, L"Shift+C");
        add(menu.Items(), L"Test print: the top layer…", [this] {
            if (printers != nullptr)
                printers->ExportTestPrint(true);
        });
        if (cut)
            add(menu.Items(), L"Test print: the layers shown…", [this] {
                if (printers != nullptr)
                    printers->ExportTestPrint(false);
            });
        add(menu.Items(), L"Reset the view", [this] {
            zs_view_reset_smooth(view);
            StartAnimation();
            RequestDraw();
        });

        Controls::Primitives::FlyoutShowOptions options;
        options.Position(Windows::Foundation::Point{ (float)x, (float)y });
        menu.Closed([this](auto &&, auto &&) { ViewPanel().Focus(FocusState::Programmatic); });
        // The window holds the menu while it is open.
        context_menu = menu;
        menu.ShowAt(ViewPanel(), options);
    }

    // C: the view stops at the layer of the selected line.
    void MainWindow::PreviewToLine()
    {
        if (SelectedPath() < 0)
            return;
        ptrdiff_t layer = zs_app_path_layer(model->Active(), (size_t)SelectedPath());
        if (layer >= 0)
            LayerSlider().Value((double)layer + 1);
    }

    void MainWindow::ShowAllLayers()
    {
        if (layer_count > 0)
            LayerSlider().Value(LayerSlider().Maximum());
    }
}
