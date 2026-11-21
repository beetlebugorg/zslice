// See zs_model.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_model.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cmath>
#include <cstdio>

namespace zs
{
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
    void Model::SyncActive()
    {
        zs_app *app = Active();
        zs_app_set_auto_simulate(app, 1);
        zs_app_set_auto_checks(app, 1);
        for (size_t i = 0; i < zs_set_count(set_); i++)
            zs_app_set_auto_scene(zs_set_app(set_, i), 1);
    }

    bool Model::AddPlate()
    {
        if (zs_set_add(set_) < 0)
            return false;
        SyncActive();
        return true;
    }

    bool Model::SelectPlate(size_t i)
    {
        if (i == zs_set_active(set_) || i >= zs_set_count(set_) || zs_set_select(set_, i) != ZS_OK)
            return false;
        SyncActive();
        return true;
    }

    bool Model::RemovePlate(size_t i)
    {
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
            zs_set_changed(set_, zs_set_active(set_));
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
            fprintf(stderr, "shell: the bed model %s did not load: %s\n", bed.mesh, zs_status_string(rc));
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
        int rc = zs_app_load_stl(zs_set_app(set_, active), utf8.c_str(), data, bytes.size());
        if (rc == ZS_OK)
        {
            zs_set_name(set_, active, utf8.c_str());
            rc = zs_set_changed(set_, active);
        }
        if (rc != ZS_OK)
            message = zs_status_message(rc);
        return rc;
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
