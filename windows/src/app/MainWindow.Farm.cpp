// The Printers page: a card for each printer with a connection, the plates
// to send, and the list of the printers of the user. It follows
// linux/src/ui/farm-page.c and managePrinters in web/app/app.js.
//
// A card has no Print button. The app uploads a file, and the person starts
// the print on the printer (see zs_printer_link.h).
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
namespace Imaging = Microsoft::UI::Xaml::Media::Imaging;
namespace Streams = Windows::Storage::Streams;
using Windows::Foundation::IInspectable;

namespace winrt::ZSlice::implementation
{
    using namespace ui;

    namespace
    {
        constexpr int every_s = 10;
        wchar_t const *const state_texts[] = { L"Offline", L"Ready", L"Printing", L"Paused", L"Done: clear the bed", L"Failed" };
        wchar_t const *const count_texts[] = { L"offline", L"ready", L"printing", L"paused", L"done", L"failed" };

        bool HasLink(zs::SavedPrinter const &p)
        {
            return p.kind != zs::LinkKind::None;
        }

        bool UsesKey(zs::LinkKind kind)
        {
            return kind == zs::LinkKind::Printdeck || kind == zs::LinkKind::OctoPrint || kind == zs::LinkKind::PrusaLink;
        }

        std::wstring HeatPart(wchar_t const *name, double value, double target)
        {
            wchar_t text[64];
            if (target > 0)
                swprintf_s(text, L"%s %.0f / %.0f °C", name, value, target);
            else
                swprintf_s(text, L"%s %.0f °C", name, value);
            return text;
        }

        // Decodes a JPEG, and shows it. A frame that comes during a decode
        // is dropped by the caller.
        winrt::fire_and_forget ShowJpeg(Image image, std::shared_ptr<std::string> jpeg, std::shared_ptr<std::atomic<bool>> busy)
        {
            try
            {
                Streams::InMemoryRandomAccessStream stream;
                Streams::DataWriter writer(stream);
                writer.WriteBytes(array_view<uint8_t const>(reinterpret_cast<uint8_t const *>(jpeg->data()),
                                                            reinterpret_cast<uint8_t const *>(jpeg->data()) + jpeg->size()));
                co_await writer.StoreAsync();
                writer.DetachStream();
                stream.Seek(0);
                Imaging::BitmapImage bitmap;
                co_await bitmap.SetSourceAsync(stream);
                image.Source(bitmap);
            }
            catch (hresult_error const &)
            {
                // A frame that does not decode is skipped.
            }
            busy->store(false);
        }

        zs::CameraFeed::Frame FrameTo(MainWindow::PrintersUi::Poster const &post, Image image, std::shared_ptr<std::atomic<bool>> busy)
        {
            return [post, image, busy](std::shared_ptr<std::string> const &jpeg) {
                if (busy->exchange(true))
                    return;
                post.Post([image, jpeg, busy](MainWindow::PrintersUi &) { ShowJpeg(image, jpeg, busy); });
            };
        }
    }

    void MainWindow::PrintersUi::BuildPage()
    {
        page = Grid();
        Grid::SetRow(page, 1);
        page.Background(ThemeBrush(L"SolidBackgroundFillColorBaseBrush"));
        page.Visibility(Visibility::Collapsed);
        ScrollViewer scroll;
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        StackPanel box = Column(10);
        box.Padding(ThicknessHelper::FromLengths(16, 12, 16, 16));

        StackPanel head = Row(10);
        head.Children().Append(Label(L"Printers", 20, true));
        counts = Label(L"", 12, false, true);
        counts.VerticalAlignment(VerticalAlignment::Center);
        head.Children().Append(counts);
        Button add = TextButton(L"Add a printer…");
        add.Click([this](auto &&, auto &&) { ShowPicker(false); });
        Button deck = TextButton(L"Connect a printdeck…");
        deck.Click([this](auto &&, auto &&) { ShowConnectDeck(); });
        Button manage = TextButton(L"Manage printers…");
        manage.Click([this](auto &&, auto &&) { ShowManage(); });
        head.Children().Append(add);
        head.Children().Append(deck);
        head.Children().Append(manage);
        box.Children().Append(head);

        page_note = Label(L"", 13, false, true);
        page_note.Visibility(Visibility::Collapsed);
        box.Children().Append(page_note);

        empty_panel = Column(8);
        empty_panel.Visibility(Visibility::Collapsed);
        empty_panel.Children().Append(Label(L"No printer has a connection. Add a printdeck, an OctoPrint, a PrusaLink, a Moonraker (Klipper), or a Bambu Lab (LAN mode) printer to see it here.", 13));
        Button empty_add = TextButton(L"Add a printer…", true);
        empty_add.Click([this](auto &&, auto &&) { ShowPicker(false); });
        empty_panel.Children().Append(empty_add);
        box.Children().Append(empty_panel);

        box.Children().Append(Label(L"Plates to send", 14, true));
        queue_empty = Label(L"Add parts to a plate, and it shows here to send.", 12, false, true);
        box.Children().Append(queue_empty);
        queue_panel = Column(4);
        box.Children().Append(queue_panel);

        tile_grid = VariableSizedWrapGrid();
        tile_grid.Orientation(Orientation::Horizontal);
        tile_grid.ItemWidth(312);
        tile_grid.ItemHeight(420);
        box.Children().Append(tile_grid);
        scroll.Content(box);
        page.Children().Append(scroll);
        w.Root().Children().Append(page);

        page_timer = w.queue.CreateTimer();
        page_timer.Interval(std::chrono::seconds(every_s));
        page_timer.Tick([this](auto &&, auto &&) {
            RefreshTiles();
            RefreshQueue();
        });
    }

    void MainWindow::PrintersUi::ShowPage(bool show)
    {
        page_button.IsChecked(show);
        page.Visibility(show ? Visibility::Visible : Visibility::Collapsed);
        if (show)
        {
            RebuildTiles();
            page_timer.Start();
        }
        else
        {
            page_timer.Stop();
            StopTiles();
            SyncBambuLinks();
        }
    }

    void MainWindow::PrintersUi::StopTiles()
    {
        if (page_cancel != nullptr)
            page_cancel->Stop();
        page_cancel = nullptr;
        for (auto const &tile : tiles)
        {
            tile->alive = false;
            Retire(tile->feed);
        }
        tiles.clear();
        if (tile_grid != nullptr)
            tile_grid.Children().Clear();
    }

    void MainWindow::PrintersUi::RebuildTiles()
    {
        if (page == nullptr || page.Visibility() != Visibility::Visible)
            return;
        StopTiles();
        page_cancel = std::make_shared<zs::http::Cancel>();
        zs::PrinterStore &store = zs::Printers();
        for (size_t i = 0; i < store.Count(); i++)
        {
            zs::SavedPrinter const &printer = store.At(i);
            if (!HasLink(printer))
                continue;
            auto tile = std::make_shared<PrinterTile>();
            tile->id = printer.id;
            Border card;
            card.Margin(ThicknessHelper::FromUniformLength(6));
            card.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
            card.BorderThickness(ThicknessHelper::FromUniformLength(1));
            card.BorderBrush(ThemeBrush(L"CardStrokeColorDefaultBrush"));
            card.Background(ThemeBrush(L"CardBackgroundFillColorDefaultBrush"));
            Name(card, zs::ToWide(printer.name));
            tile->card = card;
            StackPanel stack = Column(0);
            tile->camera = Image();
            tile->camera.Height(160);
            tile->camera.Stretch(Media::Stretch::Uniform);
            tile->camera.Visibility(Visibility::Collapsed);
            Name(tile->camera, L"Show the camera large");
            ToolTipService::SetToolTip(tile->camera, box_value(L"Show the camera large"));
            std::weak_ptr<PrinterTile> weak = tile;
            tile->camera.Tapped([this, weak](auto &&, auto &&) {
                if (auto t = weak.lock())
                    ShowCameraLarge(t);
            });
            stack.Children().Append(tile->camera);

            StackPanel body = Column(5);
            body.Padding(ThicknessHelper::FromLengths(12, 10, 12, 10));
            Grid top;
            ColumnDefinition grow, fit;
            grow.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            fit.Width(GridLengthHelper::Auto());
            top.ColumnDefinitions().Append(grow);
            top.ColumnDefinitions().Append(fit);
            StackPanel who = Column(0);
            who.Children().Append(Label(zs::ToWide(printer.name), 14, true));
            who.Children().Append(Label(zs::ToWide(zs::LinkTitle(printer.kind)), 11, false, true));
            top.Children().Append(who);
            tile->badge = Label(L"Reading", 12, true);
            tile->badge.Margin(ThicknessHelper::FromLengths(8, 0, 0, 0));
            tile->badge.MaxWidth(110);
            Grid::SetColumn(tile->badge, 1);
            top.Children().Append(tile->badge);
            body.Children().Append(top);

            tile->job = Label(L"", 13, true);
            tile->job.Visibility(Visibility::Collapsed);
            tile->bar = ProgressBar();
            tile->bar.Maximum(1);
            tile->bar.Visibility(Visibility::Collapsed);
            tile->facts = Label(L"", 12, false, true);
            tile->facts.Visibility(Visibility::Collapsed);
            tile->why = Label(L"", 12);
            tile->why.Visibility(Visibility::Collapsed);
            tile->heat = Label(L"", 12);
            tile->heat.Visibility(Visibility::Collapsed);
            tile->roll = Label(L"", 12, false, true);
            tile->roll.Visibility(Visibility::Collapsed);
            body.Children().Append(tile->job);
            body.Children().Append(tile->bar);
            body.Children().Append(tile->facts);
            body.Children().Append(tile->why);
            body.Children().Append(tile->heat);
            body.Children().Append(tile->roll);

            StackPanel actions = Row(6);
            actions.Margin(ThicknessHelper::FromLengths(0, 4, 0, 0));
            // The main button uploads. It never starts a print.
            tile->action = TextButton(L"Upload the plate", true);
            tile->action.IsEnabled(false);
            tile->action.Click([this, weak](auto &&, auto &&) {
                auto t = weak.lock();
                if (t == nullptr)
                    return;
                if (t->needs_key)
                {
                    ShowPair(t->id, false, [this](bool ok) {
                        if (ok)
                        {
                            RefreshBar();
                            RebuildTiles();
                        }
                    });
                    return;
                }
                SendPlate(t->id, (size_t)-1);
            });
            actions.Children().Append(tile->action);
            DropDownButton more;
            FontIcon dots;
            dots.Glyph(L"\xE712");
            dots.FontSize(12);
            more.Content(dots);
            Name(more, L"More");
            ToolTipService::SetToolTip(more, box_value(L"More"));
            MenuFlyout menu;
            MenuFlyoutItem show_camera;
            show_camera.Text(L"Show the camera large");
            show_camera.Click([this, weak](auto &&, auto &&) {
                if (auto t = weak.lock())
                    ShowCameraLarge(t);
            });
            menu.Items().Append(show_camera);
            if (printer.kind != zs::LinkKind::Bambu)
            {
                MenuFlyoutItem open;
                open.Text(L"Open the page of the printer");
                std::string id = printer.id;
                open.Click([id](auto &&, auto &&) {
                    zs::SavedPrinter *p = zs::Printers().Find(id);
                    if (p == nullptr)
                        return;
                    std::string url = zs::link::BaseUrl(p->url);
                    // Only a web address opens.
                    if (url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0)
                        ::ShellExecuteW(nullptr, L"open", zs::ToWide(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                });
                menu.Items().Append(open);
            }
            more.Flyout(menu);
            actions.Children().Append(more);
            body.Children().Append(actions);
            stack.Children().Append(body);
            card.Child(stack);

            // A camera plays only while its card is in the visible part of
            // the page.
            card.EffectiveViewportChanged([this, weak](FrameworkElement const &sender, EffectiveViewportChangedEventArgs const &e) {
                auto t = weak.lock();
                if (t == nullptr || !t->alive)
                    return;
                auto v = e.EffectiveViewport();
                bool in = v.Width > 0 && v.Height > 0 && v.Y < sender.ActualHeight() && v.Y + v.Height > 0;
                if (in == t->in_view)
                    return;
                t->in_view = in;
                if (in)
                    StartCamera(t);
                else
                    StopCamera(t);
            });

            tile_grid.Children().Append(card);
            tiles.push_back(tile);

            if (printer.kind == zs::LinkKind::Bambu)
            {
                // A Bambu Lab printer needs these three, as on Linux.
                char const *why = printer.url.empty() ? "Set the IP address of the printer."
                                  : printer.serial.empty() ? "Set the serial number of the printer."
                                  : printer.api_key.empty() ? "Set the access code of the printer."
                                                            : nullptr;
                if (why != nullptr)
                {
                    UpdateTile(tile, nullptr, why);
                    continue;
                }
                // The status comes from the link of this printer
                // (SyncBambuLinks), so it has one connection.
                zs::CameraSource source;
                source.bambu_host = zs::BambuHost(printer.url);
                source.bambu_code = printer.api_key;
                source.bambu_pin = printer.tls_pin;
                char model[128] = "";
                if (printer.id == store.Current().id)
                    zs_app_setting_get(w.model->Active(), "machine.model", model, sizeof model, nullptr);
                source.bambu_kind = zs_bambu_camera_kind(model);
                tile->source = std::move(source);
                tile->has_source = true;
                tile->camera_read = true;
                tile->camera.Visibility(Visibility::Visible);
            }
        }
        empty_panel.Visibility(tiles.empty() ? Visibility::Visible : Visibility::Collapsed);
        SyncBambuLinks();
        RefreshTiles();
        RefreshQueue();
    }

    // ---- the link to the current printer ----

    void MainWindow::PrintersUi::StartFollow()
    {
        follow_cancel = std::make_shared<zs::http::Cancel>();
        follow_timer = w.queue.CreateTimer();
        follow_timer.Interval(std::chrono::seconds(5));
        follow_timer.Tick([this](auto &&, auto &&) { FollowTick(); });
        follow_timer.Start();
        MainWindow *window = &w;
        w.SummaryFlyout().Opened([window](auto &&, auto &&) {
            if (window->printers != nullptr)
                window->printers->DetailsOpen(true);
        });
        w.SummaryFlyout().Closed([window](auto &&, auto &&) {
            if (window->printers != nullptr)
                window->printers->DetailsOpen(false);
        });
        SyncBambuLinks();
    }

    void MainWindow::PrintersUi::DetailsOpen(bool open)
    {
        details_open = open;
        // Each open reads the camera of the printer again.
        details_camera_id.clear();
        UpdateDetailsCamera();
    }

    void MainWindow::PrintersUi::DetailsStatus(std::string const &id, zs::link::Snapshot const *status)
    {
        details_has_status = status != nullptr;
        details_status_id = id;
        if (status != nullptr)
            details_status = *status;
        if (details_open)
            UpdateDetailsCamera();
    }

    void MainWindow::PrintersUi::UpdateDetailsCamera()
    {
        auto hide = [this] {
            Retire(details_feed);
            w.SummaryCamera().Visibility(Visibility::Collapsed);
            if (details_image != nullptr)
                details_image.Source(nullptr);
            w.SummaryCameraNote().Visibility(Visibility::Collapsed);
        };
        zs::SavedPrinter const &printer = zs::Printers().Current();
        bool page_open = page != nullptr && page.Visibility() == Visibility::Visible;
        bool printing = details_has_status && details_status_id == printer.id &&
                        (details_status.farm_state == ZS_FARM_PRINTING || details_status.farm_state == ZS_FARM_PAUSED);
        if (!details_open || follow_stopped || page_open || !HasLink(printer) || !printing)
        {
            hide();
            return;
        }
        std::wstring line = zs::ToWide(printer.name) + L": ";
        if (!details_status.job.empty())
            line += zs::ToWide(details_status.job) + L", ";
        line += std::to_wstring(std::lround(details_status.progress * 100)) + L" %";
        if (details_status.time_left > 0)
            line += L", " + zs::ToWide(zs::link::TimeText(details_status.time_left)) + L" left";
        w.SummaryCameraLine().Text(line);

        if (details_camera_id != printer.id)
        {
            Retire(details_feed);
            details_camera_id = printer.id;
            details_camera_read = false;
            details_has_source = false;
        }
        if (!details_camera_read)
        {
            details_camera_read = true;
            if (printer.kind == zs::LinkKind::Bambu)
            {
                zs::CameraSource source;
                source.bambu_host = zs::BambuHost(printer.url);
                source.bambu_code = printer.api_key;
                source.bambu_pin = printer.tls_pin;
                char model[128] = "";
                zs_app_setting_get(w.model->Active(), "machine.model", model, sizeof model, nullptr);
                source.bambu_kind = zs_bambu_camera_kind(model);
                details_source = std::move(source);
                details_has_source = true;
            }
            else
            {
                struct Result
                {
                    bool ok = false;
                    zs::link::Camera camera;
                };
                zs::link::Target target = zs::link::TargetOf(printer);
                auto cancel = follow_cancel;
                std::string id = printer.id, key = printer.api_key, url = printer.url;
                bool deck = printer.kind == zs::LinkKind::Printdeck;
                Async(
                    [target, cancel] {
                        Result r;
                        std::string ignored;
                        r.ok = zs::link::ReadCamera(target, cancel, r.camera, ignored);
                        return r;
                    },
                    [id, key, url, deck](PrintersUi &ui, Result &r) {
                        if (ui.details_camera_id != id)
                            return;
                        if (r.ok && (!r.camera.stream.empty() || !r.camera.snapshot.empty()))
                        {
                            zs::CameraSource source;
                            source.stream = r.camera.stream;
                            source.snapshot = r.camera.snapshot;
                            source.api_key = key;
                            source.printer_url = url;
                            source.printdeck = deck;
                            ui.details_source = std::move(source);
                            ui.details_has_source = true;
                        }
                        ui.UpdateDetailsCamera();
                    });
                return;
            }
        }
        if (!details_has_source)
        {
            hide();
            return;
        }
        w.SummaryCamera().Visibility(Visibility::Visible);
        if (details_feed != nullptr)
            return;
        Poster post = poster;
        if (details_image == nullptr)
        {
            details_image = Image();
            details_image.Stretch(Media::Stretch::Uniform);
            details_image.MaxHeight(170);
            Name(details_image, L"The camera of the printer");
            w.SummaryCameraBox().Child(details_image);
        }
        Image image = details_image;
        details_decoding->store(false);
        auto to_image = FrameTo(post, image, details_decoding);
        // A picture ends the note of the camera.
        auto noted = std::make_shared<std::atomic<bool>>(false);
        zs::CameraFeed::Frame frame = [post, to_image, noted](std::shared_ptr<std::string> const &jpeg) {
            if (noted->exchange(false))
                post.Post([](PrintersUi &ui) { ui.w.SummaryCameraNote().Visibility(Visibility::Collapsed); });
            to_image(jpeg);
        };
        details_feed = std::make_shared<zs::CameraFeed>(details_source, frame, [post, noted](std::string const &note) {
            noted->store(true);
            post.Post([note](PrintersUi &ui) {
                ui.w.SummaryCameraNote().Text(zs::ToWide(note));
                ui.w.SummaryCameraNote().Visibility(Visibility::Visible);
            });
        });
    }

    void MainWindow::PrintersUi::StopFollow()
    {
        follow_stopped = true;
        details_open = false;
        Retire(details_feed);
        if (follow_timer != nullptr)
            follow_timer.Stop();
        if (follow_cancel != nullptr)
            follow_cancel->Stop();
        for (auto &link : bambu_links)
            Retire(link.second.watch);
        bambu_links.clear();
    }

    // Each 5 s. An HTTP printer gets one status request, and none while the
    // page reads it. After 5 minutes minimized, the app leaves it alone.
    void MainWindow::PrintersUi::FollowTick()
    {
        if (!started || follow_stopped || w.model == nullptr)
            return;
        auto presenter = w.AppWindow().Presenter().try_as<Microsoft::UI::Windowing::OverlappedPresenter>();
        bool minimized = presenter != nullptr && presenter.State() == Microsoft::UI::Windowing::OverlappedPresenterState::Minimized;
        auto now = std::chrono::steady_clock::now();
        if (!minimized)
            minimized_since = {};
        else if (minimized_since == std::chrono::steady_clock::time_point{})
            minimized_since = now;
        follow_asleep = minimized && now - minimized_since >= std::chrono::minutes(5);
        SyncBambuLinks();
        zs::SavedPrinter const &printer = zs::Printers().Current();
        bool page_open = page != nullptr && page.Visibility() == Visibility::Visible;
        if (follow_asleep || follow_reading || page_open || !HasLink(printer) || printer.kind == zs::LinkKind::Bambu || printer.url.empty())
            return;
        follow_reading = true;
        zs::link::Target target = zs::link::TargetOf(printer);
        auto cancel = follow_cancel;
        struct Result
        {
            bool ok = false;
            zs::link::Snapshot status;
            std::string id, name, error;
        };
        Async(
            [target, cancel] {
                Result r;
                r.id = target.id;
                r.name = target.name;
                r.ok = zs::link::ReadStatus(target, cancel, r.status, r.error);
                return r;
            },
            [](PrintersUi &ui, Result &r) {
                ui.follow_reading = false;
                // The user can pick another printer during the request.
                if (ui.follow_stopped || r.id != zs::Printers().Current().id)
                    return;
                ui.DetailsStatus(r.id, r.ok ? &r.status : nullptr);
                if (!r.ok)
                    return;
                ui.rolls = r.status.rolls;
                ui.FollowSpools(r.name, r.status);
            });
    }

    // Opens and closes the Bambu Lab links, so that a printer never has two.
    // A new connection waits for the thread of the old one to end.
    void MainWindow::PrintersUi::SyncBambuLinks()
    {
        if (!started || follow_stopped || follow_timer == nullptr)
            return;
        zs::PrinterStore &store = zs::Printers();
        std::map<std::string, size_t> want;
        auto add = [&want](zs::SavedPrinter const &p) {
            if (p.kind == zs::LinkKind::Bambu && !p.url.empty() && !p.serial.empty() && !p.api_key.empty())
                want[p.id] = std::hash<std::string>{}(p.url + "\n" + p.serial + "\n" + p.api_key);
        };
        if (!follow_asleep)
        {
            add(store.Current());
            if (page != nullptr && page.Visibility() == Visibility::Visible)
                for (size_t i = 0; i < store.Count(); i++)
                    add(store.At(i));
        }
        Poster post = poster;
        for (auto it = bambu_links.begin(); it != bambu_links.end();)
        {
            auto wanted = want.find(it->first);
            if (wanted != want.end() && wanted->second == it->second.details)
            {
                ++it;
                continue;
            }
            bambu_closing.insert(it->first);
            std::thread([held = std::move(it->second.watch), post, id = it->first]() mutable {
                held.reset();
                post.Post([id](PrintersUi &ui) {
                    ui.bambu_closing.erase(id);
                    ui.SyncBambuLinks();
                });
            }).detach();
            it = bambu_links.erase(it);
        }
        for (auto const &[id, details] : want)
        {
            if (bambu_links.count(id) != 0 || bambu_closing.count(id) != 0)
                continue;
            zs::SavedPrinter *printer = store.Find(id);
            if (printer == nullptr)
                continue;
            std::string key = id;
            auto watch = std::make_shared<zs::BambuWatch>(
                zs::link::TargetOf(*printer), printer->serial,
                [post, key](zs::link::Snapshot const &s) {
                    post.Post([key, s](PrintersUi &ui) { ui.OnBambuStatus(key, &s, {}); });
                },
                [post, key](std::string const &e) {
                    post.Post([key, e](PrintersUi &ui) { ui.OnBambuStatus(key, nullptr, e); });
                },
                [post, key](std::string const &pin) {
                    // The first connection: the next ones need this
                    // certificate.
                    post.Post([key, pin](PrintersUi &) {
                        zs::SavedPrinter *p = zs::Printers().Find(key);
                        if (p != nullptr && p->kind == zs::LinkKind::Bambu && p->tls_pin.empty())
                        {
                            p->tls_pin = pin;
                            zs::Printers().Save();
                        }
                    });
                });
            bambu_links[id] = BambuLink{ std::move(watch), details };
        }
    }

    void MainWindow::PrintersUi::OnBambuStatus(std::string const &id, zs::link::Snapshot const *status, std::string const &error)
    {
        if (bambu_links.count(id) == 0)
            return;
        if (id == zs::Printers().Current().id)
            DetailsStatus(id, status);
        for (auto const &t : tiles)
        {
            if (t->id == id && t->alive)
            {
                // The tile follows the spools of the current printer.
                UpdateTile(t, status, error);
                return;
            }
        }
        zs::SavedPrinter const &current = zs::Printers().Current();
        if (status != nullptr && id == current.id)
        {
            rolls = status->rolls;
            FollowSpools(current.name, *status);
        }
    }

    void MainWindow::PrintersUi::RefreshTiles()
    {
        if (page == nullptr || page.Visibility() != Visibility::Visible || page_cancel == nullptr)
            return;
        auto cancel = page_cancel;
        for (auto const &tile : tiles)
        {
            zs::SavedPrinter *printer = zs::Printers().Find(tile->id);
            if (printer == nullptr || printer->kind == zs::LinkKind::Bambu || tile->reading)
                continue;
            tile->reading = true;
            zs::link::Target target = zs::link::TargetOf(*printer);
            bool want_camera = !tile->camera_read;
            struct Result
            {
                bool ok = false;
                bool cancelled = false;
                zs::link::Snapshot status;
                std::string error;
                bool has_camera = false;
                zs::link::Camera camera;
            };
            std::weak_ptr<PrinterTile> weak = tile;
            Async(
                [target, cancel, want_camera] {
                    Result r;
                    r.ok = zs::link::ReadStatus(target, cancel, r.status, r.error);
                    r.cancelled = cancel->Stopped();
                    if (r.ok && want_camera && !r.cancelled)
                    {
                        std::string ignored;
                        r.has_camera = zs::link::ReadCamera(target, cancel, r.camera, ignored);
                    }
                    return r;
                },
                [weak, want_camera](PrintersUi &ui, Result &r) {
                    auto t = weak.lock();
                    if (t == nullptr || !t->alive || r.cancelled)
                        return;
                    t->reading = false;
                    ui.UpdateTile(t, r.ok ? &r.status : nullptr, r.error);
                    if (!r.ok || !want_camera)
                        return;
                    t->camera_read = true;
                    if (r.has_camera && (!r.camera.stream.empty() || !r.camera.snapshot.empty()))
                    {
                        zs::SavedPrinter *p = zs::Printers().Find(t->id);
                        if (p == nullptr)
                            return;
                        zs::CameraSource source;
                        source.stream = r.camera.stream;
                        source.snapshot = r.camera.snapshot;
                        source.api_key = p->api_key;
                        source.printer_url = p->url;
                        source.printdeck = p->kind == zs::LinkKind::Printdeck;
                        t->source = std::move(source);
                        t->has_source = true;
                        t->camera.Visibility(Visibility::Visible);
                        if (t->in_view)
                            ui.StartCamera(t);
                    }
                });
        }
    }

    void MainWindow::PrintersUi::UpdateTile(std::shared_ptr<PrinterTile> const &t, zs::link::Snapshot const *st, std::string const &error)
    {
        zs::SavedPrinter *printer = zs::Printers().Find(t->id);
        if (printer == nullptr)
            return;
        t->needs_key = st == nullptr && UsesKey(printer->kind) &&
                       (printer->api_key.empty() || error.find("did not accept the API key") != std::string::npos);
        bool sliced = false;
        {
            uint8_t const *g = nullptr;
            size_t len = 0;
            sliced = zs_app_gcode(w.model->Active(), &g, &len) == ZS_OK && len > 0;
        }
        std::wstring refusal = w.PlateRefusal(w.model->Active());
        auto action = [&] {
            if (t->needs_key)
            {
                t->action.Content(box_value(L"Get a key"));
                t->action.IsEnabled(true);
                ToolTipService::SetToolTip(t->action, box_value(printer->kind == zs::LinkKind::Printdeck
                                                                    ? L"Connect zslice: tap Allow on the screen of the printdeck"
                                                                    : L"Connect zslice: allow it in the web page of the printer"));
                return;
            }
            t->action.Content(box_value(L"Upload the plate"));
            bool bambu = printer->kind == zs::LinkKind::Bambu;
            t->action.IsEnabled(sliced && t->state == ZS_FARM_IDLE && !bambu);
            wchar_t const *tip = bambu ? L"The Windows app reads a Bambu Lab printer, and sends it nothing."
                                 : !refusal.empty() ? refusal.c_str()
                                 : !sliced ? L"Slice the plate first."
                                 : t->state == ZS_FARM_FINISHED ? L"A print waits on the bed: clear it first."
                                 : t->state != ZS_FARM_IDLE ? L"The printer is busy, or does not answer."
                                                            : L"Upload the G-code of the active plate. Start the print on the printer.";
            ToolTipService::SetToolTip(t->action, box_value(tip));
        };
        auto counts_now = [&] {
            int n[6] = {};
            for (auto const &tile : tiles)
                if (tile->state >= 0 && tile->state < 6)
                    n[tile->state]++;
            std::wstring text;
            for (int s : { 5, 4, 3, 2, 1, 0 })
                if (n[s] > 0)
                    text += (text.empty() ? L"" : L" · ") + std::to_wstring(n[s]) + L" " + count_texts[s];
            counts.Text(text);
        };
        auto show = [](FrameworkElement const &e, bool on) { e.Visibility(on ? Visibility::Visible : Visibility::Collapsed); };
        if (st == nullptr)
        {
            t->state = ZS_FARM_OFFLINE;
            t->badge.Text(state_texts[0]);
            show(t->job, false);
            show(t->bar, false);
            show(t->facts, false);
            show(t->heat, false);
            show(t->roll, false);
            t->why.Text(error.empty() ? L"No answer." : zs::ToWide(error));
            show(t->why, true);
            action();
            counts_now();
            return;
        }
        int state = st->farm_state;
        t->state = state;
        t->badge.Text(state >= 0 && state < 6 ? state_texts[state] : L"");
        t->bed_x = st->bed_x;
        t->bed_y = st->bed_y;
        t->time_left = st->time_left;
        bool has_job = !st->job.empty() && state >= ZS_FARM_PRINTING;
        show(t->job, has_job);
        show(t->bar, has_job);
        show(t->facts, has_job);
        if (has_job)
        {
            double f = state == ZS_FARM_FINISHED ? 1 : st->progress;
            t->job.Text(zs::ToWide(st->job));
            t->bar.Value(f);
            std::wstring text = std::to_wstring((int)std::lround(f * 100)) + L" %";
            bool running = state == ZS_FARM_PRINTING || state == ZS_FARM_PAUSED;
            if (running && st->time_left > 0)
                text += L" · " + zs::ToWide(zs::link::TimeText(st->time_left)) + L" left";
            if (running && st->layers > 0)
                text += L" · layer " + std::to_wstring(st->layer) + L" of " + std::to_wstring(st->layers);
            t->facts.Text(text);
        }
        bool has_why = (state == ZS_FARM_FAILED || state == ZS_FARM_PAUSED) && !st->message.empty();
        t->why.Text(has_why ? zs::ToWide(st->message) : L"");
        show(t->why, has_why);
        std::wstring heat;
        auto add_heat = [&](std::wstring const &part) { heat += (heat.empty() ? L"" : L"    ") + part; };
        if (st->has_nozzle)
            add_heat(HeatPart(L"Nozzle", st->heat_nozzle, st->heat_nozzle_target));
        if (st->has_bed)
            add_heat(HeatPart(L"Bed", st->heat_bed, st->heat_bed_target));
        if (st->has_chamber)
            add_heat(HeatPart(L"Chamber", st->heat_chamber, 0));
        t->heat.Text(heat);
        show(t->heat, !heat.empty());
        std::string roll = st->spool_name.empty() ? st->material : st->spool_name;
        if (!st->spool_name.empty() && !st->material.empty())
            roll += " (" + st->material + ")";
        if (!st->spool_name.empty() && st->spool_left > 0)
            roll += ", " + std::to_string((int)std::lround(st->spool_left)) + " g left";
        t->roll.Text(zs::ToWide(roll));
        show(t->roll, !roll.empty());
        bool current = t->id == zs::Printers().Current().id;
        std::string current_name = printer->name;
        if (current)
            rolls = st->rolls;
        action();
        counts_now();
        // Last: a change of the filaments can rebuild the page.
        if (current)
            FollowSpools(current_name, *st);
    }

    void MainWindow::PrintersUi::StartCamera(std::shared_ptr<PrinterTile> const &t)
    {
        if (!t->has_source || t->feed != nullptr || !t->alive || t->state == ZS_FARM_OFFLINE)
            return;
        Poster post = poster;
        Image image = t->camera;
        t->feed = std::make_shared<zs::CameraFeed>(t->source, FrameTo(post, image, t->decoding), [post, image](std::string const &note) {
            post.Post([image, note](PrintersUi &) {
                ToolTipService::SetToolTip(image, box_value(zs::ToWide(note)));
            });
        });
    }

    void MainWindow::PrintersUi::StopCamera(std::shared_ptr<PrinterTile> const &t)
    {
        Retire(t->feed);
    }

    void MainWindow::PrintersUi::ShowCameraLarge(std::shared_ptr<PrinterTile> const &t)
    {
        zs::SavedPrinter *printer = zs::Printers().Find(t->id);
        if (printer == nullptr || !t->has_source)
        {
            Note(L"This printer shows no camera.");
            return;
        }
        Grid body;
        body.Padding(ThicknessHelper::FromLengths(12, 0, 12, 12));
        Image image;
        image.Stretch(Media::Stretch::Uniform);
        Name(image, L"The camera");
        body.Children().Append(image);
        TextBlock note = Label(L"", 12, false, true);
        note.VerticalAlignment(VerticalAlignment::Bottom);
        body.Children().Append(note);
        std::wstring title = zs::ToWide(printer->name) + L" · " + std::wstring(t->badge.Text());
        auto panel = OpenPanel(title, 960, 620, body);
        // The small camera rests while the large one plays.
        StopCamera(t);
        zs::CameraSource source = t->source;
        source.large = true;
        Poster post = poster;
        auto feed = std::make_shared<zs::CameraFeed>(source, FrameTo(post, image, std::make_shared<std::atomic<bool>>(false)), [post, note](std::string const &text) {
            post.Post([note, text](PrintersUi &) { note.Text(zs::ToWide(text)); });
        });
        std::weak_ptr<PrinterTile> weak = t;
        panel->closed = [this, feed, weak]() mutable {
            Retire(feed);
            if (auto tile = weak.lock(); tile != nullptr && tile->alive && tile->in_view)
                StartCamera(tile);
        };
    }

    // The plates with parts, each with the printers that fit, the ready ones
    // first, and Send. A send only uploads the file.
    void MainWindow::PrintersUi::RefreshQueue()
    {
        if (queue_panel == nullptr)
            return;
        queue_panel.Children().Clear();
        zs_set *set = w.model->Set();
        bool any = false;
        for (size_t i = 0; i < zs_set_count(set); i++)
        {
            zs_plate_info info{};
            if (zs_set_plate_info(set, i, &info) != ZS_OK || info.part_count == 0)
                continue;
            any = true;
            Grid row;
            ColumnDefinition grow, a, b;
            grow.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            a.Width(GridLengthHelper::Auto());
            b.Width(GridLengthHelper::Auto());
            row.ColumnDefinitions().Append(grow);
            row.ColumnDefinitions().Append(a);
            row.ColumnDefinitions().Append(b);
            row.ColumnSpacing(8);
            StackPanel what = Column(0);
            std::wstring name = std::to_wstring(i + 1) + L". " + (info.name[0] != 0 ? zs::ToWide(info.name) : L"Plate");
            what.Children().Append(Label(name, 13, true));
            std::wstring facts = std::to_wstring(info.part_count) + (info.part_count == 1 ? L" part · " : L" parts · ") +
                                 (info.status == ZS_PLATE_STATUS_DONE ? L"sliced" : L"not sliced yet");
            what.Children().Append(Label(facts, 11, false, true));
            row.Children().Append(what);
            ComboBox drop;
            drop.MinWidth(200);
            drop.VerticalAlignment(VerticalAlignment::Center);
            Name(drop, L"The printer for plate " + std::to_wstring(i + 1));
            std::vector<std::string> ids;
            for (int ready = 1; ready >= 0; ready--)
            {
                for (auto const &tile : tiles)
                {
                    if ((tile->state == ZS_FARM_IDLE) != (ready == 1) || tile->state <= ZS_FARM_OFFLINE)
                        continue;
                    // A printer with a known bed smaller than the plate bed
                    // does not fit.
                    if (tile->bed_x > 0 && (tile->bed_x + 0.5 < info.bed_x || tile->bed_y + 0.5 < info.bed_y))
                        continue;
                    zs::SavedPrinter *p = zs::Printers().Find(tile->id);
                    if (p == nullptr || p->kind == zs::LinkKind::Bambu)
                        continue;
                    std::wstring label = zs::ToWide(p->name);
                    if (tile->state == ZS_FARM_IDLE)
                        label += L" (ready)";
                    else if (tile->time_left > 0)
                        label += L" (busy, free in " + zs::ToWide(zs::link::TimeText(tile->time_left)) + L")";
                    else
                        label += L" (busy)";
                    drop.Items().Append(box_value(label));
                    ids.push_back(tile->id);
                }
            }
            if (!ids.empty())
                drop.SelectedIndex(0);
            Grid::SetColumn(drop, 1);
            row.Children().Append(drop);
            Button go = TextButton(L"Send");
            Name(go, L"Send plate " + std::to_wstring(i + 1));
            go.VerticalAlignment(VerticalAlignment::Center);
            go.IsEnabled(info.status == ZS_PLATE_STATUS_DONE && !ids.empty());
            go.Click([this, drop, ids, i](auto &&, auto &&) {
                int at = drop.SelectedIndex();
                if (at >= 0 && at < (int)ids.size())
                    SendPlate(ids[(size_t)at], i);
            });
            Grid::SetColumn(go, 2);
            row.Children().Append(go);
            queue_panel.Children().Append(row);
        }
        queue_panel.Visibility(any ? Visibility::Visible : Visibility::Collapsed);
        queue_empty.Visibility(any ? Visibility::Collapsed : Visibility::Visible);
    }

    // The printers of the user: edit, test, use, or remove each.
    void MainWindow::PrintersUi::ShowManage()
    {
        ScrollViewer scroll;
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        StackPanel list = Column(12);
        list.Padding(ThicknessHelper::FromLengths(16, 4, 22, 16));
        scroll.Content(list);
        auto panel = OpenPanel(L"Your printers", 760, 640, scroll);
        auto fill = std::make_shared<std::function<void()>>();
        auto stop = std::make_shared<zs::http::Cancel>();
        std::weak_ptr<std::function<void()>> weak_fill = fill;
        panel->closed = [this, stop, fill] {
            stop->Stop();
            *fill = nullptr;
            RefreshBar();
            RebuildTiles();
        };
        *fill = [this, list, weak_fill, panel, stop] {
            list.Children().Clear();
            zs::PrinterStore &store = zs::Printers();
            for (size_t i = 0; i < store.Count(); i++)
            {
                zs::SavedPrinter const &printer = store.At(i);
                std::string id = printer.id;
                Border card;
                card.Padding(ThicknessHelper::FromUniformLength(10));
                card.CornerRadius(CornerRadiusHelper::FromUniformRadius(6));
                card.BorderThickness(ThicknessHelper::FromUniformLength(1));
                card.BorderBrush(ThemeBrush(L"CardStrokeColorDefaultBrush"));
                StackPanel rows = Column(6);
                StackPanel line1 = Row(6);
                TextBox name;
                name.Text(zs::ToWide(printer.name));
                name.Width(240);
                Name(name, L"The name of the printer");
                TextBox url;
                url.Text(zs::ToWide(printer.url));
                url.Width(270);
                url.PlaceholderText(L"http://printer.local");
                Name(url, L"The address of " + zs::ToWide(printer.name));
                line1.Children().Append(name);
                line1.Children().Append(url);
                bool current = id == store.Current().id;
                if (current)
                {
                    TextBlock now = Label(L"in use", 12, false, true);
                    now.VerticalAlignment(VerticalAlignment::Center);
                    line1.Children().Append(now);
                }
                rows.Children().Append(line1);

                StackPanel line2 = Row(6);
                ComboBox kind;
                kind.Width(190);
                Name(kind, L"The connection of " + zs::ToWide(printer.name));
                for (int k = 0; k < (int)zs::LinkKind::Count; k++)
                    kind.Items().Append(box_value(zs::ToWide(zs::LinkTitle((zs::LinkKind)k))));
                kind.SelectedIndex((int)printer.kind);
                line2.Children().Append(kind);
                // A saved key never shows. A new one replaces it.
                PasswordBox key;
                key.Width(190);
                key.PlaceholderText(printer.api_key.empty() ? (printer.kind == zs::LinkKind::Bambu ? L"Access code" : L"API key") : L"A key is saved");
                Name(key, L"The key of " + zs::ToWide(printer.name));
                line2.Children().Append(key);
                TextBox serial;
                serial.Width(170);
                serial.Text(zs::ToWide(printer.serial));
                serial.PlaceholderText(L"Serial number");
                Name(serial, L"The serial number of " + zs::ToWide(printer.name));
                serial.Visibility(printer.kind == zs::LinkKind::Bambu ? Visibility::Visible : Visibility::Collapsed);
                line2.Children().Append(serial);
                rows.Children().Append(line2);

                StackPanel line3 = Row(6);
                TextBlock result = Label(L"", 12);
                Button use = TextButton(L"Use");
                use.IsEnabled(!current);
                Button settings = TextButton(L"Settings…");
                Button get_key = TextButton(L"Get a key");
                get_key.Visibility(UsesKey(printer.kind) ? Visibility::Visible : Visibility::Collapsed);
                Button forget = TextButton(L"Forget the key");
                forget.IsEnabled(!printer.api_key.empty());
                Button test = TextButton(L"Test");
                test.Visibility(printer.kind == zs::LinkKind::None || printer.kind == zs::LinkKind::Bambu ? Visibility::Collapsed : Visibility::Visible);
                Button remove = TextButton(L"Remove");
                remove.IsEnabled(store.Count() > 1);
                for (auto const &b : { use, settings, get_key, forget, test, remove })
                    line3.Children().Append(b);
                rows.Children().Append(line3);
                rows.Children().Append(result);
                std::string trust = zs::link::TrustText(zs::link::TargetOf(printer));
                if (!trust.empty())
                    rows.Children().Append(Label(zs::ToWide(trust), 11, false, true));
                card.Child(rows);
                list.Children().Append(card);

                auto saved = [this] {
                    zs::Printers().Save();
                    RefreshBar();
                };
                name.LostFocus([this, id, name, saved](auto &&, auto &&) {
                    zs::SavedPrinter *p = zs::Printers().Find(id);
                    std::string to = zs::ToUtf8(std::wstring(name.Text()));
                    if (p == nullptr || to.empty() || to == p->name)
                        return;
                    p->name = to;
                    if (id == zs::Printers().Current().id)
                        zs_app_setting_set(w.model->Active(), "machine.name", to.c_str());
                    saved();
                });
                url.LostFocus([id, url, saved](auto &&, auto &&) {
                    zs::SavedPrinter *p = zs::Printers().Find(id);
                    std::string to = zs::ToUtf8(std::wstring(url.Text()));
                    if (p == nullptr || to == p->url)
                        return;
                    p->url = to;
                    saved();
                });
                kind.SelectionChanged([id, kind, weak_fill, saved](auto &&, auto &&) {
                    zs::SavedPrinter *p = zs::Printers().Find(id);
                    int at = kind.SelectedIndex();
                    if (p == nullptr || at < 0 || (zs::LinkKind)at == p->kind)
                        return;
                    // An API key is no access code, and the other way round:
                    // a key does not go to the other kind of device.
                    if ((p->kind == zs::LinkKind::Bambu) != ((zs::LinkKind)at == zs::LinkKind::Bambu))
                    {
                        zs::state::Wipe(p->api_key);
                        zs::Printers().Save();
                    }
                    p->kind = (zs::LinkKind)at;
                    saved();
                    if (auto f = weak_fill.lock(); f != nullptr && *f)
                    {
                        auto run = *f;
                        Microsoft::UI::Dispatching::DispatcherQueue::GetForCurrentThread().TryEnqueue([run] { run(); });
                    }
                });
                key.LostFocus([id, key, saved, forget](auto &&, auto &&) {
                    zs::SavedPrinter *p = zs::Printers().Find(id);
                    std::string to = zs::ToUtf8(std::wstring(key.Password()));
                    if (p == nullptr || to.empty())
                        return;
                    p->api_key = to;
                    zs::state::Wipe(to);
                    key.Password(L"");
                    key.PlaceholderText(L"A key is saved");
                    forget.IsEnabled(true);
                    saved();
                });
                serial.LostFocus([id, serial, saved](auto &&, auto &&) {
                    zs::SavedPrinter *p = zs::Printers().Find(id);
                    std::string to = zs::ToUtf8(std::wstring(serial.Text()));
                    if (p == nullptr || to == p->serial)
                        return;
                    // The code file has the serial number in its name.
                    std::string code = p->api_key;
                    p->api_key.clear();
                    zs::Printers().Save();
                    p->serial = to;
                    p->api_key = code;
                    zs::state::Wipe(code);
                    saved();
                });
                use.Click([this, id, weak_fill](auto &&, auto &&) {
                    std::string message;
                    if (!setup.UsePrinter(id, message))
                        w.ShowError(zs::ToWide(message));
                    w.RefreshSettingValues();
                    w.ShowPlate();
                    RefreshBar();
                    if (auto f = weak_fill.lock(); f != nullptr && *f)
                        (*f)();
                });
                settings.Click([this, id, panel](auto &&, auto &&) {
                    std::string message;
                    setup.UsePrinter(id, message);
                    ClosePanel(panel);
                    w.ShowPlate();
                    w.ShowSettingsPane(true);
                    w.ShowDetail("machine.start_gcode");
                });
                get_key.Click([this, id, weak_fill](auto &&, auto &&) {
                    ShowPair(id, false, [weak_fill](bool ok) {
                        if (auto f = weak_fill.lock(); ok && f != nullptr && *f)
                            (*f)();
                    });
                });
                forget.Click([id, weak_fill, saved](auto &&, auto &&) {
                    if (zs::SavedPrinter *p = zs::Printers().Find(id))
                        zs::state::Wipe(p->api_key);
                    saved();
                    if (auto f = weak_fill.lock(); f != nullptr && *f)
                        (*f)();
                });
                test.Click([this, id, result, test, stop](auto &&, auto &&) {
                    zs::SavedPrinter *p = zs::Printers().Find(id);
                    if (p == nullptr)
                        return;
                    zs::link::Target target = zs::link::TargetOf(*p);
                    result.Text(L"Connecting…");
                    test.IsEnabled(false);
                    struct Reply
                    {
                        bool ok = false;
                        std::string text;
                    };
                    Async(
                        [target, stop] {
                            Reply r;
                            zs::link::Snapshot status;
                            r.ok = zs::link::ReadStatus(target, stop, status, r.text);
                            if (r.ok)
                                r.text = "Connected. " + zs::link::StatusLine(status) + ".";
                            return r;
                        },
                        [result, test, stop](PrintersUi &, Reply &r) {
                            if (stop->Stopped())
                                return;
                            test.IsEnabled(true);
                            result.Text(zs::ToWide(r.text));
                        });
                });
                remove.Click([this, id, weak_fill](auto &&, auto &&) {
                    bool was_current = id == zs::Printers().Current().id;
                    std::string next;
                    if (was_current)
                        for (size_t k = 0; k < zs::Printers().Count() && next.empty(); k++)
                            if (zs::Printers().At(k).id != id)
                                next = zs::Printers().At(k).id;
                    std::string message;
                    if (was_current && !next.empty())
                        setup.UsePrinter(next, message);
                    zs::Printers().Remove(id);
                    w.RefreshSettingValues();
                    w.ShowPlate();
                    RefreshBar();
                    if (auto f = weak_fill.lock(); f != nullptr && *f)
                        (*f)();
                });
            }
        };
        (*fill)();
    }
}
