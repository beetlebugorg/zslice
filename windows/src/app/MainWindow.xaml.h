#pragma once
#include "MainWindow.g.h"

#include <chrono>
#include <memory>

#include "zs_model.h"
#include "zs_part_meshes.h"

namespace zs
{
    class Layer2D;
}

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
        void OnPanelDoubleTapped(Microsoft::UI::Xaml::Input::DoubleTappedRoutedEventArgs const &e);

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

        // Tools and cards (MainWindow.Tools.cpp, MainWindow.Cards.cpp).
        enum class Tool
        {
            Select,
            Move,
            Turn,
            Support,
            Grab,
            Measure,
            Paint,
            Label,
        };
        void WireTools();
        void SetTool(Tool next);
        int64_t PartAt(double x, double y, double *bed_x, double *bed_y);
        bool ToolPress(double x, double y, bool ctrl);
        void ToolDrag(double x, double y, bool shift);
        void ToolRelease();
        void ToolClick(double x, double y, bool shift, bool ctrl);
        void BeginMove(int64_t part, double bed_x, double bed_y);
        void HandMove(double x, double y, bool alt, bool shift);
        bool HandRelease();
        void RunFall();
        void FallTick();
        void CheckFall();
        void MeasureClick(double x, double y, bool shift);
        void ShowMeasure();
        void ClearMeasure();
        void UpdateRings();
        void SelectLine(int64_t path, int64_t segment);
        void SelectPart(int64_t part);
        void TogglePart(int64_t part);
        void ClearSelection();
        void ApplySelection();
        void SaveLineAnchor();
        void FindLineAnchor();
        void StepLine(int direction, bool whole);
        void StepLayer(int direction);
        void PlateEdited();
        bool OnToolKey(Windows::System::VirtualKey key, bool shift, bool ctrl);
        void WireCards();

        // The session (MainWindow.Session.cpp).
        void WireSession();
        void SessionSoon();
        void SaveSession(bool wait);
        bool RestoreSession(bool has_file);
        void ShowPlateChrome();

        // The main menu and its dialogs (MainWindow.Menu.cpp).
        void WireMenu();
        void ApplyTheme();
        void ShowDialog(hstring const &title, Microsoft::UI::Xaml::UIElement const &content);
        void ShowShortcuts();
        void ShowLicenses();
        void ShowAbout();

        // The 2D view of the top layer (MainWindow.Layer2D.cpp).
        void Wire2D();
        void Size2D();
        void Fit2D();
        void Set2D(bool on);
        void Draw2D();
        void Click2D(double x, double y);
        void BedSize(double &x, double &y);
        std::shared_ptr<zs::Layer2D> layer2d;
        bool show_2d = false;
        bool layer2d_dirty = true;
        size_t layer2d_layer = 0;
        bool drag_2d = false;
        bool press_2d_left = false;
        double press_2d_x = 0, press_2d_y = 0, last_2d_x = 0, last_2d_y = 0;
        Microsoft::UI::Xaml::Controls::ToggleMenuFlyoutItem menu_2d{ nullptr };

        // The menu of the view, and the clipboard of parts
        // (MainWindow.ContextMenu.cpp).
        void ShowContextMenu(double x, double y);
        bool MenuPlace(double &x, double &y, double &z);
        void SupportEdited();
        void RemoveSupportHere();
        void CopyForAi();
        void NewProfile(int direction);
        void PreviewToLine();
        void ShowAllLayers();
        bool SelectLinePart();
        void CopyParts();
        void CutParts();
        void DuplicateParts();
        void PasteParts(bool here, double x, double y);
        bool NewPlateFrom(zs_app *from);
        bool ClipKey(Windows::System::VirtualKey key, bool shift);
        // The pointer, in points of the view.
        double pointer_x = 0, pointer_y = 0;
        Microsoft::UI::Xaml::Controls::MenuFlyout context_menu{ nullptr };
#ifdef ZS_DEV_HOOKS
        std::vector<std::pair<std::wstring, std::function<void()>>> context_actions;
#endif

        // Colors, the print as it forms, replay, gaps, check, and the bed
        // (MainWindow.View.cpp).
        void WireView();
        void SetColorMode(int mode);
        void ShowLegend();
        void OnSimulated();
        void ToggleSimulated();
        void TogglePlay();
        void StopReplay();
        void ReplayTick();
        bool LayerTimes(size_t layer, double &t0, double &t1);
        void ShowScrub(size_t layer, double t);
        void OnScrub(double fraction);
        void SetGaps(bool on);
        void ShowGaps();
        bool GapClick(double x, double y);
        void FillCheck();
        void GoToIssue(zs_issue const &issue);
        void ToggleBed();
        // The Support tool (MainWindow.Support.cpp).
        struct SupportTool;
        std::shared_ptr<SupportTool> support;
        bool pointer_alt = false, pointer_shift = false, press_right = false;
        void WireSupport();
        void SupportToolChanged();
        void SupportLoaded();
        void SupportReload();
        bool SupportPress(double x, double y);
        bool SupportDragging();
        void SupportDrag(double x, double y, bool shift);
        void SupportRelease();
        void SupportClick(double x, double y, bool shift, bool alt);
        void SupportPointer(double x, double y);
        bool SupportKey(Windows::System::VirtualKey key);
        bool SupportPicked();
        void SupportClearPick();
        bool SupportSelectLine(size_t path, size_t segment);
        bool SupportMenu(double x, double y);
#ifdef ZS_DEV_HOOKS
        bool SupportDevStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        void SupportDevLog();
        void StartDevHooks();
        void RunDevStep(std::wstring const &step);
        void LogDevState(std::wstring const &step);
        bool dev_started = false;
        size_t dev_next = 0;
        std::vector<std::wstring> dev_steps;
        Microsoft::UI::Dispatching::DispatcherQueueTimer dev_timer{ nullptr };
#endif
        void FillLineCard();
        void FillPartCard();
        void PlaceCard(Microsoft::UI::Xaml::FrameworkElement const &card, double const box[4]);
        void PlaceLineCard();
        void PlacePartCard();
        void HideCards();
        void MakeCardMovable(Microsoft::UI::Xaml::FrameworkElement const &card, Microsoft::UI::Xaml::FrameworkElement const &head, bool *moved);

        // The filaments, Paint, and Label (MainWindow.Filaments.cpp,
        // MainWindow.Paint.cpp, MainWindow.Label.cpp). Their state is in
        // those files.
        struct FilamentState;
        struct PaintState;
        struct LabelState;
        void WireFilaments();
        std::string FilamentValue(size_t i, char const *name);
        uint32_t FilamentRgb(int filament);
        int PartFilament(int64_t part);
        Microsoft::UI::Xaml::Controls::Button MakeFilamentChip(std::string const &color, std::wstring const &text, bool selected);
        int64_t AddFilament();
        void FilamentsChanged();
        void RefreshFilamentTools();
        void FillPartExtras();
        void WirePaint();
        void PaintTool(bool on);
        bool PaintPress(double x, double y, bool shift);
        bool PaintPressed();
        void PaintDrag(double x, double y);
        void PaintRelease();
        void PaintHover(double x, double y);
        void PaintReload();
        void PaintPartSelected(int64_t part);
        void PaintFilamentsChanged();
        void WireLabel();
        void LabelTool(bool on);
        bool LabelPress(double x, double y);
        bool LabelDragging();
        void LabelDrag(double x, double y, bool shift);
        void LabelRelease();
        void LabelClick(double x, double y);
        bool LabelWheel(double x, double y, int delta, bool shift);
        bool LabelKey(Windows::System::VirtualKey key);
        void LabelReload();
        void LabelPlace();
        void LabelOpen(int64_t part, uint32_t id);
        void LabelFilamentsChanged();
#ifdef ZS_DEV_HOOKS
        bool RunPaintStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        bool RunLabelStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        bool RunFilamentStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        bool PressNamed(std::wstring const &name);
#endif
        std::shared_ptr<FilamentState> filaments;
        std::shared_ptr<PaintState> paint;
        std::shared_ptr<LabelState> label;
        zs::PartMeshes meshes;
        // The press that starts a tool: Shift, and the left button.
        bool press_shift = false;
        bool press_left = true;

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

        Tool tool = Tool::Select;
        std::vector<Microsoft::UI::Xaml::Controls::Primitives::ToggleButton> tool_buttons;
        // The selection: a line, or one or more parts.
        int64_t selected_path = -1;
        int64_t selected_segment = -1;
        std::vector<int64_t> selected_parts;
        bool line_anchored = false;
        double anchor_x = 0, anchor_y = 0, anchor_z = 0;
        int anchor_feature = 0;
        double click_x = 0, click_y = 0;
        bool line_card_moved = false;
        bool part_card_moved = false;
        std::vector<SettingEditor> line_editors;
        // A drag of a tool.
        bool tool_drag = false;
        int64_t moving_part = -1;
        double move_x0 = 0, move_y0 = 0, bed_x0 = 0, bed_y0 = 0, moved_x = 0, moved_y = 0;
        std::vector<int64_t> move_group;
        std::vector<double> move_group_xy;
        int turn_axis = -1;
        int64_t turn_part = -1;
        double turn_want = 0, turn_sent = 0, turn_rotation = 0;
        double turn_pivot[3] = {};
        int tape_end = -1;
        double measure[6] = {};
        double measure_radius[2] = {};
        int measure_shape[2] = {};
        int measure_count = 0;
        // The hand of the Grab tool, and the fall of a part.
        Microsoft::UI::Dispatching::DispatcherQueueTimer fall_timer{ nullptr };
        std::chrono::steady_clock::time_point fall_last{};
        int64_t fall_part = -1;
        bool falling = false;
        bool hand = false;
        bool hand_click = false;
        bool hand_turning = false;
        double hand_height = 0, hand_x = 0, hand_y = 0, hand_turn_x = 0, hand_turn_y = 0;
        double hand_yaw = 0, hand_tilt = 0, hand_yaw_sent = 0, hand_tilt_sent = 0;

        Microsoft::UI::Dispatching::DispatcherQueueTimer session_timer{ nullptr };
        std::chrono::steady_clock::time_point session_due{};
        std::chrono::steady_clock::time_point last_input{};
        // False until the restore at launch is done: no session is written.
        bool session_ready = false;
        Windows::Graphics::SizeInt32 restore_size{ 1280, 860 };
        Microsoft::UI::Xaml::Controls::MenuFlyoutItem menu_undo{ nullptr };
        Microsoft::UI::Xaml::Controls::MenuFlyoutItem menu_redo{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleMenuFlyoutItem menu_bed{ nullptr };

        int color_mode = 0;
        bool simulated = false;
        bool sim_asked = false;
        bool gaps_on = false;
        bool bed_hidden = false;
        bool playing = false;
        bool scrub_quiet = false;
        double replay_time = 0;
        std::chrono::steady_clock::time_point replay_last{};
        Microsoft::UI::Dispatching::DispatcherQueueTimer replay_timer{ nullptr };
        std::vector<Microsoft::UI::Xaml::Controls::RadioMenuFlyoutItem> color_items;
        Microsoft::UI::Xaml::Controls::ToggleMenuFlyoutItem sim_item{ nullptr };
        Microsoft::UI::Xaml::Controls::Primitives::ToggleButton gaps_button{ nullptr };
        Microsoft::UI::Xaml::Controls::Flyout check_flyout{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel check_list{ nullptr };
    };
}

namespace winrt::ZSlice::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow>
    {
    };
}
