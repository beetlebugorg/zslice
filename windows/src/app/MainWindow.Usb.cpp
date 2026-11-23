// A print over a USB serial port (zs_usb.h).
//
// A serial port has no upload, so a send here IS a print. It runs only from
// the item "Print over USB", after a yes in a dialog for this print, with
// Cancel as the default. No timer, retry, or batch reaches it.
//
// An open can restart the printer board, so a port opens only for that print
// and for "Test the connection", after its own question. Stop ends the print,
// turns off the heaters and the fan, and shows what the printer confirmed. It
// sends no move.
//
// A build with the test hooks never opens a real port: it talks to a stub.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.Printers.h"

#include "zs_usb.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace winrt::ZSlice::implementation
{
    namespace
    {
        wchar_t const *const hot_words = L"The heaters may still be on. Turn them off on the printer.";

#ifdef ZS_DEV_HOOKS
        // The printer of a test: it logs each command and answers "ok".
        class StubPort final : public zs::usb::Port
        {
        public:
            bool Write(char const *data, size_t len) override
            {
                std::string line(data, len);
                while (!line.empty() && line.back() == '\n')
                    line.pop_back();
                if (count_++ < 3 || line.rfind("M104 S0", 0) == 0 || line.rfind("M104 T", 0) == 0 || line.rfind("M140 S0", 0) == 0 || line == "M107")
                    zs::Log("dev: usb stub line: %s\n", line.c_str());
                ready_ = true;
                return true;
            }

            int Read(char *data, size_t cap, int) override
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(4));
                if (!ready_ || cap < 3)
                    return 0;
                ready_ = false;
                memcpy(data, "ok\n", 3);
                return 3;
            }

            void Flush() override {}
            ~StubPort() override { zs::Log("dev: usb stub closed after %zu lines\n", count_); }

        private:
            size_t count_ = 0;
            bool ready_ = false;
        };
#endif

        std::unique_ptr<zs::usb::Port> OpenUsb(std::string const &device, int baud, std::string &error)
        {
#ifdef ZS_DEV_HOOKS
            if (!zs::usb::ValidPort(device) || !zs::usb::ValidBaud(baud))
            {
                error = "Pick a serial port, for example COM3.";
                return nullptr;
            }
            zs::Log("dev: usb stub opened %s at %d\n", device.c_str(), baud);
            return std::make_unique<StubPort>();
#else
            return zs::usb::OpenPort(device, baud, error);
#endif
        }

        std::string CopyPlateGcode(zs_app *app)
        {
            uint8_t const *gcode = nullptr;
            size_t len = 0;
            if (zs_app_gcode(app, &gcode, &len) != ZS_OK || gcode == nullptr)
                return {};
            return std::string(reinterpret_cast<char const *>(gcode), len);
        }

        struct UsbRun
        {
            zs::usb::Result result;
            bool opened = false;
        };
    }

    // The Stop button has its own control: a new slice can turn off the main
    // button, and Stop stays.
    void MainWindow::PrintersUi::ShowUsbState()
    {
        if (usb_stop_button == nullptr)
        {
            Button stop;
            stop.Style(w.ExportButton().Style());
            stop.MinWidth(124);
            stop.Height(32);
            stop.Padding(ThicknessHelper::FromLengths(14, 0, 14, 0));
            stop.CornerRadius(CornerRadiusHelper::FromUniformRadius(6));
            stop.Visibility(Visibility::Collapsed);
            ToolTipService::SetToolTip(stop, box_value(L"End the print, and turn off the heaters and the fan"));
            stop.Click([this](auto &&, auto &&) { StopUsb(); });
            w.ExportGroup().Children().Append(stop);
            usb_stop_button = stop;
        }
        bool running = usb_stop != nullptr;
        bool stopping = running && usb_stop->load();
        usb_stop_button.Content(box_value(stopping ? L"Stopping…" : L"Stop the USB print"));
        usb_stop_button.IsEnabled(running && !stopping);
        usb_stop_button.Visibility(running ? Visibility::Visible : Visibility::Collapsed);
        w.ExportButton().Visibility(running ? Visibility::Collapsed : Visibility::Visible);
        if (running)
            w.SendMenuButton().Visibility(Visibility::Collapsed);
    }

    void MainWindow::PrintersUi::StopUsb()
    {
        if (usb_stop == nullptr)
            return;
        usb_stop->store(true);
        ShowUsbState();
    }

    winrt::fire_and_forget MainWindow::PrintersUi::PrintUsb()
    {
        if (usb_stop != nullptr || usb_asking)
            co_return;
        auto keep = shared_from_this();
        auto window = w.get_strong();
        zs::SavedPrinter const &printer = zs::Printers().Current();
        if (printer.kind != zs::LinkKind::Usb)
            co_return;
        if (!zs::usb::ValidPort(printer.device))
        {
            w.ShowError(L"Set the serial port of this printer in Preferences.");
            co_return;
        }
        zs_set *set = w.model->Set();
        size_t index = zs_set_active(set);
        zs_app *app = zs_set_app(set, index);
        std::wstring refusal = w.PlateRefusal(app);
        if (!refusal.empty())
        {
            w.ShowError(refusal);
            co_return;
        }
        if (app == nullptr || zs_app_state(app) != ZS_STATE_DONE)
        {
            Note(L"No G-code: the plate has no slice yet.");
            co_return;
        }
        if (zs_app_is_draft(app) != 0)
        {
            w.model->SliceExact(index);
            Note(L"The exact slice runs. Print again when it is done.");
            co_return;
        }
        // The print is the G-code that the user sees when the question opens.
        std::string gcode = CopyPlateGcode(app);
        if (gcode.empty())
        {
            Note(L"No G-code: the plate has no slice yet.");
            co_return;
        }
        // A stop turns off each nozzle of the machine.
        char nozzle_text[32] = "";
        int nozzles = 1;
        if (zs_app_setting_get(app, "machine.nozzles", nozzle_text, sizeof nozzle_text, nullptr) == ZS_OK)
            nozzles = std::clamp(atoi(nozzle_text), 1, 16);
        std::string id = printer.id, device = printer.device;
        int baud = printer.baud;
        std::wstring name = zs::ToWide(printer.name);

        usb_asking = true;
        ContentDialog dialog;
        dialog.XamlRoot(w.Content().XamlRoot());
        w.ThemeDialog(dialog);
        dialog.Title(box_value(L"Print on " + name + L" over USB?"));
        TextBlock text;
        text.TextWrapping(TextWrapping::Wrap);
        text.Text(L"The printer starts this plate at once, on " + zs::ToWide(device) + L". Clear the bed first. Keep this computer on and the cable in until the print ends, because the print stops without them.");
        dialog.Content(text);
        dialog.PrimaryButtonText(L"Print");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(ContentDialogButton::Close);
        ContentDialogResult answer = ContentDialogResult::None;
        try
        {
            answer = co_await dialog.ShowAsync();
        }
        catch (winrt::hresult_error const &)
        {
            usb_asking = false;
            co_return;
        }
        usb_asking = false;
        if (answer != ContentDialogResult::Primary)
            co_return;
        // The printer can have changed while the question was open.
        zs::SavedPrinter *now = zs::Printers().Find(id);
        if (now == nullptr || now->kind != zs::LinkKind::Usb || now->device != device || now->baud != baud || usb_stop != nullptr)
            co_return;

        auto stop = std::make_shared<std::atomic<bool>>(false);
        usb_stop = stop;
        RefreshPrimary();
        Note(L"Printing on " + name + L" over USB…");
        Poster post = poster;
        Async(
            [device, baud, nozzles, gcode = std::move(gcode), stop, post, name] {
                UsbRun run;
                // The computer stays awake while the print streams.
                ::SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
                std::string error;
                auto port = OpenUsb(device, baud, error);
                if (port == nullptr)
                    run.result.message = error;
                else
                {
                    run.opened = true;
                    auto last = std::make_shared<int>(-1);
                    run.result = zs::usb::Stream(*port, gcode, *stop, [post, name, last](double f) {
                        int percent = (int)(f * 100);
                        if (percent == *last)
                            return;
                        *last = percent;
                        post.Post([name, percent](PrintersUi &ui) {
                            if (ui.usb_stop != nullptr && !ui.usb_stop->load())
                                ui.Note(L"Printing on " + name + L" over USB: " + std::to_wstring(percent) + L" %");
                        });
                    }, {}, nozzles);
                }
                port.reset();
                ::SetThreadExecutionState(ES_CONTINUOUS);
                return run;
            },
            [name](PrintersUi &ui, UsbRun &run) {
                ui.usb_stop = nullptr;
                if (ui.usb_close_after)
                {
                    ui.w.Close();
                    return;
                }
                ui.RefreshPrimary();
                if (run.result.ok)
                    ui.Note(L"The last command of the print went to " + name + L".");
                else if (!run.opened)
                    ui.w.ShowError(L"The print did not start: " + zs::ToWide(run.result.message));
                else if (run.result.cancelled && !run.result.sent)
                    ui.Note(L"The USB print stopped before its first command.");
                else if (run.result.cancelled && run.result.cooled)
                    ui.Note(L"The USB print stopped. The printer turned off the heaters and the fan. The nozzle and the bed stay hot until they cool.");
                else if (run.result.cancelled)
                    ui.w.ShowError(L"The USB print stopped, and the printer did not confirm that the heaters are off: " + zs::ToWide(run.result.message) + L" " + hot_words);
                else
                    ui.w.ShowError(L"The USB print stopped: " + zs::ToWide(run.result.message) + L" " + hot_words);
            });
    }

    // "Test the connection": an open can restart the board, so it asks.
    winrt::fire_and_forget MainWindow::PrintersUi::AskUsbTest(std::string device, int baud, std::function<void(std::wstring const &, bool)> done)
    {
        auto keep = shared_from_this();
        auto window = w.get_strong();
        if (!zs::usb::ValidPort(device))
        {
            done(L"Pick a serial port, for example COM3.", true);
            co_return;
        }
        ContentDialog dialog;
        dialog.XamlRoot(w.Content().XamlRoot());
        w.ThemeDialog(dialog);
        dialog.Title(box_value(L"Open " + zs::ToWide(device) + L"?"));
        TextBlock text;
        text.TextWrapping(TextWrapping::Wrap);
        text.Text(L"Most printer boards restart when their port opens. A print that runs from the card of the printer ends. Test only when the printer is idle.");
        dialog.Content(text);
        dialog.PrimaryButtonText(L"Open the port");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(ContentDialogButton::Close);
        ContentDialogResult answer = ContentDialogResult::None;
        try
        {
            answer = co_await dialog.ShowAsync();
        }
        catch (winrt::hresult_error const &)
        {
            done(L"", false);
            co_return;
        }
        if (answer != ContentDialogResult::Primary)
        {
            done(L"", false);
            co_return;
        }
        if (usb_stop != nullptr)
        {
            done(L"A print is running on the port.", true);
            co_return;
        }
        struct Reply
        {
            bool ok = false;
            std::string error;
        };
        Async(
            [device, baud] {
                Reply r;
                r.ok = OpenUsb(device, baud, r.error) != nullptr;
                return r;
            },
            [device, done](PrintersUi &, Reply &r) {
                if (r.ok)
                    done(L"The port " + zs::ToWide(device) + L" opens.", false);
                else
                    done(zs::ToWide(r.error), true);
            });
    }

    // True when a USB print holds the window open. The question decides.
    winrt::fire_and_forget MainWindow::PrintersUi::AskCloseDuringUsb()
    {
        if (usb_asking)
            co_return;
        auto keep = shared_from_this();
        auto window = w.get_strong();
        usb_asking = true;
        ContentDialog dialog;
        dialog.XamlRoot(w.Content().XamlRoot());
        w.ThemeDialog(dialog);
        dialog.Title(box_value(L"Stop the USB print and close?"));
        TextBlock text;
        text.TextWrapping(TextWrapping::Wrap);
        text.Text(L"The print runs through this app, so it ends when the app closes. zslice turns off the heaters and the fan first.");
        dialog.Content(text);
        dialog.PrimaryButtonText(L"Stop and close");
        dialog.CloseButtonText(L"Keep printing");
        dialog.DefaultButton(ContentDialogButton::Close);
        ContentDialogResult answer = ContentDialogResult::None;
        try
        {
            answer = co_await dialog.ShowAsync();
        }
        catch (winrt::hresult_error const &)
        {
            usb_asking = false;
            co_return;
        }
        usb_asking = false;
        if (answer != ContentDialogResult::Primary)
            co_return;
        if (usb_stop == nullptr)
        {
            w.Close();
            co_return;
        }
        usb_close_after = true;
        StopUsb();
    }

    bool MainWindow::UsbHoldsClose()
    {
        if (printers == nullptr || printers->usb_stop == nullptr || printers->usb_close_after)
            return false;
        printers->AskCloseDuringUsb();
        return true;
    }

#ifdef ZS_DEV_HOOKS
    // usbset COM7 [baud], usbprint, usbstop, usbclose, usblog.
    bool MainWindow::RunUsbStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb.rfind(L"usb", 0) != 0 || printers == nullptr)
            return false;
        zs::SavedPrinter &p = zs::Printers().Current();
        if (verb == L"usbset" && !words.empty())
        {
            p.kind = zs::LinkKind::Usb;
            p.device = zs::ToUtf8(words[0]);
            if (words.size() > 1)
                p.baud = _wtoi(words[1].c_str());
            zs::Printers().Save();
            printers->RefreshBar();
            printers->RefreshPrimary();
        }
        else if (verb == L"usbprint")
            printers->PrimaryAction();
        else if (verb == L"usbpage" && !words.empty())
        {
            printers->ShowPage(words[0] == L"1");
            for (auto const &t : printers->tiles)
                zs::Log("dev: usb tile badge %s why %s action shown %d state %d\n", zs::ToUtf8(std::wstring(t->badge.Text())).c_str(), zs::ToUtf8(std::wstring(t->why.Text())).c_str(), t->action.Visibility() == Visibility::Visible ? 1 : 0, t->state);
        }
        else if (verb == L"usbstop")
            printers->StopUsb();
        else if (verb == L"usbclose")
            zs::Log("dev: usb close held %d\n", UsbHoldsClose() ? 1 : 0);
        else if (verb == L"usbsend")
            printers->SendPlate(p.id, (size_t)-1);
        else if (verb == L"usbsendall")
            printers->SendAll();
        else if (verb == L"usbstatus")
        {
            zs::link::Snapshot status;
            std::string error;
            bool ok = zs::link::ReadStatus(zs::link::TargetOf(p), nullptr, status, error);
            zs::Log("dev: usb status ok %d: %s\n", ok ? 1 : 0, error.c_str());
        }
        else if (verb == L"usblog")
        {
            printers->FillSendMenu();
            std::string menu;
            for (auto const &item : printers->send_menu.Items())
                if (auto entry = item.try_as<MenuFlyoutItem>())
                    menu += zs::ToUtf8(std::wstring(entry.Text())) + (entry.IsEnabled() ? "=on | " : "=off | ");
            auto content = ExportButton().Content().try_as<hstring>();
            zs::Log("dev: usb kind %s device %s baud %d running %d main '%s' main shown %d | %s\n", zs::LinkKey(p.kind), p.device.c_str(), p.baud, printers->usb_stop != nullptr ? 1 : 0,
                    content ? zs::ToUtf8(std::wstring(*content)).c_str() : "", ExportButton().Visibility() == Visibility::Visible ? 1 : 0, menu.c_str());
        }
        else
            return false;
        return true;
    }
#endif
}
