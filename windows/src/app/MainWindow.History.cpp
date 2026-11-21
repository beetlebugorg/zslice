// The history over the bottom bar, as in web/app/history.js.
//
// A short hover on a mark of the timeline shows a card with the changes of
// that step, and an editor for each setting that changed. The History button
// opens the list of the steps, the newest first. Each change of the step now
// or an earlier step has an undo button for that change alone. A right click
// on a step goes to it, or clears the history after it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <ctime>
#include <sstream>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Media = Microsoft::UI::Xaml::Media;
using Windows::System::VirtualKey;

namespace
{
    std::wstring Clock(int64_t ms)
    {
        time_t seconds = (time_t)(ms / 1000);
        tm local{};
        if (localtime_s(&local, &seconds) != 0)
            return {};
        wchar_t text[32];
        return wcsftime(text, ARRAYSIZE(text), L"%X", &local) > 0 ? std::wstring(text) : std::wstring();
    }

    std::vector<std::string> Lines(char const *text, size_t len)
    {
        std::vector<std::string> out;
        std::string all(text != nullptr ? text : "", text != nullptr ? len : 0);
        size_t at = 0;
        for (;;)
        {
            size_t end = all.find('\n', at);
            out.push_back(all.substr(at, end == std::string::npos ? end : end - at));
            if (end == std::string::npos)
                return out;
            at = end + 1;
        }
    }

    TextBlock Words(std::wstring const &text, double size, Media::Brush const &brush = nullptr)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(size);
        t.TextWrapping(TextWrapping::Wrap);
        if (brush != nullptr)
            t.Foreground(brush);
        return t;
    }

    Border Pill(std::wstring const &text, Media::Brush const &back)
    {
        Border b;
        b.Background(back);
        b.CornerRadius(CornerRadiusHelper::FromUniformRadius(9));
        b.Padding(ThicknessHelper::FromLengths(8, 2, 8, 2));
        b.VerticalAlignment(VerticalAlignment::Center);
        TextBlock t;
        t.Text(text);
        t.FontSize(11);
        t.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
        t.Foreground(Media::SolidColorBrush(Microsoft::UI::Colors::White()));
        b.Child(t);
        return b;
    }

    Button FlatButton(hstring const &text)
    {
        Button b;
        b.Content(box_value(text));
        b.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        b.MinHeight(26);
        b.MinWidth(0);
        b.FontSize(12.5);
        b.Padding(ThicknessHelper::FromLengths(8, 2, 8, 2));
        return b;
    }

    bool FindInfo(std::string const &name, zs_setting_info &out)
    {
        size_t n = zs_setting_count();
        for (size_t i = 0; i < n; i++)
            if (zs_setting_get_info(i, &out) == ZS_OK && name == out.name)
                return true;
        return false;
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);
    Windows::UI::Color StepColor(char const *kind);
    std::wstring StepLabel(char const *kind);
    UIElement StepGlyph(char const *kind, double size);

    void MainWindow::WireHistory()
    {
        history_wait = queue.CreateTimer();
        history_wait.IsRepeating(false);
        history_wait.Tick([this](auto &&, auto &&) {
            if (history_wait_mark != nullptr)
                ShowHistoryCard(history_wait_mark, history_wait_step);
        });
        history_hide = queue.CreateTimer();
        history_hide.IsRepeating(false);
        history_hide.Interval(std::chrono::milliseconds(400));
        history_hide.Tick([this](auto &&, auto &&) {
            // A card with the focus in an editor stays.
            auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot()).try_as<DependencyObject>();
            for (auto at = focused; at != nullptr; at = Media::VisualTreeHelper::GetParent(at))
                if (history_card != nullptr && at == history_card)
                    return;
            CloseHistoryCard();
        });
        HistoryFlyout().Opening([this](auto &&, auto &&) {
            history_timer.Stop();
            if (model != nullptr && model->HistoryCommit())
                RefreshHistoryButtons();
            FillHistoryList();
        });
        // The arrow keys go through the steps.
        TimelineMarks().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (model == nullptr)
                return;
            zs_app *app = model->Active();
            size_t now = zs_app_history_current(app), count = zs_app_history_count(app);
            if (e.Key() == VirtualKey::Left && now > 0)
                GoToStep(now - 1);
            else if (e.Key() == VirtualKey::Right && now + 1 < count)
                GoToStep(now + 1);
            else
                return;
            e.Handled(true);
        });
        // The list shows the newest first: up is the next step.
        HistoryList().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (model == nullptr)
                return;
            zs_app *app = model->Active();
            size_t now = zs_app_history_current(app), count = zs_app_history_count(app);
            if (e.Key() == VirtualKey::Up && now + 1 < count)
                GoToStep(now + 1);
            else if (e.Key() == VirtualKey::Down && now > 0)
                GoToStep(now - 1);
            else
                return;
            e.Handled(true);
        });
    }

    void MainWindow::GoToStep(size_t step)
    {
        if (model == nullptr)
            return;
        history_timer.Stop();
        AfterRestore(model->HistoryGoto(step));
        if (HistoryFlyout().IsOpen())
            FillHistoryList();
    }

    void MainWindow::ClearHistoryAfter(size_t step)
    {
        if (model == nullptr)
            return;
        history_timer.Stop();
        model->HistoryCommit();
        AfterRestore(model->HistoryTruncate(step));
        RefreshHistoryButtons();
        if (HistoryFlyout().IsOpen())
            FillHistoryList();
    }

    void MainWindow::ShowStepMenu(FrameworkElement const &target, Windows::Foundation::Point at, size_t step)
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t now = zs_app_history_current(app), count = zs_app_history_count(app);
        std::wstring name = step == 0 ? L"the start" : L"change " + std::to_wstring(step);
        MenuFlyout menu;
        MenuFlyoutItem go;
        go.Text(L"Go to this change");
        go.IsEnabled(step != now);
        go.Click([this, step](auto &&, auto &&) { GoToStep(step); });
        menu.Items().Append(go);
        menu.Items().Append(MenuFlyoutSeparator{});
        MenuFlyoutItem clear;
        clear.Text(step < now ? L"Go to " + name + L" and clear the history after it" : L"Clear the history after " + name);
        ToolTipService::SetToolTip(clear, box_value(L"The later changes go from the history, and redo cannot bring them back."));
        clear.IsEnabled(step + 1 < count);
        clear.Click([this, step](auto &&, auto &&) { ClearHistoryAfter(step); });
        menu.Items().Append(clear);
        menu.ShowAt(target, at);
    }

    void MainWindow::HoverMark(FrameworkElement const &mark, size_t step)
    {
        history_hide.Stop();
        history_wait.Stop();
        if (history_card != nullptr && history_card_step == step)
            return;
        history_wait_mark = mark;
        history_wait_step = step;
        history_wait.Interval(std::chrono::milliseconds(history_card != nullptr ? 1 : 350));
        history_wait.Start();
    }

    void MainWindow::LeaveHistoryCard()
    {
        history_wait.Stop();
        history_hide.Stop();
        history_hide.Start();
    }

    void MainWindow::CloseHistoryCard()
    {
        history_editors.clear();
        if (history_card == nullptr)
            return;
        uint32_t index = 0;
        if (CardLayer().Children().IndexOf(history_card, index))
            CardLayer().Children().RemoveAt(index);
        history_card = nullptr;
        history_card_step = (size_t)-1;
    }

    void MainWindow::ShowHistoryCard(FrameworkElement const &mark, size_t i)
    {
        CloseHistoryCard();
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        zs_history_step step{};
        if (zs_app_history_step(app, i, &step) != ZS_OK)
            return;
        // The texts of the step are valid until the next call: copy them.
        auto word_lines = Lines(step.text, step.text_len);
        auto change_lines = Lines(step.changes, step.changes_len);
        char const *kind = i == 0 ? "start" : step.kind;
        size_t now = zs_app_history_current(app);
        auto dim = TokenBrush(Root(), L"ZsDim");

        StackPanel body;
        body.Spacing(8);
        Grid head;
        head.ColumnSpacing(8);
        ColumnDefinition dot_column, title_column;
        dot_column.Width(GridLengthHelper::Auto());
        title_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        head.ColumnDefinitions().Append(dot_column);
        head.ColumnDefinitions().Append(title_column);
        Border dot;
        dot.Width(24);
        dot.Height(24);
        dot.CornerRadius(CornerRadiusHelper::FromUniformRadius(12));
        dot.VerticalAlignment(VerticalAlignment::Top);
        dot.Background(Media::SolidColorBrush(StepColor(kind)));
        Grid glyph;
        glyph.Width(14);
        glyph.Height(14);
        glyph.Children().Append(StepGlyph(kind, 14));
        dot.Child(glyph);
        head.Children().Append(dot);
        StackPanel titles;
        TextBlock title = Words(i == 0 ? std::wstring(L"Start") : L"Change " + std::to_wstring(i), 14);
        title.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
        titles.Children().Append(title);
        titles.Children().Append(Words(StepLabel(kind) + L" · " + Clock(step.time_ms) + (i == now ? L" · now" : L""), 11.5, dim));
        Grid::SetColumn(titles, 1);
        head.Children().Append(titles);
        body.Children().Append(head);

        if (i == 0)
        {
            body.Children().Append(Words(L"The settings and the plate when the history started.", 12));
        }
        else
        {
            StackPanel lines;
            lines.Spacing(2);
            StackPanel editors;
            editors.Spacing(4);
            std::vector<std::string> done;
            for (size_t k = 0; k < word_lines.size(); k++)
            {
                auto const &words = word_lines[k];
                size_t tab = words.find('\t');
                if (tab == std::string::npos)
                    continue;
                lines.Children().Append(Words(zs::ToWide(words.substr(0, tab)) + L": " + zs::ToWide(words.substr(tab + 1)), 12.5));
                // An editor for a setting of the whole plate. A part, some
                // layers, and filament 2 and on have values of their own.
                if (k >= change_lines.size())
                    continue;
                auto const &change = change_lines[k];
                size_t first = change.find('\t');
                if (first == std::string::npos)
                    continue;
                size_t second = change.find('\t', first + 1);
                std::string scope = change.substr(0, first);
                std::string key = change.substr(first + 1, second == std::string::npos ? second : second - first - 1);
                zs_setting_info info{};
                if (!FindInfo(key, info) || std::find(done.begin(), done.end(), key) != done.end() ||
                    scope.find(':') != std::string::npos || scope.rfind("filament ", 0) == 0)
                    continue;
                done.push_back(key);
                Grid row;
                row.ColumnSpacing(8);
                ColumnDefinition name_column, edit_column;
                name_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                edit_column.Width(GridLengthHelper::Auto());
                row.ColumnDefinitions().Append(name_column);
                row.ColumnDefinitions().Append(edit_column);
                HyperlinkButton label;
                label.Content(box_value(zs::ToWide(info.label)));
                label.Padding(ThicknessHelper::FromLengths(2, 2, 2, 2));
                label.FontSize(12.5);
                label.Foreground(TokenBrush(Root(), L"ZsFg"));
                label.VerticalAlignment(VerticalAlignment::Center);
                ToolTipService::SetToolTip(label, box_value(L"Click to show this setting in the panel."));
                char const *name = info.name;
                label.Click([this, name](auto &&, auto &&) {
                    CloseHistoryCard();
                    ShowSettingsPane(true);
                    detail_from = settings_page;
                    ShowDetail(name);
                });
                row.Children().Append(label);
                size_t before = setting_editors.size();
                FrameworkElement editor = MakeEditor(info);
                for (size_t e = before; e < setting_editors.size(); e++)
                    history_editors.push_back(std::move(setting_editors[e]));
                setting_editors.resize(before);
                if (info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER)
                {
                    auto with_unit = editor.try_as<Grid>();
                    (with_unit != nullptr ? with_unit.Children().GetAt(0).as<FrameworkElement>() : editor).Width(72);
                }
                else if (info.kind == ZS_SETTING_TEXT)
                {
                    editor.Width(130);
                }
                editor.VerticalAlignment(VerticalAlignment::Center);
                Grid::SetColumn(editor, 1);
                row.Children().Append(editor);
                editors.Children().Append(row);
            }
            body.Children().Append(lines);
            if (editors.Children().Size() > 0)
            {
                Border box;
                box.BorderThickness(ThicknessHelper::FromLengths(0, 1, 0, 0));
                box.BorderBrush(TokenBrush(Root(), L"ZsLine"));
                box.Padding(ThicknessHelper::FromLengths(0, 8, 0, 0));
                StackPanel inner;
                inner.Spacing(4);
                inner.Children().Append(Words(L"The value now:", 12, dim));
                inner.Children().Append(editors);
                box.Child(inner);
                body.Children().Append(box);
            }
        }
        Button go = FlatButton(i == now ? L"This is the step now" : L"Go to this step");
        go.IsEnabled(i != now);
        go.Click([this, i](auto &&, auto &&) {
            CloseHistoryCard();
            GoToStep(i);
        });
        body.Children().Append(go);

        Border card;
        card.Width(300);
        card.MaxHeight(CardLayer().ActualHeight() * 0.6);
        card.Padding(ThicknessHelper::FromLengths(14, 10, 12, 10));
        card.Background(TokenBrush(Root(), L"ZsPopover"));
        card.BorderBrush(TokenBrush(Root(), L"ZsPopoverBorder"));
        card.BorderThickness(ThicknessHelper::FromUniformLength(1));
        card.CornerRadius(CornerRadiusHelper::FromUniformRadius(12));
        ScrollViewer scroll;
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        scroll.Content(body);
        card.Child(scroll);
        card.PointerEntered([this](auto &&, auto &&) { history_hide.Stop(); });
        card.PointerExited([this](auto &&, auto &&) { LeaveHistoryCard(); });
        Canvas::SetZIndex(card, 80);

        // Over the mark, and inside the view.
        card.Measure(Windows::Foundation::Size{ 300, (float)card.MaxHeight() });
        double height = card.DesiredSize().Height;
        Windows::Foundation::Rect size{ 0, 0, (float)mark.ActualWidth(), (float)mark.ActualHeight() };
        auto r = mark.TransformToVisual(CardLayer()).TransformBounds(size);
        double width = CardLayer().ActualWidth();
        Canvas::SetLeft(card, std::max(8.0, std::min(width - 300 - 8, (double)r.X + r.Width / 2 - 150)));
        Canvas::SetTop(card, std::max(8.0, (double)r.Y - height - 10));
        CardLayer().Children().Append(card);
        history_card = card;
        history_card_step = i;
    }

    void MainWindow::RefreshHistoryValues()
    {
        for (auto &editor : history_editors)
            editor.refresh();
    }

    // The steps, the newest first, and the edits of lines.
    void MainWindow::FillHistoryList()
    {
        auto list = HistoryList();
        list.Children().Clear();
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t count = zs_app_history_count(app), now = zs_app_history_current(app);
        auto dim = TokenBrush(Root(), L"ZsDim");
        auto accent = TokenBrush(Root(), L"ZsAccent");
        if (count <= 1)
        {
            TextBlock none = Words(L"No changes yet. Each change of a setting or of the plate shows here, and you can go back to it.", 13, dim);
            none.Padding(ThicknessHelper::FromLengths(6, 16, 6, 16));
            list.Children().Append(none);
        }
        for (size_t i = count; count > 1 && i-- > 0;)
        {
            zs_history_step step{};
            if (zs_app_history_step(app, i, &step) != ZS_OK)
                continue;
            auto word_lines = Lines(step.text, step.text_len);
            auto change_lines = Lines(step.changes, step.changes_len);
            char const *kind = i == 0 ? "start" : step.kind;

            StackPanel body;
            body.Spacing(4);
            StackPanel head;
            head.Orientation(Orientation::Horizontal);
            head.Spacing(8);
            head.Children().Append(Pill(StepLabel(kind), Media::SolidColorBrush(StepColor(kind))));
            TextBlock title = Words(i == 0 ? std::wstring(L"Start") : L"Change " + std::to_wstring(i), 13);
            title.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            title.VerticalAlignment(VerticalAlignment::Center);
            head.Children().Append(title);
            TextBlock when = Words(Clock(step.time_ms), 12, dim);
            when.VerticalAlignment(VerticalAlignment::Center);
            head.Children().Append(when);
            if (i == now)
                head.Children().Append(Pill(L"Now", accent));
            body.Children().Append(head);

            if (i == 0)
            {
                body.Children().Append(Words(L"The settings and the plate when the history started.", 12.5, dim));
            }
            else
            {
                size_t shown = 0;
                for (size_t k = 0; k < word_lines.size() && k < change_lines.size(); k++)
                {
                    auto const &words = word_lines[k];
                    size_t tab = words.find('\t');
                    if (tab == std::string::npos)
                        continue;
                    shown++;
                    std::string line = change_lines[k];
                    Grid change;
                    change.ColumnSpacing(6);
                    change.Padding(ThicknessHelper::FromLengths(4, 0, 0, 0));
                    change.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                    ColumnDefinition text_column, undo_column;
                    text_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                    undo_column.Width(GridLengthHelper::Auto());
                    change.ColumnDefinitions().Append(text_column);
                    change.ColumnDefinitions().Append(undo_column);
                    StackPanel text;
                    text.Children().Append(Words(zs::ToWide(words.substr(0, tab)), 11, dim));
                    text.Children().Append(Words(zs::ToWide(words.substr(tab + 1)), 12.5));
                    change.Children().Append(text);
                    size_t first = line.find('\t');
                    if (first != std::string::npos)
                    {
                        size_t second = line.find('\t', first + 1);
                        std::string key = line.substr(first + 1, second == std::string::npos ? second : second - first - 1);
                        zs_setting_info info{};
                        if (key.find('.') != std::string::npos && FindInfo(key, info))
                        {
                            ToolTipService::SetToolTip(change, box_value(L"Double-click to open this setting."));
                            char const *name = info.name;
                            change.DoubleTapped([this, name](auto &&, Input::DoubleTappedRoutedEventArgs const &e) {
                                e.Handled(true);
                                HistoryFlyout().Hide();
                                ShowSettingsPane(true);
                                detail_from = settings_page;
                                ShowDetail(name);
                            });
                        }
                    }
                    if (i <= now && zs_history_revertible(line.data(), line.size()) == 1)
                    {
                        Button undo = FlatButton(L"↶");
                        ToolTipService::SetToolTip(undo, box_value(L"Undo only this change. The later changes stay."));
                        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(undo, L"Undo only this change");
                        undo.VerticalAlignment(VerticalAlignment::Center);
                        undo.Click([this, line](auto &&, auto &&) { RevertChange(line); });
                        Grid::SetColumn(undo, 1);
                        change.Children().Append(undo);
                    }
                    body.Children().Append(change);
                }
                if (shown == 0)
                    body.Children().Append(Words(L"Other changes (formulas, global settings, or the plate).", 12.5, dim));
            }

            Border row;
            row.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
            row.Padding(ThicknessHelper::FromLengths(10, 8, 10, 8));
            row.Opacity(i > now ? 0.55 : 1);
            if (i == now)
            {
                auto color = accent.as<Media::SolidColorBrush>().Color();
                color.A = 0x2E;
                row.Background(Media::SolidColorBrush(color));
                row.BorderBrush(accent);
                row.BorderThickness(ThicknessHelper::FromLengths(3, 0, 0, 0));
            }
            else
            {
                row.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                ToolTipService::SetToolTip(row, box_value(L"Click to go to this step"));
            }
            row.Child(body);
            row.Tapped([this, i, now](auto &&, Input::TappedRoutedEventArgs const &e) {
                if (i != now)
                {
                    e.Handled(true);
                    GoToStep(i);
                }
            });
            row.RightTapped([this, i, row](auto &&, Input::RightTappedRoutedEventArgs const &e) {
                e.Handled(true);
                ShowStepMenu(row, e.GetPosition(row), i);
            });
            list.Children().Append(row);
        }

        // The edits of lines: each with its layer and what it does.
        size_t edits = zs_app_edit_count(app);
        if (edits == 0)
            return;
        Border box;
        box.BorderThickness(ThicknessHelper::FromLengths(0, 1, 0, 0));
        box.BorderBrush(TokenBrush(Root(), L"ZsLine"));
        box.Margin(ThicknessHelper::FromLengths(0, 12, 0, 0));
        box.Padding(ThicknessHelper::FromLengths(12, 8, 12, 8));
        StackPanel inner;
        inner.Spacing(2);
        TextBlock heading = Words(L"Line edits (" + std::to_wstring(edits) + L")", 13);
        heading.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        inner.Children().Append(heading);
        for (size_t e = 0; e < edits; e++)
        {
            int edit_kind = 0, applied = 0;
            double value = 0;
            size_t layer = 0;
            if (zs_app_edit_get(app, e, &edit_kind, &value, &layer, &applied) != ZS_OK)
                continue;
            wchar_t what[64];
            if (edit_kind == 0)
                swprintf_s(what, L"does not print");
            else if (edit_kind == 2)
                swprintf_s(what, L"a drop of %.1f mm", value);
            else
                swprintf_s(what, L"%.0f %% plastic", value * 100);
            Grid row;
            row.ColumnSpacing(6);
            for (int c = 0; c < 3; c++)
            {
                ColumnDefinition column;
                column.Width(c == 0 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                row.ColumnDefinitions().Append(column);
            }
            TextBlock text = Words(L"Layer " + std::to_wstring(layer + 1) + L": " + what, 12.5);
            text.VerticalAlignment(VerticalAlignment::Center);
            row.Children().Append(text);
            if (applied != 1)
            {
                TextBlock wait = Words(L"waits: its line is not in this slice", 11, TokenBrush(Root(), L"ZsWarning"));
                wait.MaxWidth(130);
                wait.VerticalAlignment(VerticalAlignment::Center);
                Grid::SetColumn(wait, 1);
                row.Children().Append(wait);
            }
            Button remove = FlatButton(L"×");
            ToolTipService::SetToolTip(remove, box_value(L"Remove this edit: the line prints as the slice makes it"));
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(remove, L"Remove the edit of layer " + to_hstring(layer + 1));
            remove.Click([this, e](auto &&, auto &&) {
                if (model == nullptr || zs_app_edit_remove(model->Active(), e) != ZS_OK)
                    return;
                model->RequestSlice();
                NoteChange();
                FillHistoryList();
            });
            Grid::SetColumn(remove, 2);
            row.Children().Append(remove);
            inner.Children().Append(row);
        }
        box.Child(inner);
        list.Children().Append(box);
    }

    // Undoes one change, and keeps the later ones.
    void MainWindow::RevertChange(std::string const &line)
    {
        if (model == nullptr)
            return;
        int rc = zs_app_history_revert(model->Active(), line.data(), line.size());
        if (rc != ZS_OK)
        {
            ShowToast(rc == 15 ? hstring(L"A move of a part cannot be undone alone: go to the step before it.")
                               : L"The change was not undone (" + to_hstring(rc) + L").");
            return;
        }
        history_timer.Stop();
        model->HistoryCommit();
        model->RequestSlice();
        RefreshSettingValues();
        RefreshHistoryButtons();
        PrintersNoteChange();
        if (HistoryFlyout().IsOpen())
            FillHistoryList();
    }
}
