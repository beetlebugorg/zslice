// The session: the app comes back as it was after a quit.
//
// The session file of the core holds the plates, their last scenes, the
// camera, and the size of the window. It is written 1.5 s after a slice or a
// change of the plates, once the input has paused for 2 s, and at the close.
// The app writes no session until the restore at launch is done, so a start
// that fails to read a session never replaces it. The behavior follows the
// GTK shell (linux/src/main.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <atomic>
#include <thread>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Windowing;

namespace
{
    // A later save stops an older one from writing the file.
    std::atomic<uint32_t> session_serial{ 0 };

    std::wstring SessionPath()
    {
        return zs::StateDir() + L"\\session.zslice";
    }

    // A new file, then a rename: a crash leaves the old session whole.
    bool WriteAtomic(std::wstring const &path, uint8_t const *data, size_t len)
    {
        std::wstring temp = path + L".tmp";
        HANDLE file = ::CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            return false;
        bool ok = true;
        size_t done = 0;
        while (ok && done < len)
        {
            DWORD piece = (DWORD)std::min<size_t>(len - done, 1u << 30);
            DWORD wrote = 0;
            ok = ::WriteFile(file, data + done, piece, &wrote, nullptr) != 0 && wrote > 0;
            done += wrote;
        }
        ok = ::FlushFileBuffers(file) != 0 && ok;
        ::CloseHandle(file);
        if (ok)
            ok = ::MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
        if (!ok)
            ::DeleteFileW(temp.c_str());
        return ok;
    }

    void WriteSnapshot(zs_session_snapshot *snapshot, std::wstring const &path, uint32_t serial)
    {
        uint8_t *out = nullptr;
        size_t len = 0;
        if (zs_session_snapshot_write(snapshot, &out, &len) != ZS_OK)
        {
            zs::Log("shell: the session did not save: no memory\n");
        }
        else
        {
            if (serial == session_serial.load() && !WriteAtomic(path, out, len))
                zs::Log("shell: the session did not save (error %lu)\n", ::GetLastError());
            zs_buffer_free(out, len);
        }
        zs_session_snapshot_free(snapshot);
    }

    int JsonInt(std::string const &text, char const *key)
    {
        size_t at = text.find(key);
        return at == std::string::npos ? 0 : atoi(text.c_str() + at + strlen(key));
    }
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::WireSession()
    {
        session_timer = queue.CreateTimer();
        session_timer.IsRepeating(true);
        session_timer.Interval(std::chrono::milliseconds(500));
        session_timer.Tick([this](auto &&, auto &&) {
            // The copy holds the UI thread for a few ms: it waits for a
            // pause in the input and in the moves of the view.
            auto now = std::chrono::steady_clock::now();
            if (now < session_due || now - last_input < std::chrono::seconds(2) || drag != Drag::None || hand || falling ||
                playing || animation_timer.IsRunning())
                return;
            session_timer.Stop();
            SaveSession(false);
        });
        auto input = [this](auto &&, auto &&) { last_input = std::chrono::steady_clock::now(); };
        Root().AddHandler(UIElement::PointerPressedEvent(), box_value(Input::PointerEventHandler(input)), true);
        Root().AddHandler(UIElement::PointerMovedEvent(), box_value(Input::PointerEventHandler(input)), true);
        Root().AddHandler(UIElement::KeyDownEvent(), box_value(Input::KeyEventHandler(input)), true);
    }

    void MainWindow::SessionSoon()
    {
        if (!session_ready)
            return;
        session_due = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
        if (!session_timer.IsRunning())
            session_timer.Start();
    }

    void MainWindow::SaveSession(bool wait)
    {
        // No session until the restore at launch is done.
        if (!session_ready || model == nullptr)
            return;
        float camera[8];
        bool has_camera = view != nullptr;
        if (has_camera)
            zs_view_get_camera(view, camera);
        auto window = AppWindow();
        auto presenter = window.Presenter().try_as<OverlappedPresenter>();
        bool maximized = presenter != nullptr && presenter.State() == OverlappedPresenterState::Maximized;
        // A maximized window keeps the size that it comes back to.
        if (!maximized && presenter != nullptr && presenter.State() == OverlappedPresenterState::Restored)
            restore_size = window.Size();
        char text[128];
        snprintf(text, sizeof text, "{\"width\":%d,\"height\":%d,\"maximized\":%s}", restore_size.Width, restore_size.Height,
                 maximized ? "true" : "false");
        // The ids of the plates in the store of the refinements.
        std::string app_text = text;
        app_text.pop_back();
        app_text += ",\"refine\":\"";
        for (size_t i = 0; i < refine_ids.size(); i++)
            app_text += (i > 0 ? "," : "") + refine_ids[i];
        app_text += "\"}";
        zs_session_snapshot *snapshot = nullptr;
        if (zs_session_snapshot_take(model->Set(), has_camera ? camera : nullptr, app_text.c_str(), &snapshot) != ZS_OK)
            return;
        std::wstring path = SessionPath();
        uint32_t serial = ++session_serial;
        if (wait)
            WriteSnapshot(snapshot, path, serial);
        else
            std::thread(WriteSnapshot, snapshot, path, serial).detach();
    }

    // Puts the last session back, before the first frame.
    bool MainWindow::RestoreSession()
    {
        // A file on the command line opens after this, on a new plate, so
        // it never takes the place of the session.
        std::wstring path = SessionPath();
        std::string bytes;
        if (!zs::Model::ReadFile(path, bytes))
        {
            session_ready = true;
            return false;
        }
        float camera[8];
        int has_camera = 0;
        uint8_t *app_text = nullptr;
        size_t app_len = 0;
        char message[512] = "";
        int rc = zs_session_read(model->Set(), reinterpret_cast<uint8_t const *>(bytes.data()), bytes.size(), camera, &has_camera,
                                 &app_text, &app_len, message, sizeof message);
        if (rc != ZS_OK)
        {
            zs::Log("shell: the session did not open: %s\n", message[0] != 0 ? message : zs_status_string(rc));
            // The file stays for a look, and the next save starts anew.
            ::MoveFileExW(path.c_str(), (path + L".bad").c_str(), MOVEFILE_REPLACE_EXISTING);
            session_ready = true;
            return false;
        }
        if (app_text != nullptr)
        {
            std::string text(reinterpret_cast<char const *>(app_text), app_len);
            zs_buffer_free(app_text, app_len);
            int width = JsonInt(text, "\"width\":"), height = JsonInt(text, "\"height\":");
            auto window = AppWindow();
            if (width > 200 && height > 200)
                window.Resize({ width, height });
            if (text.find("\"maximized\":true") != std::string::npos)
                if (auto presenter = window.Presenter().try_as<OverlappedPresenter>())
                    presenter.Maximize();
            char const *const refine_key = "\"refine\":\"";
            size_t at = text.find(refine_key);
            if (at != std::string::npos)
            {
                at += strlen(refine_key);
                std::string list = text.substr(at, text.find('"', at) - at);
                refine_ids.clear();
                for (size_t start = 0; start <= list.size() && !list.empty();)
                {
                    size_t comma = list.find(',', start);
                    refine_ids.push_back(list.substr(start, comma == std::string::npos ? comma : comma - start));
                    if (comma == std::string::npos)
                        break;
                    start = comma + 1;
                }
            }
        }
        model->AfterSessionRead();
        // The last scene of the active plate shows at once, and the plate
        // slices again behind it.
        uint8_t const *scene = nullptr;
        size_t scene_len = 0;
        if (zs_set_plate_scene(model->Set(), model->ActivePlate(), &scene, &scene_len) == ZS_OK)
            zs_view_scene_read(view, scene, scene_len);
        model->UpdateBed(view);
        zs_set_view_sync(model->Set(), view);
        ShowPlateChrome();
        if (has_camera)
            zs_view_set_camera(view, camera);
        session_ready = true;
        RequestDraw();
        return true;
    }
}
