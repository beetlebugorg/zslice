// See zs_printer_store.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_printer_store.h"

#include "zs_state.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdio>

namespace zs
{
    namespace
    {
        char const *const link_keys[] = { "none", "printdeck", "octoprint", "moonraker", "prusalink", "usb", "bambu" };
        char const *const link_titles[] = {
            "None (export a file)", "printdeck", "OctoPrint", "Moonraker (Klipper)", "PrusaLink", "USB (serial port)", "Bambu Lab (LAN mode)",
        };

        std::wstring Wide(std::string const &text)
        {
            if (text.empty())
                return {};
            int n = ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0);
            std::wstring out(n, L'\0');
            ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n);
            return out;
        }

        // A value on one line: a backslash and a line end are escaped.
        std::string Escape(std::string const &value)
        {
            std::string out;
            for (char c : value)
            {
                if (c == '\\')
                    out += "\\\\";
                else if (c == '\n')
                    out += "\\n";
                else if (c == '\r')
                    out += "\\r";
                else
                    out += c;
            }
            return out;
        }

        std::string Unescape(std::string const &value)
        {
            std::string out;
            for (size_t i = 0; i < value.size(); i++)
            {
                if (value[i] != '\\' || i + 1 >= value.size())
                {
                    out += value[i];
                    continue;
                }
                char c = value[++i];
                out += c == 'n' ? '\n' : c == 'r' ? '\r' : c;
            }
            return out;
        }

        std::string Trim(std::string const &text)
        {
            size_t a = text.find_first_not_of(" \t\r");
            if (a == std::string::npos)
                return {};
            size_t b = text.find_last_not_of(" \t\r");
            return text.substr(a, b - a + 1);
        }

        // A printer id or a serial number in a file name: no path.
        bool SafeName(std::string const &name)
        {
            if (name.empty() || name.size() > 64)
                return false;
            for (char c : name)
            {
                bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
                if (!ok)
                    return false;
            }
            return true;
        }

        using Group = std::map<std::string, std::string>;

        std::vector<std::pair<std::string, Group>> ParseIni(std::string const &text)
        {
            std::vector<std::pair<std::string, Group>> groups;
            size_t at = 0;
            while (at < text.size())
            {
                size_t end = text.find('\n', at);
                if (end == std::string::npos)
                    end = text.size();
                std::string line = Trim(text.substr(at, end - at));
                at = end + 1;
                if (line.empty() || line[0] == '#' || line[0] == ';')
                    continue;
                if (line.front() == '[' && line.back() == ']')
                {
                    groups.emplace_back(line.substr(1, line.size() - 2), Group{});
                    continue;
                }
                size_t eq = line.find('=');
                if (eq != std::string::npos && !groups.empty())
                    groups.back().second[Trim(line.substr(0, eq))] = Unescape(Trim(line.substr(eq + 1)));
            }
            return groups;
        }

        std::string Get(Group const &group, char const *key)
        {
            auto it = group.find(key);
            return it == group.end() ? std::string{} : it->second;
        }

        void Put(std::string &out, char const *key, std::string const &value)
        {
            if (!value.empty())
                out += std::string(key) + "=" + Escape(value) + "\n";
        }
    }

    char const *LinkKey(LinkKind kind)
    {
        return link_keys[(int)kind];
    }

    char const *LinkTitle(LinkKind kind)
    {
        return link_titles[(int)kind];
    }

    LinkKind LinkFromKey(std::string const &key)
    {
        for (int k = 0; k < (int)LinkKind::Count; k++)
            if (key == link_keys[k])
                return (LinkKind)k;
        return LinkKind::None;
    }

    std::wstring PrinterStore::ProfilePath(SavedPrinter const &p)
    {
        return state::PathOf(L"printers\\" + Wide(p.id) + L".toml");
    }

    std::wstring PrinterStore::FilamentPath(SavedPrinter const &p)
    {
        return state::PathOf(L"printers\\" + Wide(p.id) + L".filament.toml");
    }

    std::wstring PrinterStore::SecretPath(SavedPrinter const &p)
    {
        if (p.kind == LinkKind::Bambu)
            return SafeName(p.serial) ? state::PathOf(L"bambu\\" + Wide(p.serial) + L".code") : std::wstring{};
        return SafeName(p.id) ? state::PathOf(L"secrets\\" + Wide(p.id) + L".key") : std::wstring{};
    }

    void PrinterStore::Load()
    {
        printers_.clear();
        general_.clear();
        current_.clear();
        first_start_ = false;
        read_failed_ = false;
        std::string text;
        std::wstring ini = state::PathOf(L"app.ini");
        bool have_ini = state::ReadBytes(ini, text);
        // Another program can hold the file for a moment.
        for (int k = 0; !have_ini && k < 5 && ::GetFileAttributesW(ini.c_str()) != INVALID_FILE_ATTRIBUTES; k++)
        {
            ::Sleep(40);
            have_ini = state::ReadBytes(ini, text);
        }
        read_failed_ = !have_ini && ::GetFileAttributesW(ini.c_str()) != INVALID_FILE_ATTRIBUTES;
        if (have_ini)
        {
            for (auto const &[name, group] : ParseIni(text))
            {
                if (name == "general")
                {
                    general_ = group;
                    continue;
                }
                if (name.rfind("printer ", 0) != 0)
                    continue;
                SavedPrinter p;
                p.id = name.substr(8);
                if (!SafeName(p.id))
                    continue;
                p.name = Get(group, "name");
                if (p.name.empty())
                    p.name = p.id;
                p.kind = LinkFromKey(Get(group, "connection"));
                p.url = Get(group, "url");
                p.serial = Get(group, "serial");
                p.device = Get(group, "device");
                if (int baud = atoi(Get(group, "baud").c_str()); baud > 0)
                    p.baud = baud;
                p.deck_name = Get(group, "deck_name");
                p.tls_pin = Get(group, "tls_pin");
                p.tls_since = _strtoi64(Get(group, "tls_since").c_str(), nullptr, 10);
                std::wstring secret = SecretPath(p);
                if (!secret.empty())
                    state::ReadSecret(secret, p.api_key);
                printers_.push_back(std::move(p));
            }
        }
        auto it = general_.find("printer");
        if (it != general_.end())
            current_ = it->second;
        if (printers_.empty())
        {
            SavedPrinter p;
            p.id = "printer-1";
            p.name = "My printer";
            printers_.push_back(p);
            current_ = p.id;
            first_start_ = !read_failed_;
            Save();
        }
        if (Find(current_) == nullptr)
            current_ = printers_.front().id;
    }

    bool PrinterStore::Save()
    {
        if (read_failed_)
            return false;
        std::string out = "# zslice: the printers and the app settings. The machine settings of each\n"
                          "# printer are in printers\\<id>.toml. Keys are in encrypted files.\n[general]\n";
        general_["printer"] = current_;
        for (auto const &[key, value] : general_)
            Put(out, key.c_str(), value);
        bool ok = true;
        for (auto const &p : printers_)
        {
            out += "\n[printer " + p.id + "]\n";
            Put(out, "name", p.name);
            Put(out, "connection", LinkKey(p.kind));
            Put(out, "url", p.url);
            Put(out, "serial", p.serial);
            Put(out, "device", p.device);
            if (p.kind == LinkKind::Usb)
                Put(out, "baud", std::to_string(p.baud));
            Put(out, "deck_name", p.deck_name);
            Put(out, "tls_pin", p.tls_pin);
            if (p.tls_since != 0)
                Put(out, "tls_since", std::to_string(p.tls_since));
            // An empty key in memory says nothing about the file: a read
            // can have failed, or another entry can share the code. Only
            // ForgetKey deletes it.
            std::wstring secret = SecretPath(p);
            if (!secret.empty() && !p.api_key.empty() && !state::WriteSecret(secret, p.api_key))
                ok = false;
            // A printer that changed to Bambu Lab leaves no old key.
            if (p.kind == LinkKind::Bambu && SafeName(p.id))
                state::Remove(state::PathOf(L"secrets\\" + Wide(p.id) + L".key"));
        }
        return state::WriteBytes(state::PathOf(L"app.ini"), out) && ok;
    }

    SavedPrinter *PrinterStore::Find(std::string const &id)
    {
        for (auto &p : printers_)
            if (p.id == id)
                return &p;
        return nullptr;
    }

    SavedPrinter &PrinterStore::Current()
    {
        SavedPrinter *p = Find(current_);
        return p != nullptr ? *p : printers_.front();
    }

    void PrinterStore::SetCurrent(std::string const &id)
    {
        if (Find(id) == nullptr)
            return;
        current_ = id;
        Save();
    }

    SavedPrinter &PrinterStore::Add(std::string const &name)
    {
        SavedPrinter p;
        for (int n = 1;; n++)
        {
            p.id = "printer-" + std::to_string(n);
            if (Find(p.id) == nullptr)
                break;
        }
        p.name = name;
        printers_.push_back(std::move(p));
        Save();
        return printers_.back();
    }

    void PrinterStore::ForgetKey(SavedPrinter &p)
    {
        std::wstring secret = SecretPath(p);
        bool shared = false;
        for (auto const &other : printers_)
            shared = shared || (other.id != p.id && p.kind == LinkKind::Bambu && other.kind == LinkKind::Bambu && other.serial == p.serial);
        if (!secret.empty() && !shared)
            state::Remove(secret);
        state::Wipe(p.api_key);
    }

    void PrinterStore::Remove(std::string const &id)
    {
        if (printers_.size() <= 1)
            return;
        for (size_t i = 0; i < printers_.size(); i++)
        {
            SavedPrinter &p = printers_[i];
            if (p.id != id)
                continue;
            state::Remove(ProfilePath(p));
            state::Remove(FilamentPath(p));
            std::wstring secret = SecretPath(p);
            // Two printers can have the same serial number: its code stays
            // for the other one.
            bool shared = false;
            for (auto const &other : printers_)
                shared = shared || (other.id != p.id && other.kind == LinkKind::Bambu && p.kind == LinkKind::Bambu && other.serial == p.serial);
            if (!secret.empty() && !shared)
                state::Remove(secret);
            state::Wipe(p.api_key);
            printers_.erase(printers_.begin() + (ptrdiff_t)i);
            break;
        }
        if (Find(current_) == nullptr)
            current_ = printers_.front().id;
        Save();
    }

    std::string PrinterStore::Pref(std::string const &key, std::string const &fallback) const
    {
        auto it = general_.find(key);
        return it == general_.end() ? fallback : it->second;
    }

    void PrinterStore::SetPref(std::string const &key, std::string const &value)
    {
        general_[key] = value;
        Save();
    }

    PrinterStore &Printers()
    {
        static PrinterStore store;
        return store;
    }
}
