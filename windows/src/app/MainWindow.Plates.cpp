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
        PlateName().RightTapped([this](auto &&, Input::RightTappedRoutedEventArgs const &e) {
            ShowPlateNameMenu();
            e.Handled(true);
        });
        PlatePrev().Click([this](auto &&, auto &&) { StepPlate(-1); });
        PlateNext().Click([this](auto &&, auto &&) { StepPlate(1); });
        PlateAll().Click([this](auto &&, auto &&) { FramePlate((size_t)-1); });
        PlateAdd().Click([this](auto &&, auto &&) {
            if (model != nullptr && model->AddPlate())
                ShowPlate();
        });
        PlateRemove().Click([this](auto &&, auto &&) { AskRemovePlate(); });
    }

    // A plate with parts asks first: its removal has no undo.
    winrt::fire_and_forget MainWindow::AskRemovePlate()
    {
        if (model == nullptr)
            co_return;
        auto keep = get_strong();
        size_t plate = model->ActivePlate();
        zs_plate_info info{};
        if (zs_set_plate_info(model->Set(), plate, &info) == ZS_OK && info.part_count > 0)
        {
            ContentDialog dialog;
            dialog.XamlRoot(Content().XamlRoot());
            ThemeDialog(dialog);
            std::wstring number = std::to_wstring(plate + 1);
            dialog.Title(box_value(info.part_count == 1 ? L"Remove plate " + number + L" and its part?"
                                                        : L"Remove plate " + number + L" and its " + std::to_wstring(info.part_count) + L" parts?"));
            dialog.Content(box_value(L"This cannot be undone."));
            dialog.PrimaryButtonText(L"Remove");
            dialog.CloseButtonText(L"Cancel");
            dialog.DefaultButton(ContentDialogButton::Close);
            ContentDialogResult answer = ContentDialogResult::None;
            try
            {
                answer = co_await dialog.ShowAsync();
            }
            catch (winrt::hresult_error const &)
            {
                co_return;
            }
            if (answer != ContentDialogResult::Primary || model == nullptr)
                co_return;
        }
        RemovePlateAt(plate);
    }

    void MainWindow::RemovePlateAt(size_t plate)
    {
        CancelFall();
        if (!model->RemovePlate(plate))
            return;
        // The refinement history of each later plate moves with it.
        if (plate < refine_ids.size())
            refine_ids.erase(refine_ids.begin() + (ptrdiff_t)plate);
        ShowPlate();
    }

    // No parts: the plate has no name, and the set drops its slice.
    void MainWindow::ClearPlate()
    {
        if (model == nullptr)
            return;
        ClearSelection();
        zs_app_plate_clear(model->Active());
        zs_set_name(model->Set(), model->ActivePlate(), nullptr);
        zs_set_changed(model->Set(), model->ActivePlate());
        PlateEdited();
        ShowPlate();
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
        if (model == nullptr)
            return;
        SelSync();
        if (sel != nullptr)
            zs_sel_plate_request(sel.get(), index);
        bool moved = model->SelectPlate(index);
        // The sync ends the request, and a new plate drops the focus.
        SelSync();
        if (moved)
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
        CancelFall();
        zs_app *app = model->Active();
        int state = zs_app_state(app);
        ShowPlateChrome();
        SessionSoon();
        // The selection was of the plate before.
        StopReplay();
        replay_time = 0;
        simulated = false;
        ShowSimItem();
        GapCard().Visibility(Visibility::Collapsed);
        HandRelease();
        // The z range of the card is of the plate before.
        RangeClose();
        SupportReload();
        selected_path = selected_segment = -1;
        line_anchored = false;
        SetSelectedParts({});
        HideCards();
        ApplySelection();
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
        SupportLoaded();
        model->UpdateBed(view);
        zs_set_view_sync(model->Set(), view);
        LayerCard().Visibility(Visibility::Collapsed);
        SliceProgress().Visibility(Visibility::Collapsed);
        ShowBusy(L"");
        RefreshSummary();
        RefreshPlates();
        RequestDraw();
    }

    void MainWindow::ShowPlateNameMenu()
    {
        MenuFlyout menu;
        MenuFlyoutItem item;
        item.Text(L"Remove plate " + to_hstring(model->ActivePlate() + 1));
        item.Click([this](auto &&, auto &&) { AskRemovePlate(); });
        menu.Items().Append(item);
        menu.ShowAt(PlateName());
    }

    void MainWindow::ShowPlateName()
    {
        zs_plate_info info{};
        std::wstring name;
        if (zs_set_plate_info(model->Set(), model->ActivePlate(), &info) == ZS_OK && info.name != nullptr)
            name = zs::ToWide(info.name);
        FileName().Text(name);
        Title(name.empty() ? L"zslice" : name + L" - zslice");
    }

    // The name, the hint, the settings, and the history of the active plate.
    void MainWindow::ShowPlateChrome()
    {
        layer2d_dirty = true;
        ApplyEnginePrefs();
        ShowPlateName();
        // With more plates the hint would cover their beds.
        PlaceEmptyOpen();
        RefreshSettingValues();
        RefreshHistoryButtons();
        RefreshFilamentTools();
        PrintersOnPlate();
        RefreshPlates();
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
        ProjectPlatesChanged();
        RefreshSigns();
    }

    void MainWindow::RefreshSigns()
    {
        if (view == nullptr)
            return;
        zs::SignImage image;
        if (!zs::DrawPlateSigns(model->Set(), Scale(), sign_key, image, [this](size_t plate) { return ProjectPrintStatus(plate); }))
            return;
        int rc = zs_view_set_signs(view, model->PlateCount(), image.rects.data(), image.width, image.height,
                                   image.rgba.data(), image.scale);
        if (rc != ZS_OK)
            zs::Log("shell: the signs of the plates did not load: %s\n", zs_status_string(rc));
        RequestDraw();
    }
}
