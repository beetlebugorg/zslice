#pragma once
// The printers of the user, and the app settings.
//
// <state>\app.ini has [general] (the app settings and the current printer)
// and one [printer <id>] group for each printer: its name and connection.
// The machine settings of each printer are in printers\<id>.toml, and the
// filament it last used in printers\<id>.filament.toml, as in the GTK shell
// (linux/src/prefs/printers.c).
//
// app.ini has no secret. An API key is in secrets\<id>.key and the access
// code of a Bambu Lab printer is in bambu\<serial>.code, each encrypted for
// this Windows user with DPAPI (zs_state.h).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace zs
{
    enum class LinkKind
    {
        None = 0,
        Printdeck,
        OctoPrint,
        Moonraker,
        PrusaLink,
        Bambu,
        Count,
    };

    // "printdeck", the key in app.ini.
    char const *LinkKey(LinkKind kind);
    // "Moonraker (Klipper)", the title for the user.
    char const *LinkTitle(LinkKind kind);
    LinkKind LinkFromKey(std::string const &key);

    struct SavedPrinter
    {
        std::string id;
        std::string name;
        LinkKind kind = LinkKind::None;
        // http://host:port, or the IP address for Bambu Lab.
        std::string url;
        // The API key, or the access code for Bambu Lab. In memory only.
        std::string api_key;
        // The serial number of a Bambu Lab printer.
        std::string serial;
        // The name of this printer on its printdeck. A send checks it.
        std::string deck_name;
        // The SHA-256 of the certificate (hex), and the start of its
        // validity in Unix seconds. Empty until the first TLS connection.
        std::string tls_pin;
        int64_t tls_since = 0;
    };

    class PrinterStore
    {
    public:
        // Reads app.ini. With no printers, it makes "My printer" and sets
        // FirstStart().
        void Load();
        // Writes app.ini and the secrets. False if a file did not write.
        bool Save();

        size_t Count() const { return printers_.size(); }
        SavedPrinter &At(size_t i) { return printers_[i]; }
        SavedPrinter const &At(size_t i) const { return printers_[i]; }
        SavedPrinter *Find(std::string const &id);
        SavedPrinter &Current();
        void SetCurrent(std::string const &id);
        // A new printer with a new id, after the others.
        SavedPrinter &Add(std::string const &name);
        // Removes a printer, its profile files, and its secret. The last
        // printer stays.
        void Remove(std::string const &id);

        bool FirstStart() const { return first_start_; }
        void SetFirstStart(bool on) { first_start_ = on; }

        std::string Pref(std::string const &key, std::string const &fallback = {}) const;
        void SetPref(std::string const &key, std::string const &value);

        static std::wstring ProfilePath(SavedPrinter const &p);
        static std::wstring FilamentPath(SavedPrinter const &p);
        // The file of the secret of a printer, or empty for a Bambu Lab
        // printer with a serial number that is not letters and digits.
        static std::wstring SecretPath(SavedPrinter const &p);

    private:
        std::vector<SavedPrinter> printers_;
        std::map<std::string, std::string> general_;
        std::string current_;
        bool first_start_ = false;
    };

    // The one store of the app, for the UI thread.
    PrinterStore &Printers();
}
