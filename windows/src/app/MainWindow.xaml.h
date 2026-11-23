#pragma once
#include "MainWindow.g.h"

#include <chrono>
#include <memory>

#include "zs_app_shell.h"
#include "zs_model.h"
#include "zs_open_link.h"
#include "zs_part_meshes.h"

namespace zs
{
    class Layer2D;
    namespace project
    {
        class Source;
    }
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
        // Why this plate cannot print (a part does not fit), or "".
        std::wstring PlateRefusal(zs_app *app);

        // Files.
        winrt::fire_and_forget PickFile();
        // new_plate: the file goes on a new plate if this plate has parts.
        void LoadPath(std::wstring path, bool new_plate = false);
        void FinishLoad(std::wstring const &path, std::string const &bytes, bool read, bool new_plate = false);

        // A file or a link from outside the app (MainWindow.Open.cpp).
        void StartOpenLinks();
        void StopOpenLinks();
        void OpenExternal(std::wstring const &argument);
        winrt::fire_and_forget AskOpenLink(std::wstring text);
        void DownloadLink(zs::openlink::ModelLink const &link);
        void FinishDownload(zs::openlink::Download const &result);

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
        // Where an editor reads and writes its value, in place of the print:
        // a range of layers (MainWindow.Range.cpp).
        struct EditorTarget
        {
            std::function<std::string(std::string const &)> get;
            std::function<void(std::string const &, std::string const &)> set;
            // The range card has no speed hint beside its units.
            bool no_hint = false;
        };
        // The search of settings and actions (MainWindow.Search.cpp).
        enum class SearchPlace
        {
            Header,
            Card,
            Left,
            Right,
        };
        // A search of some settings only, with its own values.
        struct SearchScope
        {
            std::wstring label;
            std::function<bool(zs_setting_info const &)> only;
            std::function<std::wstring(std::string const &)> source;
            std::shared_ptr<EditorTarget> target;
            // More lines under the name of a row.
            std::function<void(zs_setting_info const &, Microsoft::UI::Xaml::Controls::StackPanel const &)> decorate;
        };
        struct SearchRow
        {
            Microsoft::UI::Xaml::Controls::ContentControl node{ nullptr };
            Microsoft::UI::Xaml::Controls::Border back{ nullptr };
            Microsoft::UI::Xaml::Controls::Button eye{ nullptr };
            std::string name;
            std::function<void(int)> nudge;
            std::function<void()> activate;
        };
        struct SearchAction
        {
            std::wstring label, keys, hint;
            std::function<void()> run;
        };
        void WireSearch();
        void OpenSearch(bool focus);
        void OpenScopedSearch(std::shared_ptr<SearchScope> scope);
        void ShowSearchScope();
        void CloseSearch();
        void SetSearchPlace(SearchPlace place);
        void FillSearch();
        void PlaceSearch();
        void FillSearchPins();
        void SelectSearchRow(int index, bool focus);
        void SearchPreviewKey(Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const &e);
        bool SearchKeyPress(Windows::System::VirtualKey key, bool ctrl);
        void RestoreSearchPlace();
        void ShowSearchField();
        void UpdateSearchField();
        void AddSearchSetting(zs_setting_info const &info);
        void AddSearchAction(SearchAction const &action);
        std::vector<SearchAction> SearchActions();
        void SetSearchEye(std::string const &name);
        void ApplySearchEye();
        void RefreshSearchValues();
        void FlushSearchDrag();
        void SaveSearchCard();
        bool InsideSearch(Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const &e);
        Microsoft::UI::Xaml::Controls::TextBox ActiveSearchEntry();
        void SupportRefocus();

        void WireSettings();
        void ShowSettingsPane(bool show);
        void ShowSections();
        int NozzleCount();
        void ShowSection(char const *group, char const *section);
        void ShowSpeedSection();
        void RedrawSettingsPage();
        // Whose setting it is: the printer or the filament, with its name.
        // With `rest`, a line of text. Without it, a badge. Null for a
        // setting of the print.
        std::wstring OwnerText(bool printer);
        Microsoft::UI::Xaml::FrameworkElement OwnerLabel(char const *group, wchar_t const *rest);
        // The lines that a setting changes, and the settings of some lines.
        void FillEffect(Microsoft::UI::Xaml::Controls::StackPanel const &box, std::string const &key);
        void ShowFeature(int feature);
        void SetPaneFocus(uint32_t mask, bool first_layer);
        void ApplyPaneFocus();
        // The layer profiles (MainWindow.Profiles.cpp).
        // Import from a model page or a ZIP file (MainWindow.ModelImport.cpp).
        struct ImportState;
        std::shared_ptr<ImportState> import_state;
        static bool IsZipName(std::wstring const &name);
        winrt::fire_and_forget AskImport(std::wstring text, bool from_link = false);
        winrt::fire_and_forget ImportZip(std::wstring name, std::shared_ptr<std::string> bytes);
        void RunImport(std::shared_ptr<ImportState> state);
        void FinishImport(std::vector<std::pair<std::wstring, std::string>> const &files, std::wstring errors, size_t total);
        void WireProfiles();
        // "Settings for" (MainWindow.Scope.cpp).
        void WireScope();
        std::shared_ptr<EditorTarget> PaneTarget();
        bool ScopeEditable(zs_setting_info const &info);
        wchar_t const *ScopeOffTip();
        bool ScopeIsGlobal() const;
        bool PartOwnValue(std::string const &name, std::string &out);
        std::string ScopeValue(std::string const &name);
        void ScopeSet(std::string const &name, std::string const &value);
        bool ScopeReset(std::string const &name);
        void GlobalChanged();
        void SetSettingsScope(int64_t scope);
        void FillScopeList();
        void ScopeRefresh();
        // The settings of a part on its card.
        void WirePartSettings();
        void FillPartSettings(int64_t part);
        void RefreshPartSettings();
        void OpenPartSearch();
        std::shared_ptr<EditorTarget> PartTarget(std::vector<int64_t> const &parts);
        void AppendProfileRows();
        void OpenProfile(double z_min, double z_max);
        void EnterProfile(double z_min, double z_max);
        void LeaveProfile();
        void ShowProfileChanges();
        void UpdateProfileBar();
        void ProfilesRefresh();
        void UpdateLayerMarks();
        void PlaceLayerMarks();
        bool ProfileHas(std::string const &name);
        std::string ProfileValue(std::string const &name);
        void ProfileSet(std::string const &name, std::string const &value);
        void ProfileClear(std::string const &name);
        size_t RangeChanges(double z_min, double z_max);
        std::wstring RangeLayers(double z_min, double z_max);
        std::wstring RangeName(double z_min, double z_max);
        void ShowSearch(std::wstring const &query);
        void ShowDetail(char const *name);
        void SettingsGoBack();
        void ClearSettingsList();
        Microsoft::UI::Xaml::FrameworkElement MakeSettingRow(zs_setting_info const &info, bool with_section = false);
        // Where the value of a row comes from. "" for a default. mine: a
        // change of this print or part.
        std::wstring RowSource(std::string const &key, bool per_part, bool &mine);
        // The lines that the settings of a section change.
        uint32_t SectionFocus(char const *group, char const *section);
        // The rows of a search come in batches, so typing stays smooth.
        void AppendSearchRows(std::shared_ptr<std::vector<uint32_t>> const &hits, size_t from, uint64_t fill);
        uint64_t pane_fill = 0;
        void TurnOffForScope(Microsoft::UI::Xaml::FrameworkElement const &editor, zs_setting_info const &info);
        Microsoft::UI::Xaml::FrameworkElement MakeEditor(zs_setting_info const &info, std::shared_ptr<EditorTarget> const &target = nullptr);
        void CommitSetting(std::string const &name, std::string const &value);
        // The state of a field: 0 plain, 1 an unusual value, 2 an error.
        struct EditorField
        {
            Microsoft::UI::Xaml::Controls::TextBox box{ nullptr };
            Microsoft::UI::Xaml::Controls::Border mark{ nullptr };
            Microsoft::UI::Dispatching::DispatcherQueueTimer live{ nullptr };
            // The text that the code put there: its change event is no edit.
            std::wstring shown, doc;
            int state = 0;
            // The slider of the field follows the value of the core.
            std::function<void(std::string const &)> follow;
        };
        // The field of the last editor that MakeEditor made, or null.
        std::shared_ptr<EditorField> made_field;
        Microsoft::UI::Xaml::FrameworkElement MakeFieldSlider(std::shared_ptr<EditorField> const &field, zs_setting_info const &info,
                                                              std::shared_ptr<EditorTarget> const &target, std::string const &now);
        // A drag on the name changes the number: 6 points for each step.
        void AddScrub(Microsoft::UI::Xaml::FrameworkElement const &label, std::shared_ptr<EditorField> const &field, zs_setting_info const &info,
                      std::shared_ptr<EditorTarget> const &target);
        void SetFieldState(EditorField &field, int state, std::wstring const &tip);
        void ShowUnusual(EditorField &field, zs_setting_info const &info, std::string const &value);
        void StepField(EditorField &field, zs_setting_info const &info, std::wstring const &base, double steps, bool fine, int delay_ms);
        // Sends the text of an editor to the core. quiet: the user is still
        // typing, so a refused value shows no error. True if the core has it.
        bool CommitSettingText(zs_setting_info const &info, std::wstring const &text, EditorTarget const *target, EditorField *field = nullptr, bool quiet = false);
        void RefreshSettingValues();
        void NoteChange();
        void RefreshHistoryButtons();
        // The hover card and the list of the history (MainWindow.History.cpp).
        void WireHistory();
        void GoToStep(size_t step);
        void OpenHistoryChange(size_t step, std::string const &line);
        void ClearHistoryAfter(size_t step);
        void ShowStepMenu(Microsoft::UI::Xaml::FrameworkElement const &target, Windows::Foundation::Point at, size_t step);
        void MarkHistorySaved();
        size_t UnsavedChanges();
        void RefreshHistoryButton();
        void LayoutDock(double width);
        void FillHistoryList();
        void RevertChange(std::string const &line);
        void AfterRestore(int bits);

        // The comparison with Cura (MainWindow.CuraCompare.cpp).
        struct CuraCompare;
        std::shared_ptr<CuraCompare> cura;
        void ShowCuraCompare();
        void CuraSettingsChanged();
        void CloseCuraCompare();
#ifdef ZS_DEV_HOOKS
        std::string FilamentNozzleLog();
        bool CuraDevStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        Microsoft::UI::Xaml::UIElement CuraDevRoot();
#endif

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
        void AddMeasure(double x, double y, double z, double radius, int shape);
        void ShowMeasure();
        // The readout goes beside the tape, and covers no part of it.
        void PlaceMeasure();
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

        // The card of a range of layers (MainWindow.Range.cpp). Its state is
        // in that file.
        struct RangeState;
        std::shared_ptr<RangeState> range;
        void WireRange();
        bool RangeOpen();
        void RangeClose();
        void RangeKey(int direction);
        bool RangePress(double x, double y);
        bool RangeDragging();
        bool RangeDragLit();
        void RangeDrag(double x, double y);
        void RangeRelease();
        void RangeScene();
        void RangeRefresh();
        void RangePlace();
        // The changes of the layers of the card: name and value.
        std::vector<std::pair<std::string, std::string>> RangeChangesNow();
        void RangePaste(std::vector<std::pair<std::string, std::string>> const &changes);
        void RangeClearChanges(std::vector<std::pair<std::string, std::string>> const &changes);
#ifdef ZS_DEV_HOOKS
        bool RunRangeStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        bool RunProfileStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        bool RunScopeStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        bool RunModelImportStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        Microsoft::UI::Xaml::UIElement RangeDevRoot();
#endif

        // The session (MainWindow.Session.cpp).
        void WireSession();
        void SessionSoon();
        void SaveSession(bool wait);
        bool RestoreSession();
        void ShowPlateChrome();

        // The main menu and its dialogs (MainWindow.Menu.cpp).
        void WireMenu();
        void ApplyTheme();
        void ShowDialog(hstring const &title, Microsoft::UI::Xaml::UIElement const &content);
        void ShowShortcuts();
        void ShowLicenses();
        void ShowAbout();
        // Preferences (MainWindow.Preferences.cpp).
        void WirePreferences();
        void ShowPreferences();
        bool PreferencesOpen();
        void ApplyThemePref();
        void ApplyFirstViewPref();
        // idle: no plate slices yet, so each plate can change now.
        void ApplyEnginePrefs(bool idle = false);
        void KeepEnginePref(std::string const &name);
        void ShowGeneralPreferences();
        void PreferencesThemeChanged();
        void ThemeDialog(Microsoft::UI::Xaml::Controls::ContentDialog const &dialog);
#ifdef ZS_DEV_HOOKS
        bool RunPreferencesStep(std::wstring const &verb, std::vector<std::wstring> const &words);
#endif
        // A short note over the dock, for a few seconds.
        void ShowToast(winrt::param::hstring const &text);
        Microsoft::UI::Dispatching::DispatcherQueueTimer toast_timer{ nullptr };
        bool InViewFocus(Windows::Foundation::IInspectable const &focused);
        void StepPart(int direction);

        // A printdeck.yml project (MainWindow.Project.cpp). Its state is in
        // that file.
        struct ProjectUi;
        std::shared_ptr<ProjectUi> project_ui;
        void WireProject();
        void ProjectStart();
        void CloseProjectUi();
        void AddProjectMenuItems();
        void RefreshProjectMenu();
        void ShowProjectDialog();
        void HideProjectDialog();
        void CloseProject();
        std::wstring ProjectName();
        void ProjectPlatesChanged();
        std::wstring ProjectPrintStatus(size_t plate);
        void ProjectFileOpening(bool project_file, bool new_plate);
        std::string ProjectSessionText();
        void ProjectSessionRead(std::string const &text);
        void ProjectRender();
        void ProjectRenderSoon();
        void ProjectKeepFocus();
        void ProjectReplan();
        void ProjectSave();
        void ProjectFail(std::wstring const &text);
        winrt::fire_and_forget ProjectPickFolder();
        void ProjectOpenFolder(std::wstring const &folder);
        void ProjectOpenGithub(std::wstring const &text);
        void ProjectOpened(uint64_t epoch, std::shared_ptr<zs::project::Source> const &source, std::string const &yml, std::string const &error);
        void ProjectOpenPlate(size_t index);
        void ProjectPlateFiles(uint64_t epoch, size_t index, std::shared_ptr<zs_files> const &files, std::string const &error);
        void ProjectSetCount(size_t part, int value);
        void ProjectSetStatus(std::string const &key, std::string const &status);
        void RefreshProjectTotals();
#ifdef ZS_DEV_HOOKS
        bool RunProjectStep(std::wstring const &verb, std::vector<std::wstring> const &words);
#endif

        // A profile of another slicer (MainWindow.Import.cpp).
        winrt::fire_and_forget PickProfile();
        void ImportProfilePath(std::wstring path);
        void FinishImport(std::wstring const &path, std::string const &bytes, bool read);
        void ShowImportReport(std::wstring const &file, std::string const &report);
        // Calibration prints (MainWindow.Calibrate.cpp).
        void AddCalibrateMenu();
        void AddCalibrateActions(std::vector<SearchAction> &out);
        void Calibrate(int kind);
        void ShowCalibration();
        void UseCalibrationValue(std::string const &setting, std::string const &value);
#ifdef ZS_DEV_HOOKS
        bool RunImportStep(std::wstring const &verb, std::vector<std::wstring> const &words);
        bool RunCalibrateStep(std::wstring const &verb, std::vector<std::wstring> const &words);
#endif

        // The chrome that all apps share (MainWindow.Chrome.cpp).
        void WireChrome();
        void LayoutHeader();
        size_t LayerAt(double y);
        void RailMove(size_t at);
        void StepLayerLo(int direction);
        void ApplyLayerRange();
        void UpdateLayerRail();
        void RefreshSummary();
        void ShowBusy(winrt::param::hstring const &text);
        void PlaceEmptyOpen();
        size_t layer_lo = 0;
        // A drag of the rail: 1 the top knob, 2 the bottom knob.
        int rail_drag = 0;

        // The 2D view of the top layer (MainWindow.Layer2D.cpp).
        void Wire2D();
        void Size2D();
        void Fit2D();
        void Set2D(bool on);
        void Draw2D();
        void Click2D(double x, double y, bool shift = false);
        void MeasureClick2D(double x, double y, bool shift);
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
        void CopyForAi(wchar_t const *done = L"Copied a report of this line.");
        void NewProfile(int direction);
        void PreviewToLine();
        void ShowAllLayers();
        bool SelectLinePart();
        void CopyParts();
        void CutParts();
        void DuplicateParts();
        void PasteParts(bool here, double x, double y);
        bool NewPlateFrom(zs_app *from);
        // The last copy, of one kind, for Ctrl+V. The core keeps the parts.
        enum class ClipKind { Empty, Parts, Label, Area, Range, Value };
        // What a copy takes now: the first that applies.
        enum class ClipSel { None, Value, Label, Area, Range, Parts, Line };
        // A support area, with the part under it.
        struct ClipArea
        {
            int kind = 0;
            double z_lo = 0, z_hi = 0;
            std::vector<double> pts;
            int64_t part = -1;
            double part_x = 0, part_y = 0, part_rot = 0;
        };
        // The switch or list of a setting that has the focus.
        struct ClipEditor
        {
            Windows::Foundation::IInspectable element{ nullptr };
            std::string name;
            std::function<std::string()> get;
            std::function<void(std::string const &)> set;
        };
        ClipKind clip_kind = ClipKind::Empty;
        std::string clip_label;
        std::vector<std::pair<std::string, std::string>> clip_range;
        ClipArea clip_area;
        std::string clip_value;
        std::optional<ClipEditor> focused_editor;
        // The test build keeps its copies out of the system clipboard.
        bool clip_private = false;
        ClipKind ClipNow() const;
        ClipSel ClipSelection();
        bool FocusedEditor();
        bool ClipCopy(ClipSel sel);
        winrt::fire_and_forget PasteValue();
        void ClipCut();
        void ClipDuplicate();
        void ClipPaste(bool at, double x, double y, bool here, bool as_plate);
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
        void ShowCheckCount(size_t count);

        // The details of the print (MainWindow.Summary.cpp).
        struct RefineTip
        {
            std::string line;
            std::wstring where, what;
            int count = 0;
        };
        void WireSummary();
        void WireWork();
        void StopWork();
        void WorkBegin(int kind);
        void WorkEnd();
        void WorkProgress(double fraction);
        void WorkSliceEnded(bool draft);
        void WorkTick();
        void ShowWorkText();
        void FillFacts();
        bool FillSummaryWarn();
        void UpdateSummaryBadge(bool warn);
        void RefreshRefine();
        void ShowRefineTips();
        void ApplyRefine(RefineTip const &tip);
        void SearchFor(std::wstring const &query);
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
        // Copy and paste of the selected support area.
        bool SupportHasArea();
        bool SupportCopyArea(ClipArea &out);
        bool SupportPasteArea(ClipArea const &area, double x, double y);
        void SupportRemoveArea();
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
        // The filament of a body of a line (MainWindow.Range.cpp).
        void FillLineFilament();
        // An edit of the selected line. Its key works while a slice runs.
        int EditSelectedLine(int kind, double value);
        // Shift+click in the Select tool: the line and its whole run.
        void SelectRun(size_t path, size_t segment);
        // Ends a fall of a part, on the plate where it started.
        void CancelFall();
        // The support mark of the user at the selected line.
        void WireLineMark();
        void FillLineMark();
        int64_t MarkOfSelection();
        void DrawLineChips();
        void PickLineFilament(int filament);
        void ExtendLineFilament(int direction);
        void ClearLineExtend();
        void LightLine(int64_t path, size_t lo, size_t hi, int filament);
        void LineLightAfterSlice();
        bool PaintBeads(std::vector<float> const &beads, int filament);
        void FillPartCard();
        void FillPartOrder();
        void MovePartInOrder(int direction);
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
        // One chip for each filament of the plate, and "+". The panel stays
        // as it is while its filaments and its value stay.
        void FillFilamentChips(Microsoft::UI::Xaml::Controls::VariableSizedWrapGrid const &panel, std::string &key_store, int value, std::wstring const &what,
                               std::function<void(int)> const &pick, wchar_t const *zero = nullptr);
        // The settings with a chip for each filament, and the word on the
        // chip of value 0 (nullptr: no such chip).
        static bool IsFilamentSetting(char const *name);
        static wchar_t const *ZeroChip(char const *name);
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
        void LabelHover(double x, double y);
        void LabelDropSvg(std::wstring const &path, double x, double y);
        bool LabelKey(Windows::System::VirtualKey key);
        void LabelReload();
        void LabelPlace();
        void LabelOpen(int64_t part, uint32_t id);
        void LabelFilamentsChanged();
        // Copy and paste of the selected label, as its JSON.
        bool LabelHasSelection();
        std::string LabelCopyJson();
        bool LabelPaste(std::string const &json, bool at_point, double x, double y);
        void LabelRemoveSelected();
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
        // The Faster slicing switch while the Speed section shows.
        Microsoft::UI::Xaml::Controls::ToggleSwitch speed_toggle{ nullptr };
        // "Settings for": -1 this print, -2 global, else a part.
        int64_t settings_scope = -1;
        zs_app *scope_app = nullptr;
        bool filling_scope = false;
        std::vector<std::wstring> scope_items;
        std::shared_ptr<EditorTarget> scope_target;
        std::string settings_detail;
        int settings_feature = -1;
        // The lines that the open setting changes, on its page.
        Microsoft::UI::Xaml::Controls::StackPanel effect_box{ nullptr };
        std::string effect_key;
        // The lines that the pane shows in the view. 0: none.
        uint32_t pane_focus = 0;
        bool pane_focus_first = false, pane_focus_on = false;
        std::string part_settings_key;
        std::vector<SettingEditor> part_editors;
        // The layer profile in edit, and the marks of the layer rail.
        bool in_profile = false;
        double profile_min = 0, profile_max = 0;
        zs_app *profile_app = nullptr;
        std::shared_ptr<EditorTarget> profile_target;
        std::string profile_key;
        struct LayerMark
        {
            size_t lo = 0, hi = 0;
            double z_min = 0, z_max = 0;
            std::wstring label;
            Microsoft::UI::Xaml::Controls::Border hit{ nullptr };
        };
        std::vector<LayerMark> layer_marks;
        std::string layer_marks_key;
        std::wstring settings_query;
        // The number of nozzles that the section list shows.
        int settings_nozzles = 1;
        // True while the code fills an editor: its change event is no edit.
        bool filling_editor = false;

        // The time of the last open or save, and what the button shows.
        int64_t history_saved_ms = 0;
        bool history_mark_late = false;
        zs_app *history_shown_app = nullptr;
        size_t history_shown_count = (size_t)-1, history_shown_now = (size_t)-1;
        bool dock_laid_out = false, dock_narrow = false;

        size_t check_problems = 0;
        std::vector<RefineTip> refine_tips;
        // The id of each plate in the store of the refinements.
        std::vector<std::string> refine_ids;
        Microsoft::UI::Dispatching::DispatcherQueueTimer refine_timer{ nullptr };
        // The work bar (MainWindow.Work.cpp). work_kind: 0 none, 1 draft,
        // 2 exact, 3 simulation.
        Microsoft::UI::Dispatching::DispatcherQueueTimer settle_timer{ nullptr }, work_show{ nullptr }, work_poll{ nullptr };
        int work_kind = 0;
        double work_fraction = 0;
        bool work_draft = false;
        bool work_has_ended = false;
        std::chrono::steady_clock::time_point work_start{}, work_ended{};

        std::unique_ptr<zs::appshell::OpenServer> open_server;
        zs::http::CancelPtr download_cancel;
        bool link_asking = false;

        SearchPlace search_place = SearchPlace::Header;
        bool search_open = false;
        // The text of the entry: a change from the code is no new search.
        std::wstring search_text;
        std::vector<SearchRow> search_rows;
        int search_index = 0;
        std::vector<SettingEditor> search_editors;
        std::string search_eye;
        bool search_eye_set = false;
        bool search_click = false;
        Windows::Foundation::Point search_press{};
        // A drag of the card or of its corner: the point in the card.
        int search_drag = 0;
        double search_drag_x = 0, search_drag_y = 0;
        double search_x = -1, search_y = -1, search_w = 0, search_h = 0;
        // A slider sends a value at most each 90 ms.
        Microsoft::UI::Dispatching::DispatcherQueueTimer search_timer{ nullptr };
        std::function<void()> search_pending;
        std::chrono::steady_clock::time_point search_sent{};
        // The scope of the open search, or null, and its label.
        std::shared_ptr<SearchScope> search_scope;
        Microsoft::UI::Xaml::Controls::Border search_scope_tag{ nullptr };

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
        uint64_t line_key = 0;
        size_t line_key_layer = 0;
        int64_t line_key_path = -1;
        bool run_lit = false;
        size_t run_others = 0;
        zs_app *fall_app = nullptr;
        int64_t line_mark = -1;
        bool line_mark_filling = false;
        // The body of the last filament pick: the beads above and below,
        // taken before the slice numbers the lines again.
        struct LineBody
        {
            std::vector<float> above, below;
            // The filament of the pick. The line that the next slice selects
            // can have another filament.
            int filament = 0;
            Microsoft::UI::Xaml::Controls::Button above_button{ nullptr }, below_button{ nullptr };
        };
        LineBody line_body;
        int line_filament = 0;
        std::string line_chips_key;
        bool line_lit = false;
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
        double measure_box[4] = { 1e9, 1e9, -1e9, -1e9 };
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
        // The gap of the gap card, for the 2D view.
        int64_t gap_selected = -1;
        size_t gap_selected_layer = 0;
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
        Microsoft::UI::Xaml::Controls::Button check_button{ nullptr };
        Microsoft::UI::Xaml::Controls::Border check_count{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock check_count_text{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel check_list{ nullptr };
    };
}

namespace winrt::ZSlice::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow>
    {
    };
}
