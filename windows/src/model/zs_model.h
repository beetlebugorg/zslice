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

        // The plates. Each call makes the new active app ready.
        size_t PlateCount() const { return zs_set_count(set_); }
        size_t ActivePlate() const { return zs_set_active(set_); }
        bool AddPlate();
        bool SelectPlate(size_t i);
        bool RemovePlate(size_t i);

        // The printer library, built into the core.
        zs_printers *Printers();
        // Applies the machine profile of a library model to the active
        // plate, and slices it again.
        bool UsePrinter(std::string const &id, std::string &message);
        // Shows the bed model of the printer of the active plate. The files
        // are in the folder `beds` beside the program, or ZSLICE_BEDS_DIR.
        void UpdateBed(zs_view *view);

        // Settings of the active plate. SetSetting slices again, and on a
        // failure `error` has the text for the user.
        std::string GetSetting(char const *name) const;
        std::string BaseValue(char const *name) const;
        std::string Formula(char const *name) const;
        std::string SourceTag(char const *name) const;
        bool SetSetting(char const *name, std::string const &value, std::string &error);
        // Slices the active plate. During a slice it waits for the end.
        void RequestSlice();
        // True once after a slice if a change came during it.
        bool TakeSlicePending();
        // During a drag the changes wait. The release slices once.
        void Hold(bool on);

        // The undo list of the active plate (see zs_app_history_commit).
        // The undo calls return the bits of enum zs_history_restored.
        bool HistoryCommit();
        bool HistoryFocus(char const *name);
        int Undo();
        int Redo();
        int HistoryGoto(size_t step);

    private:
        static void OnEvent(void *user, size_t plate, int event, double progress, int status);
        void SyncActive();

        std::function<void(Event const &)> post_;
        zs_set *set_ = nullptr;
        zs_printers *printers_ = nullptr;
        bool printers_tried_ = false;
        zs_view *bed_view_ = nullptr;
        ptrdiff_t bed_shown_ = -2;
        bool slice_pending_ = false;
        bool held_ = false;
    };

    // One line for the log: stderr, or the file of ZSLICE_LOG.
    void Log(char const *format, ...);

    std::string ToUtf8(std::wstring const &text);
    std::wstring ToWide(std::string const &text);
}
