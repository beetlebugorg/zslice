// See zs_model.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_model.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cmath>
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <mutex>

namespace zs
{
    void Log(char const *format, ...)
    {
        char text[1024];
        va_list args;
        va_start(args, format);
        int n = vsnprintf(text, sizeof text, format, args);
        va_end(args);
        if (n <= 0)
            return;
        DWORD written = 0;
        ::WriteFile(::GetStdHandle(STD_ERROR_HANDLE), text, (DWORD)std::min<size_t>((size_t)n, sizeof text - 1), &written, nullptr);
    }

    std::string ToUtf8(std::wstring const &text)
    {
        if (text.empty())
            return {};
        int n = ::WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0, nullptr, nullptr);
        std::string out(n, '\0');
        ::WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n, nullptr, nullptr);
        return out;
    }

    std::wstring ToWide(std::string const &text)
    {
        if (text.empty())
            return {};
        int n = ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0);
        std::wstring out(n, L'\0');
        ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n);
        return out;
    }

    std::wstring StateDir()
    {
        wchar_t dir[MAX_PATH];
        DWORD n = ::GetEnvironmentVariableW(L"ZSLICE_STATE_DIR", dir, MAX_PATH);
        std::wstring path;
        if (n > 0 && n < MAX_PATH)
        {
            path = dir;
        }
        else
        {
            n = ::GetEnvironmentVariableW(L"APPDATA", dir, MAX_PATH);
            std::wstring appdata(dir, n < MAX_PATH ? n : 0);
            path = appdata + L"\\zslice";
            static std::once_flag moved;
            std::call_once(moved, [&] { MoveOldStateFiles(appdata); });
        }
        ::CreateDirectoryW(path.c_str(), nullptr);
        return path;
    }

    void MoveOldStateFiles(std::wstring const &appdata)
    {
        if (appdata.empty())
            return;
        std::wstring old_dir = appdata + L"zslice", new_dir = appdata + L"\\zslice";
        ::CreateDirectoryW(new_dir.c_str(), nullptr);
        for (wchar_t const *name : { L"session.zslice", L"session.zslice.bad", L"last-slice.gcode" })
        {
            // With no replace flag, a file in the new folder stays.
            std::wstring from = old_dir + L"\\" + name, to = new_dir + L"\\" + name;
            ::MoveFileExW(from.c_str(), to.c_str(), MOVEFILE_COPY_ALLOWED);
        }
        // This removes the old folder only if it is empty.
        ::RemoveDirectoryW(old_dir.c_str());
    }

    Model::Model(std::function<void(Event const &)> post) : post_(std::move(post)) {}

    Model::~Model()
    {
        // zs_set_free stops each slice, so no event comes after it.
        if (set_ != nullptr)
            zs_set_free(set_);
        if (printers_ != nullptr)
            zs_printers_free(printers_);
    }

    int Model::Start()
    {
        int rc = zs_set_new(&Model::OnEvent, this, &set_);
        if (rc != ZS_OK)
            return rc;
        SyncActive();
        return ZS_OK;
    }

    // On the thread of each slice: the simulated print and the check of the
    // active plate, and the scene of the view of each plate.
    // A plate that went takes its draft with it.
    void Model::DropGoneDraft()
    {
        if (draft_app_ == nullptr)
            return;
        for (size_t i = 0; i < zs_set_count(set_); i++)
            if (zs_set_app(set_, i) == draft_app_)
                return;
        draft_app_ = nullptr;
    }

    void Model::SyncActive()
    {
        DropGoneDraft();
        zs_app *app = Active();
        zs_app_set_auto_simulate(app, 1);
        zs_app_set_auto_checks(app, 1);
        for (size_t i = 0; i < zs_set_count(set_); i++)
            zs_app_set_auto_scene(zs_set_app(set_, i), 1);
        slice_pending_ = false;
        // The first step of the undo list of a new plate.
        if (zs_app_history_count(app) == 0)
            HistoryCommit();
    }

    void Model::AfterSessionRead()
    {
        SyncActive();
        for (size_t i = 0; i < zs_set_count(set_); i++)
            zs_set_changed(set_, i);
    }

    int Model::LoadProject(zs_files const *files, std::string const &yml, std::string const &counts, size_t active, std::string &message)
    {
        char text[1024] = "";
        int rc = zs_set_project_load(set_, files, yml.c_str(), counts.c_str(), active, text, sizeof text);
        if (rc != ZS_OK)
        {
            message = text[0] != 0 ? text : zs_status_message(rc);
            return rc;
        }
        SyncActive();
        // The load starts the slice of the active plate before the flags of
        // SyncActive are on. A change slices it again with them. A plate
        // that failed keeps its message, so it gets no change.
        zs_plate_info info{};
        size_t now = zs_set_active(set_);
        if (zs_set_plate_info(set_, now, &info) == ZS_OK &&
            (info.status == ZS_PLATE_STATUS_STALE || info.status == ZS_PLATE_STATUS_SLICING))
            zs_set_changed(set_, now);
        return ZS_OK;
    }

    bool Model::KeepActivePlate()
    {
        if (zs_set_keep_active(set_) != ZS_OK)
            return false;
        SyncActive();
        return true;
    }

    bool Model::AddPlate()
    {
        // The pending edit ends on the plate that it belongs to.
        HistoryCommit();
        if (zs_set_add(set_) < 0)
            return false;
        SyncActive();
        return true;
    }

    bool Model::SelectPlate(size_t i)
    {
        if (i == zs_set_active(set_) || i >= zs_set_count(set_))
            return false;
        HistoryCommit();
        if (zs_set_select(set_, i) != ZS_OK)
            return false;
        SyncActive();
        return true;
    }

    bool Model::RemovePlate(size_t i)
    {
        HistoryCommit();
        if (zs_set_remove(set_, i) != ZS_OK)
            return false;
        SyncActive();
        return true;
    }

    zs_printers *Model::Printers()
    {
        if (!printers_tried_)
        {
            printers_tried_ = true;
            if (zs_printers_builtin(&printers_) != ZS_OK)
                printers_ = nullptr;
        }
        return printers_;
    }

    bool Model::UsePrinter(std::string const &id, std::string &message)
    {
        zs_printers *lib = Printers();
        ptrdiff_t i = lib != nullptr ? zs_printers_find(lib, id.c_str()) : -1;
        if (i < 0)
        {
            message = "No printer " + id + " in the library.";
            return false;
        }
        size_t len = 0;
        if (zs_printers_profile(lib, (size_t)i, 0, nullptr, 0, &len) != ZS_OK)
        {
            message = "The printer has no profile.";
            return false;
        }
        std::string text(len + 1, '\0');
        if (zs_printers_profile(lib, (size_t)i, 0, text.data(), text.size(), &len) != ZS_OK)
        {
            message = "The printer has no profile.";
            return false;
        }
        text.resize(len);
        zs_app *app = Active();
        zs_app_group_reset(app, ZS_GROUP_MACHINE);
        char error[256] = "";
        int rc = zs_app_profile_apply(app, ZS_GROUP_MACHINE, text.c_str(), text.size(), error, sizeof error);
        if (rc != ZS_OK)
        {
            message = error[0] ? error : zs_status_message(rc);
            return false;
        }
        if (zs_app_part_count(app) > 0)
        {
            LiveChange();
            MarkSliceStart();
            zs_set_changed(set_, zs_set_active(set_));
        }
        return true;
    }

    namespace
    {
        std::wstring BedsDir()
        {
            wchar_t dir[MAX_PATH];
            DWORD n = ::GetEnvironmentVariableW(L"ZSLICE_BEDS_DIR", dir, MAX_PATH);
            if (n > 0 && n < MAX_PATH)
                return dir;
            n = ::GetModuleFileNameW(nullptr, dir, MAX_PATH);
            std::wstring path(dir, n);
            size_t at = path.find_last_of(L'\\');
            return (at == std::wstring::npos ? std::wstring() : path.substr(0, at)) + L"\\beds";
        }

        bool ReadBedFile(char const *name, std::string &bytes)
        {
            bytes.clear();
            if (name == nullptr || name[0] == 0)
                return false;
            return Model::ReadFile(BedsDir() + L"\\" + ToWide(name), bytes);
        }
    }

    void Model::UpdateBed(zs_view *view)
    {
        zs_printers *lib = Printers();
        if (view == nullptr || lib == nullptr)
            return;
        zs_app *app = Active();
        char model[256] = "", name[256] = "";
        size_t n = 0;
        if (zs_app_setting_get(app, "machine.model", model, sizeof model, &n) != ZS_OK)
            model[0] = 0;
        if (zs_app_setting_get(app, "machine.name", name, sizeof name, &n) != ZS_OK)
            name[0] = 0;
        ptrdiff_t i = zs_printers_find_machine(lib, model, name);
        if (view == bed_view_ && i == bed_shown_)
            return;
        bed_view_ = view;
        bed_shown_ = i;
        zs_printer_bed bed{};
        if (i < 0 || zs_printers_bed(lib, (size_t)i, &bed) != ZS_OK)
        {
            zs_view_clear_bed(view);
            return;
        }
        std::string mesh, texture;
        bool has_mesh = ReadBedFile(bed.mesh, mesh);
        bool has_texture = ReadBedFile(bed.texture, texture);
        if (!has_mesh && !has_texture)
        {
            zs_view_clear_bed(view);
            return;
        }
        int rc = zs_view_set_bed(view, lib, (size_t)i,
                                 has_mesh ? reinterpret_cast<uint8_t const *>(mesh.data()) : nullptr, has_mesh ? mesh.size() : 0,
                                 has_texture ? reinterpret_cast<uint8_t const *>(texture.data()) : nullptr, has_texture ? texture.size() : 0);
        if (rc != ZS_OK)
        {
            Log("shell: the bed model %s did not load: %s\n", bed.mesh, zs_status_string(rc));
            zs_view_clear_bed(view);
        }
    }

    zs_app *Model::Active() const
    {
        return zs_set_app(set_, zs_set_active(set_));
    }

    bool Model::IsActive(size_t plate) const
    {
        return plate == zs_set_active(set_);
    }

    void Model::OnEvent(void *user, size_t plate, int event, double progress, int status)
    {
        static_cast<Model *>(user)->post_(Event{ plate, event, progress, status });
    }

    bool Model::ReadFile(std::wstring const &path, std::string &bytes)
    {
        HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                    FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            return false;
        LARGE_INTEGER size{};
        bool ok = ::GetFileSizeEx(file, &size) != 0 && size.QuadPart < (1LL << 40);
        if (ok)
        {
            bytes.resize((size_t)size.QuadPart);
            size_t done = 0;
            while (ok && done < bytes.size())
            {
                DWORD piece = (DWORD)std::min<size_t>(bytes.size() - done, 1u << 30);
                DWORD got = 0;
                ok = ::ReadFile(file, bytes.data() + done, piece, &got, nullptr) != 0 && got > 0;
                done += got;
            }
        }
        ::CloseHandle(file);
        return ok;
    }

    int Model::Load(std::wstring const &name, std::string const &bytes, std::string &message)
    {
        auto const *data = reinterpret_cast<uint8_t const *>(bytes.data());
        size_t active = zs_set_active(set_);
        // A project file of zslice: its plates replace the plates.
        if (zs_project_file_is(data, bytes.size()))
        {
            char text[512] = "";
            int rc = zs_set_project_open(set_, data, bytes.size(), text, sizeof text);
            message = text;
            if (rc != ZS_OK)
            {
                if (message.empty())
                    message = zs_status_message(rc);
                return rc;
            }
            for (size_t i = 0; i < zs_set_count(set_); i++)
            {
                zs_app_set_auto_scene(zs_set_app(set_, i), 1);
                zs_set_changed(set_, i);
            }
            return ZS_OK;
        }
        std::string utf8 = ToUtf8(name);
        // A plate with parts gets one more. Its parts and edits stay.
        if (zs_app_part_count(zs_set_app(set_, active)) > 0)
        {
            ptrdiff_t part = zs_app_add_stl(zs_set_app(set_, active), utf8.c_str(), data, bytes.size());
            if (part < 0)
            {
                message = zs_status_message((int)-part);
                return (int)-part;
            }
            LiveChange();
            MarkSliceStart();
            int changed = zs_set_changed(set_, active);
            if (changed != ZS_OK)
                message = zs_status_message(changed);
            return changed;
        }
        int rc = zs_app_load_stl(zs_set_app(set_, active), utf8.c_str(), data, bytes.size());
        if (rc == ZS_OK)
        {
            zs_set_name(set_, active, utf8.c_str());
            LiveChange();
            MarkSliceStart();
            rc = zs_set_changed(set_, active);
        }
        if (rc != ZS_OK)
            message = zs_status_message(rc);
        return rc;
    }

    namespace
    {
        // The buffer rule of the core: a NULL buffer gives the length.
        template <typename F>
        std::string ReadText(F const &get)
        {
            size_t len = 0;
            if (get(static_cast<char *>(nullptr), size_t{ 0 }, &len) != ZS_OK)
                return {};
            std::string text(len + 1, '\0');
            if (get(text.data(), text.size(), &len) != ZS_OK)
                return {};
            text.resize(len);
            return text;
        }

        int64_t NowMs()
        {
            FILETIME ft{};
            ::GetSystemTimeAsFileTime(&ft);
            ULARGE_INTEGER t{};
            t.LowPart = ft.dwLowDateTime;
            t.HighPart = ft.dwHighDateTime;
            // From 1601 in units of 100 ns to 1970 in ms.
            return (int64_t)(t.QuadPart / 10000) - 11644473600000LL;
        }
    }

    std::string Model::GetSetting(char const *name) const
    {
        zs_app *app = Active();
        return ReadText([&](char *buf, size_t cap, size_t *len) { return zs_app_setting_get(app, name, buf, cap, len); });
    }

    std::string Model::BaseValue(char const *name) const
    {
        zs_app *app = Active();
        return ReadText([&](char *buf, size_t cap, size_t *len) { return zs_app_setting_base_get(app, name, buf, cap, len); });
    }

    std::string Model::Formula(char const *name) const
    {
        zs_app *app = Active();
        return ReadText([&](char *buf, size_t cap, size_t *len) { return zs_app_formula_get(app, name, buf, cap, len); });
    }

    std::string Model::SourceTag(char const *name) const
    {
        int level = 0;
        char profile[128] = "";
        if (zs_app_setting_source(Active(), -1, name, &level, profile, sizeof profile) != ZS_OK)
            return {};
        std::string formula = Formula(name);
        char const *f = formula.empty() ? nullptr : formula.c_str();
        return ReadText([&](char *buf, size_t cap, size_t *len) { return zs_setting_source_text(level, profile, f, buf, cap, len); });
    }

    bool Model::SetSetting(char const *name, std::string const &value, std::string &error)
    {
        int rc = zs_app_setting_set(Active(), name, value.c_str());
        if (rc != ZS_OK)
        {
            error = zs_status_message(rc);
            return false;
        }
        RequestSlice();
        return true;
    }

    // A change of a plate that has a slice gives a draft first. The exact
    // slice follows 300 ms after the last change, or at the end of a drag.
    // A plate with no slice yet slices exact at once.
    void Model::LiveChange()
    {
        DropGoneDraft();
        zs_app *app = Active();
        if (draft_app_ != nullptr && draft_app_ != app)
            Settle();
        int state = zs_app_state(app);
        // Draft slices off (Preferences): each change slices exact.
        bool drafts = GetSetting("engine.draft_slices") != "false";
        if (draft_app_ == nullptr && drafts && (state == ZS_STATE_DONE || state == ZS_STATE_SLICING))
        {
            draft_app_ = app;
            zs_app_set_draft(app, 1);
            draft_since_exact_ = true;
        }
        if (draft_app_ != nullptr && settle_restart_)
            settle_restart_();
    }

    void Model::SetSettleTimer(std::function<void()> restart)
    {
        settle_restart_ = std::move(restart);
    }

    bool Model::SettleDue()
    {
        DropGoneDraft();
        if (draft_app_ != nullptr && zs_app_state(draft_app_) == ZS_STATE_SLICING)
            return false;
        Settle();
        return true;
    }

    // The exact slice of the plate that has a draft.
    void Model::Settle()
    {
        zs_app *app = draft_app_;
        draft_app_ = nullptr;
        if (app == nullptr)
            return;
        for (size_t i = 0; i < zs_set_count(set_); i++)
        {
            if (zs_set_app(set_, i) != app)
                continue;
            zs_app_set_draft(app, 0);
            if (i == zs_set_active(set_))
            {
                MarkSliceStart();
                slice_pending_ = false;
            }
            zs_set_changed(set_, i);
            return;
        }
    }

    void Model::SliceExact(size_t plate)
    {
        zs_app *app = zs_set_app(set_, plate);
        if (app == nullptr)
            return;
        if (app == draft_app_)
        {
            Settle();
            return;
        }
        zs_app_set_draft(app, 0);
        zs_set_changed(set_, plate);
    }

    bool Model::IsDraft() const
    {
        zs_app *app = Active();
        return zs_app_state(app) == ZS_STATE_DONE && zs_app_is_draft(app) != 0;
    }

    bool Model::SlicesDraft() const
    {
        zs_app *app = Active();
        return zs_app_state(app) == ZS_STATE_SLICING && zs_app_is_draft(app) != 0;
    }

    void Model::MarkSliceStart()
    {
        slice_timing_ = true;
        slice_start_ = std::chrono::steady_clock::now();
        slice_gen_ = edit_gen_;
    }

    // A slice that is under way: its clock starts, and it keeps the change
    // that it slices.
    void Model::NoteSliceProgress()
    {
        if (slice_timing_)
            return;
        slice_timing_ = true;
        slice_start_ = std::chrono::steady_clock::now();
    }

    void Model::NoteSliced()
    {
        shown_gen_ = slice_gen_;
        double ms = slice_timing_ ? std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - slice_start_).count() : 0;
        slice_timing_ = false;
        if (zs_app_is_draft(Active()) != 0)
        {
            draft_ms_ = ms;
            return;
        }
        exact_ms_ = ms;
        if (!draft_since_exact_)
            draft_ms_ = 0;
        draft_since_exact_ = false;
    }

    void Model::RequestSlice()
    {
        LiveChange();
        if (held_)
        {
            zs_set_changed_held(set_, zs_set_active(set_));
            return;
        }
        zs_app *app = Active();
        int state = zs_app_state(app);
        // The running slice ends and shows, then the newest settings slice.
        // A restart for each step of a drag would show nothing.
        if (state == ZS_STATE_SLICING)
            slice_pending_ = true;
        else if (state != ZS_STATE_EMPTY)
        {
            MarkSliceStart();
            zs_set_changed(set_, zs_set_active(set_));
        }
    }

    void Model::Hold(bool on)
    {
        if (held_ == on)
            return;
        held_ = on;
        if (!on)
        {
            // The end of a drag: the exact slice, with no draft before it.
            Settle();
            MarkSliceStart();
            zs_set_release(set_);
        }
    }

    void Model::SliceNow()
    {
        if (!held_)
            return;
        LiveChange();
        MarkSliceStart();
        zs_set_release(set_);
    }

    bool Model::TakeSlicePending()
    {
        bool pending = slice_pending_;
        slice_pending_ = false;
        return pending;
    }

    bool Model::HistoryCommit()
    {
        return zs_app_history_commit(Active(), NowMs()) != 0;
    }

    bool Model::HistoryFocus(char const *name)
    {
        return zs_app_history_set_focus(Active(), name, NowMs()) != 0;
    }

    int Model::Undo()
    {
        return zs_app_history_undo(Active(), NowMs());
    }

    int Model::Redo()
    {
        return zs_app_history_redo(Active(), NowMs());
    }

    int Model::HistoryGoto(size_t step)
    {
        return zs_app_history_goto(Active(), step, NowMs());
    }

    int Model::HistoryTruncate(size_t step)
    {
        return zs_app_history_truncate(Active(), step, NowMs());
    }

    std::wstring Model::Summary() const
    {
        zs_stats stats{};
        if (zs_app_state(Active()) != ZS_STATE_DONE || zs_app_stats(Active(), &stats) != ZS_OK)
            return {};
        int minutes = (int)std::lround(stats.print_time_s / 60.0);
        wchar_t time[32];
        if (minutes >= 60)
            swprintf_s(time, L"%d h %d min", minutes / 60, minutes % 60);
        else
            swprintf_s(time, L"%d min", minutes);
        wchar_t text[128];
        swprintf_s(text, L"%u layers, about %s, %.2f m, %.1f g", stats.layer_count, time,
                   stats.filament_mm / 1000.0, stats.filament_g);
        return text;
    }
}
