// The printer picker: the first start and "Add a printer".
//
// Step 1 picks a model of the printer library, by search or by brand, or a
// printer that the search of the network found. Step 2 sets the name, the
// nozzle, the filament, the bed, and the connection. The core has the library
// and the search. It follows linux/src/ui/printer-picker.c.
//
// See MainWindow.Printers.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.Printers.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Media = Microsoft::UI::Xaml::Media;
namespace Shapes = Microsoft::UI::Xaml::Shapes;
using Windows::Foundation::IInspectable;
using Windows::Foundation::Point;

namespace winrt::ZSlice::implementation
{
    using namespace ui;

    namespace
    {
        // The kinds of the connection list, in its order.
        zs::LinkKind const link_order[] = {
            zs::LinkKind::None, zs::LinkKind::Printdeck, zs::LinkKind::OctoPrint,
            zs::LinkKind::Moonraker, zs::LinkKind::PrusaLink, zs::LinkKind::Bambu,
        };

        int LinkIndex(zs::LinkKind kind)
        {
            for (int i = 0; i < (int)std::size(link_order); i++)
                if (link_order[i] == kind)
                    return i;
            return 0;
        }

        zs::LinkKind KindOfFound(int kind)
        {
            switch (kind)
            {
            case ZS_FOUND_PRINTDECK:
                return zs::LinkKind::Printdeck;
            case ZS_FOUND_MOONRAKER:
                return zs::LinkKind::Moonraker;
            case ZS_FOUND_PRUSALINK:
                return zs::LinkKind::PrusaLink;
            case ZS_FOUND_BAMBU:
                return zs::LinkKind::Bambu;
            default:
                return zs::LinkKind::OctoPrint;
            }
        }

        std::string TextOf(int (*fn)(zs_printers const *, size_t, char *, size_t, size_t *), zs_printers const *lib, size_t i)
        {
            size_t n = 0;
            if (fn(lib, i, nullptr, 0, &n) != ZS_OK)
                return {};
            std::string text(n + 1, '\0');
            if (fn(lib, i, text.data(), text.size(), &n) != ZS_OK)
                return {};
            text.resize(n);
            return text;
        }

        // The build volume, in a small isometric drawing to scale.
        void DrawVolume(Canvas const &canvas, double x, double y, double z)
        {
            canvas.Children().Clear();
            double width = canvas.Width(), height = canvas.Height();
            if (x <= 0 || y <= 0 || z <= 0)
                return;
            double c = 0.866, s = 0.5;
            double span_x = (x + y) * c, span_y = (x + y) * s + z;
            double k = std::min((width - 12) / span_x, (height - 12) / span_y);
            double ox = 6 + y * c * k + (width - 12 - span_x * k) / 2;
            double oy = height - 6 - (height - 12 - span_y * k) / 2;
            auto at = [&](double px, double py, double pz) {
                return Point{ (float)(ox + (px - py) * c * k), (float)(oy - (px + py) * s * k - pz * k) };
            };
            auto stroke = ThemeBrush(L"TextFillColorSecondaryBrush");
            auto poly = [&](std::initializer_list<Point> points, bool fill) {
                Shapes::Polygon shape;
                Media::PointCollection list;
                for (auto const &p : points)
                    list.Append(p);
                shape.Points(list);
                shape.Stroke(stroke);
                shape.StrokeThickness(1);
                if (fill)
                    shape.Fill(ThemeBrush(L"AccentFillColorDisabledBrush"));
                canvas.Children().Append(shape);
            };
            poly({ at(0, 0, 0), at(x, 0, 0), at(x, y, 0), at(0, y, 0) }, true);
            poly({ at(0, y, 0), at(x, y, 0), at(x, y, z), at(0, y, z) }, false);
            poly({ at(x, 0, 0), at(x, y, 0), at(x, y, z), at(x, 0, z) }, false);
            poly({ at(0, 0, z), at(x, 0, z), at(x, y, z), at(0, y, z) }, false);
            // The red dot is X0 Y0 of the G-code.
            Shapes::Ellipse dot;
            dot.Width(7);
            dot.Height(7);
            dot.Fill(Media::SolidColorBrush(Windows::UI::Color{ 255, 217, 48, 37 }));
            Point o = at(0, 0, 0);
            Canvas::SetLeft(dot, o.X - 3.5);
            Canvas::SetTop(dot, o.Y - 3.5);
            canvas.Children().Append(dot);
        }

        struct PickerState
        {
            bool welcome = false;
            zs_printers *lib = nullptr;
            // -1: none yet. -2: "My printer is not in the list".
            ptrdiff_t current = -1;
            // -2: the popular printers, -1: all brands.
            ptrdiff_t brand = -1;
            // The row of brand 0 in the list.
            int brand_offset = 1;
            std::vector<ptrdiff_t> shown;
            std::vector<zs::FoundPrinter> found;
            int link = -1;
            bool searching = false;
            bool filling = false;
            std::shared_ptr<zs::PrinterSearch> search;
            zs::http::CancelPtr test_cancel;
            std::string read_pin;
            std::shared_ptr<OverlayPanel> panel;

            Grid choose{ nullptr }, setup{ nullptr };
            TextBox query{ nullptr };
            ListView brands{ nullptr }, models{ nullptr }, network{ nullptr };
            TextBlock card_title{ nullptr }, card_facts{ nullptr }, card_sources{ nullptr }, hint{ nullptr }, net_state{ nullptr };
            Canvas volume{ nullptr };
            Button rescan{ nullptr }, next{ nullptr }, back{ nullptr }, test{ nullptr }, read_serial{ nullptr };
            TextBox name{ nullptr }, url{ nullptr }, serial{ nullptr };
            PasswordBox key{ nullptr };
            ComboBox nozzle{ nullptr }, filament{ nullptr }, kind{ nullptr };
            NumberBox bed_x{ nullptr }, bed_y{ nullptr }, bed_z{ nullptr };
            bool filling_bed = false;
            StackPanel url_row{ nullptr }, key_row{ nullptr }, serial_row{ nullptr };
            TextBlock key_label{ nullptr }, test_result{ nullptr }, summary{ nullptr };
            std::vector<double> nozzles;

            bool GetModel(ptrdiff_t i, zs_printer_model &m) const
            {
                return lib != nullptr && i >= 0 && zs_printers_model_get(lib, (size_t)i, &m) == ZS_OK;
            }

            void UpdateCard()
            {
                zs_printer_model m{};
                if (GetModel(current, m))
                {
                    card_title.Text(zs::ToWide(m.title));
                    card_facts.Text(zs::ToWide(TextOf(zs_printers_facts, lib, (size_t)current)));
                    std::string from = TextOf(zs_printers_sources, lib, (size_t)current);
                    card_sources.Text(from.empty() ? L"" : L"From " + zs::ToWide(from));
                    DrawVolume(volume, m.bed_x, m.round ? m.bed_x : m.bed_y, m.height);
                }
                else if (current == -2)
                {
                    card_title.Text(L"My printer is not in the list");
                    card_facts.Text(L"Enter its size in the next step.");
                    card_sources.Text(L"");
                    DrawVolume(volume, 220, 220, 250);
                }
                else
                {
                    card_title.Text(L"Pick a printer");
                    card_facts.Text(L"Type a part of a name, or pick a brand.");
                    card_sources.Text(L"");
                    volume.Children().Clear();
                }
                next.IsEnabled(current != -1);
            }

            void FillModels()
            {
                filling = true;
                std::wstring text{ query.Text() };
                std::string q = zs::ToUtf8(text);
                std::vector<uint32_t> found;
                if (lib != nullptr)
                {
                    size_t total = 0;
                    if (q.empty() && brand == -2)
                    {
                        found.resize(64);
                        total = zs_printers_popular(lib, found.data(), found.size());
                        found.resize(std::min(total, found.size()));
                    }
                    else
                    {
                        ptrdiff_t in_brand = std::max<ptrdiff_t>(brand, -1);
                        total = zs_printers_search(lib, q.c_str(), in_brand, nullptr, 0);
                        found.resize(total);
                        if (total > 0)
                            total = zs_printers_search(lib, q.c_str(), in_brand, found.data(), found.size());
                        found.resize(std::min(total, found.size()));
                    }
                }
                shown.clear();
                auto items = single_threaded_vector<IInspectable>();
                int select = -1;
                for (uint32_t i : found)
                {
                    zs_printer_model m{};
                    if (zs_printers_model_get(lib, i, &m) != ZS_OK)
                        continue;
                    if ((ptrdiff_t)i == current)
                        select = (int)shown.size();
                    shown.push_back((ptrdiff_t)i);
                    items.Append(box_value(zs::ToWide(brand >= 0 ? m.name : m.title)));
                }
                if (current == -2)
                    select = (int)shown.size();
                shown.push_back(-2);
                items.Append(box_value(L"My printer is not in the list"));
                models.ItemsSource(items);
                models.SelectedIndex(select);
                filling = false;
            }

            void ShowModel(ptrdiff_t i)
            {
                zs_printer_model m{};
                if (!GetModel(i, m))
                    return;
                current = i;
                brand = (ptrdiff_t)m.brand_index;
                filling = true;
                query.Text(L"");
                brands.SelectedIndex((int)brand + brand_offset);
                filling = false;
                FillModels();
                UpdateCard();
                if (models.SelectedItem() != nullptr)
                    models.ScrollIntoView(models.SelectedItem());
            }

            void PickFound(int i)
            {
                if (i < 0 || i >= (int)found.size())
                    return;
                link = i;
                zs::FoundPrinter const &f = found[(size_t)i];
                std::string joined = f.model + " " + f.name + " " + f.host;
                ptrdiff_t m = lib != nullptr ? zs_printers_match(lib, (f.model.empty() ? joined : f.model).c_str(), f.bed_x, f.bed_y, f.height) : -1;
                if (m < 0 && !f.model.empty() && lib != nullptr)
                    m = zs_printers_match(lib, joined.c_str(), f.bed_x, f.bed_y, f.height);
                std::wstring who = zs::ToWide(f.kind_title) + L" at " + zs::ToWide(f.address);
                if (m >= 0)
                {
                    ShowModel(m);
                    zs_printer_model pm{};
                    GetModel(m, pm);
                    hint.Text(who + L" is a " + zs::ToWide(pm.title) + L". Check the model, then go on.");
                }
                else
                {
                    hint.Text(L"zslice connects to the " + who + L". Now pick its model.");
                    query.Focus(FocusState::Programmatic);
                }
                hint.Visibility(Visibility::Visible);
            }

            void FillFound()
            {
                int selected = network.SelectedIndex();
                filling = true;
                auto items = single_threaded_vector<IInspectable>();
                for (auto const &f : found)
                    items.Append(box_value(zs::ToWide(f.name) + L"  ·  " + zs::ToWide(f.kind_title) + L" · " + zs::ToWide(f.address)));
                network.ItemsSource(items);
                if (selected >= 0 && selected < (int)found.size())
                    network.SelectedIndex(selected);
                network.Visibility(found.empty() ? Visibility::Collapsed : Visibility::Visible);
                filling = false;
                net_state.Text(searching ? (found.empty() ? L"Searching the network…" : L"Searching…")
                                         : (found.empty() ? L"No printer answered. Enter its address in the next step." : L""));
                rescan.IsEnabled(!searching);
            }

            zs::LinkKind Kind() const
            {
                int i = kind.SelectedIndex();
                return i >= 0 && i < (int)std::size(link_order) ? link_order[i] : zs::LinkKind::None;
            }

            void KindChanged()
            {
                zs::LinkKind k = Kind();
                bool net = k != zs::LinkKind::None;
                bool bambu = k == zs::LinkKind::Bambu;
                url_row.Visibility(net ? Visibility::Visible : Visibility::Collapsed);
                key_row.Visibility(net && k != zs::LinkKind::Moonraker ? Visibility::Visible : Visibility::Collapsed);
                serial_row.Visibility(bambu ? Visibility::Visible : Visibility::Collapsed);
                key_label.Text(bambu ? L"Access code" : L"API key");
                url.PlaceholderText(bambu ? L"The IP address of the printer" : L"http://printer.local");
                test.Visibility(net && !bambu ? Visibility::Visible : Visibility::Collapsed);
                test_result.Text(L"");
            }

            void GoSetup()
            {
                if (current == -1)
                    return;
                zs_printer_model m{};
                bool have = GetModel(current, m);
                name.Text(have ? zs::ToWide(m.title) : L"My printer");
                summary.Text(have ? zs::ToWide(TextOf(zs_printers_facts, lib, (size_t)current)) : L"The generic printer of zslice");
                // The nozzles of the model, with its default chosen.
                nozzles.clear();
                nozzle.Items().Clear();
                std::string list = have && m.nozzles[0] != 0 ? m.nozzles : "0.2;0.25;0.3;0.4;0.5;0.6;0.8;1";
                double want = have ? m.nozzle : 0.4;
                int chosen = 0;
                size_t at = 0;
                while (at <= list.size())
                {
                    size_t end = list.find(';', at);
                    if (end == std::string::npos)
                        end = list.size();
                    std::string part = list.substr(at, end - at);
                    at = end + 1;
                    if (part.empty())
                        continue;
                    double v = atof(part.c_str());
                    if (std::abs(v - want) < 1e-6)
                        chosen = (int)nozzles.size();
                    nozzles.push_back(v);
                    nozzle.Items().Append(box_value(zs::ToWide(part) + L" mm"));
                }
                nozzle.SelectedIndex(chosen);
                filament.SelectedIndex(have && m.filament > 2.2 ? 1 : 0);
                // The size of a profile stays exact. Only an edit rounds.
                filling_bed = true;
                bed_x.Value(have ? m.bed_x : 220);
                bed_y.Value(have ? (m.round ? m.bed_x : m.bed_y) : 220);
                bed_z.Value(have ? m.height : 250);
                filling_bed = false;
                bed_y.IsEnabled(!(have && m.round));
                // The connection: from the printer on the network, if one
                // was picked.
                if (link >= 0 && link < (int)found.size())
                {
                    zs::FoundPrinter const &f = found[(size_t)link];
                    zs::LinkKind k = KindOfFound(f.kind);
                    kind.SelectedIndex(LinkIndex(k));
                    url.Text(zs::ToWide(k == zs::LinkKind::Bambu ? f.address : f.url));
                    serial.Text(zs::ToWide(f.serial));
                }
                KindChanged();
                choose.Visibility(Visibility::Collapsed);
                setup.Visibility(Visibility::Visible);
                back.Visibility(Visibility::Visible);
                next.Content(box_value(L"Add printer"));
                name.Focus(FocusState::Programmatic);
            }

            void GoChoose()
            {
                setup.Visibility(Visibility::Collapsed);
                choose.Visibility(Visibility::Visible);
                back.Visibility(Visibility::Collapsed);
                next.Content(box_value(L"Next"));
            }
        };

        TextBlock FormLabel(wchar_t const *text)
        {
            TextBlock t = Label(text, 13);
            t.Width(110);
            t.VerticalAlignment(VerticalAlignment::Center);
            return t;
        }

        StackPanel FormRow(wchar_t const *label, FrameworkElement const &control, TextBlock *out = nullptr)
        {
            StackPanel row = Row(8);
            TextBlock t = FormLabel(label);
            if (out != nullptr)
                *out = t;
            row.Children().Append(t);
            row.Children().Append(control);
            return row;
        }

        NumberBox BedBox(wchar_t const *name)
        {
            NumberBox b;
            b.Minimum(10);
            b.Maximum(2000);
            b.SmallChange(1);
            b.Width(92);
            Name(b, name);
            return b;
        }

        ColumnDefinition FixedColumn(double width)
        {
            ColumnDefinition c;
            c.Width(GridLengthHelper::FromPixels(width));
            return c;
        }

        ColumnDefinition StarColumn()
        {
            ColumnDefinition c;
            c.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            return c;
        }

        RowDefinition AutoRow()
        {
            RowDefinition r;
            r.Height(GridLengthHelper::Auto());
            return r;
        }

        RowDefinition StarRow()
        {
            RowDefinition r;
            r.Height(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            return r;
        }
    }

    void MainWindow::PrintersUi::ShowPicker(bool welcome)
    {
        auto p = std::make_shared<PickerState>();
        p->welcome = welcome;
        p->lib = w.model->Printers();

        Grid body;
        body.Padding(ThicknessHelper::FromLengths(16, 4, 16, 14));
        body.RowSpacing(10);
        body.RowDefinitions().Append(StarRow());
        body.RowDefinitions().Append(AutoRow());

        // ---- step 1 ----
        p->choose = Grid();
        p->choose.ColumnSpacing(12);
        p->choose.ColumnDefinitions().Append(FixedColumn(190));
        p->choose.ColumnDefinitions().Append(StarColumn());
        p->choose.ColumnDefinitions().Append(FixedColumn(300));

        p->brands = ListView();
        Name(p->brands, L"Brands");
        auto brand_items = single_threaded_vector<IInspectable>();
        // A row: the name, and how many printers it has.
        auto brand_row = [this](std::wstring const &text, size_t count) {
            Grid row;
            row.ColumnSpacing(8);
            ColumnDefinition name_column, count_column;
            name_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            count_column.Width(GridLengthHelper::Auto());
            row.ColumnDefinitions().Append(name_column);
            row.ColumnDefinitions().Append(count_column);
            TextBlock name;
            name.Text(text);
            name.TextWrapping(TextWrapping::WrapWholeWords);
            name.VerticalAlignment(VerticalAlignment::Center);
            TextBlock number;
            number.Text(std::to_wstring(count));
            number.FontSize(12);
            number.Opacity(0.65);
            number.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(number, 1);
            row.Children().Append(name);
            row.Children().Append(number);
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(row, text);
            return row;
        };
        p->brands.ItemContainerStyle(Markup::XamlReader::Load(L"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='ListViewItem'><Setter Property='HorizontalContentAlignment' Value='Stretch'/></Style>").as<Style>());
        uint32_t popular[64];
        size_t popular_count = p->lib != nullptr ? zs_printers_popular(p->lib, popular, ARRAYSIZE(popular)) : 0;
        if (popular_count > 0)
        {
            brand_items.Append(brand_row(L"Popular", popular_count));
            p->brand = -2;
            p->brand_offset = 2;
        }
        brand_items.Append(brand_row(L"All brands", p->lib != nullptr ? zs_printers_model_count(p->lib) : 0));
        size_t brand_count = p->lib != nullptr ? zs_printers_brand_count(p->lib) : 0;
        for (size_t i = 0; i < brand_count; i++)
        {
            char const *name = nullptr;
            size_t first = 0, end = 0;
            if (zs_printers_brand_get(p->lib, i, &name, &first, &end) == ZS_OK)
                brand_items.Append(brand_row(zs::ToWide(name), end - first));
        }
        p->brands.ItemsSource(brand_items);
        p->brands.SelectedIndex(0);
        p->choose.Children().Append(p->brands);

        Grid center;
        center.RowSpacing(8);
        center.RowDefinitions().Append(AutoRow());
        center.RowDefinitions().Append(AutoRow());
        center.RowDefinitions().Append(StarRow());
        Grid::SetColumn(center, 1);
        p->query = TextBox();
        p->query.PlaceholderText(L"Search 1000+ printers: “ender 3”, “mk4”, “voron”");
        Name(p->query, L"Search the printers");
        center.Children().Append(p->query);
        p->hint = Label(L"", 12, false, true);
        p->hint.Visibility(Visibility::Collapsed);
        Grid::SetRow(p->hint, 1);
        center.Children().Append(p->hint);
        p->models = ListView();
        Name(p->models, L"Printers");
        Grid::SetRow(p->models, 2);
        center.Children().Append(p->models);
        p->choose.Children().Append(center);

        StackPanel side = Column(6);
        Grid::SetColumn(side, 2);
        p->volume = Canvas();
        p->volume.Width(280);
        p->volume.Height(170);
        side.Children().Append(p->volume);
        p->card_title = Label(L"", 15, true);
        p->card_facts = Label(L"", 12);
        p->card_sources = Label(L"", 11, false, true);
        side.Children().Append(p->card_title);
        side.Children().Append(p->card_facts);
        side.Children().Append(p->card_sources);
        StackPanel net_head = Row(8);
        net_head.Margin(ThicknessHelper::FromLengths(0, 8, 0, 0));
        TextBlock net_title = Label(L"On your network", 12, true, true);
        net_title.VerticalAlignment(VerticalAlignment::Center);
        net_head.Children().Append(net_title);
        p->rescan = TextButton(L"Search again");
        net_head.Children().Append(p->rescan);
        side.Children().Append(net_head);
        p->net_state = Label(L"", 12, false, true);
        side.Children().Append(p->net_state);
        p->network = ListView();
        Name(p->network, L"Printers on the network");
        p->network.MaxHeight(170);
        p->network.Visibility(Visibility::Collapsed);
        side.Children().Append(p->network);
        p->choose.Children().Append(side);
        body.Children().Append(p->choose);

        // ---- step 2 ----
        p->setup = Grid();
        p->setup.Visibility(Visibility::Collapsed);
        ScrollViewer form_scroll;
        form_scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        StackPanel form = Column(10);
        form.Padding(ThicknessHelper::FromLengths(0, 0, 14, 0));
        p->summary = Label(L"", 12, false, true);
        form.Children().Append(p->summary);
        p->name = TextBox();
        p->name.Width(360);
        Name(p->name, L"The name of the printer");
        form.Children().Append(FormRow(L"Name", p->name));
        p->nozzle = ComboBox();
        p->nozzle.Width(120);
        Name(p->nozzle, L"Nozzle");
        form.Children().Append(FormRow(L"Nozzle", p->nozzle));
        p->filament = ComboBox();
        p->filament.Width(120);
        Name(p->filament, L"Filament diameter");
        p->filament.Items().Append(box_value(L"1.75 mm"));
        p->filament.Items().Append(box_value(L"2.85 mm"));
        form.Children().Append(FormRow(L"Filament", p->filament));
        p->bed_x = BedBox(L"Bed width");
        p->bed_y = BedBox(L"Bed depth");
        p->bed_z = BedBox(L"Height");
        StackPanel bed = Row(6);
        bed.Children().Append(p->bed_x);
        bed.Children().Append(p->bed_y);
        bed.Children().Append(p->bed_z);
        TextBlock mm = Label(L"mm", 12, false, true);
        mm.VerticalAlignment(VerticalAlignment::Center);
        bed.Children().Append(mm);
        form.Children().Append(FormRow(L"Build volume", bed));
        TextBlock bed_note = Label(L"Change the size only if your printer differs from the profile.", 12, false, true);
        bed_note.TextWrapping(TextWrapping::Wrap);
        bed_note.MaxWidth(360);
        form.Children().Append(FormRow(L"", bed_note));
        p->kind = ComboBox();
        p->kind.Width(240);
        Name(p->kind, L"Connection");
        for (auto k : link_order)
            p->kind.Items().Append(box_value(zs::ToWide(zs::LinkTitle(k))));
        p->kind.SelectedIndex(0);
        form.Children().Append(FormRow(L"Connection", p->kind));
        p->url = TextBox();
        p->url.Width(360);
        Name(p->url, L"The address of the printer");
        p->url_row = FormRow(L"Address", p->url);
        form.Children().Append(p->url_row);
        p->serial = TextBox();
        p->serial.Width(240);
        Name(p->serial, L"The serial number");
        p->read_serial = TextButton(L"Read");
        ToolTipService::SetToolTip(p->read_serial, box_value(L"Read the serial number from the printer, and trust its certificate"));
        StackPanel serial_line = Row(6);
        serial_line.Children().Append(p->serial);
        serial_line.Children().Append(p->read_serial);
        p->serial_row = FormRow(L"Serial number", serial_line);
        form.Children().Append(p->serial_row);
        p->key = PasswordBox();
        p->key.Width(360);
        Name(p->key, L"The key of the printer");
        p->key_row = FormRow(L"API key", p->key, &p->key_label);
        form.Children().Append(p->key_row);
        StackPanel test_line = Row(8);
        p->test = TextButton(L"Test the connection");
        p->test_result = Label(L"", 12);
        p->test_result.MaxWidth(420);
        p->test_result.VerticalAlignment(VerticalAlignment::Center);
        test_line.Children().Append(p->test);
        test_line.Children().Append(p->test_result);
        form.Children().Append(test_line);
        form_scroll.Content(form);
        p->setup.Children().Append(form_scroll);
        body.Children().Append(p->setup);

        // ---- the buttons ----
        StackPanel buttons = Row();
        buttons.HorizontalAlignment(HorizontalAlignment::Right);
        Grid::SetRow(buttons, 1);
        Button cancel = TextButton(welcome ? L"Skip" : L"Cancel");
        if (welcome)
            ToolTipService::SetToolTip(cancel, box_value(L"Use the generic printer. Add your printer later from the printer menu."));
        p->back = TextButton(L"Back");
        p->back.Visibility(Visibility::Collapsed);
        p->next = TextButton(L"Next", true);
        buttons.Children().Append(cancel);
        buttons.Children().Append(p->back);
        buttons.Children().Append(p->next);
        body.Children().Append(buttons);

        p->panel = OpenPanel(welcome ? L"Welcome to zslice: set up your printer" : L"Add a printer", 1040, 680, body);
        std::weak_ptr<PickerState> weak = p;
        auto panel = p->panel;
        panel->closed = [p, welcome] {
            // The welcome that ends, by Esc or ×, is no first start any more.
            if (welcome)
                zs::Printers().SetFirstStart(false);
            if (p->test_cancel != nullptr)
                p->test_cancel->Stop();
            // The search joins its threads, so it ends off the UI thread.
            Retire(p->search);
            p->panel = nullptr;
        };

        // Esc in the second step goes back to the list.
        panel->escape = [weak] {
            auto s = weak.lock();
            if (s == nullptr || s->back.Visibility() != Visibility::Visible)
                return false;
            s->GoChoose();
            return true;
        };

        // ---- events ----
        for (NumberBox const &box : { p->bed_x, p->bed_y, p->bed_z })
            box.ValueChanged([weak](NumberBox const &self, NumberBoxValueChangedEventArgs const &e) {
                auto s = weak.lock();
                double v = e.NewValue();
                if (s != nullptr && !s->filling_bed && !std::isnan(v) && v != std::round(v))
                    self.Value(std::round(v));
            });
        p->query.TextChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            s->FillModels();
        });
        p->brands.SelectionChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            s->brand = s->brands.SelectedIndex() - s->brand_offset;
            s->FillModels();
        });
        p->models.SelectionChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            int i = s->models.SelectedIndex();
            if (i >= 0 && i < (int)s->shown.size())
            {
                s->current = s->shown[(size_t)i];
                s->UpdateCard();
            }
        });
        p->models.DoubleTapped([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
                s->GoSetup();
        });
        p->network.SelectionChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->filling)
                return;
            s->PickFound(s->network.SelectedIndex());
        });
        p->kind.SelectionChanged([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
                s->KindChanged();
        });
        p->back.Click([weak](auto &&, auto &&) {
            if (auto s = weak.lock())
                s->GoChoose();
        });
        cancel.Click([this, panel](auto &&, auto &&) {
            zs::Printers().SetFirstStart(false);
            ClosePanel(panel);
        });
        p->test.Click([this, weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr)
                return;
            zs::link::Target target;
            target.id = "test";
            target.name = "test";
            target.kind = s->Kind();
            target.url = zs::ToUtf8(std::wstring(s->url.Text()));
            target.api_key = zs::ToUtf8(std::wstring(s->key.Password()));
            if (s->test_cancel != nullptr)
                s->test_cancel->Stop();
            s->test_cancel = std::make_shared<zs::http::Cancel>();
            s->test_result.Text(L"Connecting…");
            s->test.IsEnabled(false);
            auto cancel_token = s->test_cancel;
            struct Result
            {
                bool ok = false;
                zs::link::Snapshot status;
                std::string error;
            };
            Async(
                [target, cancel_token] {
                    Result r;
                    r.ok = zs::link::ReadStatus(target, cancel_token, r.status, r.error);
                    return r;
                },
                [weak, cancel_token](PrintersUi &, Result &r) {
                    auto s = weak.lock();
                    if (s == nullptr || cancel_token->Stopped())
                        return;
                    s->test.IsEnabled(true);
                    if (!r.ok)
                    {
                        s->test_result.Text(L"No answer: " + zs::ToWide(r.error));
                        return;
                    }
                    std::wstring text = L"Connected";
                    if (!r.status.state.empty())
                        text += L": " + zs::ToWide(r.status.state);
                    text += L".";
                    if (r.status.bed_x > 0)
                    {
                        wchar_t bed[64];
                        swprintf_s(bed, L" The printer has a bed of %.0f × %.0f mm.", r.status.bed_x, r.status.bed_y);
                        text += bed;
                    }
                    s->test_result.Text(text);
                });
        });
        p->read_serial.Click([this, weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr)
                return;
            std::string address = zs::ToUtf8(std::wstring(s->url.Text()));
            if (address.empty())
            {
                s->test_result.Text(L"Set the IP address of the printer.");
                return;
            }
            s->read_serial.IsEnabled(false);
            s->test_result.Text(L"Reading the printer…");
            struct Result
            {
                bool ok = false;
                std::string serial, pin, error;
            };
            Async(
                [address] {
                    Result r;
                    r.ok = zs::ReadBambuSerial(address, r.serial, r.pin, r.error);
                    return r;
                },
                [weak](PrintersUi &, Result &r) {
                    auto s = weak.lock();
                    if (s == nullptr)
                        return;
                    s->read_serial.IsEnabled(true);
                    if (!r.ok)
                    {
                        s->test_result.Text(zs::ToWide(r.error));
                        return;
                    }
                    s->serial.Text(zs::ToWide(r.serial));
                    s->read_pin = r.pin;
                    s->test_result.Text(L"zslice trusts the certificate of this printer now.");
                });
        });
        p->rescan.Click([this, weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr || s->search == nullptr)
                return;
            s->searching = true;
            s->FillFound();
            // A restart joins the last search, so it runs off the UI thread.
            // The worker holds the search and no XAML object.
            Async(
                [search = s->search] {
                    search->Restart();
                    return 0;
                },
                [](PrintersUi &, int &) {});
        });
        p->next.Click([this, weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s == nullptr)
                return;
            if (s->choose.Visibility() == Visibility::Visible)
            {
                s->GoSetup();
                return;
            }
            zs::NewPrinter in;
            in.name = zs::ToUtf8(std::wstring(s->name.Text()));
            in.model = s->current >= 0 ? s->current : -1;
            int nz = s->nozzle.SelectedIndex();
            in.nozzle = nz >= 0 && nz < (int)s->nozzles.size() ? s->nozzles[(size_t)nz] : 0;
            in.bed_x = s->bed_x.Value();
            in.bed_y = s->bed_y.Value();
            in.height = s->bed_z.Value();
            in.filament = s->filament.SelectedIndex() == 1 ? 2.85 : 1.75;
            in.kind = s->Kind();
            if (in.kind != zs::LinkKind::None)
                in.url = zs::ToUtf8(std::wstring(s->url.Text()));
            if (in.kind != zs::LinkKind::None && in.kind != zs::LinkKind::Moonraker)
                in.api_key = zs::ToUtf8(std::wstring(s->key.Password()));
            if (in.kind == zs::LinkKind::Bambu)
            {
                in.serial = zs::ToUtf8(std::wstring(s->serial.Text()));
                in.tls_pin = s->read_pin;
            }
            std::string id, message;
            if (!setup.AddNewPrinter(in, s->welcome, id, message))
            {
                s->test_result.Text(zs::ToWide(message));
                zs::state::Wipe(in.api_key);
                return;
            }
            zs::state::Wipe(in.api_key);
            bool pair = (in.kind == zs::LinkKind::Printdeck || in.kind == zs::LinkKind::OctoPrint || in.kind == zs::LinkKind::PrusaLink) &&
                        !in.url.empty() && zs::Printers().Find(id)->api_key.empty();
            ClosePanel(s->panel);
            w.RefreshSettingValues();
            w.ShowPlate();
            RefreshBar();
            RebuildTiles();
            if (pair)
                ShowPair(id, false, [](bool) {});
        });

        p->FillModels();
        p->UpdateCard();

        // The search of the network. A test run stays off the network.
        int loopback = 0;
        zs::SearchMode mode = zs::SearchModeOfRun(loopback);
        p->searching = mode != zs::SearchMode::Off;
        Poster post = poster;
        p->FillFound();
        p->search = std::make_shared<zs::PrinterSearch>(mode, loopback, [post, weak](std::vector<zs::FoundPrinter> const &list, bool running) {
            post.Post([weak, list, running](PrintersUi &) {
                auto s = weak.lock();
                if (s == nullptr)
                    return;
                s->found = list;
                s->searching = running;
                s->FillFound();
            });
        });
        p->query.Focus(FocusState::Programmatic);
    }
}
