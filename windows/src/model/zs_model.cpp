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
    }

    int Model::Start()
    {
        int rc = zs_set_new(&Model::OnEvent, this, &set_);
        if (rc != ZS_OK)
            return rc;
        // The slice thread builds the scene of the view.
        zs_app_set_auto_scene(Active(), 1);
        return ZS_OK;
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
