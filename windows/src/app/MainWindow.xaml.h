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
        void OnKeyDown(Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const &e);

        // Plates (MainWindow.Plates.cpp).
        void WirePlates();
        void RefreshPlates();
        void RefreshSigns();
        void ShowPlate();
        void StepPlate(int direction);
        void SelectPlate(size_t index);
        void FramePlate(size_t index);

        // Settings and history (MainWindow.Settings.cpp).
        struct SettingEditor
        {
            std::string name;
            std::function<void()> refresh;
        };
        enum class SettingsPage
        {
            Sections,
            Section,
            Search,
            Detail,
        };
        void WireSettings();
        void ShowSettingsPane(bool show);
        void ShowSections();
        void ShowSection(char const *group, char const *section);
        void ShowSearch(std::wstring const &query);
        void ShowDetail(char const *name);
        void SettingsGoBack();
        void ClearSettingsList();
        Microsoft::UI::Xaml::FrameworkElement MakeSettingRow(zs_setting_info const &info);
        Microsoft::UI::Xaml::FrameworkElement MakeEditor(zs_setting_info const &info);
        void CommitSetting(std::string const &name, std::string const &value);
        void CommitSettingText(zs_setting_info const &info, std::wstring const &text);
        void RefreshSettingValues();
        void NoteChange();
        void RefreshHistoryButtons();
        void FillHistoryMenu();
        void AfterRestore(int bits);

    public:
        // Printers, send, and export (MainWindow.Printers.h).
        struct PrintersUi;

    private:
        void WirePrinters();
        void ClosePrinters();
        void PrintersOnSliced();
        void PrintersOnFailed();
        void PrintersNoteChange();
        void PrintersOnPlate();
        std::shared_ptr<PrintersUi> printers;

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
        double press_x = 0;
        double press_y = 0;
        std::chrono::steady_clock::time_point last_tick{};
        std::wstring sign_key;

        size_t layer_count = 0;
        bool setting_layer = false;

        Microsoft::UI::Dispatching::DispatcherQueueTimer history_timer{ nullptr };
        std::vector<SettingEditor> setting_editors;
        SettingsPage settings_page = SettingsPage::Sections;
        SettingsPage detail_from = SettingsPage::Sections;
        char const *settings_group = nullptr;
        char const *settings_section = nullptr;
        std::wstring settings_query;
        // True while the code fills an editor: its change event is no edit.
        bool filling_editor = false;
    };
}

namespace winrt::ZSlice::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow>
    {
    };
}
