#pragma once
#include "MainWindow.g.h"

#include <chrono>
#include <memory>

#include "zs_model.h"

namespace winrt::ZSlice::implementation
{
    // The main window: the core view in a SwapChainPanel, with the XAML
    // chrome around and over it. The view draws only after a change.
    struct MainWindow : MainWindowT<MainWindow>
    {
        MainWindow();

    private:
        enum class Drag
        {
            None,
            Orbit,
            Pan,
        };

        // The view.
        void EnsureView();
        void CloseView();
        double Scale();
        void ApplySize();
        void RequestDraw();
        void DrawNow();
        void StartAnimation();

        // The core.
        void OnCoreEvent(zs::Event const &event);
        void ShowSlice();
        void AfterScene();
        void ShowError(std::wstring const &text);

        // Files.
        winrt::fire_and_forget PickFile();
        void LoadPath(std::wstring path);
        void FinishLoad(std::wstring const &path, std::string const &bytes, bool read);

        // Input.
        void OnPointerPressed(Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const &e);
        void OnPointerMoved(Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const &e);
        void OnPointerEnded(Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const &e);
        void OnPointerWheel(Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const &e);
        void OnDragOver(Microsoft::UI::Xaml::DragEventArgs const &e);
        winrt::fire_and_forget OnDrop(Microsoft::UI::Xaml::DragEventArgs e);
        void OnLayerChanged(double value);

        HWND hwnd = nullptr;
        Microsoft::UI::Dispatching::DispatcherQueue queue{ nullptr };
        Microsoft::UI::Dispatching::DispatcherQueueTimer retry_timer{ nullptr };
        Microsoft::UI::Dispatching::DispatcherQueueTimer animation_timer{ nullptr };
        Microsoft::UI::Dispatching::DispatcherQueueTimer scene_timer{ nullptr };

        std::unique_ptr<zs::Model> model;
        zs_view *view = nullptr;
        bool draw_queued = false;
        // The next slice is of a new file: frame it.
        bool frame_next = false;

        Drag drag = Drag::None;
        double last_x = 0;
        double last_y = 0;
        std::chrono::steady_clock::time_point last_tick{};

        size_t layer_count = 0;
        bool setting_layer = false;
    };
}

namespace winrt::ZSlice::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow>
    {
    };
}
