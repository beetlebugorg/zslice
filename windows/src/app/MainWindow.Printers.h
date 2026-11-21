#pragma once
// The printers of the main window: the setup group of the top bar, the
// printer picker, the Printers page, pairing, and send and export.
//
// All network work runs on worker threads (windows/src/net). A worker posts
// its result to the UI thread through Poster, which drops it if the window
// is gone. The app never starts a print (see zs_printer_link.h).
//
// The behavior follows the GTK shell (linux/src/ui/printer-picker.c,
// farm-page.c, pair-dialog.c, profile-menus.c, filaments.c, window.c) and
// web/app/app.js.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "MainWindow.xaml.h"

#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>
#include <winrt/Windows.Storage.Streams.h>

#include <atomic>
#include <map>
#include <memory>
#include <thread>

#include "zs_bambu.h"
#include "zs_camera.h"
#include "zs_deck_filaments.h"
#include "zs_discovery_net.h"
#include "zs_printer_link.h"
#include "zs_printer_store.h"
#include "zs_setup.h"
#include "zs_signing.h"
#include "zs_state.h"

namespace winrt::ZSlice::implementation
{
    namespace ui
    {
        namespace Controls = Microsoft::UI::Xaml::Controls;
        namespace Media = Microsoft::UI::Xaml::Media;

        Media::Brush ThemeBrush(wchar_t const *key);
        Controls::TextBlock Label(std::wstring const &text, double size = 13, bool bold = false, bool dim = false);
        Controls::Button TextButton(std::wstring const &text, bool accent = false);
        Controls::StackPanel Row(double spacing = 8);
        Controls::StackPanel Column(double spacing = 8);
        // A brush of "#rrggbb", or nullptr.
        Media::SolidColorBrush ColorBrush(std::string const &hex);
        void Name(Microsoft::UI::Xaml::UIElement const &element, std::wstring const &name);
    }

    // A panel over the window, with a dimmed background.
    struct OverlayPanel
    {
        Microsoft::UI::Xaml::Controls::Grid root{ nullptr };
        Microsoft::UI::Xaml::Controls::Border card{ nullptr };
        std::function<void()> closed;
    };

    // One card of the Printers page.
    struct PrinterTile
    {
        std::string id;
        bool alive = true;
        Microsoft::UI::Xaml::Controls::Border card{ nullptr };
        Microsoft::UI::Xaml::Controls::Image camera{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock badge{ nullptr }, job{ nullptr }, facts{ nullptr }, why{ nullptr }, heat{ nullptr }, roll{ nullptr };
        Microsoft::UI::Xaml::Controls::ProgressBar bar{ nullptr };
        Microsoft::UI::Xaml::Controls::Button action{ nullptr };
        int state = -1;
        bool needs_key = false;
        bool camera_read = false;
        bool reading = false;
        bool in_view = false;
        double bed_x = 0, bed_y = 0, time_left = 0;
        zs::CameraSource source;
        bool has_source = false;
        std::shared_ptr<zs::CameraFeed> feed;
        std::shared_ptr<zs::BambuWatch> bambu;
        std::shared_ptr<std::atomic<bool>> decoding = std::make_shared<std::atomic<bool>>(false);
    };

    struct MainWindow::PrintersUi : std::enable_shared_from_this<MainWindow::PrintersUi>
    {
        // Moves a result to the UI thread.
        struct Poster
        {
            winrt::weak_ref<MainWindow> weak;
            Microsoft::UI::Dispatching::DispatcherQueue queue{ nullptr };

            template <typename F>
            void Post(F f) const
            {
                auto box = std::make_shared<F>(std::move(f));
                auto w = weak;
                queue.TryEnqueue([w, box] {
                    if (auto self = w.get())
                        if (self->printers != nullptr)
                            (*box)(*self->printers);
                });
            }
        };

        explicit PrintersUi(MainWindow &window);

        // Runs `work` on a thread, then `done(ui, result)` on the UI thread.
        template <typename Work, typename Done>
        void Async(Work work, Done done)
        {
            Poster p = poster;
            std::thread([p, work = std::move(work), done = std::move(done)]() mutable {
                auto result = work();
                p.Post([done = std::move(done), result = std::move(result)](PrintersUi &ui) mutable { done(ui, result); });
            }).detach();
        }

        // Ends an object that joins a thread, off the UI thread.
        template <typename T>
        static void Retire(std::shared_ptr<T> &object)
        {
            if (object == nullptr)
                return;
            std::thread([held = std::move(object)]() mutable { held.reset(); }).detach();
            object = nullptr;
        }

        // ---- MainWindow.Printers.cpp: the top bar and the menus ----
        void BuildTopBar();
        void Start();
        void Close();
        void AfterSettings();
        void RefreshBar();
        void FillPrinterMenu();
        void FillQuality();
        void FillFilament();
        void AskProfileName(int group);
        void Note(std::wstring const &text);
        void SavePin(zs::link::Target const &target);
        std::shared_ptr<OverlayPanel> OpenPanel(std::wstring const &title, double width, double height,
                                                Microsoft::UI::Xaml::UIElement const &content);
        void ClosePanel(std::shared_ptr<OverlayPanel> const &panel);

        // Pairing (MainWindow.Printers.cpp).
        void ShowPair(std::string const &printer_id, bool fresh, std::function<void(bool)> done);
        void ShowConnectDeck();
        void AddDeckPrinters(std::string const &deck_id, std::string const &key, zs::link::DeckList const &list,
                             std::vector<std::pair<Microsoft::UI::Xaml::Controls::CheckBox, size_t>> const &boxes, bool fresh);

        // ---- MainWindow.Picker.cpp ----
        void ShowPicker(bool welcome);

        // ---- MainWindow.Farm.cpp: the Printers page ----
        void BuildPage();
        void ShowPage(bool show);
        void RebuildTiles();
        void RefreshTiles();
        void RefreshQueue();
        void UpdateTile(std::shared_ptr<PrinterTile> const &tile, zs::link::Snapshot const *status, std::string const &error);
        void StartCamera(std::shared_ptr<PrinterTile> const &tile);
        void StopCamera(std::shared_ptr<PrinterTile> const &tile);
        void ShowCameraLarge(std::shared_ptr<PrinterTile> const &tile);
        void ShowManage();
        void StopTiles();

        // ---- MainWindow.Send.cpp ----
        void FillSendMenu();
        void SendPlate(std::string const &printer_id, size_t plate);
        winrt::fire_and_forget ExportGcode();
        winrt::fire_and_forget SavePlate3mf();
        winrt::fire_and_forget SaveProject();
        winrt::fire_and_forget ExportAll();
        void SendAll();
        void BatchNext();
        void BatchTake();
        void BatchFinish(std::wstring const &error);
        void OnSliced();
        void OnFailed();
        void StartPlatesHook();
        std::string GcodeName(zs_app *app, size_t plate);
        Windows::Foundation::IAsyncOperation<winrt::hstring> PickSavePath(std::wstring name, std::wstring type, std::wstring ext);

        MainWindow &w;
        zs::PrinterSetup setup;
        Poster poster;
        bool started = false;

        Microsoft::UI::Xaml::Controls::DropDownButton printer_button{ nullptr }, filament_button{ nullptr }, quality_button{ nullptr }, send_button{ nullptr };
        Microsoft::UI::Xaml::Controls::Primitives::ToggleButton page_button{ nullptr };
        Microsoft::UI::Xaml::Controls::MenuFlyout printer_menu{ nullptr }, send_menu{ nullptr };
        Microsoft::UI::Xaml::Controls::Flyout filament_flyout{ nullptr }, quality_flyout{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel filament_panel{ nullptr }, quality_panel{ nullptr };
        std::wstring filament_note;
        bool reading_filaments = false;
        // The rolls of the current printer, from its last status.
        std::vector<zs::link::Roll> rolls;

        std::vector<std::shared_ptr<OverlayPanel>> panels;

        // The Printers page.
        Microsoft::UI::Xaml::Controls::Grid page{ nullptr };
        Microsoft::UI::Xaml::Controls::VariableSizedWrapGrid tile_grid{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel queue_panel{ nullptr }, empty_panel{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock counts{ nullptr }, page_note{ nullptr }, queue_empty{ nullptr };
        Microsoft::UI::Dispatching::DispatcherQueueTimer page_timer{ nullptr };
        Microsoft::UI::Dispatching::DispatcherQueueTimer save_timer{ nullptr };
        Microsoft::UI::Dispatching::DispatcherQueueTimer plates_timer{ nullptr };
        std::vector<std::shared_ptr<PrinterTile>> tiles;
        zs::http::CancelPtr page_cancel;

        // Send and the batch of all plates.
        zs::http::CancelPtr send_cancel;
        bool sending = false;
        bool export_pending = false;
        bool batch_sending = false;
        struct Batch
        {
            bool on = false;
            bool send = false;
            size_t i = 0, n = 0, back = 0, done = 0;
            std::wstring dir;
        } batch;
    };
}
