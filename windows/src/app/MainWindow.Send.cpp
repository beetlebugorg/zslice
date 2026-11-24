// Send and export: the G-code, the plate as 3MF, the project, and all plates.
//
// Each file has the signature of this install. A send only uploads the file:
// the person starts the print on the printer (see zs_printer_link.h). A USB
// printer has no upload, so it has no send here (see MainWindow.Usb.cpp). The
// flow follows linux/src/ui/window.c.
//
// ZSLICE_SAVE_DIR=dir skips the save dialogs and writes there, for tests.
//
// See MainWindow.Printers.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.Printers.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Storage = Windows::Storage;

namespace winrt::ZSlice::implementation
{
    namespace
    {
        std::wstring SaveDirHook()
        {
            wchar_t dir[MAX_PATH];
            DWORD n = ::GetEnvironmentVariableW(L"ZSLICE_SAVE_DIR", dir, MAX_PATH);
            return n > 0 && n < MAX_PATH ? std::wstring(dir, n) : std::wstring{};
        }

        std::string CopyGcode(zs_app *app)
        {
            uint8_t const *gcode = nullptr;
            size_t len = 0;
            if (zs_app_gcode(app, &gcode, &len) != ZS_OK || gcode == nullptr)
                return {};
            return std::string(reinterpret_cast<char const *>(gcode), len);
        }

        bool IsBambuModel(zs_app *app)
        {
            char model[128] = "";
            return zs_app_setting_get(app, "machine.model", model, sizeof model, nullptr) == ZS_OK && strncmp(model, "bambu-lab", 9) == 0;
        }

        // The .gcode.3mf around the signed G-code.
        bool WrapBambu(zs_app *app, std::string const &signed_gcode, std::string &out)
        {
            uint8_t *bytes = nullptr;
            size_t len = 0;
            if (zs_app_bambu_file_gcode(app, reinterpret_cast<uint8_t const *>(signed_gcode.data()), signed_gcode.size(), nullptr, &bytes, &len) != ZS_OK || bytes == nullptr)
                return false;
            out.assign(reinterpret_cast<char const *>(bytes), len);
            zs_buffer_free(bytes, len);
            return true;
        }

        bool EndsWith(std::wstring const &text, wchar_t const *suffix)
        {
            size_t n = wcslen(suffix);
            return text.size() >= n && _wcsicmp(text.c_str() + text.size() - n, suffix) == 0;
        }
    }

    std::wstring MainWindow::PlateRefusal(zs_app *app)
    {
        size_t len = 0;
        if (app == nullptr || zs_app_plate_printable(app, nullptr, 0, &len) != ZS_PART_TOO_LARGE)
            return {};
        std::string text(len + 1, '\0');
        zs_app_plate_printable(app, text.data(), text.size(), &len);
        text.resize(len);
        return text.empty() ? std::wstring(L"A part does not fit the printer.") : zs::ToWide(text);
    }

    std::string MainWindow::PrintersUi::GcodeName(zs_app *app, size_t plate)
    {
        zs_part first{};
        char const *model = zs_app_part_count(app) > 0 && zs_app_part_get(app, 0, &first) == ZS_OK && first.name != nullptr ? first.name : "plate";
        char base[256] = "";
        size_t count = zs_set_count(w.model->Set());
        if (zs_app_gcode_name(app, model, count > 1 ? plate + 1 : 0, base, sizeof base, nullptr) != ZS_OK || base[0] == 0)
            snprintf(base, sizeof base, "plate-%zu", plate + 1);
        return base;
    }

    void MainWindow::PrintersUi::FillSendMenu()
    {
        send_menu.Items().Clear();
        zs_app *app = w.model->Active();
        int state = zs_app_state(app);
        bool draft = w.model->IsDraft();
        bool sliced = state == ZS_STATE_DONE && !draft;
        bool printable = w.PlateRefusal(app).empty();
        zs::SavedPrinter const &printer = zs::Printers().Current();
        bool usb = printer.kind == zs::LinkKind::Usb;
        bool can_send = printer.kind != zs::LinkKind::None && printer.kind != zs::LinkKind::Bambu && !usb;
        auto add = [&](std::wstring const &text, bool enabled, std::function<void()> run) {
            MenuFlyoutItem item;
            item.Text(text);
            item.IsEnabled(enabled);
            item.Click([run](auto &&, auto &&) { run(); });
            send_menu.Items().Append(item);
        };
        std::string id = printer.id;
        if (usb)
        {
            add(L"Print on " + zs::ToWide(printer.name) + L" over USB…", usb_stop == nullptr && printable && sliced, [this] { PrintUsb(); });
        }
        else
        {
        add(L"Upload only", can_send && !sending && !batch.on && printable && (sliced || state == ZS_STATE_SLICING),
            [this, id] { SendPlate(id, (size_t)-1); });
        add(L"Send all plates", can_send && !sending && !batch.on, [this] { SendAll(); });
        }
        send_menu.Items().Append(MenuFlyoutSeparator());
        add(L"Export G-code…", printable && (sliced || state == ZS_STATE_SLICING), [this] { ExportGcode(); });
        add(L"Export all plates…", !batch.on, [this] { ExportAll(); });
    }

    // Uploads the G-code of a plate (-1: the active plate). The file has the
    // signature. It starts a print only with a SendKind from AskBedClear.
    // The print needs more plastic than the roll in the printer has left.
    winrt::fire_and_forget MainWindow::PrintersUi::AskLowFilament(std::string printer_id, size_t plate, double need, SendKind kind)
    {
        auto keep = shared_from_this();
        low_asking = true;
        ContentDialog dialog;
        dialog.XamlRoot(w.Content().XamlRoot());
        w.ThemeDialog(dialog);
        dialog.Title(box_value(L"Not enough filament on the roll"));
        TextBlock text;
        text.TextWrapping(TextWrapping::Wrap);
        text.Text(L"This print needs " + std::to_wstring(std::lround(need)) + L" g of filament. The roll in the printer (" + zs::ToWide(spool_now) + L") has " +
                  std::to_wstring(std::lround(spool_left_now)) + L" g left.");
        dialog.Content(text);
        dialog.PrimaryButtonText(L"Send anyway");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(ContentDialogButton::Close);
        ContentDialogResult answer = ContentDialogResult::None;
        try
        {
            answer = co_await dialog.ShowAsync();
        }
        catch (winrt::hresult_error const &)
        {
        }
        low_asking = false;
        if (answer == ContentDialogResult::Primary)
            SendPlate(printer_id, plate, true, kind);
    }

    bool MainWindow::PrintersUi::PlateReady(zs_app *app, size_t index)
    {
        std::wstring refusal = w.PlateRefusal(app);
        if (!refusal.empty())
        {
            w.ShowError(refusal);
            return false;
        }
        if (app == nullptr || zs_app_state(app) != ZS_STATE_DONE)
        {
            Note(L"No G-code: the plate has no slice yet.");
            return false;
        }
        // A draft has no G-code.
        if (zs_app_is_draft(app) != 0)
        {
            w.model->SliceExact(index);
            Note(L"The exact slice runs. Send again when it is done.");
            return false;
        }
        return true;
    }

    void MainWindow::PrintersUi::PrintPlate(std::string const &printer_id, size_t plate, bool from_page, bool busy)
    {
        zs::SavedPrinter *printer = zs::Printers().Find(printer_id);
        if (printer == nullptr || sending || low_asking || print_asking)
            return;
        if (printer->kind == zs::LinkKind::Usb)
        {
            Note(L"A USB printer prints with Print over USB.");
            return;
        }
        if (printer->kind == zs::LinkKind::None || printer->kind == zs::LinkKind::Bambu)
        {
            Note(L"The Windows app cannot send a print to this printer.");
            return;
        }
        if (batch.on)
        {
            Note(L"Wait for the plates that go out now.");
            return;
        }
        zs_set *set = w.model->Set();
        size_t index = plate == (size_t)-1 ? zs_set_active(set) : plate;
        if (!PlateReady(zs_set_app(set, index), index))
            return;
        AskBedClear(printer_id, index, from_page, busy);
    }

    // A print can start as soon as the file is there: a fresh yes of the
    // user, each time. Cancel is the default.
    winrt::fire_and_forget MainWindow::PrintersUi::AskBedClear(std::string printer_id, size_t index, bool from_page, bool busy)
    {
        auto keep = shared_from_this();
        zs::SavedPrinter *printer = zs::Printers().Find(printer_id);
        zs_set *set = w.model->Set();
        zs_plate_info info{};
        if (printer == nullptr || zs_set_plate_info(set, index, &info) != ZS_OK)
            co_return;
        uint64_t plate_id = info.id;
        std::string url = printer->url;
        zs::LinkKind link = printer->kind;
        std::wstring name = zs::ToWide(printer->name);
        bool deck = link == zs::LinkKind::Printdeck;
        std::wstring title, detail, yes;
        if (from_page)
        {
            std::wstring plate_name = info.name != nullptr && info.name[0] != 0 ? zs::ToWide(info.name) : L"the plate";
            title = L"Send \"" + plate_name + L"\" to " + name + L"?";
            detail = L"Is the bed of " + name + L" clear? The print can start when the file is there";
            detail += deck ? L" (a deck set to ask waits for a press of Print on it)." : L".";
            if (busy)
                detail += L"\n\nThe printer looks busy now.";
            zs::SavedPrinter const &current = zs::Printers().Current();
            if (current.id != printer_id)
                detail += L"\n\nThe plate is sliced for " + zs::ToWide(current.name) + L", another printer.";
            yes = L"Send";
        }
        else
        {
            title = L"Is the bed of " + name + L" clear?";
            detail = deck ? L"The print starts when the file is there. A deck set to ask waits for a press of Print on it." : L"The print starts when the file is there.";
            yes = L"Print";
        }
        print_asking = true;
        ContentDialog dialog;
        dialog.XamlRoot(w.Content().XamlRoot());
        w.ThemeDialog(dialog);
        dialog.Title(box_value(title));
        TextBlock text;
        text.TextWrapping(TextWrapping::Wrap);
        text.Text(detail);
        dialog.Content(text);
        dialog.PrimaryButtonText(yes);
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(ContentDialogButton::Close);
        ContentDialogResult answer = ContentDialogResult::None;
        try
        {
            answer = co_await dialog.ShowAsync();
        }
        catch (winrt::hresult_error const &)
        {
        }
        print_asking = false;
        if (answer != ContentDialogResult::Primary)
            co_return;
        // The yes is for this printer at this address, and for this plate.
        zs::SavedPrinter *now = zs::Printers().Find(printer_id);
        zs_plate_info after{};
        if (now == nullptr || now->kind != link || now->url != url || zs_set_plate_info(set, index, &after) != ZS_OK || after.id != plate_id)
        {
            Note(L"The printer or the plate changed. Nothing was sent.");
            co_return;
        }
        SendPlate(printer_id, index, false, from_page ? SendKind::Print : SendKind::PrintFromBar);
    }

    void MainWindow::PrintersUi::SendPlate(std::string const &printer_id, size_t plate, bool low_ok, SendKind kind)
    {
        zs::SavedPrinter *printer = zs::Printers().Find(printer_id);
        if (printer == nullptr || sending || low_asking || print_asking)
            return;
#ifdef ZS_DEV_HOOKS
        // A build with test hooks starts a print only on a stub on this
        // computer.
        if (kind != SendKind::Upload && printer->url.rfind("http://127.0.0.1:", 0) != 0)
        {
            zs::Log("dev: print refused, not a local stub\n");
            Note(L"A test build prints only on a stub on this computer.");
            return;
        }
#endif
        // Each line on a USB port runs, so nothing here reaches it.
        if (printer->kind == zs::LinkKind::Usb)
        {
            Note(L"A USB printer has no upload. Use Print over USB.");
            return;
        }
        // The batch counts each upload that ends, so it allows no other.
        if (batch.on && !batch_sending)
        {
            Note(L"Wait for the plates that go out now.");
            return;
        }
        zs_set *set = w.model->Set();
        size_t index = plate == (size_t)-1 ? zs_set_active(set) : plate;
        zs_app *app = zs_set_app(set, index);
        if (!PlateReady(app, index))
            return;
        // The core gives 0 grams for a roll with no known weight.
        if (!low_ok && !batch.on && printer_id == rolls_printer && !spool_now.empty() && spool_left_now > 0)
        {
            zs_stats stats{};
            if (zs_app_stats(app, &stats) == ZS_OK && stats.filament_g > spool_left_now)
            {
                AskLowFilament(printer_id, index, stats.filament_g, kind);
                return;
            }
        }
        std::string gcode = CopyGcode(app);
        if (gcode.empty())
        {
            Note(L"No G-code: the plate has no slice yet.");
            return;
        }
        std::string file = GcodeName(app, index);
        std::string bytes = zs::signing::Sign(gcode);
        // A Bambu Lab printer behind a deck prints a .gcode.3mf.
        if (printer->kind == zs::LinkKind::Printdeck && IsBambuModel(app))
        {
            std::string wrapped;
            if (!WrapBambu(app, bytes, wrapped))
            {
                w.ShowError(L"zslice could not make the .gcode.3mf file of the plate.");
                return;
            }
            bytes = std::move(wrapped);
            file += ".gcode.3mf";
        }
        else
            file += ".gcode";
        sending = true;
        send_cancel = std::make_shared<zs::http::Cancel>();
        std::wstring name = zs::ToWide(printer->name);
        Note(L"Sending to " + name + L"…");
        zs::link::Target target = zs::link::TargetOf(*printer);
        auto cancel = send_cancel;
        Poster post = poster;
        struct Result
        {
            zs::link::UploadResult upload;
            zs::link::Target target;
            bool from_bar = false;
        };
        Async(
            [target, file, bytes = std::move(bytes), cancel, post, name, kind]() mutable {
                Result r;
                r.from_bar = kind == SendKind::PrintFromBar;
                auto last = std::make_shared<int>(-1);
                auto sent = [post, name, last](double f) {
                    int percent = (int)(f * 100);
                    if (percent == *last)
                        return;
                    *last = percent;
                    post.Post([name, percent](PrintersUi &ui) {
                        ui.Note(L"Sending to " + name + L": " + std::to_wstring(percent) + L" %");
                    });
                };
                r.upload = kind == SendKind::Upload ? zs::link::Upload(target, file, bytes, cancel, sent)
                                                    : zs::link::UploadAndPrint(target, file, bytes, cancel, sent, zs::link::PrintConfirmed{});
                r.target = std::move(target);
                return r;
            },
            [](PrintersUi &ui, Result &r) {
                ui.sending = false;
                ui.send_cancel = nullptr;
                ui.SavePin(r.target);
                if (r.upload.cancelled)
                    return;
                if (r.upload.ok)
                    ui.Note(zs::ToWide(r.upload.message));
                else
                    ui.w.ShowError(L"The file was not sent: " + zs::ToWide(r.upload.message));
                // The plate of a project prints now.
                if (r.upload.ok && r.from_bar)
                    ui.w.ProjectPlateSent();
                if (ui.batch.on && ui.batch.send)
                {
                    if (!r.upload.ok)
                    {
                        ui.BatchFinish(zs::ToWide(r.upload.message));
                        return;
                    }
                    ui.batch.done++;
                    ui.batch.i++;
                    ui.BatchNext();
                }
                ui.RefreshTiles();
            });
    }

    Windows::Foundation::IAsyncOperation<hstring> MainWindow::PrintersUi::PickSavePath(std::wstring name, std::wstring type, std::wstring ext)
    {
        auto keep = shared_from_this();
        auto window = w.get_strong();
        std::wstring hook = SaveDirHook();
        if (!hook.empty())
            co_return hstring(hook + L"\\" + name + ext);
        Storage::Pickers::FileSavePicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(w.hwnd);
        picker.SuggestedFileName(name);
        auto extensions = single_threaded_vector<hstring>();
        extensions.Append(ext);
        picker.FileTypeChoices().Insert(type, extensions);
        auto file = co_await picker.PickSaveFileAsync();
        co_return file != nullptr ? file.Path() : hstring{};
    }

    winrt::fire_and_forget MainWindow::PrintersUi::ExportGcode()
    {
        auto keep = shared_from_this();
        // The await can outlast the window: this keeps it.
        auto window = w.get_strong();
        zs_app *app = w.model->Active();
        std::wstring refusal = w.PlateRefusal(app);
        if (!refusal.empty())
        {
            w.ShowError(refusal);
            co_return;
        }
        int state = zs_app_state(app);
        if (state == ZS_STATE_DONE && zs_app_is_draft(app) != 0)
        {
            // A draft has no G-code: the exact slice comes first.
            w.model->Settle();
            state = zs_app_state(app);
            if (state == ZS_STATE_DONE)
                state = ZS_STATE_SLICING;
        }
        if (state == ZS_STATE_SLICING)
        {
            // Export when the slice is done.
            export_pending = true;
            Note(L"Slicing. The export follows.");
            co_return;
        }
        if (state != ZS_STATE_DONE)
            co_return;
        size_t plate = w.model->ActivePlate();
        std::wstring name = zs::ToWide(GcodeName(app, plate));
        bool bambu = IsBambuModel(app);
        hstring path = co_await PickSavePath(name, bambu ? L"Bambu Lab G-code 3MF" : L"G-code", bambu ? L".gcode.3mf" : L".gcode");
        if (path.empty() || w.model == nullptr || w.model->Active() != app || zs_app_state(app) != ZS_STATE_DONE)
            co_return;
        // The size can change while the file dialog is open.
        std::string gcode = CopyGcode(app);
        if (gcode.empty())
        {
            refusal = w.PlateRefusal(app);
            w.ShowError(refusal.empty() ? std::wstring(L"The plate has no G-code.") : refusal);
            co_return;
        }
        std::string bytes = zs::signing::Sign(gcode);
        if (EndsWith(std::wstring(path), L".3mf"))
        {
            std::string wrapped;
            if (!WrapBambu(app, bytes, wrapped))
            {
                w.ShowError(L"zslice could not make the .gcode.3mf file of the plate.");
                co_return;
            }
            bytes = std::move(wrapped);
        }
        if (zs::state::WriteBytes(std::wstring(path), bytes))
            Note(L"Exported " + std::wstring(path));
        else
            w.ShowError(L"The G-code was not saved.");
    }

    // A file to check some layers before a long print. It starts no print.
    winrt::fire_and_forget MainWindow::PrintersUi::ExportTestPrint(bool top_only)
    {
        auto keep = shared_from_this();
        // The await can outlast the window: this keeps it.
        auto window = w.get_strong();
        zs_app *app = w.model->Active();
        if (zs_app_state(app) != ZS_STATE_DONE || w.layer_count == 0)
        {
            Note(L"No G-code: slice first.");
            co_return;
        }
        size_t hi = (size_t)std::lround(w.LayerSlider().Value()) - 1;
        size_t lo = top_only ? hi : std::min(w.layer_lo, hi);
        uint8_t *out = nullptr;
        size_t len = 0;
        int rc = zs_app_debug_gcode(app, lo, hi + 1, &out, &len);
        if (rc != ZS_OK || out == nullptr)
        {
            std::wstring refusal = w.PlateRefusal(app);
            w.ShowError(refusal.empty() ? zs::ToWide(zs_status_message(rc)) : refusal);
            co_return;
        }
        std::string bytes = zs::signing::Sign(std::string(reinterpret_cast<char const *>(out), len));
        zs_buffer_free(out, len);
        zs_plate_info info{};
        std::string base = zs_set_plate_info(w.model->Set(), w.model->ActivePlate(), &info) == ZS_OK && info.name != nullptr && info.name[0] != 0 ? info.name : "part";
        size_t dot = base.find_last_of('.');
        if (dot != std::string::npos && dot > 0)
            base.resize(dot);
        for (char &c : base)
            if (strchr("\\/:*?\"<>|", c) != nullptr)
                c = '_';
        std::wstring what = lo == hi ? L"layer-" + std::to_wstring(hi + 1) : L"layers-" + std::to_wstring(lo + 1) + L"-" + std::to_wstring(hi + 1);
        hstring path = co_await PickSavePath(zs::ToWide(base) + L"-test-" + what, L"G-code", L".gcode");
        if (path.empty())
            co_return;
        if (zs::state::WriteBytes(std::wstring(path), bytes))
            Note(lo == hi ? L"A test print of layer " + std::to_wstring(hi + 1) + L", on the bed."
                          : L"A test print of layers " + std::to_wstring(lo + 1) + L" to " + std::to_wstring(hi + 1) + L", on the bed.");
        else
            w.ShowError(L"The test print was not saved.");
    }

    winrt::fire_and_forget MainWindow::PrintersUi::SaveProject()
    {
        auto keep = shared_from_this();
        // The await can outlast the window: this keeps it.
        auto window = w.get_strong();
        // A project with a part on any plate saves, also from an empty plate.
        // Its name comes from the active plate, else the first with parts.
        std::string base;
        size_t active = w.model->ActivePlate();
        for (size_t i = 0, n = w.model->PlateCount(); i < n; i++)
        {
            zs_plate_info plate{};
            if (zs_set_plate_info(w.model->Set(), i, &plate) != ZS_OK || plate.part_count == 0)
                continue;
            if (base.empty() || i == active)
                base = plate.name[0] != 0 ? plate.name : "plate";
        }
        if (base.empty())
            co_return;
        size_t dot = base.find_last_of('.');
        if (dot != std::string::npos && dot > 0)
            base.resize(dot);
        hstring path = co_await PickSavePath(zs::ToWide(base), L"zslice project (3MF)", L".3mf");
        if (path.empty() || w.model == nullptr)
            co_return;
        std::wstring chosen{ path };
        size_t slash = chosen.find_last_of(L"\\/");
        std::wstring stem = slash == std::wstring::npos ? chosen : chosen.substr(slash + 1);
        size_t ext = stem.find_last_of(L'.');
        if (ext != std::wstring::npos && ext > 0)
            stem.resize(ext);
        uint8_t *bytes = nullptr;
        size_t len = 0;
        if (zs_set_project_save(w.model->Set(), zs::ToUtf8(stem).c_str(), &bytes, &len) != ZS_OK || bytes == nullptr)
        {
            w.ShowError(L"The project did not write.");
            co_return;
        }
        bool ok = zs::state::WriteBytes(chosen, std::string(reinterpret_cast<char const *>(bytes), len));
        zs_buffer_free(bytes, len);
        if (ok)
        {
            Note(L"Saved " + chosen);
            w.MarkHistorySaved();
        }
        else
            w.ShowError(L"The project was not saved.");
    }

    winrt::fire_and_forget MainWindow::PrintersUi::ExportAll()
    {
        auto keep = shared_from_this();
        // The await can outlast the window: this keeps it.
        auto window = w.get_strong();
        if (batch.on)
            co_return;
        std::wstring dir = SaveDirHook();
        if (dir.empty())
        {
            Storage::Pickers::FolderPicker picker;
            picker.as<::IInitializeWithWindow>()->Initialize(w.hwnd);
            picker.FileTypeFilter().Append(L"*");
            auto folder = co_await picker.PickSingleFolderAsync();
            if (folder == nullptr)
                co_return;
            dir = std::wstring(folder.Path());
        }
        if (w.model == nullptr || batch.on)
            co_return;
        zs_set *set = w.model->Set();
        batch = Batch{};
        batch.on = true;
        batch.send = false;
        batch.n = zs_set_count(set);
        batch.back = zs_set_active(set);
        batch.dir = dir;
        BatchNext();
    }

    void MainWindow::PrintersUi::SendAll()
    {
        if (batch.on || sending)
            return;
        // Plates in a row need a clear bed between them.
        if (zs::Printers().Current().kind == zs::LinkKind::Usb)
        {
            Note(L"A USB printer prints one plate at a time. Use Print over USB.");
            return;
        }
        zs_set *set = w.model->Set();
        batch = Batch{};
        batch.on = true;
        batch.send = true;
        batch.n = zs_set_count(set);
        batch.back = zs_set_active(set);
        BatchNext();
    }

    // The next plate with parts: switch to it, and wait for its slice.
    void MainWindow::PrintersUi::BatchNext()
    {
        zs_set *set = w.model->Set();
        zs_plate_info info{};
        while (batch.i < batch.n)
        {
            if (zs_set_plate_info(set, batch.i, &info) != ZS_OK || info.part_count == 0 || info.status == ZS_PLATE_STATUS_CANNOT)
            {
                batch.i++;
                continue;
            }
            // A plate with a part that does not fit stays here, and the
            // last note says so.
            std::wstring refusal = w.PlateRefusal(zs_set_app(set, batch.i));
            if (refusal.empty())
                break;
            if (batch.skipped++ == 0)
                batch.why = L"plate " + std::to_wstring(batch.i + 1) + L": " + refusal;
            batch.i++;
        }
        if (batch.i >= batch.n)
        {
            BatchFinish({});
            return;
        }
        if (zs_set_active(set) != batch.i)
            w.SelectPlate(batch.i);
        int state = zs_app_state(w.model->Active());
        // The batch waits for a slice that is no draft.
        if (state == ZS_STATE_DONE && w.model->IsDraft())
        {
            w.model->SliceExact(batch.i);
        }
        else if (state == ZS_STATE_DONE)
        {
            Poster post = poster;
            post.Post([](PrintersUi &ui) { ui.BatchTake(); });
        }
        else if (state != ZS_STATE_SLICING)
            zs_set_changed(set, batch.i);
    }

    // The slice of the plate is done: send it, or write it.
    void MainWindow::PrintersUi::BatchTake()
    {
        if (!batch.on || sending || w.model->ActivePlate() != batch.i)
            return;
        zs_app *app = w.model->Active();
        if (zs_app_state(app) != ZS_STATE_DONE || zs_app_is_draft(app) != 0)
            return;
        if (batch.send)
        {
            Note(L"Sending plate " + std::to_wstring(batch.i + 1) + L" of " + std::to_wstring(batch.n) + L"…");
            batch_sending = true;
            SendPlate(zs::Printers().Current().id, batch.i);
            batch_sending = false;
            if (!sending)
                BatchFinish(L"The plate did not go out.");
            return;
        }
        zs_plate_info info{};
        std::string base = zs_set_plate_info(w.model->Set(), batch.i, &info) == ZS_OK && info.name[0] != 0 ? info.name : "plate";
        size_t dot = base.find_last_of('.');
        if (dot != std::string::npos && dot > 0)
            base.resize(dot);
        for (char &c : base)
            if (strchr("\\/:*?\"<>|", c) != nullptr)
                c = '_';
        std::wstring path = batch.dir + L"\\" + zs::ToWide(base) + L"-plate-" + std::to_wstring(batch.i + 1) + L".gcode";
        std::string gcode = CopyGcode(app);
        if (gcode.empty() || !zs::state::WriteBytes(path, zs::signing::Sign(gcode)))
        {
            BatchFinish(L"A file did not write.");
            return;
        }
        batch.done++;
        batch.i++;
        BatchNext();
    }

    void MainWindow::PrintersUi::BatchFinish(std::wstring const &error)
    {
        bool was_send = batch.send;
        size_t done = batch.done, back = batch.back;
        batch.on = false;
        if (back < zs_set_count(w.model->Set()))
            w.SelectPlate(back);
        if (!error.empty())
        {
            w.ShowError((was_send ? L"Not all plates were sent: " : L"Not all plates were exported: ") + error);
            return;
        }
        std::wstring count = std::to_wstring(done) + (done == 1 ? L" plate" : L" plates");
        std::wstring result = was_send ? count + L" sent to " + zs::ToWide(zs::Printers().Current().name) + L"." : count + L" exported.";
        if (batch.skipped > 0)
            w.ShowError(result + L" " + std::to_wstring(batch.skipped) + (batch.skipped == 1 ? L" plate does not fit, " : L" plates do not fit, ") + batch.why);
        else
            Note(result);
    }

    // ZSLICE_PLATES=file;file adds a plate for each file and loads the file
    // on it, one each 1.5 s, then goes back to plate 1, as in the GTK shell.
    void MainWindow::PrintersUi::StartPlatesHook()
    {
        wchar_t value[2048];
        DWORD n = ::GetEnvironmentVariableW(L"ZSLICE_PLATES", value, ARRAYSIZE(value));
        if (n == 0 || n >= ARRAYSIZE(value))
            return;
        auto files = std::make_shared<std::vector<std::wstring>>();
        std::wstring text(value, n);
        size_t at = 0;
        while (at <= text.size())
        {
            size_t end = text.find(L';', at);
            if (end == std::wstring::npos)
                end = text.size();
            if (end > at)
                files->push_back(text.substr(at, end - at));
            at = end + 1;
        }
        plates_timer = w.queue.CreateTimer();
        plates_timer.Interval(std::chrono::milliseconds(1500));
        auto next = std::make_shared<size_t>(0);
        plates_timer.Tick([this, files, next](auto &&, auto &&) {
            if (*next >= files->size())
            {
                plates_timer.Stop();
                w.SelectPlate(0);
                return;
            }
            if (w.model->AddPlate())
            {
                w.ShowPlate();
                w.LoadPath((*files)[(*next)]);
            }
            (*next)++;
        });
        plates_timer.Start();
    }

    void MainWindow::PrintersUi::OnSliced()
    {
        if (export_pending)
        {
            export_pending = false;
            ExportGcode();
        }
        if (batch.on)
            BatchTake();
        if (page != nullptr && page.Visibility() == Visibility::Visible)
            RefreshQueue();
    }

    void MainWindow::PrintersUi::OnFailed()
    {
        export_pending = false;
        if (batch.on)
            BatchFinish(L"A plate did not slice.");
    }
}
