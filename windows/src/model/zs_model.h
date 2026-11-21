#pragma once
// The core as one object of the Windows shell. It owns the plate set, reads
// model files, and hands each core event to the UI thread through `post`.
// It has no WinRT, so a test program can link it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

#include "zslice.h"
#include "zslice-app.h"

namespace zs
{
    struct Event
    {
        size_t plate;
        int kind; // enum zs_event
        double progress;
        int status;
    };

    class Model
    {
    public:
        // `post` runs on the slice threads. It must move the event to the UI
        // thread, and it must not call the core.
        explicit Model(std::function<void(Event const &)> post);
        ~Model();
        Model(Model const &) = delete;
        Model &operator=(Model const &) = delete;

        // ZS_OK, or the status of the failure.
        int Start();

        zs_set *Set() const { return set_; }
        zs_app *Active() const;
        bool IsActive(size_t plate) const;

        // Reads a file into `bytes`. False if it cannot be read.
        static bool ReadFile(std::wstring const &path, std::string &bytes);
        // Loads the bytes of a model or a project on the active plate and
        // starts the slice. `name` is the file name. On a failure, `message`
        // has the text for the user.
        int Load(std::wstring const &name, std::string const &bytes, std::string &message);

        // "84 layers, 26 min, 2.34 m, 7.0 g", or empty with no slice.
        std::wstring Summary() const;

    private:
        static void OnEvent(void *user, size_t plate, int event, double progress, int status);

        std::function<void(Event const &)> post_;
        zs_set *set_ = nullptr;
    };

    std::string ToUtf8(std::wstring const &text);
    std::wstring ToWide(std::string const &text);
}
