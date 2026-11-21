// The plates of the main window: the bar, the signs, and the switch of the
// active plate. The behavior follows the GTK shell (linux/src/ui/preview.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include "zs_signs.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace
{
    wchar_t const *const plate_status[] = { L"empty", L"to slice", L"slicing", L"", L"failed", L"resin: not yet" };
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::WirePlates()
    {
        PlatePrev().Click([this](auto &&, auto &&) { StepPlate(-1); });
        PlateNext().Click([this](auto &&, auto &&) { StepPlate(1); });
        PlateAll().Click([this](auto &&, auto &&) { FramePlate((size_t)-1); });
        PlateAdd().Click([this](auto &&, auto &&) {
            if (model != nullptr && model->AddPlate())
                ShowPlate();
        });
        PlateRemove().Click([this](auto &&, auto &&) {
            if (model != nullptr && model->RemovePlate(model->ActivePlate()))
                ShowPlate();
        });
    }

    void MainWindow::StepPlate(int direction)
    {
        if (model == nullptr)
            return;
        size_t active = model->ActivePlate();
        if ((direction < 0 && active == 0) || (direction > 0 && active + 1 >= model->PlateCount()))
            return;
        SelectPlate(direction < 0 ? active - 1 : active + 1);
    }

    void MainWindow::SelectPlate(size_t index)
    {
        if (model != nullptr && model->SelectPlate(index))
            ShowPlate();
    }

    void MainWindow::FramePlate(size_t index)
    {
        if (view == nullptr)
            return;
        zs_view_frame_plate(view, index);
        StartAnimation();
        RequestDraw();
    }

    // The active plate changed: its slice, or a plate with no slice yet.
    void MainWindow::ShowPlate()
    {
        if (model == nullptr || view == nullptr)
            return;
        zs_app *app = model->Active();
        int state = zs_app_state(app);
        zs_plate_info info{};
        std::wstring name;
        if (zs_set_plate_info(model->Set(), model->ActivePlate(), &info) == ZS_OK && info.name != nullptr)
            name = zs::ToWide(info.name);
        FileName().Text(name);
        Title(name.empty() ? L"zslice" : name + L" - zslice");
        // With more plates the hint would cover their beds.
        EmptyHint().Visibility(zs_app_part_count(app) == 0 && model->PlateCount() == 1 ? Visibility::Visible : Visibility::Collapsed);
        // The selection was of the plate before.
        StopReplay();
        replay_time = 0;
        simulated = false;
        sim_item.IsChecked(false);
        GapCard().Visibility(Visibility::Collapsed);
        HandRelease();
        selected_path = selected_segment = -1;
        line_anchored = false;
        selected_parts.clear();
        HideCards();
        ApplySelection();
        // The settings and the history are those of the new plate.
        RefreshSettingValues();
        RefreshHistoryButtons();
        // The slider of the new plate starts at its top.
        layer_count = 0;
        if (state == ZS_STATE_DONE)
        {
            ShowSlice();
            return;
        }
        // The view keeps no beads of the plate before. A plate with no
        // result has none to read.
        zs_view_load(view, app);
        model->UpdateBed(view);
        zs_set_view_sync(model->Set(), view);
        LayerCard().Visibility(Visibility::Collapsed);
        SliceProgress().Visibility(Visibility::Collapsed);
        StatusText().Text(state == ZS_STATE_SLICING ? L"Slicing" : L"");
        RefreshPlates();
        RequestDraw();
    }

    void MainWindow::RefreshPlates()
    {
        if (model == nullptr)
            return;
        size_t n = model->PlateCount(), active = model->ActivePlate();
        PlateName().Text(L"Plate " + to_hstring(active + 1) + L" of " + to_hstring(n));
        PlatePrev().IsEnabled(active > 0);
        PlateNext().IsEnabled(active + 1 < n);
        PlateAll().Visibility(n > 1 ? Visibility::Visible : Visibility::Collapsed);
        std::wstring tip;
        for (size_t i = 0; i < n; i++)
        {
            zs_plate_info info{};
            if (zs_set_plate_info(model->Set(), i, &info) != ZS_OK)
                continue;
            wchar_t const *status = info.status >= 0 && info.status <= ZS_PLATE_STATUS_CANNOT ? plate_status[info.status] : L"";
            if (!tip.empty())
                tip += L"\n";
            tip += (i == active ? L"▸ " : L"") + std::to_wstring(i + 1) + L". " +
                   (info.name[0] ? zs::ToWide(info.name) : L"Empty plate");
            if (status[0] != 0)
                tip += std::wstring(L" · ") + status;
        }
        ToolTipService::SetToolTip(PlateName(), box_value(tip));
        RefreshSigns();
    }

    void MainWindow::RefreshSigns()
    {
        if (view == nullptr)
            return;
        zs::SignImage image;
        if (!zs::DrawPlateSigns(model->Set(), Scale(), sign_key, image))
            return;
        int rc = zs_view_set_signs(view, model->PlateCount(), image.rects.data(), image.width, image.height,
                                   image.rgba.data(), image.scale);
        if (rc != ZS_OK)
            zs::Log("shell: the signs of the plates did not load: %s\n", zs_status_string(rc));
        RequestDraw();
    }
}
