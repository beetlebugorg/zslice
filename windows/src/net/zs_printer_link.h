#pragma once
// Talks to a printer over HTTP: reads its status, its camera, and its
// filaments, gets an API key, and uploads a file.
//
// printdeck, OctoPrint, and PrusaLink use the OctoPrint API (X-Api-Key).
// printdeck also has /api/plugin/printdeck and /slicer/printer.json at the
// root of the deck. Moonraker has its own API. The core reads each status
// reply (zs_printer_status). The flow follows linux/src/net/printer-link.c
// and web/app/link.js. See docs/references/formats-and-protocols.md.
//
// THE APP NEVER STARTS A PRINT. Upload always sends print=false, and no
// function here can send anything else. The person starts the print on the
// printer.
//
// Each call blocks, so it runs on a worker thread. It has no WinRT.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "zslice.h"
#include "zslice-app.h"

#include "zs_http.h"
#include "zs_printer_store.h"

namespace zs::link
{
    using http::CancelPtr;

    // A copy of a printer for a worker thread.
    struct Target
    {
        std::string id;
        std::string name;
        LinkKind kind = LinkKind::None;
        std::string url;
        std::string api_key;
        std::string deck_name;
        std::string tls_pin;
        int64_t tls_since = 0;
        // Set when a reply trusts a new certificate. The UI thread saves it.
        bool pin_changed = false;
    };
    Target TargetOf(SavedPrinter const &printer);

    // ---- addresses ----

    // The address with its scheme and no slash at the end.
    std::string BaseUrl(std::string const &url);
    // An address of a printer on a deck, with ".../printers/<id>" cut.
    std::string DeckRoot(std::string const &url);
    // An address with the path of a printer twice has it once.
    std::string FixDoubled(std::string const &url);
    // The address of a deck printer: the root and a path of the deck, or ""
    // for a path that could leave the deck.
    std::string DeckAddress(std::string const &base, std::string const &path);
    // True if both addresses have the same scheme, host, and port.
    bool SameOrigin(std::string const &a, std::string const &b);

    // ---- status ----

    struct Roll
    {
        std::string id, name, material, color;
        double left = 0;
    };

    // What a printer told, with no pointer into the core.
    struct Snapshot
    {
        std::string state, job, material, message;
        std::string spool_name, spool_id, spool_color;
        double bed_x = 0, bed_y = 0, height = 0, nozzle = 0, diameter = 0;
        double spool_left = 0, spool_price = 0, spool_full = 0;
        double progress = 0, time_left = -1;
        int layer = 0, layers = 0;
        // enum zs_farm_printer_state.
        int farm_state = ZS_FARM_OFFLINE;
        double heat_nozzle = 0, heat_nozzle_target = 0, heat_bed = 0, heat_bed_target = 0, heat_chamber = 0;
        bool has_nozzle = false, has_bed = false, has_chamber = false;
        std::vector<Roll> rolls;
        // The status of the core, for zs_app_apply_printer_status. Nothing
        // writes to it after the snapshot.
        std::shared_ptr<zs_printer_status> core;
    };

    Snapshot SnapshotOf(zs_printer_status const *status);
    // The kind of zs_printer_status for a link, or 0.
    int CoreKind(LinkKind kind);
    // "Printing Slate frame, 50 %, 1 h 5 min left".
    std::string StatusLine(Snapshot const &s);
    // The text of a time, "1 h 5 min".
    std::string TimeText(double seconds);

    bool ReadStatus(Target const &target, CancelPtr const &cancel, Snapshot &out, std::string &error);

    // ---- the camera ----

    struct Camera
    {
        std::string stream, snapshot; // absolute addresses, or ""
        int flip_h = 0, flip_v = 0, rotation = 0;
    };
    bool ReadCamera(Target const &target, CancelPtr const &cancel, Camera &out, std::string &error);

    // ---- a printdeck ----

    struct DeckPrinter
    {
        std::string id, name, label, color, kind, path, model;
    };
    struct DeckList
    {
        std::string name;  // of the deck
        std::string https; // its https address, or ""
        std::vector<DeckPrinter> printers;
    };
    // GET /slicer/printer.json at the root of the deck, with the key.
    bool ReadDeck(Target const &target, CancelPtr const &cancel, DeckList &out, std::string &error);
    // GET /api/plugin/printdeck: the reply for ParseDeckFilaments.
    bool ReadLoadedFilaments(Target const &target, CancelPtr const &cancel, std::string &body, std::string &error);
    // Pure, for tests: why a send to this deck list must stop, or "".
    std::string DeckRefusal(Target const &target, DeckList const &list);

    // The kind of printer at an address, from the paths that answer with no
    // key. False, with the reason, if none answers.
    bool DetectKind(std::string const &url, CancelPtr const &cancel, LinkKind &kind, std::string &error);

    // ---- an API key from the printer (App Keys) ----

    struct KeyResult
    {
        bool ok = false;
        bool cancelled = false;
        std::string key;
        std::string message;
    };
    // Asks the printer for a key. It asks its user "Allow zslice?". `wait`
    // gets the seconds since the request. A printdeck pairs at its root.
    KeyResult RequestKey(Target &target, CancelPtr const &cancel, std::function<void(int)> const &wait);

    // ---- upload ----

    struct UploadResult
    {
        bool ok = false;
        bool cancelled = false;
        std::string message;
    };
    // Uploads a file that is signed already, with print=false. A deck is
    // checked first, and the certificate of an https printer too.
    UploadResult Upload(Target &target, std::string const &filename, std::string const &bytes, CancelPtr const &cancel,
                        std::function<void(double)> const &progress);

    // Why this printer is or is not verified, for the printer list.
    std::string TrustText(Target const &target);
}
