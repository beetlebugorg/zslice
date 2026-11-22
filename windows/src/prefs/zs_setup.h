#pragma once
// The setup of the active plate: its printer, filament, and quality, and the
// files that keep them.
//
// The machine settings are the profile of the current printer. The filament
// and the project settings are in filament.toml and project.toml. Each
// printer also keeps the filament that it last used. The behavior follows
// linux/src/model/app-model.c and linux/src/ui/profile-menus.c.
//
// It has no WinRT, so a test program can link it. Call it on the UI thread.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <string>
#include <vector>

#include "zs_deck_filaments.h"
#include "zs_model.h"
#include "zs_printer_store.h"

namespace zs
{
    // What the second step of the printer picker chose.
    struct NewPrinter
    {
        std::string name;
        // The library model, or -1 for a printer that is not in the list.
        ptrdiff_t model = -1;
        double nozzle = 0;
        double bed_x = 0, bed_y = 0, height = 0;
        double filament = 1.75;
        LinkKind kind = LinkKind::None;
        std::string url, api_key, serial, tls_pin, deck_name;
    };

    class PrinterSetup
    {
    public:
        explicit PrinterSetup(Model &model) : model_(model) {}

        // Loads the printers and the saved settings into the active plate.
        void Start();
        // Writes each group that changed since the last write.
        void SaveState();

        // The plates of a printdeck.yml project have the machine of their
        // Cura stack. While this is on, SaveState writes no machine profile
        // and no filament of the printer, so the printer of the user stays.
        void SetProjectPlates(bool on) { project_ = on; }
        bool ProjectPlates() const { return project_; }
        // Ends project mode: the active plate gets the machine settings of
        // the current printer again.
        void EndProject();
        // The active plate gets the machine settings of the current printer,
        // and the other plates of the project stay.
        void UsePrinterMachine();

        // Makes a saved printer the current printer: saves the settings of
        // the one before, and loads its machine profile and its filament.
        bool UsePrinter(std::string const &id, std::string &message);
        // Adds a printer from the picker, or on a first start makes the
        // default printer this one. It becomes the current printer.
        bool AddNewPrinter(NewPrinter const &printer, bool welcome, std::string &id, std::string &message);

        // A quality: a profile of the user, else the built-in one. The
        // changes of this print stay on top when keep_edits is true.
        bool SetQuality(std::string const &name, bool keep_edits, std::string &message);
        // "Standard": a built-in name with a capital. A name of the user
        // stays as the user wrote it.
        static std::string QualityTitle(std::string const &name);
        // The current quality for the top bar, with a mark for changes.
        std::string QualityLabel() const;
        // The detail line of a built-in quality.
        static std::string QualitySummary(std::string const &name);

        // A material type: its built-in profile, with the diameter kept.
        bool UseMaterial(std::string const &material, std::string &message);
        // A profile of a group by its text.
        bool LoadProfile(int group, std::string const &name, std::string const &text, std::string &message);
        // Saves the settings of a group as a profile of the user.
        bool SaveProfile(int group, std::string const &name, std::string &message);
        // A profile of the user, by name.
        bool LoadUserProfile(int group, std::string const &name, std::string &message);
        std::vector<std::string> UserProfiles(int group) const;
        // True when the group has changes since its profile loaded.
        bool GroupChanged(int group) const;
        std::string GroupProfile(int group) const;

        // Makes the filaments of the plate the spools of the printer.
        void ApplySpools(DeckFilaments const &spools, bool two_nozzles);

        bool TwoNozzles() const;
        int NozzleCount() const;
        // A file name: letters, digits, dashes, and underscores.
        static std::string ProfileFileName(std::string const &name);

    private:
        // True while other plates can still have the machine of a project.
        // A pick of a printer then keeps the guard of SaveState.
        bool KeepProject() const;
        std::string GroupText(int group) const;
        bool ApplyText(int group, std::string const &text, std::string &message);
        // True if the text loaded and has settings that moved to another
        // group (zs_profile_moved).
        bool LoadGroup(int group);
        std::wstring StatePath(int group);
        void Touch(int group);

        Model &model_;
        std::string written_[3];
        // The profile in use, and the text right after it loaded.
        std::string profile_[3];
        std::string loaded_[3];
        bool project_ = false;
    };
}
