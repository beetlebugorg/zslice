// See zs_setup.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_setup.h"

#include "zs_state.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>

namespace zs
{
    namespace
    {
        char const *const group_dirs[] = { "machine", "filament", "project" };
        wchar_t const *const group_files[] = { L"machine", L"filament.toml", L"project.toml" };

        std::string Number(double v)
        {
            char text[32];
            snprintf(text, sizeof text, "%.6g", v);
            return text;
        }

        std::wstring ProfileDir(int group)
        {
            return state::PathOf(L"profiles\\" + ToWide(group_dirs[group]));
        }

        std::string Lower(std::string text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            return text;
        }

        bool IsBuiltinQuality(std::string const &name)
        {
            if (name == "custom")
                return true;
            for (size_t i = 0; i < zs_builtin_profile_count(ZS_GROUP_PROJECT); i++)
                if (name == zs_builtin_profile_name(ZS_GROUP_PROJECT, i))
                    return true;
            return false;
        }

        bool HasSettings(std::string const &text)
        {
            size_t at = 0;
            while (at < text.size())
            {
                size_t end = text.find('\n', at);
                if (end == std::string::npos)
                    end = text.size();
                if (end > at && text[at] != '#' && text[at] != '[' && text[at] != '\r')
                    return true;
                at = end + 1;
            }
            return false;
        }
    }

    std::string PrinterSetup::ProfileFileName(std::string const &raw)
    {
        std::string name;
        for (unsigned char c : raw)
            name += std::isalnum(c) || c == '-' || c == '_' ? (char)c : c == ' ' ? '-' : '_';
        return name;
    }

    std::string PrinterSetup::GroupText(int group) const
    {
        size_t len = 0;
        zs_app *app = model_.Active();
        if (zs_app_state_write(app, group, nullptr, 0, &len) != ZS_OK)
            return {};
        std::string text(len + 1, '\0');
        if (zs_app_state_write(app, group, text.data(), text.size(), &len) != ZS_OK)
            return {};
        text.resize(len);
        return text;
    }

    std::string PrinterSetup::FormulasText() const
    {
        size_t len = 0;
        zs_app *app = model_.Active();
        if (zs_app_formulas_write(app, nullptr, 0, &len) != ZS_OK)
            return {};
        std::string text(len + 1, '\0');
        if (zs_app_formulas_write(app, text.data(), text.size(), &len) != ZS_OK)
            return {};
        text.resize(len);
        return text;
    }

    std::string PrinterSetup::GlobalWritten() const
    {
        size_t len = 0;
        zs_app *app = model_.Active();
        if (zs_app_global_write(app, nullptr, 0, &len) != ZS_OK)
            return {};
        std::string text(len + 1, '\0');
        if (zs_app_global_write(app, text.data(), text.size(), &len) != ZS_OK)
            return {};
        text.resize(len);
        return text;
    }

    void PrinterSetup::SaveGlobal()
    {
        std::string text = GlobalWritten();
        global_text_ = text;
        if (!state::WriteBytes(state::PathOf(L"global.toml"), text))
            Log("shell: the global settings were not saved\n");
    }

    std::wstring PrinterSetup::StatePath(int group)
    {
        if (group == ZS_GROUP_MACHINE)
            return PrinterStore::ProfilePath(Printers().Current());
        return state::PathOf(group_files[group]);
    }

    bool PrinterSetup::LoadGroup(int group)
    {
        std::wstring path = StatePath(group);
        std::string text;
        if (!state::ReadBytes(path, text))
            return false;
        bool moved = zs_profile_moved(group, text.data(), text.size()) > 0;
        char message[256] = "";
        int rc = zs_app_profile_apply(model_.Active(), group, text.data(), text.size(), message, sizeof message);
        if (rc != ZS_OK)
        {
            // The file stays beside it: the next save writes over it.
            state::WriteBytes(path + L".bad", text);
            Log("shell: a settings file was not loaded (%s). A copy has the suffix .bad.\n", message);
            return false;
        }
        return moved;
    }

    void PrinterSetup::Start()
    {
        PrinterStore &store = Printers();
        store.Load();
        bool moved = false;
        for (int g = 0; g < 3; g++)
            moved |= LoadGroup(g);
        // The quality of the last session, under the changes of this print.
        std::string quality = store.Pref("profile_project");
        if (!quality.empty() && quality != "custom")
        {
            std::string text;
            if (!state::ReadBytes(ProfileDir(ZS_GROUP_PROJECT) + L"\\" + ToWide(ProfileFileName(quality)) + L".toml", text))
                text = "extends = \"" + quality + "\"\n";
            char message[256] = "";
            if (zs_app_quality_set(model_.Active(), quality.c_str(), text.data(), text.size(), true, message, sizeof message) != ZS_OK)
                Log("shell: the quality profile %s was not loaded (%s)\n", quality.c_str(), message);
        }
        // The global settings of the user, under the quality.
        bool global_moved = false;
        {
            std::string text;
            if (state::ReadBytes(state::PathOf(L"global.toml"), text))
            {
                global_moved = zs_profile_moved(ZS_GROUP_PROJECT, text.data(), text.size()) > 0;
                moved = moved || global_moved;
                char message[256] = "";
                if (zs_app_global_set(model_.Active(), text.data(), text.size(), message, sizeof message) != ZS_OK)
                    Log("shell: the global settings were not loaded (%s)\n", message);
            }
            global_text_ = GlobalWritten();
        }
        // The formulas of the settings, on top.
        {
            std::string text;
            if (state::ReadBytes(state::PathOf(L"formulas.txt"), text))
                zs_app_formulas_read(model_.Active(), text.data(), text.size());
            formulas_ = FormulasText();
        }
        for (int g = 0; g < 3; g++)
        {
            written_[g] = GroupText(g);
            profile_[g] = store.Pref(std::string("profile_") + group_dirs[g]);
            if (!profile_[g].empty())
                loaded_[g] = written_[g];
        }
        // An older text has settings that moved to another group. The core
        // put each value in its new group. Save both groups once, so the
        // values stay there and the current printer keeps its own.
        if (moved)
        {
            Log("shell: saved settings moved to the printer group\n");
            written_[ZS_GROUP_MACHINE].clear();
            written_[ZS_GROUP_PROJECT].clear();
            SaveState();
            if (global_moved)
                SaveGlobal();
        }
    }

    void PrinterSetup::SaveState()
    {
        for (int g = 0; g < 3; g++)
        {
            // The machine of a project plate is not the printer of the user.
            if (project_ && g == ZS_GROUP_MACHINE)
                continue;
            std::string text = GroupText(g);
            if (text == written_[g])
                continue;
            bool ok = state::WriteBytes(StatePath(g), text);
            // The filament also goes with the printer: it gets it back after
            // a switch to it.
            if (g == ZS_GROUP_FILAMENT && !project_)
                ok = state::WriteBytes(PrinterStore::FilamentPath(Printers().Current()), text) && ok;
            if (ok)
                written_[g] = std::move(text);
            else
                Log("shell: the settings were not saved\n");
        }
        // The formulas of any group. A project plate has its own values, so
        // the formulas of the user stay.
        if (!project_)
        {
            std::string text = FormulasText();
            if (text != formulas_ && state::WriteBytes(state::PathOf(L"formulas.txt"), text))
                formulas_ = std::move(text);
        }
    }

    void PrinterSetup::EndProject()
    {
        if (!project_)
            return;
        project_ = false;
        UsePrinterMachine();
        written_[ZS_GROUP_MACHINE] = GroupText(ZS_GROUP_MACHINE);
    }

    bool PrinterSetup::KeepProject() const
    {
        return project_ && zs_set_count(model_.Set()) > 1;
    }

    void PrinterSetup::UsePrinterMachine()
    {
        zs_app_group_reset(model_.Active(), ZS_GROUP_MACHINE);
        LoadGroup(ZS_GROUP_MACHINE);
    }

    void PrinterSetup::Touch(int group)
    {
        loaded_[group] = GroupText(group);
    }

    bool PrinterSetup::ApplyText(int group, std::string const &text, std::string &message)
    {
        zs_app *app = model_.Active();
        // An error leaves the settings as they are.
        std::string before = GroupText(group);
        zs_app_group_reset(app, group);
        char error[256] = "";
        int rc = zs_app_profile_apply(app, group, text.data(), text.size(), error, sizeof error);
        if (rc != ZS_OK)
        {
            zs_app_profile_apply(app, group, before.data(), before.size(), nullptr, 0);
            message = error[0] != 0 ? error : zs_status_message(rc);
            return false;
        }
        return true;
    }

    bool PrinterSetup::UsePrinter(std::string const &id, std::string &message)
    {
        PrinterStore &store = Printers();
        if (store.Find(id) == nullptr)
        {
            message = "That printer is gone.";
            return false;
        }
        if (store.Current().id == id)
        {
            // A pick of the printer puts its machine on a plate of a project.
            if (project_)
            {
                if (KeepProject())
                    UsePrinterMachine();
                else
                    EndProject();
                model_.RequestSlice();
            }
            return true;
        }
        // The machine and the filament of the printer before. A plate of a
        // project has neither.
        SaveState();
        if (!project_)
        {
            std::string machine = GroupText(ZS_GROUP_MACHINE);
            state::WriteBytes(PrinterStore::ProfilePath(store.Current()), machine);
            state::WriteBytes(PrinterStore::FilamentPath(store.Current()), GroupText(ZS_GROUP_FILAMENT));
        }
        project_ = KeepProject();
        store.SetCurrent(id);
        zs_app *app = model_.Active();
        zs_app_group_reset(app, ZS_GROUP_MACHINE);
        LoadGroup(ZS_GROUP_MACHINE);
        written_[ZS_GROUP_MACHINE] = GroupText(ZS_GROUP_MACHINE);
        // A printer with no saved filament keeps the filament now.
        std::string filament;
        if (state::ReadBytes(PrinterStore::FilamentPath(store.Current()), filament))
        {
            std::string why;
            if (!ApplyText(ZS_GROUP_FILAMENT, filament, why))
                Log("shell: the filament of the printer was not loaded (%s)\n", why.c_str());
        }
        model_.RequestSlice();
        SaveState();
        return true;
    }

    bool PrinterSetup::AddNewPrinter(NewPrinter const &in, bool welcome, std::string &id, std::string &message)
    {
        PrinterStore &store = Printers();
        std::string name = in.name.empty() ? "My printer" : in.name;
        std::string profile = "extends = \"generic\"\n";
        zs_printers *lib = model_.Printers();
        if (in.model >= 0 && lib != nullptr)
        {
            size_t n = 0;
            if (zs_printers_profile(lib, (size_t)in.model, in.nozzle, nullptr, 0, &n) == ZS_OK)
            {
                std::string text(n + 1, '\0');
                if (zs_printers_profile(lib, (size_t)in.model, in.nozzle, text.data(), text.size(), &n) == ZS_OK)
                {
                    text.resize(n);
                    profile = std::move(text);
                }
            }
        }
        SaveState();
        SavedPrinter *printer;
        if (welcome)
        {
            printer = &store.Current();
            printer->name = name;
        }
        else
        {
            if (!project_)
                state::WriteBytes(PrinterStore::ProfilePath(store.Current()), GroupText(ZS_GROUP_MACHINE));
            printer = &store.Add(name);
        }
        // The profile of the new printer is written below.
        bool was_project = project_, keep_project = KeepProject();
        project_ = false;
        printer->kind = in.kind;
        printer->url = in.url;
        printer->api_key = in.api_key;
        printer->serial = in.serial;
        printer->tls_pin = in.tls_pin;
        printer->deck_name = in.deck_name;
        id = printer->id;
        store.SetCurrent(id);
        store.Save();
        if (!ApplyText(ZS_GROUP_MACHINE, profile, message))
        {
            project_ = was_project;
            return false;
        }
        zs_app *app = model_.Active();
        zs_app_setting_set(app, "machine.name", name.c_str());
        if (in.nozzle > 0)
            zs_app_setting_set(app, "machine.nozzle_diameter", Number(in.nozzle).c_str());
        if (in.bed_x > 0)
            zs_app_setting_set(app, "machine.bed_size_x", Number(in.bed_x).c_str());
        if (in.bed_y > 0)
            zs_app_setting_set(app, "machine.bed_size_y", Number(in.bed_y).c_str());
        if (in.height > 0)
            zs_app_setting_set(app, "machine.max_height", Number(in.height).c_str());
        zs_app_setting_set(app, "filament.diameter", Number(in.filament).c_str());
        store.SetFirstStart(false);
        model_.RequestSlice();
        written_[ZS_GROUP_MACHINE].clear();
        SaveState();
        project_ = keep_project;
        return true;
    }

    bool PrinterSetup::SetQuality(std::string const &name, bool keep_edits, std::string &message)
    {
        std::string text;
        if (!state::ReadBytes(ProfileDir(ZS_GROUP_PROJECT) + L"\\" + ToWide(ProfileFileName(name)) + L".toml", text))
            text = "extends = \"" + name + "\"\n";
        char error[256] = "";
        int rc = zs_app_quality_set(model_.Active(), name.c_str(), text.data(), text.size(), keep_edits, error, sizeof error);
        if (rc != ZS_OK)
        {
            message = error[0] != 0 ? error : zs_status_message(rc);
            return false;
        }
        profile_[ZS_GROUP_PROJECT] = name;
        Touch(ZS_GROUP_PROJECT);
        Printers().SetPref("profile_project", name);
        model_.RequestSlice();
        SaveState();
        return true;
    }

    std::string PrinterSetup::QualityTitle(std::string const &name)
    {
        if (name.empty() || !IsBuiltinQuality(name))
            return name;
        std::string out = name;
        out[0] = (char)std::toupper((unsigned char)out[0]);
        return out;
    }

    std::string PrinterSetup::QualityLabel() const
    {
        char const *q = zs_app_quality_name(model_.Active());
        std::string name = q != nullptr && q[0] != 0 ? q : "custom";
        std::string label = "Quality: " + QualityTitle(name);
        if (HasSettings(GroupText(ZS_GROUP_PROJECT)))
            label += " \xE2\x80\xA2";
        return label;
    }

    std::string PrinterSetup::QualitySummary(std::string const &name)
    {
        size_t len = 0;
        if (zs_quality_summary(name.c_str(), nullptr, 0, &len) != ZS_OK || len == 0)
            return {};
        std::string text(len + 1, '\0');
        if (zs_quality_summary(name.c_str(), text.data(), text.size(), &len) != ZS_OK)
            return {};
        text.resize(len);
        return text;
    }

    bool PrinterSetup::UseMaterial(std::string const &material, std::string &message)
    {
        std::string base = "generic-" + Lower(material);
        // The diameter is a property of the printer. The built-in profiles
        // are for 1.75 mm.
        std::string diameter = model_.GetSetting("filament.diameter");
        std::string text = "extends = \"" + base + "\"\ndiameter = " + (diameter.empty() ? std::string("1.75") : diameter) + "\n";
        return LoadProfile(ZS_GROUP_FILAMENT, base, text, message);
    }

    bool PrinterSetup::LoadProfile(int group, std::string const &name, std::string const &text, std::string &message)
    {
        if (!ApplyText(group, text, message))
            return false;
        // A machine profile that the user picks goes to the printer. The
        // guard stays while other plates of the project are on the view.
        bool keep_project = group == ZS_GROUP_MACHINE ? KeepProject() : project_;
        if (group == ZS_GROUP_MACHINE)
            project_ = false;
        profile_[group] = name;
        Touch(group);
        Printers().SetPref(std::string("profile_") + group_dirs[group], name);
        model_.RequestSlice();
        SaveState();
        project_ = keep_project;
        return true;
    }

    bool PrinterSetup::SaveProfile(int group, std::string const &raw, std::string &message)
    {
        std::string name = ProfileFileName(raw);
        if (name.empty())
        {
            message = "Type a name for the profile.";
            return false;
        }
        std::string text;
        if (group == ZS_GROUP_PROJECT)
        {
            // The full profile: the values of the quality and the changes of
            // this print together.
            size_t len = 0;
            zs_app *app = model_.Active();
            if (zs_app_profile_write(app, group, nullptr, 0, &len) == ZS_OK)
            {
                text.resize(len + 1);
                if (zs_app_profile_write(app, group, text.data(), text.size(), &len) == ZS_OK)
                    text.resize(len);
                else
                    text.clear();
            }
        }
        else
            text = GroupText(group);
        if (!state::WriteBytes(ProfileDir(group) + L"\\" + ToWide(name) + L".toml", text))
        {
            message = "The profile was not saved.";
            return false;
        }
        profile_[group] = name;
        Printers().SetPref(std::string("profile_") + group_dirs[group], name);
        // The new profile is the quality now, with no changes on top.
        if (group == ZS_GROUP_PROJECT)
            return SetQuality(name, false, message);
        Touch(group);
        return true;
    }

    bool PrinterSetup::LoadUserProfile(int group, std::string const &name, std::string &message)
    {
        std::string text;
        if (!state::ReadBytes(ProfileDir(group) + L"\\" + ToWide(ProfileFileName(name)) + L".toml", text))
        {
            message = "The profile does not read.";
            return false;
        }
        return LoadProfile(group, name, text, message);
    }

    std::vector<std::string> PrinterSetup::UserProfiles(int group) const
    {
        std::vector<std::string> out;
        for (auto const &name : state::ListNames(ProfileDir(group), L".toml"))
            out.push_back(ToUtf8(name));
        return out;
    }

    bool PrinterSetup::GroupChanged(int group) const
    {
        std::string now = GroupText(group);
        return loaded_[group].empty() ? HasSettings(now) : now != loaded_[group];
    }

    std::string PrinterSetup::GroupProfile(int group) const
    {
        return profile_[group];
    }

    bool PrinterSetup::FilamentsFromPrinter(std::string const &printer, std::string const &json, int flags, std::string &message)
    {
        char text[1024] = "";
        int changed = 0;
        int rc = zs_app_filaments_from_printer(model_.Active(), printer.c_str(), json.data(), json.size(), flags, &changed, text, sizeof text);
        message = text;
        if (rc != ZS_OK || changed == 0)
            return false;
        SaveState();
        return true;
    }

    int PrinterSetup::NozzleCount() const
    {
        return std::max(1, atoi(model_.GetSetting("machine.nozzles").c_str()));
    }

    bool PrinterSetup::TwoNozzles() const
    {
        return atof(model_.GetSetting("machine.nozzles").c_str()) >= 2;
    }
}
