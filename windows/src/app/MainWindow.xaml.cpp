// The main window. See MainWindow.xaml.h.
//
// The core draws into a composition swapchain, and the shell attaches it to
// the SwapChainPanel. The swapchain is in device pixels, so the shell
// presents it through the inverse of the composition scale. This follows
// Lookout Marine. See docs/references/libraries.md.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif

#include <cmath>
#include <thread>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Dispatching;
using Microsoft::UI::Input::PointerDeviceType;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Storage = Windows::Storage;

namespace
{
    std::wstring FileNameOf(std::wstring const &path)
    {
        size_t at = path.find_last_of(L"\\/");
        return at == std::wstring::npos ? path : path.substr(at + 1);
    }

}

namespace winrt::ZSlice::implementation
{
    MainWindow::MainWindow()
    {
        InitializeComponent();
        Title(L"zslice");
        this->try_as<::IWindowNative>()->get_WindowHandle(&hwnd);
        // The icon of the exe (ZSlice.rc), at the sizes of this display.
        UINT icon_dpi = GetDpiForWindow(hwnd);
        for (auto [kind, metric] : { std::pair{ ICON_BIG, SM_CXICON }, std::pair{ ICON_SMALL, SM_CXSMICON } })
        {
            int size = GetSystemMetricsForDpi(metric, icon_dpi);
            if (HANDLE icon = LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, size, size, LR_DEFAULTCOLOR))
                SendMessageW(hwnd, WM_SETICON, kind, reinterpret_cast<LPARAM>(icon));
        }
        queue = DispatcherQueue::GetForCurrentThread();

        retry_timer = queue.CreateTimer();
        retry_timer.IsRepeating(false);
        retry_timer.Interval(std::chrono::milliseconds(8));
        retry_timer.Tick([this](auto &&, auto &&) { RequestDraw(); });

        animation_timer = queue.CreateTimer();
        animation_timer.Interval(std::chrono::milliseconds(16));
        animation_timer.Tick([this](auto &&, auto &&) {
            auto now = std::chrono::steady_clock::now();
            double dt = std::min(std::chrono::duration<double>(now - last_tick).count(), 0.1);
            last_tick = now;
            if (view == nullptr || !zs_view_animate(view, dt))
                animation_timer.Stop();
            RequestDraw();
        });

        scene_timer = queue.CreateTimer();
        scene_timer.Interval(std::chrono::milliseconds(4));
        scene_timer.Tick([this](auto &&, auto &&) {
            if (view == nullptr || !zs_view_scene_pending(view))
            {
                scene_timer.Stop();
                return;
            }
            if (zs_view_scene_poll(view))
            {
                scene_timer.Stop();
                AfterScene();
            }
        });

        ViewPanel().Loaded([this](auto &&, auto &&) { EnsureView(); });
        ViewPanel().SizeChanged([this](auto &&, auto &&) { ApplySize(); });
        ViewPanel().CompositionScaleChanged([this](auto &&, auto &&) { ApplySize(); });
        ViewPanel().PointerPressed([this](auto &&, Input::PointerRoutedEventArgs const &e) { OnPointerPressed(e); });
        ViewPanel().PointerMoved([this](auto &&, Input::PointerRoutedEventArgs const &e) { OnPointerMoved(e); });
        ViewPanel().PointerReleased([this](auto &&, Input::PointerRoutedEventArgs const &e) { OnPointerEnded(e); });
        ViewPanel().PointerCaptureLost([this](auto &&, Input::PointerRoutedEventArgs const &e) { OnPointerEnded(e); });
        ViewPanel().PointerWheelChanged([this](auto &&, Input::PointerRoutedEventArgs const &e) { OnPointerWheel(e); });

        Root().DragOver([this](auto &&, DragEventArgs const &e) { OnDragOver(e); });
        Root().Drop([this](auto &&, DragEventArgs const &e) { OnDrop(e); });
        OpenButton().Click([this](auto &&, auto &&) { PickFile(); });
        LayerSlider().ValueChanged([this](auto &&, Primitives::RangeBaseValueChangedEventArgs const &e) {
            OnLayerChanged(e.NewValue());
        });
        Root().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) { OnKeyDown(e); });
        WirePlates();
        WireSettings();
        WireTools();
        WireSession();
        WireMenu();
        Wire2D();
        WireChrome();
        WireSummary();
        Closed([this](auto &&, auto &&) {
            CloseCuraCompare();
            SaveSession(true);
            CloseView();
        });
    }

    // ---- the view ----

    double MainWindow::Scale()
    {
        double s = ViewPanel().CompositionScaleX();
        return s > 0 ? s : 1.0;
    }

    void MainWindow::EnsureView()
    {
        if (view != nullptr)
            return;
        uint32_t width = (uint32_t)std::lround(ViewPanel().ActualWidth() * Scale());
        uint32_t height = (uint32_t)std::lround(ViewPanel().ActualHeight() * Scale());
        if (width == 0 || height == 0)
            return;

        // Made here and not in the constructor: a weak reference needs the
        // finished XAML object.
        auto weak = get_weak();
        auto target = queue;
        model = std::make_unique<zs::Model>([weak, target](zs::Event const &event) {
            target.TryEnqueue([weak, event] {
                if (auto self = weak.get())
                    self->OnCoreEvent(event);
            });
        });
        int rc = model->Start();
        if (rc != ZS_OK)
        {
            ShowError(zs::ToWide(zs_status_message(rc)));
            return;
        }

        zs_surface surface{};
        surface.kind = ZS_SURFACE_PANEL;
        rc = zs_view_new(&surface, width, height, &view);
        if (rc != ZS_OK)
        {
            ShowError(L"The 3D view did not start: " + zs::ToWide(zs_status_message(rc)));
            return;
        }
        void *swapchain = nullptr;
        rc = zs_view_swapchain(view, &swapchain);
        HRESULT attached = rc == ZS_OK
            ? ViewPanel().as<ISwapChainPanelNative>()->SetSwapChain(static_cast<IDXGISwapChain *>(swapchain))
            : E_FAIL;
        if (FAILED(attached))
        {
            ShowError(L"The 3D view did not attach to the window.");
            zs_view_free(view);
            view = nullptr;
            return;
        }
        ApplySize();
        WireWork();
        WirePrinters();
        ApplyThemePref();
        WireProject();
        // ZSLICE_PRINTER=id: starts on a printer of the library, for tests.
        wchar_t printer[128];
        if (::GetEnvironmentVariableW(L"ZSLICE_PRINTER", printer, ARRAYSIZE(printer)) > 0)
        {
            std::string message;
            if (!model->UsePrinter(zs::ToUtf8(printer), message))
                ShowError(zs::ToWide(message));
            PrintersNoteChange();
        }
        zs_view_set_dark(view, Root().ActualTheme() == ElementTheme::Dark ? 1 : 0);
        if (!RestoreSession())
            ShowPlate();
        ProjectStart();
        ViewPanel().Focus(FocusState::Programmatic);
        ApplyEnginePrefs();
        ApplyFirstViewPref();

        StartOpenLinks();
        std::wstring argument = zs::appshell::FirstArgument();
        if (!argument.empty())
            OpenExternal(argument);
    }

    void MainWindow::CloseView()
    {
        StopOpenLinks();
        StopWork();
        retry_timer.Stop();
        animation_timer.Stop();
        scene_timer.Stop();
        history_timer.Stop();
        fall_timer.Stop();
        session_timer.Stop();
        replay_timer.Stop();
        CloseProjectUi();
        ClosePrinters();
        // The view reads the apps of the set, so it goes first.
        if (view != nullptr)
            zs_view_free(view);
        view = nullptr;
        model.reset();
    }

    void MainWindow::ApplySize()
    {
        if (view == nullptr)
        {
            EnsureView();
            return;
        }
        double sx = ViewPanel().CompositionScaleX();
        double sy = ViewPanel().CompositionScaleY();
        if (sx <= 0 || sy <= 0)
            return;
        uint32_t width = (uint32_t)std::lround(ViewPanel().ActualWidth() * sx);
        uint32_t height = (uint32_t)std::lround(ViewPanel().ActualHeight() * sy);
        if (width == 0 || height == 0)
            return;
        zs_view_resize(view, width, height);
        void *swapchain = nullptr;
        if (zs_view_swapchain(view, &swapchain) == ZS_OK)
        {
            com_ptr<IDXGISwapChain2> chain;
            if (SUCCEEDED(static_cast<IUnknown *>(swapchain)->QueryInterface(__uuidof(IDXGISwapChain2), chain.put_void())))
            {
                DXGI_MATRIX_3X2_F inverse{ (float)(1.0 / sx), 0.0f, 0.0f, (float)(1.0 / sy), 0.0f, 0.0f };
                chain->SetMatrixTransform(&inverse);
            }
        }
        RequestDraw();
    }

    void MainWindow::RequestDraw()
    {
        if (draw_queued || view == nullptr)
            return;
        draw_queued = true;
        auto weak = get_weak();
        queue.TryEnqueue([weak] {
            if (auto self = weak.get())
                self->DrawNow();
        });
    }

    void MainWindow::DrawNow()
    {
        draw_queued = false;
        if (view == nullptr)
            return;
        if (show_2d)
        {
            Draw2D();
            PlaceMeasure();
            return;
        }
        PlaceEmptyOpen();
        int rc = zs_view_draw(view);
        // The GPU or the compositor holds the frame before.
        if (rc == ZS_BUSY && !retry_timer.IsRunning())
            retry_timer.Start();
        else if (rc != ZS_OK && rc != ZS_BUSY)
            zs::Log("shell: the view did not draw: %s\n", zs_status_string(rc));
        // The handle and the card of a label follow the camera.
        LabelPlace();
        RangePlace();
        PlaceMeasure();
    }

    void MainWindow::StartAnimation()
    {
        if (animation_timer.IsRunning())
            return;
        last_tick = std::chrono::steady_clock::now();
        animation_timer.Start();
    }

    // ---- the core ----

    void MainWindow::OnCoreEvent(zs::Event const &event)
    {
        if (model == nullptr || view == nullptr)
            return;
        if (event.kind == ZS_EVENT_PLATES)
        {
            zs_set_view_sync(model->Set(), view);
            ApplyEnginePrefs();
            RefreshPlates();
            RequestDraw();
            SessionSoon();
            return;
        }
        // A slice of another plate shows only in its status.
        if (!model->IsActive(event.plate))
            return;
        switch (event.kind)
        {
        case ZS_EVENT_PROGRESS:
            // The state is the truth: an old slice can still report.
            if (zs_app_state(model->Active()) == ZS_STATE_SLICING)
            {
                model->NoteSliceProgress();
                WorkProgress(event.progress);
                SliceProgress().Visibility(Visibility::Visible);
                SliceProgress().Value(event.progress);
            }
            break;
        case ZS_EVENT_SLICED:
            if (zs_app_state(model->Active()) == ZS_STATE_DONE)
            {
                // A draft has no G-code and no simulation: the file, the
                // session, and the refinements wait for the exact slice.
                bool draft = model->IsDraft();
                model->NoteSliced();
                WorkSliceEnded(draft);
                if (!draft)
                {
                    refine_timer.Stop();
                    refine_timer.Start();
                }
                // A new slice shows the plan again.
                simulated = false;
                sim_item.IsChecked(false);
                StopReplay();
                replay_time = 0;
                ShowSlice();
                if (!draft)
                {
                    SessionSoon();
                    PrintersOnSliced();
                }
            }
            break;
        case ZS_EVENT_SIMULATED:
            OnSimulated();
            break;
        case ZS_EVENT_FAILED:
            if (zs_app_state(model->Active()) == ZS_STATE_FAILED)
            {
                WorkSliceEnded(false);
                SliceProgress().Visibility(Visibility::Collapsed);
                // A failed slice has no G-code to export.
                ExportButton().IsEnabled(false);
                {
                    std::wstring refusal = PlateRefusal(model->Active());
                    ToolTipService::SetToolTip(ExportGroup(), refusal.empty() ? nullptr : box_value(refusal));
                }
                // The name of the error goes to the log, for a bug report.
                zs::Log("shell: the slice failed: %s\n", zs_app_failure_name(model->Active()));
                ShowError(zs::ToWide(zs_status_message(event.status)));
                PrintersOnFailed();
            }
            break;
        default:
            break;
        }
    }

    void MainWindow::ShowSlice()
    {
        layer2d_dirty = true;
        SliceProgress().Visibility(Visibility::Collapsed);
        // A change came during the slice: this result shows, and the newest
        // settings slice next.
        if (model->TakeSlicePending())
            model->RequestSlice();
        zs_view_set_mode(view, color_mode);
        int rc = zs_view_load(view, model->Active());
        if (rc != ZS_OK)
        {
            ShowError(L"The 3D view did not load the slice: " + zs::ToWide(zs_status_message(rc)));
            return;
        }
        // A large scene: the view draws the old one until the copy of its
        // beads to the GPU is done.
        if (zs_view_scene_pending(view))
        {
            SupportLoaded();
            if (!scene_timer.IsRunning())
                scene_timer.Start();
            RefreshSummary();
            return;
        }
        AfterScene();
    }

    void MainWindow::AfterScene()
    {
        model->UpdateBed(view);
        zs_set_view_sync(model->Set(), view);
        SupportLoaded();
        ApplySearchEye();
        ApplyPaneFocus();
        if (effect_box != nullptr)
            FillEffect(effect_box, effect_key);
        RefreshPlates();
        FindLineAnchor();
        ApplySelection();
        FillPartCard();
        RefreshFilamentTools();
        size_t count = zs_app_layer_count(model->Active());
        bool at_top = layer_count == 0 || LayerSlider().Value() >= (double)layer_count;
        layer_count = count;
        setting_layer = true;
        LayerSlider().Maximum((double)std::max<size_t>(count, 1));
        if (at_top || frame_next || LayerSlider().Value() > (double)count)
            LayerSlider().Value((double)std::max<size_t>(count, 1));
        setting_layer = false;
        size_t shown = (size_t)LayerSlider().Value();
        LayerText().Text(to_hstring(shown));
        LayerCard().Visibility(count > 0 ? Visibility::Visible : Visibility::Collapsed);
        UpdateLayerRail();
        if (count > 0)
            zs_view_set_layer(view, shown - 1);
        if (frame_next)
        {
            frame_next = false;
            zs_view_reset(view);
        }
        ShowGaps();
        if (count > 0)
            ShowScrub(shown - 1, 1e12);
        LineLightAfterSlice();
        RangeScene();
        ProfilesRefresh();
        ScopeRefresh();
#ifdef ZS_DEV_HOOKS
        StartDevHooks();
#endif
        RefreshSummary();
        RequestDraw();
    }

    void MainWindow::ShowError(std::wstring const &text)
    {
        zs::Log("shell: %s\n", zs::ToUtf8(text).c_str());
        ShowBusy(L"");
        ShowToast(text);
    }

    // ---- files ----

    winrt::fire_and_forget MainWindow::PickFile()
    {
        auto lifetime = get_strong();
        Storage::Pickers::FileOpenPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(hwnd);
        picker.FileTypeFilter().Append(L".stl");
        picker.FileTypeFilter().Append(L".3mf");
        picker.FileTypeFilter().Append(L".step");
        picker.FileTypeFilter().Append(L".stp");
        picker.FileTypeFilter().Append(L".obj");
        picker.FileTypeFilter().Append(L".zip");
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
            LoadPath(std::wstring(file.Path()));
    }

    void MainWindow::LoadPath(std::wstring path, bool new_plate)
    {
        if (model == nullptr)
            return;
        ShowBusy(L"Reading " + FileNameOf(path));
        // A large file reads off the UI thread.
        auto self = get_strong();
        auto target = queue;
        std::thread([self, target, path, new_plate] {
            auto bytes = std::make_shared<std::string>();
            bool read = zs::Model::ReadFile(path, *bytes);
            target.TryEnqueue([self, path, bytes, read, new_plate] { self->FinishLoad(path, *bytes, read, new_plate); });
        }).detach();
    }

    void MainWindow::FinishLoad(std::wstring const &path, std::string const &bytes, bool read, bool new_plate)
    {
        if (model == nullptr)
            return;
        std::wstring name = FileNameOf(path);
        if (!read)
        {
            ShowError(L"Could not read " + name);
            return;
        }
        CancelFall();
        // A ZIP file of a model: the user chooses its files.
        if (IsZipName(name))
        {
            ShowBusy(L"");
            ImportZip(name, std::make_shared<std::string>(bytes));
            return;
        }
        // A file from outside the app replaces no work on this plate.
        if (new_plate && zs_app_part_count(model->Active()) > 0 &&
            !zs_project_file_is(reinterpret_cast<uint8_t const *>(bytes.data()), bytes.size()) && model->AddPlate())
            ShowPlate();
        ProjectFileOpening(zs_project_file_is(reinterpret_cast<uint8_t const *>(bytes.data()), bytes.size()) != 0, new_plate);
        std::string message;
        frame_next = true;
        // A new model has no layers of the old range.
        RangeClose();
        int rc = model->Load(name, bytes, message);
        if (rc != ZS_OK)
        {
            frame_next = false;
            ShowError(name + L": " + zs::ToWide(message));
            return;
        }
        FileName().Text(name);
        Title(name + L" - zslice");
        EmptyHint().Visibility(Visibility::Collapsed);
        ShowBusy(L"");
        // The load is a step of its own. The first edit after it is another.
        NoteChange();
        MarkHistorySaved();
        history_mark_late = true;
    }

    void MainWindow::OnDragOver(DragEventArgs const &e)
    {
        if (e.DataView().Contains(Windows::ApplicationModel::DataTransfer::StandardDataFormats::StorageItems()))
            e.AcceptedOperation(Windows::ApplicationModel::DataTransfer::DataPackageOperation::Copy);
    }

    winrt::fire_and_forget MainWindow::OnDrop(DragEventArgs e)
    {
        auto lifetime = get_strong();
        auto data = e.DataView();
        if (!data.Contains(Windows::ApplicationModel::DataTransfer::StandardDataFormats::StorageItems()))
            co_return;
        auto drop_at = e.GetPosition(ViewPanel());
        auto items = co_await data.GetStorageItemsAsync();
        // An SVG file makes a label on the part under the pointer.
        std::wstring svg;
        for (auto const &item : items)
        {
            std::wstring path{ item.Path() };
            if (item.IsOfType(Storage::StorageItemTypes::File) && path.size() >= 4 && _wcsicmp(path.c_str() + path.size() - 4, L".svg") == 0)
                svg = path;
        }
        if (!svg.empty())
        {
            LabelDropSvg(svg, drop_at.X, drop_at.Y);
            co_return;
        }
        for (auto const &item : items)
        {
            std::wstring path{ item.Path() };
            if (item.IsOfType(Storage::StorageItemTypes::File) && (zs::openlink::IsModelName(path) || IsZipName(path)))
            {
                LoadPath(path);
                break;
            }
        }
    }

    // ---- input ----

    void MainWindow::OnPointerWheel(Input::PointerRoutedEventArgs const &e)
    {
        if (view == nullptr)
            return;
        auto point = e.GetCurrentPoint(ViewPanel());
        int delta = point.Properties().MouseWheelDelta();
        if (delta == 0)
            return;
        // The wheel over the selected label turns it.
        auto wheel_mods = e.KeyModifiers();
        if (tool == Tool::Label && (wheel_mods & Windows::System::VirtualKeyModifiers::Control) == Windows::System::VirtualKeyModifiers::None &&
            LabelWheel(point.Position().X, point.Position().Y, delta, (wheel_mods & Windows::System::VirtualKeyModifiers::Shift) != Windows::System::VirtualKeyModifiers::None))
        {
            e.Handled(true);
            return;
        }
        // One notch (120) is a step of 15 %. A touchpad and a pinch send
        // small deltas, so they zoom smoothly.
        float factor = std::pow(1.15f, -(float)delta / 120.0f);
        zs_view_zoom_at(view, factor, (float)(point.Position().X * Scale()), (float)(point.Position().Y * Scale()));
        StartAnimation();
        e.Handled(true);
    }

    void MainWindow::OnLayerChanged(double value)
    {
        UpdateLayerRail();
        if (setting_layer || view == nullptr || layer_count == 0)
            return;
        StopReplay();
        replay_time = 0;
        size_t layer = (size_t)std::lround(value);
        LayerText().Text(to_hstring(layer));
        ApplyLayerRange();
        ShowGaps();
        ShowScrub(layer - 1, 1e12);
        RequestDraw();
    }
}
