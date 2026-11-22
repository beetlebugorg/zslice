// The layer profiles of the settings pane, and their marks on the layer
// rail, as in linux/src/ui/settings-browser.c and linux/src/ui/layer-range.c.
//
// A layer profile is a name for a z range (zs_app_profile_set). The
// overrides with the same range are its changes. The pane lists the named
// profiles and the other ranges with changes. A click opens one: a bar shows
// its name and its layers, and each editor of the pane then reads and sets
// the values of that range. A setting that cannot change for some layers
// still changes the whole print. Done ends the edit.
//
// The rail has an orange mark beside each range with changes. A click on a
// mark goes to its top layer and opens its range.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Media = Microsoft::UI::Xaml::Media;
using Windows::System::VirtualKey;

namespace
{
    bool SameRange(double a0, double a1, double b0, double b1)
    {
        return std::abs(a0 - b0) < 1e-6 && std::abs(a1 - b1) < 1e-6;
    }

    bool FindSetting(char const *name, zs_setting_info &out)
    {
        size_t n = zs_setting_count();
        for (size_t i = 0; i < n; i++)
            if (zs_setting_get_info(i, &out) == ZS_OK && strcmp(out.name, name) == 0)
                return true;
        return false;
    }

    std::wstring LabelOf(char const *name, size_t len)
    {
        std::string key(name, len);
        zs_setting_info info{};
        return zs::ToWide(FindSetting(key.c_str(), info) ? std::string(info.label) : key);
    }

    // The ranges with a name or with changes, lowest first. The whole part
    // is not a layer range.
    std::vector<std::pair<double, double>> RangesOf(zs_app *app)
    {
        std::vector<std::pair<double, double>> list;
        auto add = [&](double z_min, double z_max) {
            if (z_min < -1e5 && z_max > 1e5)
                return;
            for (auto const &r : list)
                if (SameRange(r.first, r.second, z_min, z_max))
                    return;
            list.emplace_back(z_min, z_max);
        };
        for (size_t i = 0, n = zs_app_profile_count(app); i < n; i++)
        {
            zs_layer_profile p{};
            if (zs_app_profile_get(app, i, &p) == ZS_OK)
                add(p.z_min, p.z_max);
        }
        for (size_t i = 0, n = zs_app_override_count(app); i < n; i++)
        {
            zs_override o{};
            if (zs_app_override_get(app, i, &o) == ZS_OK)
                add(o.z_min, o.z_max);
        }
        std::sort(list.begin(), list.end());
        return list;
    }

    std::wstring Capital(std::wstring text)
    {
        if (!text.empty())
            text[0] = (wchar_t)towupper(text[0]);
        return text;
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    void MainWindow::WireProfiles()
    {
        profile_target = std::make_shared<EditorTarget>();
        profile_target->get = [this](std::string const &name) { return ProfileValue(name); };
        profile_target->set = [this](std::string const &name, std::string const &value) { ProfileSet(name, value); };
        ProfileDone().Click([this](auto &&, auto &&) { LeaveProfile(); });
        ProfileDelete().Click([this](auto &&, auto &&) {
            if (!in_profile || model == nullptr)
                return;
            double lo = profile_min, hi = profile_max;
            LeaveProfile();
            if (zs_app_profile_remove(model->Active(), lo, hi) > 0)
                model->RequestSlice();
            NoteChange();
            RefreshSettingValues();
        });
        ProfileRenameFlyout().Opening([this](auto &&, auto &&) {
            ProfileRenameBox().Text(RangeName(profile_min, profile_max));
            ProfileRenameBox().SelectAll();
        });
        ProfileRenameBox().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() != VirtualKey::Enter)
                return;
            e.Handled(true);
            std::string text = zs::ToUtf8(std::wstring(ProfileRenameBox().Text()));
            if (in_profile && model != nullptr && !text.empty() && zs_app_profile_set(model->Active(), profile_min, profile_max, text.c_str()) == ZS_OK)
            {
                NoteChange();
                RefreshSettingValues();
            }
            ProfileRenameFlyout().Hide();
        });
        LayerCard().SizeChanged([this](auto &&, auto &&) { PlaceLayerMarks(); });
    }

    // ---- the ranges ----

    bool MainWindow::ProfileHas(std::string const &name)
    {
        if (!in_profile || model == nullptr)
            return false;
        zs_app *app = model->Active();
        for (size_t i = 0, n = zs_app_override_count(app); i < n; i++)
        {
            zs_override o{};
            if (zs_app_override_get(app, i, &o) == ZS_OK && SameRange(o.z_min, o.z_max, profile_min, profile_max) && name.size() == o.name_len &&
                strncmp(name.c_str(), o.name, o.name_len) == 0)
                return true;
        }
        return false;
    }

    size_t MainWindow::RangeChanges(double z_min, double z_max)
    {
        zs_app *app = model->Active();
        size_t count = 0;
        for (size_t i = 0, n = zs_app_override_count(app); i < n; i++)
        {
            zs_override o{};
            if (zs_app_override_get(app, i, &o) == ZS_OK && SameRange(o.z_min, o.z_max, z_min, z_max))
                count++;
        }
        return count;
    }

    // The layers of a range, as the user counts them (from 1).
    std::wstring MainWindow::RangeLayers(double z_min, double z_max)
    {
        zs_toolpaths tp{};
        wchar_t text[64];
        if (zs_app_toolpaths(model->Active(), &tp) != ZS_OK || tp.layer_count == 0)
        {
            if (z_min < -1e5)
                swprintf_s(text, L"up to z %.2f mm", z_max);
            else if (z_max > 1e5)
                swprintf_s(text, L"from z %.2f mm up", z_min);
            else
                swprintf_s(text, L"z %.2f to %.2f mm", z_min, z_max);
            return text;
        }
        size_t first = tp.layer_count, last = 0;
        for (size_t i = 0; i < tp.layer_count; i++)
        {
            double z = tp.layer_z[i];
            if (z >= z_min - 1e-4 && z <= z_max + 1e-4)
            {
                if (first == tp.layer_count)
                    first = i;
                last = i;
            }
        }
        if (first == tp.layer_count)
            return L"no layers of this part";
        if (first == last)
            return L"layer " + std::to_wstring(first + 1);
        return L"layers " + std::to_wstring(first + 1) + L" to " + std::to_wstring(last + 1);
    }

    // The name of a range: its profile name, or its layers.
    std::wstring MainWindow::RangeName(double z_min, double z_max)
    {
        zs_app *app = model->Active();
        for (size_t i = 0, n = zs_app_profile_count(app); i < n; i++)
        {
            zs_layer_profile p{};
            if (zs_app_profile_get(app, i, &p) == ZS_OK && SameRange(p.z_min, p.z_max, z_min, z_max))
                return zs::ToWide(std::string(p.name, p.name_len));
        }
        return Capital(RangeLayers(z_min, z_max));
    }

    // ---- the values of the open range ----

    std::string MainWindow::ProfileValue(std::string const &name)
    {
        if (model == nullptr)
            return {};
        zs_setting_info info{};
        if (!in_profile || !FindSetting(name.c_str(), info) || info.per_layer == 0)
            return model->GetSetting(name.c_str());
        zs_app *app = model->Active();
        double z = profile_min < -1e5 ? profile_max : profile_min;
        size_t len = 0;
        if (zs_app_setting_get_at(app, z, name.c_str(), nullptr, 0, &len) != ZS_OK)
            return {};
        std::string text(len + 1, '\0');
        if (zs_app_setting_get_at(app, z, name.c_str(), text.data(), text.size(), &len) != ZS_OK)
            return {};
        text.resize(len);
        return text;
    }

    void MainWindow::ProfileSet(std::string const &name, std::string const &value)
    {
        if (model == nullptr)
            return;
        zs_setting_info info{};
        if (!in_profile || !FindSetting(name.c_str(), info) || info.per_layer == 0)
        {
            CommitSetting(name, value);
            return;
        }
        int rc = zs_app_override_set(model->Active(), profile_min, profile_max, name.c_str(), value.c_str());
        if (rc != ZS_OK)
        {
            ShowToast(zs::ToWide(info.label) + L": " + zs::ToWide(zs_status_message(rc)));
            RefreshSettingValues();
            return;
        }
        model->RequestSlice();
        NoteChange();
        RefreshSettingValues();
    }

    void MainWindow::ProfileClear(std::string const &name)
    {
        if (!in_profile || model == nullptr || zs_app_override_remove(model->Active(), profile_min, profile_max, name.c_str()) != 1)
            return;
        model->RequestSlice();
        NoteChange();
        RefreshSettingValues();
    }

    // ---- the pane ----

    // The rows of the profiles, at the top of the list of sections.
    void MainWindow::AppendProfileRows()
    {
        TextBlock heading;
        heading.Text(L"Layer profiles");
        heading.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        heading.Foreground(TokenBrush(Root(), L"ZsDim"));
        heading.Margin(ThicknessHelper::FromLengths(4, 4, 0, 2));
        SettingsList().Children().Append(heading);
        auto list = model != nullptr ? RangesOf(model->Active()) : std::vector<std::pair<double, double>>{};
        if (list.empty())
        {
            TextBlock hint;
            hint.Text(L"None yet. Right-click a line in the 3D view, then “New profile from here up”, to change any settings for some layers.");
            hint.TextWrapping(TextWrapping::WrapWholeWords);
            hint.FontSize(12);
            hint.Foreground(TokenBrush(Root(), L"ZsDim"));
            hint.Margin(ThicknessHelper::FromLengths(12, 0, 0, 4));
            SettingsList().Children().Append(hint);
            return;
        }
        for (auto const &r : list)
        {
            double z_min = r.first, z_max = r.second;
            size_t count = RangeChanges(z_min, z_max);
            StackPanel texts;
            TextBlock name;
            name.Text(RangeName(z_min, z_max));
            name.TextWrapping(TextWrapping::WrapWholeWords);
            if (in_profile && SameRange(z_min, z_max, profile_min, profile_max))
                name.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
            TextBlock sub;
            sub.Text(RangeLayers(z_min, z_max) + L" · " + std::to_wstring(count) + (count == 1 ? L" change" : L" changes"));
            sub.TextWrapping(TextWrapping::WrapWholeWords);
            sub.FontSize(11.5);
            sub.Foreground(TokenBrush(Root(), L"ZsDim"));
            texts.Children().Append(name);
            texts.Children().Append(sub);
            Button row;
            row.HorizontalAlignment(HorizontalAlignment::Stretch);
            row.HorizontalContentAlignment(HorizontalAlignment::Left);
            row.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            row.BorderThickness(ThicknessHelper::FromUniformLength(0));
            row.Content(texts);
            row.Click([this, z_min, z_max](auto &&, auto &&) { OpenProfile(z_min, z_max); });
            SettingsList().Children().Append(row);
        }
    }

    void MainWindow::EnterProfile(double z_min, double z_max)
    {
        in_profile = true;
        profile_min = z_min;
        profile_max = z_max;
        profile_app = model->Active();
        ProfileBar().Visibility(Visibility::Visible);
        UpdateProfileBar();
    }

    void MainWindow::LeaveProfile()
    {
        if (!in_profile)
            return;
        in_profile = false;
        profile_app = nullptr;
        ProfileBar().Visibility(Visibility::Collapsed);
        ShowSections();
    }

    // A click on a profile or on its mark: edit it, and list its changes.
    void MainWindow::OpenProfile(double z_min, double z_max)
    {
        if (model == nullptr)
            return;
        ShowSettingsPane(true);
        EnterProfile(z_min, z_max);
        ShowProfileChanges();
    }

    void MainWindow::ShowProfileChanges()
    {
        if (!in_profile || RangeChanges(profile_min, profile_max) == 0)
        {
            // No change yet: the sections, to pick a setting for it.
            ShowSections();
            return;
        }
        ClearSettingsList();
        settings_page = SettingsPage::Section;
        settings_group = "profiles";
        settings_section = "";
        SettingsBack().Visibility(Visibility::Visible);
        SettingsCrumb().Text(RangeName(profile_min, profile_max));
        zs_app *app = model->Active();
        for (size_t i = 0, n = zs_app_override_count(app); i < n; i++)
        {
            zs_override o{};
            if (zs_app_override_get(app, i, &o) != ZS_OK || !SameRange(o.z_min, o.z_max, profile_min, profile_max))
                continue;
            zs_setting_info info{};
            if (FindSetting(std::string(o.name, o.name_len).c_str(), info))
                SettingsList().Children().Append(MakeSettingRow(info));
        }
    }

    void MainWindow::UpdateProfileBar()
    {
        if (!in_profile || model == nullptr)
            return;
        size_t n = RangeChanges(profile_min, profile_max);
        std::wstring count = n == 0 ? L"no changes yet" : std::to_wstring(n) + (n == 1 ? L" change" : L" changes");
        ProfileTitle().Text(RangeName(profile_min, profile_max));
        ProfileNote().Text(Capital(RangeLayers(profile_min, profile_max)) + L" · " + count + L". A change here applies only to these layers.");
    }

    // After an edit, an undo, or a new scene.
    void MainWindow::ProfilesRefresh()
    {
        if (model == nullptr)
            return;
        // A profile belongs to its plate.
        if (in_profile && model->Active() != profile_app)
            LeaveProfile();
        UpdateLayerMarks();
        UpdateProfileBar();
        zs_app *app = model->Active();
        std::string key;
        for (auto const &r : RangesOf(app))
            key += std::to_string(r.first) + ":" + std::to_string(r.second) + ":" + std::to_string(RangeChanges(r.first, r.second)) + ":" +
                   zs::ToUtf8(RangeName(r.first, r.second)) + ";";
        if (key == profile_key)
            return;
        profile_key = key;
        bool sections = settings_page == SettingsPage::Sections;
        bool changes = settings_page == SettingsPage::Section && settings_group != nullptr && strcmp(settings_group, "profiles") == 0;
        if (!sections && !changes)
            return;
        // After the event of the editor that may go away with its row.
        auto weak = get_weak();
        queue.TryEnqueue([weak, changes] {
            auto self = weak.get();
            if (self == nullptr)
                return;
            if (changes)
                self->ShowProfileChanges();
            else if (self->settings_page == SettingsPage::Sections)
                self->ShowSections();
        });
    }

    // ---- the marks of the rail ----

    // One mark for each layer range with changes of its own.
    void MainWindow::UpdateLayerMarks()
    {
        zs_app *app = model->Active();
        zs_toolpaths tp{};
        // A running slice has no toolpaths: the marks stay.
        if (zs_app_toolpaths(app, &tp) != ZS_OK || tp.layer_count == 0)
            return;
        struct Range
        {
            double z_min, z_max;
            std::wstring names, profile;
            bool named = false;
        };
        std::vector<Range> ranges;
        auto range_of = [&](double z_min, double z_max) -> Range * {
            if (z_min < -1e4 && z_max > 1e4)
                return nullptr;
            for (auto &r : ranges)
                if (SameRange(r.z_min, r.z_max, z_min, z_max))
                    return &r;
            ranges.push_back({ z_min, z_max });
            return &ranges.back();
        };
        for (size_t i = 0, n = zs_app_override_count(app); i < n; i++)
        {
            zs_override o{};
            if (zs_app_override_get(app, i, &o) != ZS_OK)
                continue;
            if (Range *r = range_of(o.z_min, o.z_max))
                r->names += (r->names.empty() ? L"" : L", ") + LabelOf(o.name, o.name_len);
        }
        for (size_t i = 0, n = zs_app_profile_count(app); i < n; i++)
        {
            zs_layer_profile p{};
            if (zs_app_profile_get(app, i, &p) != ZS_OK)
                continue;
            if (Range *r = range_of(p.z_min, p.z_max))
            {
                r->profile = zs::ToWide(std::string(p.name, p.name_len));
                r->named = true;
            }
        }
        std::vector<LayerMark> marks;
        std::string key;
        for (auto const &r : ranges)
        {
            bool any = false;
            size_t lo = 0, hi = 0;
            for (size_t j = 0; j < tp.layer_count; j++)
            {
                double z = tp.layer_z[j];
                if (z >= r.z_min - 1e-4 && z <= r.z_max + 1e-4)
                {
                    if (!any)
                        lo = j;
                    hi = j;
                    any = true;
                }
            }
            if (!any)
                continue;
            LayerMark mark;
            mark.lo = lo;
            mark.hi = hi;
            mark.z_min = r.z_min;
            mark.z_max = r.z_max;
            mark.label = (r.named ? r.profile : std::wstring(L"Changes for these layers")) + (r.names.empty() ? L"" : L": ") + r.names;
            key += std::to_string(lo) + "-" + std::to_string(hi) + ":" + std::to_string(r.z_min) + ":" + std::to_string(r.z_max) + ":" + zs::ToUtf8(mark.label) + ";";
            marks.push_back(std::move(mark));
        }
        if (key == layer_marks_key)
            return;
        layer_marks_key = key;
        LayerMarks().Children().Clear();
        for (auto &mark : marks)
        {
            Border bar;
            bar.Width(4);
            bar.CornerRadius(CornerRadiusHelper::FromUniformRadius(2));
            bar.Background(Media::SolidColorBrush(Windows::UI::Color{ 255, 255, 140, 26 }));
            bar.Margin(ThicknessHelper::FromLengths(0, 6, 0, 6));
            bar.HorizontalAlignment(HorizontalAlignment::Center);
            // A wider place to click than the mark.
            Border hit;
            hit.Width(10);
            hit.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            hit.Child(bar);
            Canvas::SetLeft(hit, 17);
            std::wstring tip = mark.label + L"\nClick to go to layer " + std::to_wstring(mark.hi + 1) + L".";
            ToolTipService::SetToolTip(hit, box_value(tip));
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(hit, tip);
            double z_min = mark.z_min, z_max = mark.z_max;
            size_t hi = mark.hi;
            hit.PointerPressed([this, z_min, z_max, hi](auto &&, Input::PointerRoutedEventArgs const &e) {
                e.Handled(true);
                if (hi < layer_count)
                    LayerSlider().Value((double)hi + 1);
                OpenProfile(z_min, z_max);
            });
            mark.hit = hit;
            LayerMarks().Children().Append(hit);
        }
        layer_marks = std::move(marks);
        PlaceLayerMarks();
    }

    void MainWindow::PlaceLayerMarks()
    {
        if (layer_count == 0)
            return;
        double height = LayerCard().ActualHeight();
        double max = (double)std::max<size_t>(1, layer_count - 1);
        auto y = [&](size_t v) { return 9 + (height - 18) * (1 - (double)v / max); };
        for (auto const &mark : layer_marks)
        {
            double top = y(mark.hi), bottom = y(mark.lo);
            if (bottom - top < 3)
            {
                double mid = (top + bottom) / 2;
                top = mid - 1.5;
                bottom = mid + 1.5;
            }
            Canvas::SetTop(mark.hit, top - 6);
            mark.hit.Height(bottom - top + 12);
        }
    }

#ifdef ZS_DEV_HOOKS
    bool MainWindow::RunProfileStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb.rfind(L"prof", 0) != 0 || model == nullptr)
            return false;
        auto list = RangesOf(model->Active());
        size_t number = words.empty() ? 0 : (size_t)_wtoi(words[0].c_str());
        if (verb == L"profnew" && !words.empty())
            NewProfile(_wtoi(words[0].c_str()));
        else if (verb == L"profopen" && number < list.size())
            OpenProfile(list[number].first, list[number].second);
        else if (verb == L"profset" && words.size() >= 2)
            ProfileSet(zs::ToUtf8(words[0]), zs::ToUtf8(words[1]));
        else if (verb == L"profclear" && !words.empty())
            ProfileClear(zs::ToUtf8(words[0]));
        else if (verb == L"profrename" && !words.empty())
        {
            std::wstring text = words[0];
            std::replace(text.begin(), text.end(), L'_', L' ');
            if (in_profile && zs_app_profile_set(model->Active(), profile_min, profile_max, zs::ToUtf8(text).c_str()) == ZS_OK)
            {
                NoteChange();
                RefreshSettingValues();
            }
        }
        else if (verb == L"profdelete")
        {
            if (in_profile)
            {
                double lo = profile_min, hi = profile_max;
                LeaveProfile();
                if (zs_app_profile_remove(model->Active(), lo, hi) > 0)
                    model->RequestSlice();
                NoteChange();
                RefreshSettingValues();
            }
        }
        else if (verb == L"profdone")
            LeaveProfile();
        else if (verb == L"profmark" && number < layer_marks.size())
        {
            LayerMark const &mark = layer_marks[number];
            LayerSlider().Value((double)mark.hi + 1);
            OpenProfile(mark.z_min, mark.z_max);
        }
        else if (verb == L"proflog")
        {
            zs::Log("dev: profile on %d range %.3f %.3f title '%s' note '%s' | ranges %zu overrides %zu profiles %zu | page %d crumb '%s' rows %u | infill print %s here %s\n", in_profile ? 1 : 0,
                    profile_min, profile_max, zs::ToUtf8(std::wstring(ProfileTitle().Text())).c_str(), zs::ToUtf8(std::wstring(ProfileNote().Text())).c_str(), list.size(),
                    zs_app_override_count(model->Active()), zs_app_profile_count(model->Active()), (int)settings_page, zs::ToUtf8(std::wstring(SettingsCrumb().Text())).c_str(),
                    SettingsList().Children().Size(), model->GetSetting("project.infill_density").c_str(), ProfileValue("project.infill_density").c_str());
            for (auto const &mark : layer_marks)
                zs::Log("dev: profile mark layers %zu-%zu top %.0f height %.0f '%s'\n", mark.lo + 1, mark.hi + 1, Canvas::GetTop(mark.hit), mark.hit.Height(), zs::ToUtf8(mark.label).c_str());
        }
        else
            return false;
        return true;
    }
#endif
}
