// A printdeck.yml project: a dialog over the window, as in web/app/project.js
// and linux/src/ui/project-page.c.
//
// A project is a repository with a printdeck.yml: the parts to print, with
// their files, printer, Cura profile, material, and settings. It opens from a
// public GitHub repository or from a folder (src/net/zs_project_source). The
// core plans the plates (zs_project_plan). An open of a plate loads all
// plates of the plan into the plate set (zs_set_project_load), and the plate
// becomes the active plate.
//
// Each plate has a print status. Its key is the printer, the profile, the
// material, and the parts with their counts, as in the other apps. The
// project, the counts, and the status are in project.json in the state
// folder.
//
// The plates of the set are matched to the plates of the plan by the id of
// each plate (zs_plate_info.id), so a plate that the user removes or adds
// needs no call from the code that does it. The session has a tag of the
// project. A session with the same tag has the plates of this project.
//
// A plate of a project has the machine of its Cura stack. PrinterSetup
// writes no machine profile while such plates are on the view.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#include <atomic>
#include <cwctype>
#include <map>
#include <set>
#include <thread>

#include "zs_json.h"
#include "zs_project_source.h"
#include "zs_state.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Media = Microsoft::UI::Xaml::Media;
namespace json = zs::json;
namespace source_ns = zs::project;
using Windows::System::VirtualKey;

namespace
{
    struct StatusName
    {
        char const *key;
        wchar_t const *label;
    };
    StatusName const statuses[] = {
        { "todo", L"To print" },
        { "printing", L"Printing" },
        { "printed", L"Printed" },
        { "failed", L"Failed" },
    };

    // "taz/pla" gives "taz".
    std::string ProfileFolder(std::string const &profile)
    {
        return profile.substr(0, profile.find('/'));
    }

    // "taz/pla" gives "pla".
    std::string ProfileName(std::string const &profile)
    {
        size_t slash = profile.find('/');
        if (slash == std::string::npos)
            return profile;
        size_t end = profile.find('/', slash + 1);
        return profile.substr(slash + 1, end == std::string::npos ? end : end - slash - 1);
    }

    // "printer · profile · material", with no empty parts.
    std::wstring Facts(json::Value const &o)
    {
        std::wstring out;
        for (std::string const &part : { o.Str("printer"), ProfileName(o.Str("profile")), o.Str("material") })
        {
            if (part.empty())
                continue;
            if (!out.empty())
                out += L" · ";
            out += zs::ToWide(part);
        }
        return out;
    }

    std::string FolderName(std::string const &path)
    {
        size_t end = path.find_last_not_of("\\/");
        if (end == std::string::npos)
            return path;
        size_t at = path.find_last_of("\\/", end);
        return at == std::string::npos ? path.substr(0, end + 1) : path.substr(at + 1, end - at);
    }

    // The value of a setting of a part, for its tooltip.
    std::wstring ValueText(json::Value const *v)
    {
        if (v == nullptr)
            return {};
        if (v->type == json::Type::String)
            return zs::ToWide(v->text);
        if (v->type == json::Type::Bool)
            return v->boolean ? L"true" : L"false";
        if (v->type == json::Type::Number)
        {
            wchar_t text[32];
            swprintf_s(text, L"%g", v->number);
            return text;
        }
        return {};
    }

    uint64_t Fnv(std::string const &text)
    {
        uint64_t h = 14695981039346656037ull;
        for (unsigned char c : text)
        {
            h ^= c;
            h *= 1099511628211ull;
        }
        return h;
    }

    bool EqualNoCase(std::string const &a, std::string const &b)
    {
        return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(), [](unsigned char x, unsigned char y) {
                   return std::tolower(x) == std::tolower(y);
               });
    }

    // printdeck.yml of a source, with the limits of a text for the core.
    bool ReadYml(source_ns::Source &source, std::string &yml, std::string &error, zs::http::CancelPtr const &cancel)
    {
        if (!source.Has("printdeck.yml"))
        {
            error = source.kind == source_ns::Source::Kind::Github ? source.owner + "/" + source.repo + " has no printdeck.yml at its root."
                                                                   : "The folder " + zs::ToUtf8(source.folder) + " has no printdeck.yml at its root.";
            return false;
        }
        if (!source.Read("printdeck.yml", yml, error, cancel))
            return false;
        if (yml.size() > source_ns::max_yml || yml.find('\0') != std::string::npos)
        {
            error = "printdeck.yml is not a text file of at most 4 MB.";
            return false;
        }
        return true;
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    struct MainWindow::ProjectUi
    {
        // What project.json keeps. open is false with no project.
        bool open = false;
        std::string kind, owner, repo, sha, path;
        std::string text;
        // For each part: its count, or -1 for the count of printdeck.yml.
        std::vector<int> counts;
        std::map<std::string, std::string> status;
        std::string active;
        bool has_active = false;
        bool set_loaded = false;
        // The plan plate of each plate of the set that is of the project.
        std::vector<int> set_map;

        // This run.
        std::shared_ptr<source_ns::Source> source;
        json::Value plan;
        bool has_plan = false;
        std::string plan_key;
        // The plan_key of the plates in the set.
        std::string loaded;
        bool is_loaded = false;
        std::map<uint64_t, int> plate_ids;
        std::wstring busy, error, github_text;
        zs::http::CancelPtr cancel;
        // A result of an older request is dropped.
        uint64_t epoch = 0;
        bool render_queued = false;

        // The dialog.
        Grid overlay{ nullptr };
        Border card{ nullptr };
        Grid bar{ nullptr };
        StackPanel page{ nullptr };
        ScrollViewer scroll{ nullptr };
        Button close_button{ nullptr };
        TextBox github_box{ nullptr };
        MenuFlyoutItem menu_open{ nullptr }, menu_close{ nullptr };
        std::vector<ComboBox> status_boxes;
        std::vector<NumberBox> count_boxes;
        std::vector<CheckBox> check_boxes;

        bool Visible() const
        {
            return overlay != nullptr && overlay.Visibility() == Visibility::Visible;
        }

        json::Value const *Plates() const
        {
            json::Value const *v = has_plan ? plan.Get("plates") : nullptr;
            return v != nullptr && v->IsArray() ? v : nullptr;
        }

        json::Value const *Parts() const
        {
            json::Value const *v = has_plan ? plan.Get("parts") : nullptr;
            return v != nullptr && v->IsArray() ? v : nullptr;
        }

        std::string CountsText() const
        {
            std::string out;
            for (size_t i = 0; i < counts.size(); i++)
            {
                if (i > 0)
                    out += ',';
                out += counts[i] < 0 ? std::string("-") : std::to_string(counts[i]);
            }
            return out;
        }

        // The error of the plan with its line, or empty.
        std::wstring PlanError() const
        {
            if (!open)
                return {};
            if (!has_plan)
                return L"printdeck.yml: the plan did not load.";
            json::Value const *e = plan.Get("error");
            if (e == nullptr)
                return {};
            int line = (int)plan.Num("line");
            return L"printdeck.yml" + (line > 0 ? L", line " + std::to_wstring(line) : std::wstring()) + L": " + zs::ToWide(e->text);
        }

        std::string PlateKey(json::Value const &plate) const
        {
            std::string out = plate.Str("printer") + "|" + plate.Str("profile") + "|" + plate.Str("material") + "|";
            json::Value const *items = plate.Get("items");
            json::Value const *parts = Parts();
            if (items == nullptr || parts == nullptr)
                return out;
            for (size_t i = 0; i < items->items.size(); i++)
            {
                json::Value const &it = items->items[i];
                size_t part = (size_t)it.Num("part");
                if (i > 0)
                    out += ',';
                out += (part < parts->items.size() ? parts->items[part].Str("name") : std::string()) + "x" + std::to_string((int)it.Num("count"));
            }
            return out;
        }

        std::string StatusOf(std::string const &key) const
        {
            auto it = status.find(key);
            return it == status.end() ? "todo" : it->second;
        }

        std::wstring Name() const
        {
            if (!open)
                return {};
            std::string name = has_plan && plan.Get("error") == nullptr ? plan.Str("name") : "";
            if (name.empty())
                name = kind == "github" ? owner + "/" + repo : FolderName(path);
            return zs::ToWide(name);
        }

        // Plate i of the set, as a plate of the plan, or -1.
        int PlanIndex(zs_set *set, size_t i) const
        {
            zs_plate_info info{};
            if (zs_set_plate_info(set, i, &info) != ZS_OK)
                return -1;
            auto it = plate_ids.find(info.id);
            return it == plate_ids.end() ? -1 : it->second;
        }

        bool IsInSet() const
        {
            return is_loaded && loaded == plan_key;
        }

        void Stop()
        {
            epoch++;
            if (cancel != nullptr)
                cancel->Stop();
            cancel = nullptr;
            busy.clear();
        }

        zs::http::CancelPtr NewRequest()
        {
            Stop();
            cancel = std::make_shared<zs::http::Cancel>();
            return cancel;
        }

        void Clear()
        {
            open = false;
            kind.clear();
            owner.clear();
            repo.clear();
            sha.clear();
            path.clear();
            text.clear();
            counts.clear();
            status.clear();
            active.clear();
            has_active = false;
            set_loaded = false;
            set_map.clear();
            source = nullptr;
            plan = json::Value{};
            has_plan = false;
            plan_key.clear();
            loaded.clear();
            is_loaded = false;
            plate_ids.clear();
            error.clear();
        }
    };

    // ---- the state file ----

    void MainWindow::ProjectSave()
    {
        auto &p = *project_ui;
        std::wstring path = zs::state::PathOf(L"project.json");
        if (!p.open)
        {
            zs::state::Remove(path);
            return;
        }
        std::string out = "{\"source\":{\"kind\":" + json::Quote(p.kind);
        if (p.kind == "folder")
            out += ",\"path\":" + json::Quote(p.path);
        else
            out += ",\"owner\":" + json::Quote(p.owner) + ",\"repo\":" + json::Quote(p.repo) + ",\"sha\":" + json::Quote(p.sha);
        out += "},\"text\":" + json::Quote(p.text) + ",\"counts\":[";
        for (size_t i = 0; i < p.counts.size(); i++)
            out += (i > 0 ? "," : "") + (p.counts[i] < 0 ? std::string("null") : std::to_string(p.counts[i]));
        out += "],\"status\":{";
        bool first = true;
        for (auto const &[key, value] : p.status)
        {
            out += (first ? "" : ",") + json::Quote(key) + ":" + json::Quote(value);
            first = false;
        }
        out += "},\"active\":" + (p.has_active ? json::Quote(p.active) : std::string("null"));
        out += std::string(",\"setLoaded\":") + (p.set_loaded ? "true" : "false") + ",\"setMap\":[";
        for (size_t i = 0; i < p.set_map.size(); i++)
            out += (i > 0 ? "," : "") + std::to_string(p.set_map[i]);
        out += "]}";
        zs::state::EnsureParent(path);
        if (!zs::state::WriteBytes(path, out))
            zs::Log("shell: the project was not saved\n");
    }

    void MainWindow::ProjectReplan()
    {
        auto &p = *project_ui;
        p.plan = json::Value{};
        p.has_plan = false;
        p.plan_key.clear();
        if (!p.open)
            return;
        std::string counts = p.CountsText();
        p.plan_key = p.text + "\n" + counts;
        size_t len = 0;
        if (zs_project_plan(p.text.c_str(), counts.c_str(), nullptr, 0, &len) != ZS_OK)
            return;
        std::string text(len + 1, '\0');
        if (zs_project_plan(p.text.c_str(), counts.c_str(), text.data(), text.size(), &len) != ZS_OK)
            return;
        text.resize(len);
        p.has_plan = json::Parse(text, p.plan) && p.plan.IsObject();
    }

    // ---- the window ----

    void MainWindow::AddProjectMenuItems()
    {
        if (project_ui == nullptr)
            project_ui = std::make_shared<ProjectUi>();
        auto &p = *project_ui;
        p.menu_open = MenuFlyoutItem{};
        p.menu_open.Text(L"Open a project…");
        p.menu_open.Click([this](auto &&, auto &&) { ShowProjectDialog(); });
        MainMenu().Items().Append(p.menu_open);
        p.menu_close = MenuFlyoutItem{};
        p.menu_close.Visibility(Visibility::Collapsed);
        p.menu_close.Click([this](auto &&, auto &&) { CloseProject(); });
        MainMenu().Items().Append(p.menu_close);
    }

    void MainWindow::RefreshProjectMenu()
    {
        if (project_ui == nullptr)
            return;
        auto &p = *project_ui;
        std::wstring name = p.Name();
        p.menu_open.Text(name.empty() ? std::wstring(L"Open a project…") : L"The project " + name + L"…");
        p.menu_close.Text(L"Close the project " + name);
        p.menu_close.Visibility(name.empty() ? Visibility::Collapsed : Visibility::Visible);
    }

    std::wstring MainWindow::ProjectName()
    {
        return project_ui != nullptr ? project_ui->Name() : std::wstring();
    }

    void MainWindow::WireProject()
    {
        if (project_ui == nullptr)
            project_ui = std::make_shared<ProjectUi>();
        auto &p = *project_ui;
        if (p.overlay != nullptr)
            return;

        // The dialog: a card over a shade, as .project-dialog in style.css.
        p.overlay = Grid{};
        Grid::SetRowSpan(p.overlay, 2);
        p.overlay.Visibility(Visibility::Collapsed);
        p.overlay.Background(TokenBrush(Root(), L"ZsShade"));
        Automation::AutomationProperties::SetName(p.overlay, L"Open a project");
        p.card = Border{};
        p.card.Width(620);
        p.card.HorizontalAlignment(HorizontalAlignment::Center);
        p.card.VerticalAlignment(VerticalAlignment::Center);
        p.card.CornerRadius(CornerRadiusHelper::FromUniformRadius(12));
        p.card.Background(TokenBrush(Root(), L"ZsBg"));
        Grid inner;
        RowDefinition bar_row, body_row;
        bar_row.Height(GridLengthHelper::Auto());
        body_row.Height(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        inner.RowDefinitions().Append(bar_row);
        inner.RowDefinitions().Append(body_row);

        // The top row of the dialog (.page-bar).
        Grid bar;
        p.bar = bar;
        bar.Padding(ThicknessHelper::FromLengths(14, 10, 14, 10));
        bar.BorderThickness(ThicknessHelper::FromLengths(0, 0, 0, 1));
        bar.BorderBrush(TokenBrush(Root(), L"ZsBorder"));
        TextBlock title;
        title.Text(L"Project");
        title.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
        title.VerticalAlignment(VerticalAlignment::Center);
        title.Margin(ThicknessHelper::FromLengths(6, 0, 0, 0));
        bar.Children().Append(title);
        p.close_button = Button{};
        p.close_button.Content(box_value(L"×"));
        p.close_button.HorizontalAlignment(HorizontalAlignment::Right);
        p.close_button.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        p.close_button.Padding(ThicknessHelper::FromLengths(8, 5, 8, 5));
        p.close_button.MinHeight(32);
        p.close_button.MinWidth(0);
        Automation::AutomationProperties::SetName(p.close_button, L"Close");
        p.close_button.Click([this](auto &&, auto &&) { HideProjectDialog(); });
        bar.Children().Append(p.close_button);
        inner.Children().Append(bar);

        ScrollViewer scroll;
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        Grid::SetRow(scroll, 1);
        p.page = StackPanel{};
        p.page.Spacing(8);
        // The padding of .page and of .project together.
        p.page.Padding(ThicknessHelper::FromLengths(28, 22, 28, 36));
        scroll.Content(p.page);
        p.scroll = scroll;
        inner.Children().Append(scroll);
        p.card.Child(inner);
        p.overlay.Children().Append(p.card);

        // The keys of the view do not act behind the dialog.
        p.overlay.KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() == VirtualKey::Escape)
            {
                HideProjectDialog();
                e.Handled(true);
            }
            else if (e.Key() != VirtualKey::Tab)
            {
                e.Handled(true);
            }
        });
        auto fit = [this] {
            auto &ui = *project_ui;
            double w = Root().ActualWidth(), h = Root().ActualHeight();
            if (w > 0)
                ui.card.Width(std::min(620.0, std::max(240.0, w - 32)));
            if (h > 0)
                ui.card.MaxHeight(std::max(200.0, h - 64));
        };
        Root().SizeChanged([fit](auto &&, auto &&) { fit(); });
        fit();
        Root().ActualThemeChanged([this](auto &&, auto &&) {
            auto &ui = *project_ui;
            ui.overlay.Background(TokenBrush(Root(), L"ZsShade"));
            ui.card.Background(TokenBrush(Root(), L"ZsBg"));
            ui.bar.BorderBrush(TokenBrush(Root(), L"ZsBorder"));
            ProjectRenderSoon();
        });
        Root().Children().Append(p.overlay);

        // The project of the last run.
        std::string data;
        json::Value saved;
        if (!zs::state::ReadBytes(zs::state::PathOf(L"project.json"), data) || !json::Parse(data, saved) || !saved.IsObject())
            return;
        json::Value const *from = saved.Get("source");
        std::string text = saved.Str("text");
        if (from == nullptr || !from->IsObject() || text.empty() || text.size() > source_ns::max_yml || text.find('\0') != std::string::npos)
            return;
        std::string kind = from->Str("kind");
        if (kind == "github")
        {
            if (!source_ns::IsRepoName(from->Str("owner")) || !source_ns::IsRepoName(from->Str("repo")) || !source_ns::IsCommit(from->Str("sha")))
                return;
            p.owner = from->Str("owner");
            p.repo = from->Str("repo");
            p.sha = from->Str("sha");
        }
        else if (kind == "folder" && !from->Str("path").empty())
        {
            p.path = from->Str("path");
        }
        else
        {
            return;
        }
        p.open = true;
        p.kind = kind;
        p.text = std::move(text);
        if (json::Value const *counts = saved.Get("counts"); counts != nullptr && counts->IsArray())
            for (auto const &n : counts->items)
                p.counts.push_back(n.type == json::Type::Number ? std::clamp((int)n.number, 0, 99) : -1);
        if (json::Value const *status = saved.Get("status"); status != nullptr && status->IsObject())
            for (auto const &[key, value] : status->members)
                if (value.type == json::Type::String)
                    p.status[key] = value.text;
        if (json::Value const *active = saved.Get("active"); active != nullptr && active->type == json::Type::String)
        {
            p.active = active->text;
            p.has_active = true;
        }
        json::Value const *set_loaded = saved.Get("setLoaded");
        p.set_loaded = set_loaded != nullptr && set_loaded->type == json::Type::Bool && set_loaded->boolean;
        if (json::Value const *map = saved.Get("setMap"); map != nullptr && map->IsArray())
            for (auto const &n : map->items)
                if (n.type == json::Type::Number)
                    p.set_map.push_back((int)n.number);
        ProjectReplan();
    }

    // After the restore of the session: the files of the saved project.
    void MainWindow::ProjectStart()
    {
        if (project_ui == nullptr || !project_ui->open)
            return;
        auto &p = *project_ui;
        // No session of these plates: the plates on the view are the user's.
        if (p.set_loaded && !p.is_loaded)
        {
            p.set_loaded = false;
            p.set_map.clear();
            ProjectSave();
        }
        auto cancel = p.NewRequest();
        uint64_t epoch = p.epoch;
        auto weak = get_weak();
        auto target = queue;
        bool github = p.kind == "github";
        source_ns::GithubRepo repo{ p.owner, p.repo, "" };
        std::string sha = p.sha;
        std::wstring folder = zs::ToWide(p.path);
        std::thread([weak, target, cancel, epoch, github, repo, sha, folder] {
            std::string error;
            auto source = github ? source_ns::OpenGithub(repo, sha, cancel, error) : source_ns::OpenFolder(folder, cancel, error);
            target.TryEnqueue([weak, epoch, source] {
                auto self = weak.get();
                if (self == nullptr || self->project_ui == nullptr || self->project_ui->epoch != epoch)
                    return;
                self->project_ui->cancel = nullptr;
                // No network, or no folder: the plates show, and an open
                // says why.
                self->project_ui->source = source;
                self->ProjectRenderSoon();
            });
        }).detach();
    }

    void MainWindow::CloseProjectUi()
    {
        if (project_ui != nullptr)
            project_ui->Stop();
    }

    void MainWindow::ShowProjectDialog()
    {
        if (project_ui == nullptr || project_ui->overlay == nullptr)
            return;
        auto &p = *project_ui;
        p.overlay.Visibility(Visibility::Visible);
        ProjectRender();
    }

    // The focus stays in the dialog, so Esc reaches it and the keys of the
    // view do not act behind it. A render removes the control that had the
    // focus. It runs after the layout: a new control has no focus before.
    void MainWindow::ProjectKeepFocus()
    {
        auto weak = get_weak();
        queue.TryEnqueue(Microsoft::UI::Dispatching::DispatcherQueuePriority::Low, [weak] {
            auto self = weak.get();
            if (self == nullptr || self->project_ui == nullptr || !self->project_ui->Visible())
                return;
            auto &ui = *self->project_ui;
            auto focused = Input::FocusManager::GetFocusedElement(self->Content().XamlRoot()).try_as<DependencyObject>();
            for (DependencyObject at = focused; at != nullptr; at = Media::VisualTreeHelper::GetParent(at))
                if (at == ui.overlay)
                    return;
            if (ui.github_box == nullptr || !ui.github_box.Focus(FocusState::Programmatic))
                ui.close_button.Focus(FocusState::Programmatic);
        });
    }

    void MainWindow::HideProjectDialog()
    {
        if (project_ui == nullptr || !project_ui->Visible())
            return;
        project_ui->overlay.Visibility(Visibility::Collapsed);
        ViewPanel().Focus(FocusState::Programmatic);
    }

    // Closes the project. Its plates stay on the view as plates of the user.
    void MainWindow::CloseProject()
    {
        if (project_ui == nullptr || !project_ui->open)
            return;
        auto &p = *project_ui;
        std::wstring name = p.Name();
        p.Stop();
        p.Clear();
        ProjectSave();
        ProjectRender();
        RefreshSigns();
        SessionSoon();
        ShowToast(L"The project " + name + L" is closed. Its plates stay.");
    }

    void MainWindow::ProjectFail(std::wstring const &text)
    {
        auto &p = *project_ui;
        p.error = text;
        zs::Log("shell: project: %s\n", zs::ToUtf8(text).c_str());
        ShowToast(text);
        ProjectRender();
    }

    // ---- open ----

    void MainWindow::ProjectOpenGithub(std::wstring const &text)
    {
        auto &p = *project_ui;
        source_ns::GithubRepo repo;
        if (!source_ns::ParseGithub(zs::ToUtf8(text), repo))
        {
            ProjectFail(L"Type owner/repo, or the address of a repository on github.com.");
            return;
        }
        auto cancel = p.NewRequest();
        p.error.clear();
        p.busy = L"Opening " + zs::ToWide(repo.owner) + L"/" + zs::ToWide(repo.repo) + L"…";
        ProjectRender();
        uint64_t epoch = p.epoch;
        auto weak = get_weak();
        auto target = queue;
        std::thread([weak, target, cancel, epoch, repo] {
            std::string error, yml;
            auto source = source_ns::OpenGithub(repo, "", cancel, error);
            if (source != nullptr && !ReadYml(*source, yml, error, cancel))
                source = nullptr;
            target.TryEnqueue([weak, epoch, source, yml = std::move(yml), error = std::move(error)] {
                if (auto self = weak.get())
                    self->ProjectOpened(epoch, source, yml, error);
            });
        }).detach();
    }

    void MainWindow::ProjectOpenFolder(std::wstring const &folder)
    {
        auto &p = *project_ui;
        auto cancel = p.NewRequest();
        p.error.clear();
        p.busy = L"Opening the folder…";
        ProjectRender();
        uint64_t epoch = p.epoch;
        auto weak = get_weak();
        auto target = queue;
        std::thread([weak, target, cancel, epoch, folder] {
            std::string error, yml;
            auto source = source_ns::OpenFolder(folder, cancel, error);
            if (source != nullptr && !ReadYml(*source, yml, error, cancel))
                source = nullptr;
            target.TryEnqueue([weak, epoch, source, yml = std::move(yml), error = std::move(error)] {
                if (auto self = weak.get())
                    self->ProjectOpened(epoch, source, yml, error);
            });
        }).detach();
    }

    winrt::fire_and_forget MainWindow::ProjectPickFolder()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FolderPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(hwnd);
        picker.FileTypeFilter().Append(L"*");
        auto folder = co_await picker.PickSingleFolderAsync();
        if (folder != nullptr && project_ui != nullptr)
            ProjectOpenFolder(std::wstring(folder.Path()));
    }

    void MainWindow::ProjectOpened(uint64_t epoch, std::shared_ptr<source_ns::Source> const &source, std::string const &yml, std::string const &error)
    {
        if (project_ui == nullptr || project_ui->epoch != epoch)
            return;
        auto &p = *project_ui;
        p.busy.clear();
        p.cancel = nullptr;
        if (source == nullptr)
        {
            if (error.empty())
                ProjectRender();
            else
                ProjectFail(zs::ToWide(error));
            return;
        }
        // The counts, the status, and the plates stay if printdeck.yml is
        // the same.
        bool same = p.open && p.text == yml;
        if (!same)
        {
            p.counts.clear();
            p.status.clear();
            p.active.clear();
            p.has_active = false;
            p.set_loaded = false;
            p.set_map.clear();
        }
        p.open = true;
        p.source = source;
        p.text = yml;
        bool github = source->kind == source_ns::Source::Kind::Github;
        p.kind = github ? "github" : "folder";
        p.owner = github ? source->owner : "";
        p.repo = github ? source->repo : "";
        p.sha = github ? source->sha : "";
        p.path = github ? "" : zs::ToUtf8(source->folder);
        p.error.clear();
        ProjectReplan();
        std::wstring problem = p.PlanError();
        if (problem.empty())
            ProjectSave();
        else
            ShowToast(problem);
        ProjectRender();
        RefreshSigns();
    }

    // ---- plates ----

    // Opens plate i of the plan. All plates load into the plate set, and
    // plate i is the active plate. With the set loaded, it only becomes
    // active.
    void MainWindow::ProjectOpenPlate(size_t index)
    {
        if (project_ui == nullptr || model == nullptr)
            return;
        auto &p = *project_ui;
        json::Value const *plates = p.Plates();
        json::Value const *parts = p.Parts();
        if (plates == nullptr || parts == nullptr || index >= plates->items.size())
            return;
        if (p.IsInSet())
        {
            for (size_t k = 0; k < model->PlateCount(); k++)
                if (p.PlanIndex(model->Set(), k) == (int)index)
                {
                    SelectPlate(k);
                    ProjectPlatesChanged();
                    return;
                }
        }
        if (!p.busy.empty())
            return;
        if (p.source == nullptr)
        {
            if (p.kind == "folder")
            {
                ProjectFail(L"The folder " + zs::ToWide(p.path) + L" is not there. Open the folder of the project again.");
                return;
            }
            ProjectFail(L"GitHub did not answer. Try again.");
            ProjectStart();
            return;
        }

        // The files of all plates: the profile folders and the models. The
        // core finds the plates with no Cura stack (a resin plate), and
        // loads their parts for their footprints.
        std::vector<std::string> paths;
        std::set<std::string> seen;
        auto want = [&](std::string const &path) {
            if (seen.insert(path).second)
                paths.push_back(path);
        };
        for (auto const &plate : plates->items)
        {
            std::string folder = ProfileFolder(plate.Str("profile"));
            if (!folder.empty() && p.source->Has("profiles/" + folder + "/cura.json"))
                for (auto const &file : p.source->List("profiles/" + folder))
                    want(file);
            json::Value const *items = plate.Get("items");
            if (items == nullptr)
                continue;
            for (auto const &it : items->items)
            {
                size_t part = (size_t)it.Num("part");
                if (part >= parts->items.size())
                    continue;
                if (json::Value const *files = parts->items[part].Get("files"); files != nullptr && files->IsArray())
                    for (auto const &f : files->items)
                        if (f.type == json::Type::String)
                            want(f.text);
            }
        }
        size_t count = plates->items.size();
        std::wstring label = count == 1 ? std::wstring(L"Loading 1 plate") : L"Loading " + std::to_wstring(count) + L" plates";
        auto cancel = p.NewRequest();
        p.error.clear();
        p.busy = label + L"…";
        ProjectRender();
        uint64_t epoch = p.epoch;
        auto weak = get_weak();
        auto target = queue;
        auto source = p.source;
        std::thread([weak, target, cancel, epoch, index, source, paths = std::move(paths), label] {
            std::shared_ptr<zs_files> files(zs_files_new(), zs_files_free);
            std::string error;
            size_t total = 0;
            bool ok = files != nullptr;
            if (!ok)
                error = "No memory for the files of the project.";
            for (size_t i = 0; ok && i < paths.size(); i++)
            {
                std::string bytes;
                ok = source->Read(paths[i], bytes, error, cancel);
                if (!ok)
                    break;
                total += bytes.size();
                if (total > source_ns::max_total)
                {
                    error = "The files of the project are larger than 1 GB.";
                    ok = false;
                    break;
                }
                if (zs_files_add(files.get(), paths[i].c_str(), bytes.data(), bytes.size()) != ZS_OK)
                {
                    error = "No memory for the files of the project.";
                    ok = false;
                    break;
                }
                std::wstring progress = label + L": " + std::to_wstring(i + 1) + L" of " + std::to_wstring(paths.size()) + L" files…";
                target.TryEnqueue([weak, epoch, progress] {
                    auto self = weak.get();
                    if (self == nullptr || self->project_ui == nullptr || self->project_ui->epoch != epoch)
                        return;
                    self->project_ui->busy = progress;
                    self->ProjectRenderSoon();
                });
            }
            if (!ok)
                files = nullptr;
            target.TryEnqueue([weak, epoch, index, files, error = std::move(error)] {
                if (auto self = weak.get())
                    self->ProjectPlateFiles(epoch, index, files, error);
            });
        }).detach();
    }

    void MainWindow::ProjectPlateFiles(uint64_t epoch, size_t index, std::shared_ptr<zs_files> const &files, std::string const &error)
    {
        if (project_ui == nullptr || project_ui->epoch != epoch || model == nullptr)
            return;
        auto &p = *project_ui;
        p.busy.clear();
        p.cancel = nullptr;
        if (files == nullptr)
        {
            if (error.empty())
                ProjectRender();
            else
                ProjectFail(zs::ToWide(error));
            return;
        }
        json::Value const *plates = p.Plates();
        if (plates == nullptr || index >= plates->items.size())
        {
            ProjectRender();
            return;
        }
        // The settings of the printer of the user go to its files first.
        // The profiles of the plates then replace them on the view, and do
        // not change that printer.
        bool was = printers != nullptr && printers->setup.ProjectPlates();
        if (printers != nullptr)
        {
            printers->setup.SaveState();
            printers->setup.SetProjectPlates(true);
        }
        std::string message;
        int rc = model->LoadProject(files.get(), p.text, p.CountsText(), index, message);
        if (rc != ZS_OK)
        {
            if (printers != nullptr)
                printers->setup.SetProjectPlates(was);
            ProjectFail(zs::ToWide(message));
            return;
        }
        if (printers != nullptr)
            printers->setup.ForgetRoll();
        p.loaded = p.plan_key;
        p.is_loaded = true;
        p.set_loaded = true;
        p.plate_ids.clear();
        p.set_map.clear();
        std::wstring bad;
        for (size_t k = 0; k < model->PlateCount(); k++)
        {
            zs_plate_info info{};
            if (zs_set_plate_info(model->Set(), k, &info) != ZS_OK)
                continue;
            p.plate_ids[info.id] = (int)k;
            p.set_map.push_back((int)k);
            std::wstring text = info.message != nullptr ? zs::ToWide(info.message) : std::wstring();
            if (info.status == ZS_PLATE_STATUS_FAILED)
                bad += (bad.empty() ? L"" : L" ") + (L"Plate " + std::to_wstring(k + 1) + L": " + (text.empty() ? L"The plate did not load." : text));
            else if (!text.empty())
                bad += (bad.empty() ? L"" : L" ") + text;
        }
        json::Value const &plate = plates->items[index];
        p.active = p.PlateKey(plate);
        p.has_active = true;
        ProjectSave();

        // The ids of the refinements belong to the plates that went.
        refine_ids.clear();
        RequestFrame(ZS_SEL_FRAME_NONE);
        ShowPlate();
        FramePlate((size_t)-1);
        NoteChange();

        // The printer of the plate, if the user has one with its name. Its
        // machine settings do not load.
        std::string printer = plate.Str("printer");
        zs::PrinterStore &store = zs::Printers();
        for (size_t k = 0; k < store.Count(); k++)
            if (!printer.empty() && EqualNoCase(store.At(k).name, printer))
            {
                if (store.Current().id != store.At(k).id)
                    store.SetCurrent(store.At(k).id);
                if (printers != nullptr)
                    printers->RefreshBar();
                break;
            }
        if (!bad.empty())
        {
            // The dialog covers the toast, so the page says it too.
            zs::Log("shell: project: %s\n", zs::ToUtf8(bad).c_str());
            p.error = bad;
            ShowToast(bad);
        }
        ProjectRender();
        SessionSoon();
    }

    // The list of the plates, or the active plate, may have changed.
    void MainWindow::ProjectPlatesChanged()
    {
        RefreshProjectTotals();
        if (project_ui == nullptr || model == nullptr)
            return;
        auto &p = *project_ui;
        if (!p.open || !p.is_loaded)
            return;
        std::vector<int> map;
        int active_plan = -1;
        size_t n = model->PlateCount(), active = model->ActivePlate();
        for (size_t k = 0; k < n; k++)
        {
            int at = p.PlanIndex(model->Set(), k);
            if (at >= 0)
                map.push_back(at);
            if (k == active)
                active_plan = at;
        }
        bool changed = false;
        if (map != p.set_map)
        {
            p.set_map = std::move(map);
            changed = true;
        }
        if (p.IsInSet())
        {
            json::Value const *plates = p.Plates();
            bool has = plates != nullptr && active_plan >= 0 && (size_t)active_plan < plates->items.size();
            std::string key = has ? p.PlateKey(plates->items[(size_t)active_plan]) : std::string();
            if (has != p.has_active || key != p.active)
            {
                p.has_active = has;
                p.active = key;
                changed = true;
            }
        }
        if (changed)
        {
            ProjectSave();
            ProjectRenderSoon();
        }
    }

    std::wstring MainWindow::ProjectPrintStatus(size_t plate)
    {
        if (project_ui == nullptr || model == nullptr || !project_ui->open || !project_ui->IsInSet())
            return {};
        auto &p = *project_ui;
        json::Value const *plates = p.Plates();
        int at = p.PlanIndex(model->Set(), plate);
        if (plates == nullptr || at < 0 || (size_t)at >= plates->items.size())
            return {};
        std::string status = p.StatusOf(p.PlateKey(plates->items[(size_t)at]));
        if (status == "printing")
            return L"Printing";
        if (status == "printed")
            return L"Printed";
        if (status == "failed")
            return L"Print failed";
        return {};
    }

    // A file opens. A model file of the user ends project mode: only the
    // active plate stays, with the machine of the current printer. A file
    // from outside the app goes on a new plate, and the plates stay.
    void MainWindow::ProjectFileOpening(bool project_file, bool new_plate)
    {
        if (project_ui == nullptr || model == nullptr)
            return;
        bool mode = printers != nullptr && printers->setup.ProjectPlates();
        if (new_plate && !project_file)
        {
            // The new plate is for the printer of the user.
            if (mode)
            {
                printers->setup.UsePrinterMachine();
                printers->RefreshBar();
            }
            return;
        }
        auto &p = *project_ui;
        bool was = p.is_loaded || mode;
        p.is_loaded = false;
        p.loaded.clear();
        p.plate_ids.clear();
        p.set_map.clear();
        if (p.open && p.set_loaded)
        {
            p.set_loaded = false;
            ProjectSave();
        }
        ProjectRenderSoon();
        if (project_file)
        {
            if (printers != nullptr)
                printers->setup.SetProjectPlates(false);
            return;
        }
        if (!was)
            return;
        if (model->PlateCount() > 1 && model->KeepActivePlate())
            refine_ids.clear();
        if (printers != nullptr)
        {
            printers->setup.EndProject();
            printers->RefreshBar();
        }
    }

    // ---- the session ----

    std::string MainWindow::ProjectSessionText()
    {
        if (project_ui == nullptr)
            return {};
        auto &p = *project_ui;
        std::string out;
        if (printers != nullptr && printers->setup.ProjectPlates())
            out += ",\"projectPlates\":1";
        if (p.open && p.IsInSet())
        {
            char tag[32];
            snprintf(tag, sizeof tag, "%016llx", (unsigned long long)Fnv(p.kind + p.owner + p.repo + p.sha + p.path + "\n" + p.plan_key));
            out += std::string(",\"projectTag\":\"") + tag + "\",\"projectMap\":\"";
            for (size_t i = 0; i < p.set_map.size(); i++)
                out += (i > 0 ? "," : "") + std::to_string(p.set_map[i]);
            out += "\"";
        }
        return out;
    }

    void MainWindow::ProjectSessionRead(std::string const &text)
    {
        if (project_ui == nullptr || model == nullptr)
            return;
        if (printers != nullptr && text.find("\"projectPlates\":1") != std::string::npos)
            printers->setup.SetProjectPlates(true);
        auto &p = *project_ui;
        if (!p.open || !p.set_loaded)
            return;
        auto value = [&](char const *key) {
            size_t at = text.find(key);
            if (at == std::string::npos)
                return std::string();
            at += strlen(key);
            return text.substr(at, text.find('"', at) - at);
        };
        char tag[32];
        snprintf(tag, sizeof tag, "%016llx", (unsigned long long)Fnv(p.kind + p.owner + p.repo + p.sha + p.path + "\n" + p.plan_key));
        if (value("\"projectTag\":\"") != tag)
            return;
        std::vector<int> map;
        std::string list = value("\"projectMap\":\"");
        for (size_t start = 0; start < list.size();)
        {
            size_t comma = list.find(',', start);
            map.push_back(atoi(list.c_str() + start));
            if (comma == std::string::npos)
                break;
            start = comma + 1;
        }
        // A plate removed after the last write of the session: project.json
        // has it no more.
        for (size_t k = map.size(); k-- > 0;)
            if (k < model->PlateCount() && std::find(p.set_map.begin(), p.set_map.end(), map[k]) == p.set_map.end())
            {
                zs_set_remove(model->Set(), k);
                map.erase(map.begin() + (ptrdiff_t)k);
            }
        p.plate_ids.clear();
        for (size_t k = 0; k < map.size() && k < model->PlateCount(); k++)
        {
            zs_plate_info info{};
            if (zs_set_plate_info(model->Set(), k, &info) == ZS_OK)
                p.plate_ids[info.id] = map[k];
        }
        p.set_map = map;
        p.loaded = p.plan_key;
        p.is_loaded = true;
    }

    // ---- changes on the page ----

    void MainWindow::ProjectSetCount(size_t part, int value)
    {
        auto &p = *project_ui;
        json::Value const *parts = p.Parts();
        // A load reads the files of the plan that it started with.
        if (parts == nullptr || part >= parts->items.size() || !p.busy.empty())
            return;
        json::Value const &item = parts->items[part];
        json::Value const *on = item.Get("on");
        int base = on != nullptr && on->type == json::Type::Bool && !on->boolean ? 0 : (int)item.Num("count");
        if (p.counts.size() < parts->items.size())
            p.counts.resize(parts->items.size(), -1);
        int next = value == base ? -1 : value;
        if (p.counts[part] == next)
            return;
        p.counts[part] = next;
        // With no choices left, the plan is the plan of the plates in the set.
        while (!p.counts.empty() && p.counts.back() < 0)
            p.counts.pop_back();
        ProjectSave();
        ProjectReplan();
        ProjectRenderSoon();
        RefreshSigns();
    }

    void MainWindow::ProjectSetStatus(std::string const &key, std::string const &status)
    {
        auto &p = *project_ui;
        if (p.StatusOf(key) == status)
            return;
        p.status[key] = status;
        ProjectSave();
        ProjectRenderSoon();
        RefreshSigns();
    }

    void MainWindow::ProjectPlateSent()
    {
        if (project_ui == nullptr || printers == nullptr || !printers->setup.ProjectPlates())
            return;
        if (project_ui->has_active && !project_ui->active.empty())
            ProjectSetStatus(project_ui->active, "printing");
    }

    // ---- the page ----

    // A render after the handler of a control that the render replaces.
    void MainWindow::ProjectRenderSoon()
    {
        if (project_ui == nullptr || project_ui->render_queued)
            return;
        project_ui->render_queued = true;
        auto weak = get_weak();
        queue.TryEnqueue([weak] {
            auto self = weak.get();
            if (self == nullptr || self->project_ui == nullptr)
                return;
            self->project_ui->render_queued = false;
            self->ProjectRender();
        });
    }

    void MainWindow::ProjectRender()
    {
        if (project_ui == nullptr || project_ui->page == nullptr || !project_ui->Visible())
            return;
        auto &p = *project_ui;
        ProjectKeepFocus();
        auto root = Root();
        auto dim = TokenBrush(root, L"ZsDim");
        // --accent of style.css: lighter than the fill of a button in dark.
        auto accent = TokenBrush(root, L"ZsAccentText");
        auto error_brush = TokenBrush(root, L"ZsError");
        auto fg = TokenBrush(root, L"ZsFg").as<Media::SolidColorBrush>().Color();
        // --accent-rgb, the same in both themes.
        Windows::UI::Color accent_color{ 255, 53, 132, 228 };
        auto tint = [](Windows::UI::Color c, double alpha) {
            c.A = (uint8_t)std::lround(alpha * 255);
            return Media::SolidColorBrush(c);
        };
        auto line = [](std::wstring const &text, double size, bool bold, Media::Brush const &brush) {
            TextBlock t;
            t.Text(text);
            t.FontSize(size);
            t.TextWrapping(TextWrapping::WrapWholeWords);
            if (bold)
                t.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            if (brush != nullptr)
                t.Foreground(brush);
            return t;
        };
        auto flat = [](Button const &b) {
            Media::SolidColorBrush clear(Microsoft::UI::Colors::Transparent());
            b.Background(clear);
            // A disabled flat button has no fill either (button.flat).
            b.Resources().Insert(box_value(L"ButtonBackgroundDisabled"), clear);
        };
        auto compact = [](Button const &b) {
            b.MinHeight(32);
            b.MinWidth(0);
            b.Padding(ThicknessHelper::FromLengths(10, 5, 10, 5));
            b.HorizontalAlignment(HorizontalAlignment::Left);
        };

        p.page.Children().Clear();
        p.status_boxes.clear();
        p.count_boxes.clear();
        p.check_boxes.clear();
        p.github_box = nullptr;
        auto add = [&](UIElement const &element) { p.page.Children().Append(element); };
        auto show_notes = [&] {
            if (!p.busy.empty())
                add(line(p.busy, 13, false, accent));
            if (!p.error.empty())
                add(line(p.error, 14, false, error_brush));
        };

        // ---- no project: the form ----
        if (!p.open)
        {
            add(line(L"Open a project", 15, true, nullptr));
            add(line(L"A project is a repository with a printdeck.yml: the parts, their printers, Cura profiles, and settings. zslice puts the parts on plates, and keeps the status of each plate.", 14, false, dim));
            auto github_label = line(L"From GitHub (a public repository)", 12, true, dim);
            github_label.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
            add(github_label);
            Grid row;
            row.ColumnSpacing(6);
            ColumnDefinition entry_column, go_column;
            entry_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            go_column.Width(GridLengthHelper::Auto());
            row.ColumnDefinitions().Append(entry_column);
            row.ColumnDefinitions().Append(go_column);
            TextBox entry;
            entry.PlaceholderText(L"owner/repo or a github.com address");
            entry.IsSpellCheckEnabled(false);
            entry.Text(p.github_text);
            Automation::AutomationProperties::SetName(entry, L"owner/repo or a github.com address");
            entry.TextChanged([this](auto &&sender, auto &&) {
                project_ui->github_text = std::wstring(sender.template as<TextBox>().Text());
            });
            entry.KeyDown([this](auto &&sender, Input::KeyRoutedEventArgs const &e) {
                if (e.Key() != VirtualKey::Enter)
                    return;
                e.Handled(true);
                ProjectOpenGithub(std::wstring(sender.template as<TextBox>().Text()));
            });
            row.Children().Append(entry);
            Button go;
            go.Content(box_value(L"Open"));
            go.MinHeight(32);
            go.IsEnabled(p.busy.empty());
            go.Click([this, entry](auto &&, auto &&) { ProjectOpenGithub(std::wstring(entry.Text())); });
            Grid::SetColumn(go, 1);
            row.Children().Append(go);
            add(row);
            p.github_box = entry;
            auto folder_label = line(L"From this computer", 12, true, dim);
            folder_label.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
            add(folder_label);
            Button folder;
            folder.Content(box_value(L"Open a folder…"));
            compact(folder);
            folder.IsEnabled(p.busy.empty());
            folder.Click([this](auto &&, auto &&) { ProjectPickFolder(); });
            add(folder);
            show_notes();
            return;
        }

        // ---- the head: the name, the source, and Close ----
        Grid head;
        head.ColumnSpacing(8);
        ColumnDefinition name_column, close_column;
        name_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        close_column.Width(GridLengthHelper::Auto());
        head.ColumnDefinitions().Append(name_column);
        head.ColumnDefinitions().Append(close_column);
        StackPanel names;
        names.Children().Append(line(p.Name(), 15, true, nullptr));
        std::wstring from = p.kind == "github" ? L"GitHub " + zs::ToWide(p.owner) + L"/" + zs::ToWide(p.repo) + L" @ " + zs::ToWide(p.sha.substr(0, 7))
                                               : L"Folder " + zs::ToWide(p.path);
        names.Children().Append(line(from, 14, false, dim));
        head.Children().Append(names);
        Button close;
        close.Content(box_value(L"Close"));
        compact(close);
        flat(close);
        close.VerticalAlignment(VerticalAlignment::Top);
        ToolTipService::SetToolTip(close, box_value(L"Close the project. Its plates stay, and the print status of its plates goes."));
        Automation::AutomationProperties::SetName(close, L"Close the project");
        close.Click([this](auto &&, auto &&) { CloseProject(); });
        Grid::SetColumn(close, 1);
        head.Children().Append(close);
        add(head);
        show_notes();

        if (p.kind == "folder" && p.source == nullptr)
        {
            add(line(L"The folder " + zs::ToWide(p.path) + L" is not there.", 14, false, dim));
            Button again;
            again.Content(box_value(L"Open the folder again…"));
            compact(again);
            again.Click([this](auto &&, auto &&) { ProjectPickFolder(); });
            add(again);
        }
        std::wstring problem = p.PlanError();
        if (!problem.empty())
        {
            add(line(problem, 14, false, error_brush));
            return;
        }
        json::Value const *plates = p.Plates();
        json::Value const *parts = p.Parts();
        if (plates == nullptr || parts == nullptr)
            return;

        auto heading = [&](wchar_t const *text) {
            auto h = line(text, 12, true, dim);
            h.CharacterSpacing(40);
            h.Margin(ThicknessHelper::FromLengths(0, 8, 0, 0));
            add(h);
        };

        // ---- the plates ----
        heading(L"PLATES");
        StackPanel plate_list;
        plate_list.Spacing(6);
        if (plates->items.empty())
            plate_list.Children().Append(line(L"No parts are chosen.", 14, false, dim));
        bool in_set = p.IsInSet();
        size_t done = 0;
        for (size_t i = 0; i < plates->items.size(); i++)
        {
            json::Value const &plate = plates->items[i];
            std::string key = p.PlateKey(plate);
            std::string status = p.StatusOf(key);
            if (status == "printed")
                done++;
            bool active = p.has_active && p.active == key;
            Border card;
            card.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
            card.Padding(ThicknessHelper::FromLengths(active ? 7 : 10, 8, 10, 8));
            card.Background(active ? tint(accent_color, 0.15) : tint(fg, 0.05));
            if (active)
            {
                card.BorderBrush(accent);
                card.BorderThickness(ThicknessHelper::FromLengths(3, 0, 0, 0));
            }
            if (status == "printed")
                card.Opacity(0.6);
            StackPanel body;
            body.Spacing(6);

            // The head: the title, the facts, and the status.
            Grid plate_head;
            plate_head.ColumnSpacing(8);
            for (int c = 0; c < 3; c++)
            {
                ColumnDefinition column;
                column.Width(c == 1 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                plate_head.ColumnDefinitions().Append(column);
            }
            auto plate_title = line(L"Plate " + std::to_wstring(i + 1), 14, true, nullptr);
            plate_title.VerticalAlignment(VerticalAlignment::Center);
            plate_head.Children().Append(plate_title);
            auto facts = line(Facts(plate), 12, false, dim);
            facts.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(facts, 1);
            plate_head.Children().Append(facts);
            ComboBox box;
            box.FontSize(12);
            box.MinWidth(104);
            box.Background(TokenBrush(root, L"ZsButton"));
            box.BorderThickness(ThicknessHelper::FromUniformLength(0));
            box.VerticalAlignment(VerticalAlignment::Center);
            Automation::AutomationProperties::SetName(box, L"The status of plate " + std::to_wstring(i + 1));
            int selected = 0;
            for (size_t s = 0; s < std::size(statuses); s++)
            {
                box.Items().Append(box_value(statuses[s].label));
                if (status == statuses[s].key)
                    selected = (int)s;
            }
            box.SelectedIndex(selected);
            if (status == "printing")
                box.Foreground(accent);
            else if (status == "failed")
                box.Foreground(error_brush);
            box.SelectionChanged([this, key](auto &&sender, auto &&) {
                int at = sender.template as<ComboBox>().SelectedIndex();
                if (at >= 0 && at < (int)std::size(statuses))
                    ProjectSetStatus(key, statuses[at].key);
            });
            Grid::SetColumn(box, 2);
            plate_head.Children().Append(box);
            p.status_boxes.push_back(box);
            body.Children().Append(plate_head);

            // The parts, with their counts.
            StackPanel items;
            if (json::Value const *list = plate.Get("items"); list != nullptr)
                for (auto const &it : list->items)
                {
                    size_t part = (size_t)it.Num("part");
                    int count = (int)it.Num("count");
                    std::wstring name = part < parts->items.size() ? zs::ToWide(parts->items[part].Str("name")) : L"";
                    items.Children().Append(line(count > 1 ? name + L" × " + std::to_wstring(count) : name, 13, false, nullptr));
                }
            body.Children().Append(items);

            // A plate with no Cura stack (cura.json) in its profile folder:
            // a resin plate, which zslice does not slice yet.
            std::string folder = ProfileFolder(plate.Str("profile"));
            bool resin = folder.empty() || (p.source != nullptr && !p.source->Has("profiles/" + folder + "/cura.json"));
            Button open;
            open.Content(box_value(in_set ? (active ? L"Active" : L"Show") : (active ? L"Open again" : L"Open")));
            compact(open);
            if (!active)
                flat(open);
            open.IsEnabled(p.busy.empty() && !resin);
            std::wstring tip = resin ? L"This plate has no Cura profile stack (a resin plate?). zslice slices FDM plates only, for now."
                               : in_set ? L"Make this plate the active plate, and move the view to it."
                                        : L"Load all plates of the project on the view, each with its profiles and settings, and slice them. This plate is the active plate.";
            ToolTipService::SetToolTip(open, box_value(tip));
            Automation::AutomationProperties::SetName(open, (in_set ? (active ? L"Active plate " : L"Show plate ") : L"Open plate ") + std::to_wstring(i + 1));
            open.Click([this, i](auto &&, auto &&) { ProjectOpenPlate(i); });
            body.Children().Append(open);
            card.Child(body);
            plate_list.Children().Append(card);
        }
        if (!plates->items.empty())
            plate_list.Children().Append(line(std::to_wstring(done) + L" of " + std::to_wstring(plates->items.size()) + L" plates printed", 12, false, dim));
        add(plate_list);

        // ---- the parts ----
        heading(L"PARTS");
        StackPanel part_list;
        part_list.Spacing(6);
        std::string group;
        for (size_t i = 0; i < parts->items.size(); i++)
        {
            json::Value const &part = parts->items[i];
            std::string this_group = part.Str("group");
            if (!this_group.empty() && this_group != group)
            {
                group = this_group;
                auto title = line(zs::ToWide(group), 11.5, true, dim);
                title.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
                part_list.Children().Append(title);
            }
            // A later variant is off until the user chooses it.
            json::Value const *on_value = part.Get("on");
            int file_count = (int)part.Num("count");
            int base = on_value != nullptr && on_value->type == json::Type::Bool && !on_value->boolean ? 0 : file_count;
            int count = i < p.counts.size() && p.counts[i] >= 0 ? p.counts[i] : base;

            Grid row;
            row.ColumnSpacing(8);
            for (int c = 0; c < 3; c++)
            {
                ColumnDefinition column;
                column.Width(c == 1 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                row.ColumnDefinitions().Append(column);
            }
            CheckBox check;
            check.MinWidth(0);
            check.Width(28);
            check.Padding(ThicknessHelper::FromUniformLength(0));
            check.VerticalAlignment(VerticalAlignment::Center);
            check.IsChecked(count > 0);
            check.IsEnabled(p.busy.empty());
            std::wstring part_name = zs::ToWide(part.Str("name"));
            Automation::AutomationProperties::SetName(check, part_name);
            check.Click([this, i, file_count](auto &&sender, auto &&) {
                auto value = sender.template as<CheckBox>().IsChecked();
                ProjectSetCount(i, value != nullptr && value.Value() ? std::max(1, file_count) : 0);
            });
            row.Children().Append(check);
            p.check_boxes.push_back(check);

            StackPanel info;
            info.VerticalAlignment(VerticalAlignment::Center);
            auto part_title = line(part_name, 14, false, nullptr);
            part_title.TextWrapping(TextWrapping::Wrap);
            info.Children().Append(part_title);
            info.Children().Append(line(Facts(part), 11.5, false, dim));
            // The tooltip: the description and the settings of the part.
            std::wstring tip = zs::ToWide(part.Str("description"));
            if (json::Value const *settings = part.Get("settings"); settings != nullptr && settings->IsArray() && !settings->items.empty())
            {
                if (!tip.empty())
                    tip += L"\n\n";
                tip += L"Settings: ";
                for (size_t s = 0; s < settings->items.size(); s++)
                    tip += (s > 0 ? L", " : L"") + zs::ToWide(settings->items[s].Str("key")) + L" = " + ValueText(settings->items[s].Get("value"));
            }
            if (!tip.empty())
                ToolTipService::SetToolTip(info, box_value(tip));
            Grid::SetColumn(info, 1);
            row.Children().Append(info);

            NumberBox number;
            number.Minimum(0);
            number.Maximum(99);
            number.Value(count);
            number.IsEnabled(p.busy.empty());
            number.Width(84);
            number.SpinButtonPlacementMode(NumberBoxSpinButtonPlacementMode::Compact);
            number.VerticalAlignment(VerticalAlignment::Center);
            Automation::AutomationProperties::SetName(number, L"The copies of " + part_name);
            ToolTipService::SetToolTip(number, box_value(L"The copies of each file on the plate"));
            number.ValueChanged([this, i](NumberBox const &, NumberBoxValueChangedEventArgs const &e) {
                double v = e.NewValue();
                ProjectSetCount(i, std::isnan(v) ? 0 : std::clamp((int)v, 0, 99));
            });
            Grid::SetColumn(number, 2);
            row.Children().Append(number);
            p.count_boxes.push_back(number);
            part_list.Children().Append(row);
        }
        add(part_list);
    }

#ifdef ZS_DEV_HOOKS
    // The steps of the project (see MainWindow.DevHooks.cpp).
    bool MainWindow::RunProjectStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb.rfind(L"pj", 0) != 0 || project_ui == nullptr)
            return false;
        auto &p = *project_ui;
        auto number = [&](size_t i) { return i < words.size() ? _wtoi(words[i].c_str()) : 0; };
        if (verb == L"pjshow")
            ShowProjectDialog();
        else if (verb == L"pjhide")
            HideProjectDialog();
        else if (verb == L"pjfolder" && !words.empty())
            ProjectOpenFolder(words[0]);
        else if (verb == L"pjgithub" && !words.empty())
            ProjectOpenGithub(words[0]);
        else if (verb == L"pjplate")
            ProjectOpenPlate((size_t)(number(0) - 1));
        else if (verb == L"pjstatus" && words.size() >= 2)
        {
            json::Value const *plates = p.Plates();
            size_t i = (size_t)(number(0) - 1);
            if (plates != nullptr && i < plates->items.size())
                ProjectSetStatus(p.PlateKey(plates->items[i]), zs::ToUtf8(words[1]));
        }
        else if (verb == L"pjcount" && words.size() >= 2)
            ProjectSetCount((size_t)(number(0) - 1), number(1));
        else if (verb == L"pjcheck" && words.size() >= 2)
        {
            json::Value const *parts = p.Parts();
            size_t i = (size_t)(number(0) - 1);
            if (parts != nullptr && i < parts->items.size())
                ProjectSetCount(i, words[1] == L"on" ? std::max(1, (int)parts->items[i].Num("count")) : 0);
        }
        else if (verb == L"pjclose")
            CloseProject();
        else if (verb == L"pjscroll")
            p.scroll.ChangeView(nullptr, (double)number(0), nullptr, true);
        else if (verb == L"pjfile" && !words.empty())
            LoadPath(words[0]);
        else if (verb == L"pjmenu")
        {
            RefreshProjectMenu();
            zs::Log("dev: project menu '%s' close '%s' shown %d\n", to_string(p.menu_open.Text()).c_str(), to_string(p.menu_close.Text()).c_str(),
                    p.menu_close.Visibility() == Visibility::Visible ? 1 : 0);
        }
        else if (verb == L"pjactions")
        {
            for (auto const &action : SearchActions())
                if (action.label.find(L"project") != std::wstring::npos)
                    zs::Log("dev: action '%s' hint '%s'\n", zs::ToUtf8(action.label).c_str(), zs::ToUtf8(action.hint).c_str());
        }
        else if (verb == L"pjsum")
        {
            RefreshProjectTotals();
            zs::Log("dev: project line shown %d '%s'\n", SummaryProject().Visibility() == Visibility::Visible ? 1 : 0, to_string(SummaryProject().Text()).c_str());
        }
        else if (verb != L"pjlog")
            return false;
        json::Value const *plates = p.Plates();
        json::Value const *parts = p.Parts();
        std::string map;
        for (int m : p.set_map)
            map += std::to_string(m) + ",";
        std::string signs;
        if (model != nullptr)
            for (size_t k = 0; k < model->PlateCount(); k++)
                signs += "[" + zs::ToUtf8(ProjectPrintStatus(k)) + "]";
        auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot()).try_as<FrameworkElement>();
        zs::Log("dev: project focus in dialog %d\n", focused != nullptr && p.overlay != nullptr && [&] {
            for (DependencyObject at = focused; at != nullptr; at = Media::VisualTreeHelper::GetParent(at))
                if (at == p.overlay)
                    return true;
            return false;
        }() ? 1 : 0);
        zs::Log("dev: project open %d name '%s' kind '%s' source %d plan plates %zu parts %zu counts '%s' in_set %d map '%s' active '%s' busy '%s' error '%s' dialog %d\n",
                p.open ? 1 : 0, zs::ToUtf8(p.Name()).c_str(), p.kind.c_str(), p.source != nullptr ? 1 : 0, plates != nullptr ? plates->items.size() : 0,
                parts != nullptr ? parts->items.size() : 0, p.CountsText().c_str(), p.IsInSet() ? 1 : 0, map.c_str(), p.active.c_str(),
                zs::ToUtf8(p.busy).c_str(), zs::ToUtf8(p.error).c_str(), p.Visible() ? 1 : 0);
        if (model != nullptr)
            for (size_t k = 0; k < model->PlateCount(); k++)
            {
                zs_plate_info info{};
                if (zs_set_plate_info(model->Set(), k, &info) == ZS_OK)
                    zs::Log("dev: project plate %zu status %d parts %zu name '%s' message '%s'\n", k, info.status, info.part_count, info.name, info.message);
            }
        if (model != nullptr)
            zs::Log("dev: project set plates %zu active %zu status %s machine '%s' bed %s project-mode %d printer '%s'\n", model->PlateCount(), model->ActivePlate(), signs.c_str(),
                    model->GetSetting("machine.name").c_str(), model->GetSetting("machine.bed_size_x").c_str(),
                    printers != nullptr && printers->setup.ProjectPlates() ? 1 : 0, zs::Printers().Current().name.c_str());
        return true;
    }
#endif
}
