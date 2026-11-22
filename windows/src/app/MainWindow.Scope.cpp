// "Settings for" of the settings pane: this print, the global settings of
// the user, or one part. The behavior follows settings-browser.c and
// app-model.c of the GTK shell.
//
// The editors of the pane read and set the values of the scope through
// scope_target. A global setting is a project setting for all prints, under
// the quality profile: global.toml keeps it, and each plate gets it
// (ApplyEnginePrefs). A part has the values of the print, with its own
// changes on top. A setting that the scope cannot have shows, and is off.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace
{
    constexpr int64_t scope_print = -1, scope_global = -2;

    bool IsProject(std::string const &name)
    {
        return name.rfind("project.", 0) == 0;
    }
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::WireScope()
    {
        scope_target = std::make_shared<EditorTarget>();
        scope_target->get = [this](std::string const &name) { return ScopeValue(name); };
        scope_target->set = [this](std::string const &name, std::string const &value) { ScopeSet(name, value); };
        SettingsScope().SelectionChanged([this](auto &&, auto &&) {
            if (filling_scope)
                return;
            int32_t at = SettingsScope().SelectedIndex();
            if (at >= 0)
                SetSettingsScope(at == 0 ? scope_print : at == 1 ? scope_global : (int64_t)at - 2);
        });
        FillScopeList();
    }

    std::shared_ptr<MainWindow::EditorTarget> MainWindow::PaneTarget()
    {
        if (in_profile)
            return profile_target;
        return settings_scope != scope_print ? scope_target : nullptr;
    }

    bool MainWindow::ScopeEditable(zs_setting_info const &info)
    {
        if (in_profile)
            return true;
        if (settings_scope >= 0)
            return info.per_part != 0;
        return settings_scope != scope_global || IsProject(info.name);
    }

    wchar_t const *MainWindow::ScopeOffTip()
    {
        return settings_scope == scope_global ? L"Printer and filament settings are in their profiles (the menus at the top)."
                                              : L"This setting is the same for all the parts of a print. Change it for this print.";
    }

    bool MainWindow::ScopeIsGlobal() const
    {
        return settings_scope == scope_global;
    }

    // The value that part of the scope has of its own.
    bool MainWindow::PartOwnValue(std::string const &name, std::string &out)
    {
        if (model == nullptr || settings_scope < 0 || zs_setting_is_part(name.c_str()) != 1)
            return false;
        zs_app *app = model->Active();
        size_t len = 0;
        if (zs_app_part_setting_get(app, (size_t)settings_scope, name.c_str(), nullptr, 0, &len) != ZS_OK)
            return false;
        out.assign(len + 1, '\0');
        if (zs_app_part_setting_get(app, (size_t)settings_scope, name.c_str(), out.data(), out.size(), &len) != ZS_OK)
            return false;
        out.resize(len);
        return true;
    }

    std::string MainWindow::ScopeValue(std::string const &name)
    {
        if (model == nullptr)
            return {};
        if (settings_scope == scope_global && IsProject(name))
        {
            zs_app *app = model->Active();
            size_t len = 0;
            if (zs_app_global_get(app, name.c_str(), nullptr, 0, &len) != ZS_OK)
                return {};
            std::string text(len + 1, '\0');
            if (zs_app_global_get(app, name.c_str(), text.data(), text.size(), &len) != ZS_OK)
                return {};
            text.resize(len);
            return text;
        }
        std::string own;
        return PartOwnValue(name, own) ? own : model->GetSetting(name.c_str());
    }

    void MainWindow::ScopeSet(std::string const &name, std::string const &value)
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        int rc = ZS_OK;
        if (settings_scope == scope_global && IsProject(name))
        {
            rc = zs_app_global_setting_set(app, name.c_str(), value.c_str());
            if (rc == ZS_OK)
            {
                GlobalChanged();
                return;
            }
        }
        else if (settings_scope >= 0 && zs_setting_is_part(name.c_str()) == 1)
        {
            rc = zs_app_part_setting_set(app, (size_t)settings_scope, name.c_str(), value.c_str());
            if (rc == ZS_OK)
            {
                PlateEdited();
                RefreshSettingValues();
                return;
            }
        }
        else
        {
            CommitSetting(name, value);
            return;
        }
        ShowToast(zs::ToWide(name) + L": " + zs::ToWide(zs_status_message(rc)));
        RefreshSettingValues();
    }

    // Reset in the detail page. False: the scope has no value of its own,
    // so the reset of the print applies.
    bool MainWindow::ScopeReset(std::string const &name)
    {
        if (model == nullptr)
            return false;
        zs_app *app = model->Active();
        if (settings_scope == scope_global)
        {
            if (IsProject(name) && zs_app_global_setting_set(app, name.c_str(), nullptr) == ZS_OK)
                GlobalChanged();
            return true;
        }
        std::string own;
        if (!PartOwnValue(name, own))
            return false;
        if (zs_app_part_setting_set(app, (size_t)settings_scope, name.c_str(), nullptr) == ZS_OK)
        {
            PlateEdited();
            RefreshSettingValues();
        }
        return true;
    }

    void MainWindow::GlobalChanged()
    {
        if (printers != nullptr)
            printers->setup.SaveGlobal();
        ApplyEnginePrefs();
        model->RequestSlice();
        NoteChange();
        RefreshSettingValues();
    }

    void MainWindow::SetSettingsScope(int64_t scope)
    {
        if (scope == settings_scope)
            return;
        settings_scope = scope;
        scope_app = model != nullptr ? model->Active() : nullptr;
        FillScopeList();
        // The rows show the values and the editors of the new scope.
        if (settings_page == SettingsPage::Section && settings_group != nullptr)
            ShowSection(settings_group, settings_section);
        else if (settings_page == SettingsPage::Detail && !settings_detail.empty())
            ShowDetail(settings_detail.c_str());
        else if (settings_page == SettingsPage::Search && !settings_query.empty())
            ShowSearch(settings_query);
    }

    void MainWindow::FillScopeList()
    {
        std::vector<std::wstring> items = { L"This print (all parts)", L"Global (all prints)" };
        if (model != nullptr)
        {
            zs_app *app = model->Active();
            for (size_t i = 0, n = zs_app_part_count(app); i < n; i++)
            {
                zs_part p{};
                if (zs_app_part_get(app, i, &p) == ZS_OK)
                    items.push_back(L"Part: " + zs::ToWide(p.name != nullptr ? p.name : ""));
            }
        }
        int32_t at = settings_scope == scope_global ? 1 : settings_scope < 0 ? 0 : (int32_t)settings_scope + 2;
        filling_scope = true;
        if (items != scope_items)
        {
            scope_items = items;
            SettingsScope().Items().Clear();
            for (auto const &item : items)
                SettingsScope().Items().Append(box_value(item));
        }
        if (SettingsScope().SelectedIndex() != at)
            SettingsScope().SelectedIndex(at);
        filling_scope = false;
    }

    // After an edit, an undo, or a new scene: a part of the scope can go.
    void MainWindow::ScopeRefresh()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        bool gone = settings_scope >= 0 && (app != scope_app || (size_t)settings_scope >= zs_app_part_count(app));
        if (gone)
        {
            // Not in the event of an editor that goes with its row.
            settings_scope = scope_print;
            scope_app = nullptr;
            FillScopeList();
            auto weak = get_weak();
            queue.TryEnqueue([weak] {
                auto self = weak.get();
                if (self == nullptr)
                    return;
                if (self->settings_page == SettingsPage::Section && self->settings_group != nullptr)
                    self->ShowSection(self->settings_group, self->settings_section);
                else if (self->settings_page == SettingsPage::Detail && !self->settings_detail.empty())
                    self->ShowDetail(self->settings_detail.c_str());
            });
            return;
        }
        FillScopeList();
    }

#ifdef ZS_DEV_HOOKS
    // scopeset n (0 print, 1 global, 2 and up a part), scopeedit name value,
    // scopereset name, scopelog name.
    bool MainWindow::RunScopeStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb.rfind(L"scope", 0) != 0 || model == nullptr)
            return false;
        if (verb == L"scopeset" && !words.empty())
            SettingsScope().SelectedIndex(_wtoi(words[0].c_str()));
        else if (verb == L"scopeedit" && words.size() >= 2)
            ScopeSet(zs::ToUtf8(words[0]), zs::ToUtf8(words[1]));
        else if (verb == L"scopereset" && !words.empty())
            ScopeReset(zs::ToUtf8(words[0]));
        else if (verb == L"scopelog" && !words.empty())
        {
            std::string name = zs::ToUtf8(words[0]), own;
            bool has = PartOwnValue(name, own);
            size_t len = 0;
            std::string global;
            if (zs_app_global_write(model->Active(), nullptr, 0, &len) == ZS_OK)
            {
                global.assign(len + 1, '\0');
                zs_app_global_write(model->Active(), global.data(), global.size(), &len);
                global.resize(len);
                std::replace(global.begin(), global.end(), '\n', ' ');
            }
            std::string formula = model->Formula(name.c_str());
            zs::Log("dev: scope %lld index %d items %zu | %s print %s scope %s part own %d '%s' | formula '%s' | global '%s' | plates %zu\n", (long long)settings_scope, SettingsScope().SelectedIndex(),
                    scope_items.size(), name.c_str(), model->GetSetting(name.c_str()).c_str(), ScopeValue(name).c_str(), has ? 1 : 0, own.c_str(), formula.c_str(), global.c_str(),
                    model->PlateCount());
        }
        else
            return false;
        return true;
    }
#endif
}
