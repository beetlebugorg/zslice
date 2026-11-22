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
        if (selected_path < 0 || zs_app_toolpaths(model->Active(), &tp) != ZS_OK || (size_t)selected_path >= tp.path_count)
            return false;
        uint32_t a = selected_path == 0 ? 0 : tp.path_ends[selected_path - 1], b = tp.path_ends[selected_path];
        if (b <= a)
            return false;
        uint32_t i = selected_segment >= 0 && a + (uint32_t)selected_segment + 1 < b
                         ? a + (uint32_t)selected_segment
                         : a + (b - a) / 2 - ((b - a) > 1 ? 1 : 0);
        uint32_t j = i + 1 < b ? i + 1 : i;
        x = (tp.points[2 * i] + tp.points[2 * j]) / 2;
        y = (tp.points[2 * i + 1] + tp.points[2 * j + 1]) / 2;
        size_t layer = 0;
        while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)selected_path)
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
    void MainWindow::CopyForAi()
    {
        zs_app *app = model->Active();
        uint8_t const *gcode = nullptr;
        size_t gcode_len = 0;
        if (selected_path >= 0 && model->IsDraft())
        {
            ShowToast(L"The exact slice runs. Try again when it is done.");
            return;
        }
        if (selected_path < 0 || zs_app_gcode(app, &gcode, &gcode_len) != ZS_OK)
            return;
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
        if (zs_app_line_report(app, (size_t)selected_path, zs::ToUtf8(file).c_str(), &report, &report_len) != ZS_OK)
            return;
        Windows::ApplicationModel::DataTransfer::DataPackage package;
        package.SetText(zs::ToWide(std::string(report, report_len)));
        Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(package);
        ShowToast(L"Copied a report of this line.");
    }

    void MainWindow::NewProfile(int direction)
    {
        zs_inspect info{};
        if (selected_path < 0 || zs_app_inspect(model->Active(), (size_t)selected_path, &info) != ZS_OK)
            return;
        double z_min = direction > 0 ? info.z : -1e6, z_max = direction > 0 ? 1e6 : info.z;
        char name[64];
        snprintf(name, sizeof name, direction > 0 ? "Layers %zu and up" : "Layers 1 to %zu", (size_t)info.layer + 1);
        if (zs_app_profile_set(model->Active(), z_min, z_max, name) == ZS_OK)
            ShowToast(zs::ToWide(std::string("New profile: ") + name));
    }

    // ---- copy and paste ----

    // The part of the selected line becomes the selection.
    bool MainWindow::SelectLinePart()
    {
        if (selected_path < 0)
            return !selected_parts.empty();
        ptrdiff_t part = zs_app_part_of_path(model->Active(), (size_t)selected_path);
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
        std::vector<size_t> parts(selected_parts.begin(), selected_parts.end());
        if (zs_app_parts_copy(model->Active(), parts.data(), parts.size(), 0) == ZS_OK)
            ShowToast(parts.size() == 1 ? hstring(L"Copied the part.") : hstring(L"Copied the parts."));
    }

    void MainWindow::CutParts()
    {
        if (!SelectLinePart())
        {
            ShowToast(L"Select a part first.");
            return;
        }
        zs_app *app = model->Active();
        std::vector<size_t> parts(selected_parts.begin(), selected_parts.end());
        if (zs_app_parts_copy(app, parts.data(), parts.size(), 0) != ZS_OK)
            return;
        // The last index first: a removal moves the parts after it.
        std::sort(parts.rbegin(), parts.rend());
        for (size_t part : parts)
            zs_app_part_remove(app, part);
        selected_parts.clear();
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
        for (int64_t part : std::vector<int64_t>(selected_parts))
        {
            ptrdiff_t copy = zs_app_part_duplicate(app, (size_t)part);
            if (copy >= 0)
                copies.push_back(copy);
        }
        if (copies.empty())
            return;
        selected_path = selected_segment = -1;
        selected_parts = copies;
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
        bool point = (here || selected_parts.empty()) &&
                     zs_view_bed_point(view, (float)(x * Scale()), (float)(y * Scale()), &bed_x, &bed_y) != 0;
        ptrdiff_t first = zs_app_parts_paste(app, point ? 1 : 0, bed_x, bed_y);
        if (first < 0)
        {
            ShowToast(L"The parts did not paste.");
            return;
        }
        selected_path = selected_segment = -1;
        selected_parts.clear();
        for (size_t k = 0; k < zs_clipboard_parts(); k++)
            selected_parts.push_back(first + (int64_t)k);
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

    bool MainWindow::ClipKey(VirtualKey key, bool shift)
    {
        if (key == VirtualKey::V)
        {
            if (shift)
            {
                if (!NewPlateFrom(nullptr))
                    ShowToast(L"The plate did not paste.");
            }
            else
            {
                PasteParts(false, pointer_x, pointer_y);
            }
            return true;
        }
        if (shift)
            return false;
        if (key == VirtualKey::C)
            CopyParts();
        else if (key == VirtualKey::X)
            CutParts();
        else if (key == VirtualKey::D)
            DuplicateParts();
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
        size_t clip = zs_clipboard_parts();

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
            return selected_path >= 0 ? zs_app_part_of_path(model->Active(), (size_t)selected_path) : -1;
        };
        auto place = [this, line_part](int mode, int axis) {
            ptrdiff_t part = line_part();
            if (part >= 0 && zs_app_part_place(model->Active(), (size_t)part, mode, axis) == ZS_OK)
                PlateEdited();
        };

        if (clip > 0)
            add(menu.Items(), L"Paste here", [this, x, y] { PasteParts(true, x, y); }, L"Ctrl+V");
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
                ptrdiff_t layer = selected_path >= 0 ? zs_app_path_layer(now, (size_t)selected_path) : -1;
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
                    ShowToast(L"Not all parts fit on the bed.");
                PlateEdited();
            });
            add(menu.Items(), L"Arrange the plate", [this] {
                if (zs_app_part_count(model->Active()) == 0)
                    return;
                if (!zs_app_plate_arrange(model->Active()))
                    ShowToast(L"Not all parts fit on the bed.");
                PlateEdited();
            });
            add(menu.Items(), L"Add models…", [this] { PickFile(); });
            add(menu.Items(), L"Clear the plate", [this] {
                ClearSelection();
                zs_app_plate_clear(model->Active());
                PlateEdited();
            });
            add(menu.Items(), L"Remove this plate", [this] {
                if (model->RemovePlate(model->ActivePlate()))
                    ShowPlate();
            });
            section();
            add(menu.Items(), L"Copy the plate", [this] {
                if (zs_app_part_count(model->Active()) == 0)
                    ShowToast(L"The plate has no parts to copy.");
                else if (zs_app_parts_copy(model->Active(), nullptr, 0, 1) == ZS_OK)
                    ShowToast(L"Copied the plate.");
            });
            add(menu.Items(), L"Duplicate the plate", [this] {
                if (!NewPlateFrom(model->Active()))
                    ShowToast(L"The plate has no parts to duplicate.");
            });
            if (clip > 0)
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
        if (selected_path < 0)
            return;
        ptrdiff_t layer = zs_app_path_layer(model->Active(), (size_t)selected_path);
        if (layer >= 0)
            LayerSlider().Value((double)layer + 1);
    }

    void MainWindow::ShowAllLayers()
    {
        if (layer_count > 0)
            LayerSlider().Value(LayerSlider().Maximum());
    }
}
