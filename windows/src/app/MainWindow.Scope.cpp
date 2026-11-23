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
// The part card lists the settings that the part has of its own, each with
// its editor and × (the value of the plate again). "+ Add a setting" opens
// the search for the selected part or parts, as web/app/partcard.js does.
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

    // ---- the settings of a part on its card ----

    void MainWindow::WirePartSettings()
    {
        PartAddSetting().Click([this](auto &&, auto &&) { OpenPartSearch(); });
    }

    // Reads the first part, and sets each of them.
    std::shared_ptr<MainWindow::EditorTarget> MainWindow::PartTarget(std::vector<int64_t> const &parts)
    {
        auto target = std::make_shared<EditorTarget>();
        target->get = [this, parts](std::string const &name) -> std::string {
            if (model == nullptr || parts.empty())
                return {};
            zs_app *app = model->Active();
            size_t len = 0;
            if (zs_app_part_setting_get(app, (size_t)parts[0], name.c_str(), nullptr, 0, &len) != ZS_OK)
                return model->GetSetting(name.c_str());
            std::string text(len + 1, '\0');
            if (zs_app_part_setting_get(app, (size_t)parts[0], name.c_str(), text.data(), text.size(), &len) != ZS_OK)
                return model->GetSetting(name.c_str());
            text.resize(len);
            return text;
        };
        target->set = [this, parts](std::string const &name, std::string const &value) {
            if (model == nullptr)
                return;
            zs_app *app = model->Active();
            int rc = ZS_OK;
            for (int64_t part : parts)
                if (rc == ZS_OK)
                    rc = zs_app_part_setting_set(app, (size_t)part, name.c_str(), value.c_str());
            if (rc != ZS_OK)
                ShowToast(zs::ToWide(name) + L": " + zs::ToWide(zs_status_message(rc)));
            PlateEdited();
            RefreshSettingValues();
        };
        return target;
    }

    void MainWindow::FillPartSettings(int64_t part)
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        // The settings from the file of the part: read only.
        {
            size_t file_len = 0;
            std::string file_text;
            if (zs_app_part_settings(app, (size_t)part, nullptr, 0, &file_len) == ZS_OK && file_len > 0)
            {
                file_text.assign(file_len + 1, '\0');
                if (zs_app_part_settings(app, (size_t)part, file_text.data(), file_text.size(), &file_len) == ZS_OK)
                    file_text.resize(file_len);
                else
                    file_text.clear();
            }
            PartFileText().Text(zs::ToWide(file_text));
            PartFileBox().Visibility(file_text.empty() ? Visibility::Collapsed : Visibility::Visible);
        }
        std::vector<zs_setting_info> own;
        std::string key = std::to_string(part) + ":";
        for (size_t i = 0, n = zs_setting_count(); i < n; i++)
        {
            zs_setting_info info{};
            size_t len = 0;
            // The filament has its own row of chips at the top of the card.
            if (zs_setting_get_info(i, &info) != ZS_OK || info.per_part == 0 || strcmp(info.name, "project.filament") == 0 ||
                zs_app_part_setting_get(app, (size_t)part, info.name, nullptr, 0, &len) != ZS_OK)
                continue;
            key += std::string(info.name) + ",";
            own.push_back(info);
        }
        if (key == part_settings_key)
        {
            RefreshPartSettings();
            return;
        }
        part_settings_key = key;
        part_editors.clear();
        auto box = PartOwnSettings();
        box.Children().Clear();
        box.Visibility(own.empty() ? Visibility::Collapsed : Visibility::Visible);
        if (own.empty())
            return;
        TextBlock head;
        head.Text(L"Settings of this part");
        head.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        head.FontSize(12);
        box.Children().Append(head);
        auto target = PartTarget({ part });
        for (auto const &info : own)
        {
            Grid row;
            row.ColumnSpacing(6);
            ColumnDefinition label_column, editor_column, clear_column;
            label_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            editor_column.Width(GridLengthHelper::Auto());
            clear_column.Width(GridLengthHelper::FromPixels(22));
            row.ColumnDefinitions().Append(label_column);
            row.ColumnDefinitions().Append(editor_column);
            row.ColumnDefinitions().Append(clear_column);
            std::wstring text = zs::ToWide(info.label);
            TextBlock label;
            label.Text(text);
            label.FontSize(13);
            label.TextWrapping(TextWrapping::WrapWholeWords);
            label.VerticalAlignment(VerticalAlignment::Center);
            std::wstring doc = zs::ToWide(info.doc != nullptr ? info.doc : "");
            doc.erase(std::remove(doc.begin(), doc.end(), L'`'), doc.end());
            ToolTipService::SetToolTip(label, box_value(doc));
            row.Children().Append(label);
            // The editors of the card refresh on their own: the list of the
            // pane goes away with its page.
            size_t before = setting_editors.size();
            FrameworkElement editor = MakeEditor(info, target);
            for (size_t i = before; i < setting_editors.size(); i++)
                part_editors.push_back(std::move(setting_editors[i]));
            setting_editors.resize(before);
            if (IsFilamentSetting(info.name))
            {
            }
            else if (info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER)
            {
                auto with_unit = editor.try_as<Grid>();
                (with_unit != nullptr ? with_unit.Children().GetAt(0).as<FrameworkElement>() : editor).Width(64);
                if (with_unit != nullptr)
                    with_unit.ColumnDefinitions().GetAt(1).MinWidth(40);
            }
            else if (info.kind == ZS_SETTING_TEXT)
            {
                editor.Width(120);
            }
            editor.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(editor, 1);
            row.Children().Append(editor);
            Button clear;
            clear.Width(22);
            clear.Height(22);
            clear.MinWidth(0);
            clear.MinHeight(0);
            clear.Padding(ThicknessHelper::FromUniformLength(0));
            clear.Background(Microsoft::UI::Xaml::Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            clear.BorderThickness(ThicknessHelper::FromUniformLength(0));
            clear.Content(box_value(L"×"));
            clear.VerticalAlignment(VerticalAlignment::Center);
            ToolTipService::SetToolTip(clear, box_value(L"The value of the plate again"));
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(clear, text + L": the value of the plate again");
            std::string name = info.name;
            clear.Click([this, part, name](auto &&, auto &&) {
                // After the click: the button goes away with its row.
                queue.TryEnqueue([this, part, name] {
                    if (model != nullptr && (size_t)part < zs_app_part_count(model->Active()) &&
                        zs_app_part_setting_set(model->Active(), (size_t)part, name.c_str(), nullptr) == ZS_OK)
                    {
                        PlateEdited();
                        RefreshSettingValues();
                    }
                });
            });
            Grid::SetColumn(clear, 2);
            row.Children().Append(clear);
            box.Children().Append(row);
        }
    }

    void MainWindow::RefreshPartSettings()
    {
        if (PartCard().Visibility() != Visibility::Visible)
            return;
        for (auto &editor : part_editors)
            editor.refresh();
    }

    // The search of the settings that a part can have, for the selection.
    void MainWindow::OpenPartSearch()
    {
        if (model == nullptr || selected_parts.empty())
            return;
        std::vector<int64_t> parts = selected_parts;
        auto scope = std::make_shared<SearchScope>();
        if (parts.size() > 1)
        {
            scope->label = std::to_wstring(parts.size()) + L" parts";
        }
        else
        {
            zs_part p{};
            std::wstring name = zs_app_part_get(model->Active(), (size_t)parts[0], &p) == ZS_OK && p.name != nullptr ? zs::ToWide(p.name) : L"";
            scope->label = L"Part: " + (name.empty() ? std::to_wstring(parts[0] + 1) : name);
        }
        scope->only = [](zs_setting_info const &info) { return info.per_part != 0; };
        scope->source = [this, first = parts[0]](std::string const &name) -> std::wstring {
            size_t len = 0;
            if (model != nullptr && zs_app_part_setting_get(model->Active(), (size_t)first, name.c_str(), nullptr, 0, &len) == ZS_OK)
                return L"This part";
            return model != nullptr ? zs::ToWide(model->SourceTag(name.c_str())) : L"";
        };
        scope->target = PartTarget(parts);
        OpenScopedSearch(scope);
    }

#ifdef ZS_DEV_HOOKS
    // scopeset n (0 print, 1 global, 2 and up a part), scopeedit name value,
    // scopereset name, scopelog name, scopepart name value, scopepartclear
    // name, scopepartadd, scopepartpick i, scopeparttoggle i, scopepartlog,
    // scopepartscale percent, scopemark add k|kind k|radius r|remove|log.
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
        else if (verb == L"scopepart" && words.size() >= 2)
            PartTarget(selected_parts)->set(zs::ToUtf8(words[0]), zs::ToUtf8(words[1]));
        else if (verb == L"scopepartclear" && !words.empty() && !selected_parts.empty())
        {
            for (int64_t part : selected_parts)
                zs_app_part_setting_set(model->Active(), (size_t)part, zs::ToUtf8(words[0]).c_str(), nullptr);
            PlateEdited();
            RefreshSettingValues();
        }
        else if (verb == L"scopepartadd")
            OpenPartSearch();
        else if (verb == L"scopemark" && !words.empty())
        {
            // add k, kind k, radius r, remove, log.
            double value = words.size() > 1 ? _wtof(words[1].c_str()) : 0;
            double x, y, z;
            if (words[0] == L"add" && MenuPlace(x, y, z) && zs_app_mark_add(model->Active(), x, y, z, 3, (int)value) == ZS_OK)
                SupportEdited();
            else if (words[0] == L"kind")
                LineMarkKind().SelectedIndex((int32_t)value);
            else if (words[0] == L"radius")
                LineMarkRadius().Value(value);
            else if (words[0] == L"remove" && line_mark >= 0)
            {
                zs_app_mark_remove(model->Active(), (size_t)line_mark);
                line_mark = -1;
                LineMark().Visibility(Visibility::Collapsed);
                SupportEdited();
            }
            else if (words[0] == L"log")
            {
                double r = 0;
                int kind = -1;
                if (line_mark >= 0)
                    zs_app_mark_get(model->Active(), (size_t)line_mark, nullptr, nullptr, nullptr, &r, &kind);
                zs::Log("dev: mark count %zu, path %lld, row %d, index %lld, core kind %d radius %.1f, combo %d box %.1f\n", zs_app_mark_count(model->Active()), (long long)selected_path,
                        LineMark().Visibility() == Visibility::Visible ? 1 : 0, (long long)line_mark, kind, r, LineMarkKind().SelectedIndex(), LineMarkRadius().Value());            }
        }
        else if (verb == L"scopepartpick" && !words.empty())
            SelectPart(_wtoi(words[0].c_str()));
        else if (verb == L"scopeparttoggle" && !words.empty())
            TogglePart(_wtoi(words[0].c_str()));
        else if (verb == L"scopepartscale" && !words.empty() && !selected_parts.empty())
        {
            // A percent, for a part that does not fit or is too thin.
            double k = _wtof(words[0].c_str()) / 100;
            for (int64_t part : selected_parts)
                zs_app_part_scale(model->Active(), (size_t)part, k, k, k);
            PlateEdited();
            zs_part_fit fit{};
            size_t len = 0;
            std::string words_of_fit;
            if (zs_app_part_fit_text(model->Active(), (size_t)selected_parts[0], nullptr, 0, &len) == ZS_OK)
            {
                words_of_fit.assign(len + 1, '\0');
                zs_app_part_fit_text(model->Active(), (size_t)selected_parts[0], words_of_fit.data(), words_of_fit.size(), &len);
                words_of_fit.resize(len);
            }
            zs_app_part_fit(model->Active(), (size_t)selected_parts[0], &fit);
            zs::Log("dev: part fit cause %d '%s'\n", fit.cause, words_of_fit.c_str());
        }
        else if (verb == L"scopepartlog")
        {
            std::string own;
            for (int64_t part : selected_parts)
            {
                own += "[" + std::to_string(part) + ":";
                for (size_t i = 0, n = zs_setting_count(); i < n; i++)
                {
                    zs_setting_info info{};
                    size_t len = 0;
                    if (zs_setting_get_info(i, &info) == ZS_OK && info.per_part != 0 &&
                        zs_app_part_setting_get(model->Active(), (size_t)part, info.name, nullptr, 0, &len) == ZS_OK)
                        own += std::string(" ") + info.name + "=" + PartTarget({ part })->get(info.name);
                }
                own += "]";
            }
            zs::Log("dev: part settings selected %zu rows %u editors %zu add '%s' search %d | %s\n", selected_parts.size(), PartOwnSettings().Children().Size(), part_editors.size(),
                    to_string(unbox_value<hstring>(PartAddSetting().Content())).c_str(), search_scope != nullptr ? 1 : 0, own.c_str());
        }
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
