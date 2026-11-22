// The search of settings and actions (/), as in web/app/search.js and
// linux/src/ui/search.c.
//
// The field is in the header. Text in it, a click in it, or / shows the
// results under it. A click outside closes those results. The undock button
// makes the search a card over the view, which the user moves and resizes.
// The pin buttons put it on the left or right rail of the view. A card or a
// rail stays open until Esc, /, or ×.
//
// The results are live controls. A number has a slider and an entry, a
// choice its list, and a switch its switch. A change goes to the core at
// once, and the view shows the new slice. The eye of a result shows only the
// lines that its setting changes.
//
// Keys: Up and Down go through the results. Left and Right change the value
// of the result. Space or Enter turns a switch or runs an action. V turns
// the eye on or off. Tab goes into the controls. Esc leaves a control, then
// closes the search.
//
// The actions never start a print. The upload action only sends the file.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#include <cmath>
#include <cwctype>
#include <limits>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Media = Microsoft::UI::Xaml::Media;
namespace Markup = Microsoft::UI::Xaml::Markup;
namespace Shapes = Microsoft::UI::Xaml::Shapes;
namespace Automation = Microsoft::UI::Xaml::Automation;
using Windows::System::VirtualKey;

namespace
{
    size_t const max_settings = 14;
    size_t const max_actions = 4;
    auto const drag_interval = std::chrono::milliseconds(90);
    double const search_unit_width = 40;
    double const search_hint_width = 84;

    wchar_t const *const left_pin = L"M2.5 2.5v11M5.5 4.5h8v7h-8z";
    wchar_t const *const right_pin = L"M13.5 2.5v11M2.5 4.5h8v7h-8z";
    wchar_t const *const card_pin = L"M9.5 2.5h4v4M13.5 2.5 8 8M7 3.5H2.5v10h10V9";
    wchar_t const *const dock_pin = L"M2.5 2.5h11M8 13.5V6M5 9l3-3 3 3";
    wchar_t const *const eye_icon = L"M1.5 9s2.8-5 7.5-5 7.5 5 7.5 5-2.8 5-7.5 5-7.5-5-7.5-5zM11.3 9a2.3 2.3 0 1 1-4.6 0a2.3 2.3 0 1 1 4.6 0z";

    wchar_t const *GroupTitle(char const *group)
    {
        if (strcmp(group, "project") == 0)
            return L"Part";
        if (strcmp(group, "filament") == 0)
            return L"Filament";
        if (strcmp(group, "machine") == 0)
            return L"Printer";
        return L"Engine";
    }

    char const *PlaceName(int place)
    {
        char const *const names[] = { "header", "card", "left", "right" };
        return names[place];
    }

    Shapes::Path Icon(wchar_t const *data, double size, double scale)
    {
        std::wstring s = std::to_wstring(size), k = std::to_wstring(scale);
        std::wstring xaml = L"<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='" + s + L"' Height='" + s +
                            L"' Stroke='{ThemeResource ZsFg}' StrokeThickness='1.5' StrokeStartLineCap='Round' StrokeEndLineCap='Round' "
                            L"StrokeLineJoin='Round' Data='" + data + L"'><Path.RenderTransform><ScaleTransform ScaleX='" + k + L"' ScaleY='" + k +
                            L"'/></Path.RenderTransform></Path>";
        return Markup::XamlReader::Load(xaml).as<Shapes::Path>();
    }

    Button IconButton(wchar_t const *data, wchar_t const *tip, wchar_t const *name, double size = 26)
    {
        Button b;
        b.Width(size);
        b.Height(size);
        b.MinWidth(0);
        b.MinHeight(0);
        b.Padding(ThicknessHelper::FromUniformLength(0));
        b.Opacity(0.7);
        b.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        b.HorizontalContentAlignment(HorizontalAlignment::Center);
        b.VerticalContentAlignment(VerticalAlignment::Center);
        b.Content(Icon(data, 15, 1));
        Automation::AutomationProperties::SetName(b, name);
        ToolTipService::SetToolTip(b, box_value(tip));
        return b;
    }

    std::wstring Lower(std::wstring text)
    {
        std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) { return (wchar_t)std::towlower(c); });
        return text;
    }

    std::vector<std::wstring> Words(std::wstring const &text)
    {
        std::vector<std::wstring> words;
        std::wstringstream in{ text };
        std::wstring word;
        while (in >> word)
            words.push_back(word);
        return words;
    }

    std::wstring PlainDoc(char const *doc)
    {
        std::wstring text = zs::ToWide(doc != nullptr ? doc : "");
        text.erase(std::remove(text.begin(), text.end(), L'`'), text.end());
        return text;
    }

    std::vector<std::string> Choices(char const *text)
    {
        std::vector<std::string> out;
        std::stringstream in{ std::string(text != nullptr ? text : "") };
        std::string line;
        while (std::getline(in, line))
            if (!line.empty())
                out.push_back(line);
        return out;
    }

    std::string Shortest(double value)
    {
        char text[40];
        snprintf(text, sizeof text, "%.10g", value);
        return text;
    }

    double Pref(char const *key, double fallback)
    {
        std::string text = zs::Printers().Pref(key);
        return text.empty() ? fallback : strtod(text.c_str(), nullptr);
    }

    // The search has its own × button: the × of the text box goes away.
    void HideDeleteButton(DependencyObject const &at)
    {
        int n = Media::VisualTreeHelper::GetChildrenCount(at);
        for (int i = 0; i < n; i++)
        {
            auto child = Media::VisualTreeHelper::GetChild(at, i);
            if (auto button = child.try_as<Button>(); button != nullptr && button.Name() == L"DeleteButton")
            {
                // The states of the text box set its visibility, so it stays
                // in the tree with no size, no paint, and no clicks.
                button.Width(0);
                button.MinWidth(0);
                button.Opacity(0);
                button.IsHitTestVisible(false);
                button.IsTabStop(false);
                return;
            }
            HideDeleteButton(child);
        }
    }

    double const nan_size = std::numeric_limits<double>::quiet_NaN();
    double const no_limit = std::numeric_limits<double>::infinity();
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    void MainWindow::WireSearch()
    {
        search_timer = queue.CreateTimer();
        search_timer.IsRepeating(false);
        search_timer.Tick([this](auto &&, auto &&) { FlushSearchDrag(); });

        auto changed = [this](TextBox const &entry) {
            HideDeleteButton(entry);
            std::wstring text{ entry.Text() };
            if (text == search_text)
                return;
            search_text = text;
            if (search_open)
                FillSearch();
            else
                OpenSearch(false);
        };
        HeaderSearch().TextChanged([this, changed](auto &&, auto &&) { changed(HeaderSearch()); });
        SearchEntry().TextChanged([this, changed](auto &&, auto &&) { changed(SearchEntry()); });

        // A click or Tab into the field shows the results. The window gives
        // it the focus again by code: that opens nothing.
        SearchEntry().GotFocus([this](auto &&, auto &&) { HideDeleteButton(SearchEntry()); });
        HeaderSearch().GotFocus([this](auto &&, auto &&) {
            HideDeleteButton(HeaderSearch());
            UpdateSearchField();
            if (!search_open && search_place == SearchPlace::Header && HeaderSearch().FocusState() != FocusState::Programmatic)
                OpenSearch(false);
        });
        HeaderSearch().LostFocus([this](auto &&, auto &&) { UpdateSearchField(); });
        HeaderSearch().PreviewKeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) { SearchPreviewKey(e); });
        SearchBox().PreviewKeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) { SearchPreviewKey(e); });

        SearchClose().Click([this](auto &&, auto &&) { CloseSearch(); });
        SearchUndock().Click([this](auto &&, auto &&) { SetSearchPlace(SearchPlace::Card); });
        SearchOpen().Click([this](auto &&, auto &&) { OpenSearch(true); });
        SearchOpen().SizeChanged([this](auto &&, auto &&) { LayoutHeader(); });
        CardLayer().SizeChanged([this](auto &&, auto &&) { PlaceSearch(); });
        SearchField().SizeChanged([this](auto &&, auto &&) { PlaceSearch(); });
        Dock().SizeChanged([this](auto &&, auto &&) { PlaceSearch(); });

        // Docked results close at a click outside them. A drag in the view
        // (a turn or a pan) keeps them open.
        Root().AddHandler(UIElement::PointerPressedEvent(), box_value(Input::PointerEventHandler([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            search_click = search_open && search_place == SearchPlace::Header && !InsideSearch(e);
            if (search_click)
                search_press = e.GetCurrentPoint(Root()).Position();
        })), true);
        Root().AddHandler(UIElement::PointerReleasedEvent(), box_value(Input::PointerEventHandler([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!search_click)
                return;
            search_click = false;
            auto at = e.GetCurrentPoint(Root()).Position();
            if (std::hypot(at.X - search_press.X, at.Y - search_press.Y) < 5)
                CloseSearch();
        })), true);

        // A drag of the head moves the card. The entry and the buttons keep
        // their own clicks.
        SearchHead().PointerPressed([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (search_place != SearchPlace::Card || !e.GetCurrentPoint(SearchHead()).Properties().IsLeftButtonPressed())
                return;
            auto at = e.GetCurrentPoint(SearchBox()).Position();
            search_drag = 1;
            search_drag_x = at.X;
            search_drag_y = at.Y;
            SearchHead().CapturePointer(e.Pointer());
            e.Handled(true);
        });
        SearchHead().PointerMoved([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (search_drag != 1)
                return;
            auto at = e.GetCurrentPoint(CardLayer()).Position();
            search_x = at.X - search_drag_x;
            search_y = at.Y - search_drag_y;
            PlaceSearch();
            e.Handled(true);
        });
        auto head_up = [this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (search_drag != 1)
                return;
            search_drag = 0;
            SearchHead().ReleasePointerCapture(e.Pointer());
            SaveSearchCard();
            SearchEntry().Focus(FocusState::Programmatic);
        };
        SearchHead().PointerReleased(head_up);
        SearchHead().PointerCaptureLost(head_up);
        SearchHead().DoubleTapped([this](auto &&, auto &&) {
            if (search_place != SearchPlace::Card)
                return;
            search_x = search_y = -1;
            PlaceSearch();
            SaveSearchCard();
        });

        // A drag of the corner changes the size of the card.
        SearchResize().PointerPressed([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto at = e.GetCurrentPoint(SearchResize()).Position();
            search_drag = 2;
            search_drag_x = SearchResize().ActualWidth() - at.X;
            search_drag_y = SearchResize().ActualHeight() - at.Y;
            SearchResize().CapturePointer(e.Pointer());
            e.Handled(true);
        });
        SearchResize().PointerMoved([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (search_drag != 2)
                return;
            auto at = e.GetCurrentPoint(SearchBox()).Position();
            search_w = std::max(260.0, at.X + search_drag_x);
            search_h = std::max(140.0, at.Y + search_drag_y);
            PlaceSearch();
            e.Handled(true);
        });
        auto corner_up = [this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (search_drag != 2)
                return;
            search_drag = 0;
            SearchResize().ReleasePointerCapture(e.Pointer());
            SaveSearchCard();
        };
        SearchResize().PointerReleased(corner_up);
        SearchResize().PointerCaptureLost(corner_up);
    }

    // The saved place, after the printer store has loaded.
    void MainWindow::RestoreSearchPlace()
    {
        std::string place = zs::Printers().Pref("search_place", "header");
        search_place = place == "card" ? SearchPlace::Card : place == "left" ? SearchPlace::Left : place == "right" ? SearchPlace::Right : SearchPlace::Header;
        search_x = Pref("search_x", -1);
        search_y = Pref("search_y", -1);
        search_w = Pref("search_w", 0);
        search_h = Pref("search_h", 0);
        ShowSearchField();
    }

    void MainWindow::SaveSearchCard()
    {
        auto &store = zs::Printers();
        store.SetPref("search_x", Shortest(search_x));
        store.SetPref("search_y", Shortest(search_y));
        store.SetPref("search_w", Shortest(search_w));
        store.SetPref("search_h", Shortest(search_h));
    }

    // The header shows the field, or a Search button for a card or a rail.
    void MainWindow::ShowSearchField()
    {
        bool docked = search_place == SearchPlace::Header;
        SearchField().Visibility(docked ? Visibility::Visible : Visibility::Collapsed);
        SearchOpen().Visibility(docked ? Visibility::Collapsed : Visibility::Visible);
        LayoutHeader();
    }

    void MainWindow::UpdateSearchField()
    {
        bool docked = search_open && search_place == SearchPlace::Header;
        bool active = docked || HeaderSearch().FocusState() != FocusState::Unfocused;
        SearchKey().Visibility(active ? Visibility::Collapsed : Visibility::Visible);
        SearchClose().Visibility(docked ? Visibility::Visible : Visibility::Collapsed);
        SearchField().BorderBrush(TokenBrush(Root(), active ? L"ZsAccent" : L"ZsBorder"));
    }

    TextBox MainWindow::ActiveSearchEntry()
    {
        return search_place == SearchPlace::Header ? HeaderSearch() : SearchEntry();
    }

    bool MainWindow::InsideSearch(Input::PointerRoutedEventArgs const &e)
    {
        auto at = e.GetCurrentPoint(Root()).Position();
        auto inside = [&](FrameworkElement const &element) {
            if (element.Visibility() != Visibility::Visible)
                return false;
            Windows::Foundation::Rect size{ 0, 0, (float)element.ActualWidth(), (float)element.ActualHeight() };
            auto r = element.TransformToVisual(Root()).TransformBounds(size);
            return at.X >= r.X && at.X <= r.X + r.Width && at.Y >= r.Y && at.Y <= r.Y + r.Height;
        };
        return inside(SearchBox()) || inside(SearchField());
    }

    void MainWindow::OpenSearch(bool focus)
    {
        TextBox entry = ActiveSearchEntry();
        if (!search_open)
        {
            search_open = true;
            bool docked = search_place == SearchPlace::Header;
            bool card = search_place == SearchPlace::Card;
            SearchHead().Visibility(docked ? Visibility::Collapsed : Visibility::Visible);
            SearchPinRow().Visibility(docked ? Visibility::Visible : Visibility::Collapsed);
            SearchGrip().Visibility(card ? Visibility::Visible : Visibility::Collapsed);
            SearchResize().Visibility(card ? Visibility::Visible : Visibility::Collapsed);
            SearchBox().CornerRadius(CornerRadiusHelper::FromUniformRadius(docked || card ? 14 : 12));
            FillSearchPins();
            SearchBox().Visibility(Visibility::Visible);
            PlaceSearch();
            FillSearch();
            UpdateSearchField();
        }
        if (focus)
        {
            // A card that just showed takes the focus after its first layout.
            if (!entry.Focus(FocusState::Keyboard))
                queue.TryEnqueue([entry] { entry.Focus(FocusState::Keyboard); });
            entry.SelectAll();
        }
    }

    // Opens the search on these words, as a click on a fact of the print.
    void MainWindow::SearchFor(std::wstring const &query)
    {
        search_text = query;
        ActiveSearchEntry().Text(query);
        if (search_open)
            FillSearch();
        OpenSearch(true);
    }

    void MainWindow::CloseSearch()
    {
        if (!search_open)
            return;
        FlushSearchDrag();
        // The focus goes back to the view only from inside the search.
        bool inside = false;
        auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot()).try_as<DependencyObject>();
        for (auto at = focused; at != nullptr && !inside; at = Media::VisualTreeHelper::GetParent(at))
            inside = at == SearchBox() || at == SearchField();
        search_open = false;
        search_click = false;
        search_drag = 0;
        SetSearchEye({});
        search_rows.clear();
        search_editors.clear();
        SearchList().Children().Clear();
        SearchBox().Visibility(Visibility::Collapsed);
        if (model != nullptr && model->HistoryFocus(nullptr))
            RefreshHistoryButtons();
        if (inside)
            (show_2d ? Layer2DPanel() : ViewPanel()).Focus(FocusState::Programmatic);
        UpdateSearchField();
    }

    // The search opens again in its new place, with its text.
    void MainWindow::SetSearchPlace(SearchPlace place)
    {
        std::wstring text = search_text;
        CloseSearch();
        search_place = place;
        zs::Printers().SetPref("search_place", PlaceName((int)place));
        ShowSearchField();
        ActiveSearchEntry().Text(text);
        OpenSearch(true);
    }

    void MainWindow::FillSearchPins()
    {
        SearchPins().Children().Clear();
        SearchHeadPins().Children().Clear();
        auto panel = search_place == SearchPlace::Header ? SearchPins() : SearchHeadPins();
        auto pin = [this, panel](wchar_t const *data, wchar_t const *tip, wchar_t const *name, SearchPlace place) {
            Button b = IconButton(data, tip, name);
            b.Click([this, place](auto &&, auto &&) { SetSearchPlace(place); });
            panel.Children().Append(b);
        };
        if (search_place != SearchPlace::Left)
            pin(left_pin, L"Pin to the left rail: the search stays open at the left of the view", L"Pin to the left rail", SearchPlace::Left);
        if (search_place != SearchPlace::Right)
            pin(right_pin, L"Pin to the right rail: the search stays open at the right of the view", L"Pin to the right rail", SearchPlace::Right);
        if (search_place != SearchPlace::Card)
            pin(card_pin, L"Undock the search: a card over the view that you can move and resize", L"Undock the search", SearchPlace::Card);
        if (search_place == SearchPlace::Header)
            return;
        pin(dock_pin, L"Dock the search: put it back in the header", L"Dock the search", SearchPlace::Header);
        Button close;
        close.Width(26);
        close.Height(26);
        close.MinWidth(0);
        close.Padding(ThicknessHelper::FromUniformLength(0));
        close.Opacity(0.75);
        close.FontSize(16);
        close.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        close.Content(box_value(L"×"));
        Automation::AutomationProperties::SetName(close, L"Close the search");
        ToolTipService::SetToolTip(close, box_value(L"Close the search (Esc)"));
        close.Click([this](auto &&, auto &&) { CloseSearch(); });
        panel.Children().Append(close);
    }

    void MainWindow::PlaceSearch()
    {
        if (!search_open)
            return;
        double W = CardLayer().ActualWidth(), H = CardLayer().ActualHeight();
        if (W <= 0 || H <= 0)
            return;
        double w = 560, x = 8, y = 8, height = nan_size, max_height = no_limit;
        if (search_place == SearchPlace::Header)
        {
            Windows::Foundation::Rect size{ 0, 0, (float)SearchField().ActualWidth(), (float)SearchField().ActualHeight() };
            auto r = SearchField().TransformToVisual(CardLayer()).TransformBounds(size);
            w = std::min(std::max((double)r.Width, 640.0), W - 16);
            x = std::max(8.0, std::min(W - w - 8, r.X + r.Width / 2 - w / 2));
            y = r.Y + r.Height + 6;
            max_height = std::min({ H * 0.62, 560.0, H - y - 8 });
        }
        else if (search_place == SearchPlace::Card)
        {
            w = std::min(search_w > 0 ? search_w : 560.0, W - 16);
            if (search_h > 0)
            {
                height = std::min(search_h, H - 16);
                max_height = H - 16;
            }
            else
            {
                max_height = std::min(H * 0.62, 560.0);
            }
            // The first place: centered at the top of the view.
            double px = search_x >= 0 ? search_x : (W - w) / 2, py = search_y >= 0 ? search_y : 8;
            double shown = std::isnan(height) ? std::min(SearchBox().ActualHeight(), 80.0) : std::min(height, 80.0);
            x = std::max(8.0, std::min(W - w - 8, px));
            y = std::max(8.0, std::min(H - shown - 8, py));
        }
        else
        {
            w = std::clamp(W * 0.3, 260.0, 380.0);
            double bottom = (Dock().Visibility() == Visibility::Visible ? H - Dock().ActualHeight() : H) - 8;
            y = 8;
            height = std::max(160.0, bottom - y);
            if (search_place == SearchPlace::Left)
            {
                Windows::Foundation::Rect size{ 0, 0, (float)ToolStrip().ActualWidth(), (float)ToolStrip().ActualHeight() };
                auto strip = ToolStrip().TransformToVisual(CardLayer()).TransformBounds(size);
                x = std::max(8.0, (double)strip.X + strip.Width + 8);
            }
            else
            {
                x = W - w - 8;
            }
        }
        SearchBox().Width(w);
        SearchBox().Height(height);
        SearchBox().MaxHeight(max_height);
        Canvas::SetLeft(SearchBox(), x);
        Canvas::SetTop(SearchBox(), y);
    }

    void MainWindow::FillSearch()
    {
        FlushSearchDrag();
        search_rows.clear();
        search_editors.clear();
        SearchList().Children().Clear();
        auto note = [this](std::wstring const &text) {
            TextBlock t;
            t.Text(text);
            t.TextWrapping(TextWrapping::WrapWholeWords);
            t.LineHeight(19);
            t.Foreground(TokenBrush(Root(), L"ZsDim"));
            t.Padding(ThicknessHelper::FromLengths(12, 14, 12, 14));
            SearchList().Children().Append(t);
        };
        auto heading = [this](wchar_t const *text) {
            TextBlock t;
            t.Text(text);
            t.FontSize(11);
            t.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            t.CharacterSpacing(40);
            t.Foreground(TokenBrush(Root(), L"ZsDim"));
            t.Padding(ThicknessHelper::FromLengths(10, 8, 10, 4));
            SearchList().Children().Append(t);
        };
        std::wstring query = Lower(search_text);
        std::vector<std::wstring> words = Words(query);
        if (words.empty())
        {
            note(L"Type a setting (infill, walls, brim, speed) or an action (export, arrange, upload).");
            return;
        }
        std::vector<uint32_t> hits(200);
        size_t count = std::min(zs_setting_search(zs::ToUtf8(query).c_str(), 0, hits.data(), nullptr, hits.size()), hits.size());
        if (count > 0)
        {
            heading(L"SETTINGS");
            for (size_t i = 0; i < std::min(count, max_settings); i++)
            {
                zs_setting_info info{};
                if (zs_setting_get_info(hits[i], &info) == ZS_OK)
                    AddSearchSetting(info);
            }
            if (count > max_settings)
                note(std::to_wstring(count - max_settings) + L" more settings match. Type more words to narrow the list.");
        }
        size_t actions = 0;
        for (auto const &action : SearchActions())
        {
            std::wstring text = Lower(action.label), hint = Lower(action.hint);
            bool all = std::all_of(words.begin(), words.end(), [&](std::wstring const &w) {
                return text.find(w) != std::wstring::npos || hint.find(w) != std::wstring::npos;
            });
            if (!all)
                continue;
            if (actions == 0)
                heading(L"ACTIONS");
            AddSearchAction(action);
            if (++actions == max_actions)
                break;
        }
        if (search_rows.empty())
            note(L"No setting or action matches.");
        SelectSearchRow(0, false);
    }

    void MainWindow::SelectSearchRow(int index, bool focus)
    {
        if (search_rows.empty())
            return;
        search_index = std::clamp(index, 0, (int)search_rows.size() - 1);
        auto color = TokenBrush(Root(), L"ZsAccent").as<Media::SolidColorBrush>().Color();
        color.A = 0x38;
        for (size_t i = 0; i < search_rows.size(); i++)
        {
            if ((int)i == search_index)
                search_rows[i].back.Background(Media::SolidColorBrush(color));
            else
                search_rows[i].back.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        }
        if (focus)
        {
            auto const &row = search_rows[(size_t)search_index];
            row.node.StartBringIntoView();
            row.node.Focus(FocusState::Keyboard);
        }
    }

    void MainWindow::SearchPreviewKey(Input::KeyRoutedEventArgs const &e)
    {
        auto down = [](VirtualKey k) {
            return (Microsoft::UI::Input::InputKeyboardSource::GetKeyStateForCurrentThread(k) &
                    Windows::UI::Core::CoreVirtualKeyStates::Down) == Windows::UI::Core::CoreVirtualKeyStates::Down;
        };
        if (SearchKeyPress(e.Key(), down(VirtualKey::Control)))
            e.Handled(true);
    }

    bool MainWindow::SearchKeyPress(VirtualKey key, bool ctrl)
    {
        if (!search_open)
            return false;
        auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
        bool in_entry = focused == ActiveSearchEntry();
        bool in_row = false;
        for (auto const &row : search_rows)
            in_row = in_row || focused == row.node;
        TextBox text = in_entry ? nullptr : focused.try_as<TextBox>();
        bool in_control = text != nullptr || focused.try_as<ComboBox>() != nullptr || focused.try_as<Slider>() != nullptr;
        bool has_row = !search_rows.empty();

        if (key == VirtualKey::Escape)
        {
            if (in_control && has_row)
                SelectSearchRow(search_index, true);
            else
                CloseSearch();
            return true;
        }
        // The editor sends the value on Enter. Then the focus goes back to
        // the row, for the next Up or Down.
        if (key == VirtualKey::Enter && text != nullptr && !text.AcceptsReturn())
        {
            queue.TryEnqueue([this] {
                if (search_open)
                    SelectSearchRow(search_index, true);
            });
            return false;
        }
        if (in_control)
            return false;
        if ((key == VirtualKey::Down || key == VirtualKey::Up) && has_row)
        {
            SelectSearchRow(search_index + (key == VirtualKey::Down ? 1 : -1), true);
            return true;
        }
        if (has_row && (key == VirtualKey::Enter && in_entry))
        {
            auto run = search_rows[(size_t)search_index].activate;
            run();
            return true;
        }
        if (!in_row)
            return false;
        auto const &row = search_rows[(size_t)search_index];
        if ((key == VirtualKey::Left || key == VirtualKey::Right) && row.nudge)
        {
            row.nudge(key == VirtualKey::Right ? 1 : -1);
            return true;
        }
        if (key == VirtualKey::V && !ctrl && row.eye != nullptr)
        {
            SetSearchEye(search_eye == row.name ? std::string() : row.name);
            return true;
        }
        if (key == VirtualKey::Enter || key == VirtualKey::Space)
        {
            auto run = row.activate;
            run();
            return true;
        }
        // In a row, a letter is no tool key of the view.
        return !ctrl && key != VirtualKey::Tab;
    }

    void MainWindow::AddSearchSetting(zs_setting_info const &info)
    {
        bool rail = search_place == SearchPlace::Left || search_place == SearchPlace::Right;
        int index = (int)search_rows.size();
        zs_setting_info copy = info;
        std::string name = info.name;

        Grid grid;
        grid.ColumnSpacing(12);
        grid.RowSpacing(4);
        for (int i = 0; i < 3; i++)
        {
            ColumnDefinition column;
            column.Width(i == 0 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
            grid.ColumnDefinitions().Append(column);
        }
        if (rail)
        {
            RowDefinition first, second;
            first.Height(GridLengthHelper::Auto());
            second.Height(GridLengthHelper::Auto());
            grid.RowDefinitions().Append(first);
            grid.RowDefinitions().Append(second);
        }

        StackPanel label;
        label.VerticalAlignment(VerticalAlignment::Center);
        TextBlock title;
        title.Text(zs::ToWide(info.label));
        title.TextWrapping(TextWrapping::WrapWholeWords);
        TextBlock tag;
        tag.FontSize(12);
        tag.TextWrapping(TextWrapping::Wrap);
        tag.Foreground(TokenBrush(Root(), L"ZsDim"));
        label.Children().Append(title);
        label.Children().Append(tag);
        ToolTipService::SetToolTip(label, box_value(PlainDoc(info.doc)));
        grid.Children().Append(label);

        std::wstring place = std::wstring(GroupTitle(info.group)) + L" · " + zs::ToWide(info.section);
        auto fill_tag = [this, tag, name, place]() mutable {
            if (model == nullptr)
                return;
            std::wstring source = zs::ToWide(model->SourceTag(name.c_str()));
            tag.Text(source.empty() ? place : place + L" · " + source);
        };
        fill_tag();
        search_editors.push_back({ name, fill_tag });

        Button eye = IconButton(eye_icon, L"Show only the lines that this setting changes (the others as ghosts). Key: V",
                                (zs::ToWide(info.label) + L": show only its lines").c_str(), 28);
        eye.Content(Icon(eye_icon, 16, 16.0 / 18.0));
        eye.Opacity(0.45);
        eye.IsTabStop(false);
        eye.VerticalAlignment(VerticalAlignment::Center);
        eye.Click([this, name](auto &&, auto &&) { SetSearchEye(search_eye == name ? std::string() : name); });
        Grid::SetColumn(eye, rail ? 2 : 1);
        grid.Children().Append(eye);

        Grid controls;
        controls.ColumnSpacing(8);
        ColumnDefinition slider_column, editor_column;
        slider_column.Width(rail ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
        editor_column.Width(GridLengthHelper::Auto());
        controls.ColumnDefinitions().Append(slider_column);
        controls.ColumnDefinitions().Append(editor_column);
        controls.VerticalAlignment(VerticalAlignment::Center);
        if (rail)
        {
            Grid::SetRow(controls, 1);
            Grid::SetColumnSpan(controls, 3);
        }
        else
        {
            Grid::SetColumn(controls, 2);
        }

        bool number = info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER;
        bool ratio = info.unit != nullptr && strcmp(info.unit, "%") == 0;
        double k = ratio ? 100 : 1;
        if (number && info.slider_max > info.slider_min)
        {
            Slider slider;
            if (!rail)
                slider.Width(160);
            slider.Minimum(info.slider_min * k);
            slider.Maximum(info.slider_max * k);
            double step = info.slider_step > 0 ? info.slider_step : info.kind == ZS_SETTING_INTEGER ? 1 : (info.slider_max - info.slider_min) / 100;
            slider.StepFrequency(step * k);
            slider.IsThumbToolTipEnabled(false);
            slider.VerticalAlignment(VerticalAlignment::Center);
            Automation::AutomationProperties::SetName(slider, zs::ToWide(info.label));
            auto held = std::make_shared<bool>(false);
            auto fill = [this, slider, name, k, held]() mutable {
                if (*held || model == nullptr)
                    return;
                filling_editor = true;
                slider.Value(strtod(model->GetSetting(name.c_str()).c_str(), nullptr) * k);
                filling_editor = false;
            };
            fill();
            search_editors.push_back({ name, fill });
            // A drag sends a value at most each 90 ms, and the last one at
            // the end: each value starts a slice.
            slider.ValueChanged([this, copy](auto &&, Primitives::RangeBaseValueChangedEventArgs const &e) {
                if (filling_editor)
                    return;
                std::wstring text = zs::ToWide(Shortest(e.NewValue()));
                search_pending = [this, copy, text] { CommitSettingText(copy, text); };
                auto wait = drag_interval - std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - search_sent);
                if (wait.count() <= 0)
                {
                    FlushSearchDrag();
                }
                else if (!search_timer.IsRunning())
                {
                    search_timer.Interval(wait);
                    search_timer.Start();
                }
            });
            slider.AddHandler(UIElement::PointerPressedEvent(), box_value(Input::PointerEventHandler([held](auto &&, auto &&) { *held = true; })), true);
            auto let_go = [this, held, fill](auto &&, auto &&) mutable {
                *held = false;
                FlushSearchDrag();
                fill();
            };
            slider.AddHandler(UIElement::PointerReleasedEvent(), box_value(Input::PointerEventHandler(let_go)), true);
            slider.AddHandler(UIElement::PointerCaptureLostEvent(), box_value(Input::PointerEventHandler(let_go)), true);
            controls.Children().Append(slider);
        }

        // The editor of the settings pane, with its refresh in this list.
        size_t before = setting_editors.size();
        FrameworkElement editor = MakeEditor(info);
        for (size_t i = before; i < setting_editors.size(); i++)
            search_editors.push_back(std::move(setting_editors[i]));
        setting_editors.resize(before);
        if (number)
        {
            // The entry is narrow, with the unit after it. The unit and the
            // speed hint have fixed columns, so the sliders and the entries
            // of all rows line up, with a hint or without one.
            auto with_unit = editor.try_as<Grid>();
            (with_unit != nullptr ? with_unit.Children().GetAt(0).as<FrameworkElement>() : editor).Width(72);
            if (!rail)
            {
                if (with_unit != nullptr)
                {
                    with_unit.ColumnDefinitions().GetAt(1).Width(GridLengthHelper::FromPixels(search_unit_width));
                    with_unit.ColumnDefinitions().GetAt(2).Width(GridLengthHelper::FromPixels(search_hint_width));
                }
                else
                {
                    editor.Margin(ThicknessHelper::FromLengths(0, 0, search_unit_width + search_hint_width + 12, 0));
                }
            }
        }
        else if (info.kind == ZS_SETTING_CHOICE)
        {
            editor.MinHeight(32);
        }
        else if (info.kind == ZS_SETTING_TEXT)
        {
            editor.Width(rail ? nan_size : 180);
        }
        editor.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(editor, 1);
        controls.Children().Append(editor);
        grid.Children().Append(controls);

        Border back;
        back.CornerRadius(CornerRadiusHelper::FromUniformRadius(9));
        back.Padding(ThicknessHelper::FromLengths(10, 8, 10, 8));
        back.Child(grid);
        ContentControl node;
        node.IsTabStop(true);
        node.UseSystemFocusVisuals(true);
        node.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        node.Content(back);
        Automation::AutomationProperties::SetName(node, zs::ToWide(info.label));
        node.PointerEntered([this, index](auto &&, auto &&) { SelectSearchRow(index, false); });
        // The edits of this row are one step while the focus stays in it.
        node.GotFocus([this, name, index](auto &&, auto &&) {
            search_index = index;
            if (model != nullptr && model->HistoryFocus(name.c_str()))
                RefreshHistoryButtons();
        });
        node.LostFocus([this](auto &&, auto &&) {
            FlushSearchDrag();
            if (model != nullptr && model->HistoryFocus(nullptr))
                RefreshHistoryButtons();
        });

        // Left and Right: one step of a number, or the next choice.
        auto nudge = [this, copy, name, step = info.slider_step, ratio](int dir) {
            if (model == nullptr)
                return;
            std::string now = model->GetSetting(name.c_str());
            if (copy.kind == ZS_SETTING_NUMBER || copy.kind == ZS_SETTING_INTEGER)
            {
                double by = step > 0 ? step : copy.kind == ZS_SETTING_INTEGER ? 1 : ratio ? 0.01 : 0.1;
                CommitSetting(name, Shortest(strtod(now.c_str(), nullptr) + dir * by));
            }
            else if (copy.kind == ZS_SETTING_CHOICE)
            {
                auto list = Choices(copy.choices);
                if (list.empty())
                    return;
                auto at = std::find(list.begin(), list.end(), now);
                int i = at == list.end() ? 0 : (int)(at - list.begin());
                int n = (int)list.size();
                CommitSetting(name, list[(size_t)(((i + dir) % n + n) % n)]);
            }
            else if (copy.kind == ZS_SETTING_BOOLEAN)
            {
                CommitSetting(name, now == "true" ? "false" : "true");
            }
        };
        // Enter: into the value, with its text selected, so that a number
        // typed replaces it.
        auto activate = [editor, nudge, kind = info.kind] {
            if (kind == ZS_SETTING_BOOLEAN)
            {
                nudge(1);
                return;
            }
            TextBox box = editor.try_as<TextBox>();
            if (box == nullptr)
                if (auto with_unit = editor.try_as<Grid>(); with_unit != nullptr && with_unit.Children().Size() > 0)
                    box = with_unit.Children().GetAt(0).try_as<TextBox>();
            if (box != nullptr)
            {
                box.Focus(FocusState::Keyboard);
                box.SelectAll();
            }
            else if (auto combo = editor.try_as<ComboBox>())
            {
                combo.Focus(FocusState::Keyboard);
            }
        };
        search_rows.push_back({ node, back, eye, name, nudge, activate });
        SearchList().Children().Append(node);
        if (search_eye == name)
            SetSearchEye(name);
    }

    void MainWindow::AddSearchAction(SearchAction const &action)
    {
        int index = (int)search_rows.size();
        Grid grid;
        grid.ColumnSpacing(12);
        ColumnDefinition text_column, key_column;
        text_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        key_column.Width(GridLengthHelper::Auto());
        grid.ColumnDefinitions().Append(text_column);
        grid.ColumnDefinitions().Append(key_column);
        StackPanel label;
        TextBlock title;
        title.Text(action.label);
        label.Children().Append(title);
        if (!action.hint.empty())
        {
            TextBlock hint;
            hint.Text(action.hint);
            hint.FontSize(12);
            hint.TextWrapping(TextWrapping::Wrap);
            hint.Foreground(TokenBrush(Root(), L"ZsDim"));
            label.Children().Append(hint);
        }
        grid.Children().Append(label);
        if (!action.keys.empty())
        {
            TextBlock keys;
            keys.Text(action.keys);
            keys.FontSize(12);
            keys.VerticalAlignment(VerticalAlignment::Center);
            keys.Foreground(TokenBrush(Root(), L"ZsDim"));
            Grid::SetColumn(keys, 1);
            grid.Children().Append(keys);
        }
        Border back;
        back.CornerRadius(CornerRadiusHelper::FromUniformRadius(9));
        back.Padding(ThicknessHelper::FromLengths(10, 8, 10, 8));
        back.Child(grid);
        ContentControl node;
        node.IsTabStop(true);
        node.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        node.Content(back);
        Automation::AutomationProperties::SetName(node, action.label);
        node.PointerEntered([this, index](auto &&, auto &&) { SelectSearchRow(index, false); });
        std::function<void()> activate = [this, run = action.run] {
            CloseSearch();
            run();
        };
        node.Tapped([activate](auto &&, auto &&) { activate(); });
        search_rows.push_back({ node, back, nullptr, {}, nullptr, activate });
        SearchList().Children().Append(node);
    }

    // The actions of the other apps that this app has. It has no action that
    // starts a print.
    std::vector<MainWindow::SearchAction> MainWindow::SearchActions()
    {
        auto with_printers = [this](auto f) {
            return [this, f] {
                if (printers != nullptr)
                    f(*printers);
            };
        };
        auto place = [this](auto f) {
            return [this, f] {
                if (model != nullptr && zs_app_part_count(model->Active()) > 0)
                {
                    if (!f(model->Active()))
                        ShowToast(L"Not all parts fit on the bed.");
                    PlateEdited();
                }
            };
        };
        std::vector<SearchAction> out;
        out.push_back({ L"Open a model…", L"Ctrl+O", L"", [this] { PickFile(); } });
        out.push_back({ L"Add models to the plate…", L"", L"", [this] { PickFile(); } });
        out.push_back({ L"Export G-code…", L"Ctrl+E", L"", with_printers([](PrintersUi &p) { p.ExportGcode(); }) });
        out.push_back({ L"Save the project…", L"Ctrl+S", L"all plates in one 3MF file", with_printers([](PrintersUi &p) { p.SaveProject(); }) });
        out.push_back({ L"Upload to the printer", L"", L"send the G-code to the printer, and do not start it", with_printers([](PrintersUi &p) { p.PrimaryAction(); }) });
        out.push_back({ L"Arrange the plate", L"", L"pack the parts on the bed", place([](zs_app *a) { return zs_app_plate_arrange(a) != 0; }) });
        out.push_back({ L"Smart placement", L"", L"turn and arrange the parts", place([](zs_app *a) { return zs_app_plate_smart_place(a) != 0; }) });
        out.push_back({ L"Remove this plate", L"", L"the plate and its parts", [this] {
                           if (model != nullptr && model->RemovePlate(model->ActivePlate()))
                               ShowPlate();
                       } });
        out.push_back({ L"Check the print", L"", L"problems and advice", [this] { check_flyout.ShowAt(ToolStrip()); } });
        out.push_back({ L"Label tool", L"E", L"text and marks on the surface of a part, in another filament", [this] { SetTool(Tool::Label); } });
        out.push_back({ L"Undo", L"Ctrl+Z", L"", [this] {
                           if (model != nullptr)
                           {
                               history_timer.Stop();
                               AfterRestore(model->Undo());
                           }
                       } });
        out.push_back({ L"Redo", L"Ctrl+Shift+Z", L"", [this] {
                           if (model != nullptr)
                           {
                               history_timer.Stop();
                               AfterRestore(model->Redo());
                           }
                       } });
        out.push_back({ L"2D layer view", L"2", L"", [this] { Set2D(true); } });
        out.push_back({ L"3D view", L"3", L"", [this] { Set2D(false); } });
        out.push_back({ L"Manage printers…", L"Ctrl+,", L"preferences, connections, API keys", [this] { ShowPreferences(); } });
        out.push_back({ L"Compare with Cura…", L"", L"", [this] { ShowCuraCompare(); } });
        std::wstring project_name = ProjectName();
        out.push_back({ project_name.empty() ? L"Open a project" : L"The project", L"",
                        project_name.empty() ? L"printdeck.yml from GitHub or a folder" : project_name, [this] { ShowProjectDialog(); } });
        if (!project_name.empty())
            out.push_back({ L"Close the project", L"", project_name + L": its plates stay", [this] { CloseProject(); } });
        out.push_back({ L"History", L"", L"the changes, undo one change", [this] { HistoryFlyout().ShowAt(HistoryButton()); } });
        out.push_back({ L"Keyboard shortcuts", L"?", L"", [this] { ShowShortcuts(); } });
        out.push_back({ L"All settings", L"N", L"the panel of the settings", [this] { ShowSettingsPane(true); } });
        out.push_back({ L"Printers", L"", L"your printers, their jobs, and the plates to print", with_printers([](PrintersUi &p) { p.ShowPage(true); }) });
        return out;
    }

    void MainWindow::SetSearchEye(std::string const &name)
    {
        search_eye = name;
        for (auto const &row : search_rows)
        {
            if (row.eye == nullptr)
                continue;
            bool on = row.name == name && !name.empty();
            row.eye.Opacity(on ? 1 : 0.45);
            row.eye.Background(on ? TokenBrush(Root(), L"ZsAccent") : Media::Brush(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent())));
            if (auto path = row.eye.Content().try_as<Shapes::Path>())
                path.Stroke(on ? Media::Brush(Media::SolidColorBrush(Microsoft::UI::Colors::White())) : TokenBrush(Root(), L"ZsFg"));
        }
        ApplySearchEye();
    }

    // The view shows only the lines of the setting with its eye on. The
    // focus goes on again after each new slice.
    void MainWindow::ApplySearchEye()
    {
        if (view == nullptr || model == nullptr)
            return;
        if (search_eye.empty())
        {
            if (!search_eye_set)
                return;
            search_eye_set = false;
            zs_view_focus(view, 0, -1);
            SupportRefocus();
            RequestDraw();
            return;
        }
        zs_setting_effect effect{};
        if (zs_setting_get_effect(search_eye.c_str(), &effect) != ZS_OK)
            return;
        uint32_t mask = effect.features != 0 ? effect.features : (1u << ZS_FEATURE_COUNT) - 1;
        double zmax = -1;
        zs_toolpaths paths{};
        if (effect.first_layer_only != 0 && zs_app_toolpaths(model->Active(), &paths) == ZS_OK && paths.layer_count > 0)
            zmax = paths.layer_z[0];
        zs_view_focus(view, mask, zmax);
        search_eye_set = true;
        RequestDraw();
    }

    void MainWindow::RefreshSearchValues()
    {
        for (auto &editor : search_editors)
            editor.refresh();
    }

    void MainWindow::FlushSearchDrag()
    {
        if (search_timer != nullptr)
            search_timer.Stop();
        if (!search_pending)
            return;
        auto run = std::move(search_pending);
        search_pending = nullptr;
        search_sent = std::chrono::steady_clock::now();
        run();
    }
}
