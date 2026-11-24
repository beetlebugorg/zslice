// See zs_printer_link.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_printer_link.h"

#include "zs_json.h"
#include "zs_signing.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <thread>

namespace zs::link
{
    namespace
    {
        // The printer keeps a request for a key for 2 minutes.
        constexpr int key_wait_s = 125;

        std::string Lower(std::string text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            return text;
        }

        bool StartsWith(std::string const &text, char const *prefix)
        {
            return text.rfind(prefix, 0) == 0;
        }

        std::string Trimmed(std::string const &text)
        {
            size_t a = text.find_first_not_of(" \t\r\n");
            if (a == std::string::npos)
                return {};
            return text.substr(a, text.find_last_not_of(" \t\r\n") - a + 1);
        }

        std::vector<std::string> Words(std::string const &text)
        {
            std::vector<std::string> out;
            std::string word;
            for (unsigned char c : Lower(text))
            {
                if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
                    word += (char)c;
                else if (!word.empty())
                {
                    out.push_back(word);
                    word.clear();
                }
            }
            if (!word.empty())
                out.push_back(word);
            return out;
        }

        // True when the words of one name are all in the other ("Bambu Lab
        // X2D" and "X2D"), with no case.
        bool NamesOne(std::string const &a, std::string const &b)
        {
            auto wa = Words(a), wb = Words(b);
            if (wa.empty() || wb.empty())
                return false;
            auto all_in = [](std::vector<std::string> const &x, std::vector<std::string> const &y) {
                return std::all_of(x.begin(), x.end(), [&](std::string const &w) { return std::find(y.begin(), y.end(), w) != y.end(); });
            };
            return all_in(wa, wb) || all_in(wb, wa);
        }

        bool NamesPrinter(DeckPrinter const &d, std::string const &name)
        {
            return NamesOne(d.name, name) || NamesOne(d.label, name);
        }

        std::string SameText(std::string const &text)
        {
            return Lower(Trimmed(text));
        }

        // The path of a deck printer in an address ("/printers/<id>", or ""
        // for the deck itself), and the length of the root before it.
        std::string DeckPath(std::string const &url, size_t &root_len)
        {
            size_t n = url.size();
            while (n > 0 && url[n - 1] == '/')
                n--;
            size_t at = url.find("/printers/");
            if (at == std::string::npos || at >= n)
            {
                root_len = n;
                return {};
            }
            root_len = at;
            size_t end = url.find('/', at + 10);
            return url.substr(at, (end == std::string::npos ? n : std::min(end, n)) - at);
        }

        struct Origin
        {
            std::string scheme, host;
            int port = 0;
        };

        bool OriginOf(std::string const &url, Origin &out)
        {
            size_t s = url.find("://");
            if (s == std::string::npos)
                return false;
            out.scheme = Lower(url.substr(0, s));
            if (out.scheme != "http" && out.scheme != "https")
                return false;
            size_t start = s + 3;
            size_t end = url.find_first_of("/?#", start);
            std::string auth = url.substr(start, end == std::string::npos ? std::string::npos : end - start);
            // A user part can hide the real host ("printer@other").
            if (auth.find('@') != std::string::npos || auth.empty())
                return false;
            size_t colon = auth.rfind(':');
            size_t bracket = auth.rfind(']');
            if (colon != std::string::npos && (bracket == std::string::npos || colon > bracket))
            {
                out.host = Lower(auth.substr(0, colon));
                out.port = atoi(auth.c_str() + colon + 1);
            }
            else
            {
                out.host = Lower(auth);
                out.port = out.scheme == "https" ? 443 : 80;
            }
            return !out.host.empty();
        }

        http::Response Get(Target const &t, std::string const &base, std::string const &path, CancelPtr const &cancel, int timeout_ms = 15000)
        {
            http::Request req;
            req.url = base + path;
            req.api_key = t.api_key;
            req.cancel = cancel;
            req.timeout_ms = timeout_ms;
            return http::Send(req);
        }

        std::string StatusText(char const *who, http::Response const &r)
        {
            return std::string("The ") + who + " answered " + std::to_string(r.status) + ".";
        }

        // Checks the certificate of an https reply against the pin. WinHTTP
        // has checked the chain and the name. The first reply sets the pin.
        // A later certificate replaces it (a deck renews every 60 days).
        bool CheckPin(Target &t, http::Response const &r, std::string &why)
        {
            if (r.cert_sha256.empty())
                return true;
            if (t.tls_pin.empty() || (r.cert_since > t.tls_since && r.cert_sha256 != t.tls_pin))
            {
                t.tls_pin = r.cert_sha256;
                t.tls_since = r.cert_since;
                t.pin_changed = true;
                return true;
            }
            if (r.cert_sha256 == t.tls_pin)
                return true;
            why = "The certificate of " + t.name +
                  " changed to an older or another one. A device on the network can claim to be the printer. "
                  "The file did not go out. If you set up the printer again, press Get a key to trust it again.";
            return false;
        }

        bool StoredAnswer(std::string const &body)
        {
            json::Value root;
            if (!json::Parse(body, root))
                return false;
            json::Value const *done = root.Get("done");
            return root.Path("files.local") != nullptr || (done != nullptr && done->type == json::Type::Bool && done->boolean);
        }
    }

    Target TargetOf(SavedPrinter const &p)
    {
        Target t;
        t.id = p.id;
        t.name = p.name;
        t.kind = p.kind;
        t.url = p.url;
        t.api_key = p.api_key;
        t.deck_name = p.deck_name;
        t.tls_pin = p.tls_pin;
        t.tls_since = p.tls_since;
        return t;
    }

    std::string BaseUrl(std::string const &url)
    {
        std::string base = Trimmed(url);
        while (!base.empty() && base.back() == '/')
            base.pop_back();
        if (base.empty())
            return base;
        std::string low = Lower(base);
        if (!StartsWith(low, "http://") && !StartsWith(low, "https://"))
            base = "http://" + base;
        return FixDoubled(base);
    }

    std::string FixDoubled(std::string const &url)
    {
        // "/printers/x/printers/x" has one copy.
        std::string out = url;
        for (;;)
        {
            size_t at = out.find("/printers/");
            bool changed = false;
            while (at != std::string::npos)
            {
                size_t end = out.find('/', at + 10);
                if (end == std::string::npos)
                    break;
                std::string part = out.substr(at, end - at);
                if (out.compare(end, part.size(), part) == 0 &&
                    (end + part.size() == out.size() || out[end + part.size()] == '/'))
                {
                    out.erase(end, part.size());
                    changed = true;
                    break;
                }
                at = out.find("/printers/", end);
            }
            if (!changed)
                return out;
        }
    }

    std::string DeckRoot(std::string const &url)
    {
        size_t root_len = 0;
        std::string fixed = FixDoubled(url);
        DeckPath(fixed, root_len);
        return fixed.substr(0, root_len);
    }

    std::string DeckAddress(std::string const &base, std::string const &path)
    {
        if (base.empty())
            return {};
        // An empty path is the first printer: it lives at the root, also
        // when the base is the address of another printer.
        if (path.empty())
            return BaseUrl(DeckRoot(BaseUrl(base)));
        // A path stays on the deck: the key goes there.
        if (path[0] != '/' || StartsWith(path, "//"))
            return {};
        for (unsigned char c : path)
        {
            bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '~' || c == '/' || c == '-';
            if (!ok)
                return {};
        }
        if (path.find("/../") != std::string::npos || (path.size() >= 3 && path.compare(path.size() - 3, 3, "/..") == 0))
            return {};
        std::string root = BaseUrl(DeckRoot(BaseUrl(base)));
        std::string url = root + path;
        return SameOrigin(url, root) ? url : std::string{};
    }

    bool SameOrigin(std::string const &a, std::string const &b)
    {
        Origin x, y;
        return OriginOf(a, x) && OriginOf(b, y) && x.scheme == y.scheme && x.host == y.host && x.port == y.port;
    }

    int CoreKind(LinkKind kind)
    {
        switch (kind)
        {
        case LinkKind::OctoPrint:
        case LinkKind::PrusaLink:
            return 1;
        case LinkKind::Printdeck:
            return 2;
        case LinkKind::Moonraker:
            return 3;
        case LinkKind::Bambu:
            return 4;
        default:
            return 0;
        }
    }

    Snapshot SnapshotOf(zs_printer_status const *st)
    {
        Snapshot s;
        zs_printer_info i{};
        if (st == nullptr || zs_printer_status_get(st, &i) != ZS_OK)
            return s;
        auto text = [](char const *t) { return std::string(t != nullptr ? t : ""); };
        s.state = text(i.state);
        s.job = text(i.job);
        s.material = text(i.material);
        s.message = text(zs_printer_status_message(st));
        s.spool_name = text(i.spool.name);
        s.spool_id = text(i.spool.id);
        s.spool_color = text(i.spool.color);
        s.spool_left = i.spool.left;
        s.spool_price = i.spool_price;
        s.spool_full = i.spool_full;
        s.bed_x = i.bed_x;
        s.bed_y = i.bed_y;
        s.height = i.height;
        s.nozzle = i.nozzle;
        s.diameter = i.diameter;
        s.progress = i.progress;
        s.time_left = i.time_left;
        s.layer = i.layer;
        s.layers = i.layers;
        s.farm_state = zs_printer_status_farm_state(st);
        // A Bambu Lab printer that answers with no state yet: it is there.
        if (s.farm_state == ZS_FARM_OFFLINE && s.state.empty())
            s.farm_state = ZS_FARM_IDLE;
        zs_printer_heat h{};
        if (zs_printer_status_heat(st, &h) == ZS_OK)
        {
            s.has_nozzle = !std::isnan(h.nozzle);
            s.has_bed = !std::isnan(h.bed);
            s.has_chamber = !std::isnan(h.chamber);
            s.heat_nozzle = s.has_nozzle ? h.nozzle : 0;
            s.heat_nozzle_target = std::isnan(h.nozzle_target) ? 0 : h.nozzle_target;
            s.heat_bed = s.has_bed ? h.bed : 0;
            s.heat_bed_target = std::isnan(h.bed_target) ? 0 : h.bed_target;
            s.heat_chamber = s.has_chamber ? h.chamber : 0;
        }
        for (size_t k = 0; k < i.roll_count; k++)
        {
            zs_printer_roll r{};
            if (zs_printer_status_roll(st, k, &r) != ZS_OK)
                continue;
            s.rolls.push_back(Roll{ text(r.id), text(r.name), text(r.material), text(r.color), r.left });
        }
        return s;
    }

    std::string TimeText(double seconds)
    {
        int m = (int)std::lround(seconds / 60);
        return m >= 60 ? std::to_string(m / 60) + " h " + std::to_string(m % 60) + " min" : std::to_string(m) + " min";
    }

    std::string StatusLine(Snapshot const &s)
    {
        std::string out = s.state.empty() ? "Connected" : s.state;
        if (!s.job.empty())
        {
            out += " · " + s.job;
            if (s.progress > 0)
                out += ", " + std::to_string((int)std::lround(s.progress * 100)) + " %";
            if (s.time_left > 0)
                out += ", " + TimeText(s.time_left) + " left";
        }
        if (!s.spool_name.empty())
        {
            out += " · " + s.spool_name;
            if (!s.material.empty())
                out += " (" + s.material + ")";
            if (s.spool_left > 0)
                out += ", " + std::to_string((int)std::lround(s.spool_left)) + " g left";
        }
        else if (!s.material.empty())
            out += " · " + s.material;
        return out;
    }

    bool ReadStatus(Target const &t, CancelPtr const &cancel, Snapshot &out, std::string &error)
    {
        // A status read never opens a serial port: an open can restart it.
        if (t.kind == LinkKind::Usb)
        {
            error = "A USB printer has no network connection.";
            return false;
        }
        int kind = CoreKind(t.kind);
        if (kind == 0 || kind == 4)
        {
            error = kind == 4 ? "A Bambu Lab printer gives its status on the Printers page." : "This printer has no connection.";
            return false;
        }
        std::string base = BaseUrl(t.url);
        if (base.empty())
        {
            error = "Set the address of the printer.";
            return false;
        }
        std::shared_ptr<zs_printer_status> status(zs_printer_status_new(), zs_printer_status_free);
        if (status == nullptr)
        {
            error = "Out of memory.";
            return false;
        }
        std::string paths = zs_printer_status_paths(kind);
        size_t at = 0;
        for (int step = 0; at < paths.size(); step++)
        {
            size_t end = paths.find('\n', at);
            if (end == std::string::npos)
                end = paths.size();
            std::string path = paths.substr(at, end - at);
            at = end + 1;
            if (path.empty())
                continue;
            http::Response r = Get(t, base, path, cancel);
            if (r.status == 0)
            {
                error = r.error;
                return false;
            }
            if (r.status == 401 || r.status == 403)
            {
                error = "The printer did not accept the API key.";
                return false;
            }
            if (r.Ok())
                zs_printer_status_feed(status.get(), kind, path.c_str(), r.body.data(), r.body.size());
            else if (step == 0)
            {
                error = StatusText("printer", r);
                return false;
            }
        }
        out = SnapshotOf(status.get());
        out.core = std::move(status);
        return true;
    }

    bool ReadCamera(Target const &t, CancelPtr const &cancel, Camera &out, std::string &error)
    {
        if (t.kind == LinkKind::Usb)
        {
            error = "A USB printer has no network connection.";
            return false;
        }
        int kind = CoreKind(t.kind);
        std::string base = BaseUrl(t.url);
        if (kind == 0 || kind == 4 || base.empty())
        {
            error = "This printer gives no camera over HTTP.";
            return false;
        }
        std::unique_ptr<zs_printer_status, decltype(&zs_printer_status_free)> status(zs_printer_status_new(), zs_printer_status_free);
        std::string paths = zs_printer_camera_paths(kind);
        size_t at = 0;
        while (at < paths.size())
        {
            size_t end = paths.find('\n', at);
            if (end == std::string::npos)
                end = paths.size();
            std::string path = paths.substr(at, end - at);
            at = end + 1;
            if (path.empty())
                continue;
            http::Response r = Get(t, base, path, cancel);
            if (r.status == 0)
            {
                error = r.error;
                return false;
            }
            if (r.status == 401 || r.status == 403)
            {
                error = "The printer did not accept the API key.";
                return false;
            }
            if (r.Ok())
                zs_printer_status_feed(status.get(), kind, path.c_str(), r.body.data(), r.body.size());
        }
        zs_printer_camera cam{};
        if (zs_printer_status_camera(status.get(), &cam) != ZS_OK)
            return true;
        // An address of the camera, absolute: a relative one is on the
        // printer. Only http and https load.
        auto absolute = [&](char const *u) -> std::string {
            if (u == nullptr || u[0] == 0)
                return {};
            std::string text = u;
            if (text.find("://") != std::string::npos)
            {
                Origin o;
                return OriginOf(text, o) ? text : std::string{};
            }
            if (text[0] == '/')
            {
                Origin o;
                if (StartsWith(text, "//") || !OriginOf(base, o))
                    return {};
                size_t s = base.find("://") + 3;
                size_t slash = base.find('/', s);
                return (slash == std::string::npos ? base : base.substr(0, slash)) + text;
            }
            return base + "/" + text;
        };
        out.stream = absolute(cam.stream);
        out.snapshot = absolute(cam.snapshot);
        out.flip_h = cam.flip_h;
        out.flip_v = cam.flip_v;
        out.rotation = cam.rotation;
        return true;
    }

    bool ReadDeck(Target const &t, CancelPtr const &cancel, DeckList &out, std::string &error)
    {
        std::string root = BaseUrl(DeckRoot(BaseUrl(t.url)));
        if (root.empty())
        {
            error = "The address is not valid.";
            return false;
        }
        http::Response r = Get(t, root, "/slicer/printer.json", cancel);
        if (r.status == 0)
        {
            error = r.error;
            return false;
        }
        if (r.status == 401 || r.status == 403)
        {
            error = "The deck refused the key.";
            return false;
        }
        if (!r.Ok())
        {
            error = StatusText("deck", r);
            return false;
        }
        json::Value doc;
        out = DeckList{};
        if (!json::Parse(r.body, doc) || !doc.IsObject())
            return true;
        out.name = doc.Str("name");
        // The https address must be https: the key goes there.
        std::string https = doc.Str("https");
        if (StartsWith(Lower(https), "https://"))
            out.https = https;
        json::Value const *list = doc.Get("printers");
        if (list == nullptr || !list->IsArray())
            return true;
        for (auto const &e : list->items)
        {
            DeckPrinter d;
            d.id = e.Str("id");
            d.name = e.Str("name");
            d.label = e.Str("label");
            d.color = e.Str("color");
            d.kind = e.Str("kind");
            d.path = e.Str("url");
            d.model = e.Str("model");
            if (!d.name.empty())
                out.printers.push_back(std::move(d));
        }
        return true;
    }

    std::string DeckRepairedUrl(std::string const &url, std::string const &deck_name, DeckList const &list)
    {
        if (SameText(deck_name).empty())
            return {};
        DeckPrinter const *hit = nullptr;
        for (auto const &d : list.printers)
        {
            if (SameText(d.name) != SameText(deck_name))
                continue;
            // Two printers of one name: the list cannot tell which.
            if (hit != nullptr)
                return {};
            hit = &d;
        }
        if (hit == nullptr)
            return {};
        std::string base = BaseUrl(url);
        std::string want = DeckAddress(base, hit->path);
        return want == base ? std::string{} : want;
    }

    bool ReadLoadedFilaments(Target const &t, CancelPtr const &cancel, std::string &body, std::string &error)
    {
        if (t.kind != LinkKind::Printdeck)
        {
            error = "Only a printdeck printer tells its filaments.";
            return false;
        }
        std::string base = BaseUrl(t.url);
        if (base.empty())
        {
            error = "The address is not valid.";
            return false;
        }
        http::Response r = Get(t, base, "/api/plugin/printdeck", cancel);
        if (r.status == 0)
        {
            error = r.error;
            return false;
        }
        if (r.status == 401 || r.status == 403)
        {
            error = "The deck refused the key.";
            return false;
        }
        if (!r.Ok())
        {
            error = StatusText("deck", r);
            return false;
        }
        body = std::move(r.body);
        return true;
    }

    std::string DeckRefusal(Target const &t, DeckList const &list)
    {
        if (list.printers.size() < 2)
            return {};
        size_t root_len = 0;
        std::string path = DeckPath(BaseUrl(t.url), root_len);
        DeckPrinter const *at = nullptr, *other = nullptr;
        for (auto const &d : list.printers)
            if (d.path == path)
                at = &d;
        for (auto const &d : list.printers)
            if (&d != at && NamesPrinter(d, t.name))
                other = &d;
        if (at == nullptr)
            return "The deck has no printer at " + (path.empty() ? std::string("its own address") : path) +
                   ". Nothing was sent. Add the printer again from the deck.";
        if (!t.deck_name.empty() && SameText(t.deck_name) != SameText(at->name))
            return "This address leads to " + at->name + " on the deck, not to " + t.deck_name +
                   ". Nothing was sent. Add the printer again from the deck.";
        if (other != nullptr && !NamesPrinter(*at, t.name))
            return t.name + " is at " + other->path + " on the deck, but the address of this printer leads to " + at->name +
                   ". Nothing was sent. Add " + t.name + " again from the deck.";
        // The address of the deck itself leads to its first printer. With
        // more printers, that must be the printer of the user for sure.
        if (path.empty() && t.deck_name.empty() && !NamesPrinter(*at, t.name) && SameText(at->name) != SameText(t.name))
            return "The address of " + t.name + " is the deck itself, which prints on " + at->name + ". zslice cannot tell that " +
                   t.name + " is " + at->name + ". Nothing was sent. Add the printer again from the deck, and pick it from the list of the deck.";
        return {};
    }

    bool DetectKind(std::string const &url, CancelPtr const &cancel, LinkKind &kind, std::string &error)
    {
        std::string base = BaseUrl(url);
        if (base.empty())
        {
            error = "Type the address of the printer.";
            return false;
        }
        Target none;
        http::Response r = Get(none, base, "/api/version", cancel, 5000);
        if (r.cancelled)
        {
            error = r.error;
            return false;
        }
        if (r.Ok())
        {
            json::Value doc;
            std::string text;
            if (json::Parse(r.body, doc))
                text = Lower(doc.Str("text") + " " + doc.Str("server") + " " + doc.Str("name"));
            kind = text.find("printdeck") != std::string::npos   ? LinkKind::Printdeck
                   : text.find("prusalink") != std::string::npos ? LinkKind::PrusaLink
                                                                 : LinkKind::OctoPrint;
            return true;
        }
        r = Get(none, base, "/server/info", cancel, 5000);
        if (r.Ok())
        {
            kind = LinkKind::Moonraker;
            return true;
        }
        error = r.status == 0 ? r.error : "The printer at this address is not a printdeck, an OctoPrint, a PrusaLink, or a Moonraker printer.";
        return false;
    }

    KeyResult RequestKey(Target &t, CancelPtr const &cancel, std::function<void(int)> const &wait)
    {
        KeyResult out;
        if (t.url.empty())
        {
            out.message = "No address.";
            return out;
        }
        if (t.kind == LinkKind::Moonraker)
        {
            out.message = "Moonraker gives no API keys this way: it needs none, or the key of its config.";
            return out;
        }
        // A printdeck pairs at its root: the key is of the deck, good for
        // all its printers and their list.
        std::string base = (t.kind == LinkKind::Printdeck ? BaseUrl(DeckRoot(BaseUrl(t.url))) : BaseUrl(t.url)) + "/plugin/appkeys/request";
        std::string body = "{\"app\":\"zslice\"";
        if (t.kind == LinkKind::Printdeck)
        {
            std::string pub = signing::PublicKey();
            if (!pub.empty())
                body += ",\"public_key\":" + json::Quote(pub);
        }
        body += "}";
        http::Request ask;
        ask.method = "POST";
        ask.url = base;
        ask.content_type = "application/json";
        ask.body = body;
        ask.cancel = cancel;
        http::Response r = http::Send(ask);
        if (r.cancelled)
        {
            out.cancelled = true;
            out.message = "Canceled.";
            return out;
        }
        if (r.status == 0)
        {
            out.message = r.error;
            return out;
        }
        if (r.status == 404)
        {
            out.message = "The printer does not give keys to apps (App Keys is off or missing).";
            return out;
        }
        if (!r.Ok())
        {
            out.message = StatusText("printer", r);
            return out;
        }
        json::Value doc;
        std::string token = json::Parse(r.body, doc) ? doc.Str("app_token") : std::string{};
        if (token.empty())
        {
            out.message = "The printer gave no request token.";
            return out;
        }
        auto t0 = std::chrono::steady_clock::now();
        auto elapsed = [&] { return (int)std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - t0).count(); };
        for (;;)
        {
            if (cancel != nullptr && cancel->Stopped())
            {
                out.cancelled = true;
                out.message = "Canceled.";
                return out;
            }
            if (elapsed() >= key_wait_s)
            {
                out.message = "No answer on the printer in 2 minutes.";
                return out;
            }
            if (wait)
                wait(elapsed());
            for (int i = 0; i < 10 && (cancel == nullptr || !cancel->Stopped()); i++)
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            if (cancel != nullptr && cancel->Stopped())
                continue;
            http::Request poll;
            poll.url = base + "/" + http::Escape(token);
            poll.cancel = cancel;
            http::Response p = http::Send(poll);
            if (p.cancelled)
                continue;
            if (p.status == 0)
            {
                out.message = p.error;
                return out;
            }
            if (p.status == 202)
                continue;
            if (p.status == 404)
            {
                out.message = "The printer did not allow it (Deny), or the request waited too long.";
                return out;
            }
            if (p.status != 200)
            {
                out.message = StatusText("printer", p);
                return out;
            }
            json::Value answer;
            std::string key = json::Parse(p.body, answer) ? answer.Str("api_key") : std::string{};
            if (key.empty())
            {
                out.message = "The printer gave no key.";
                return out;
            }
            // A pairing trusts the certificate of now.
            if (!p.cert_sha256.empty())
            {
                t.tls_pin = p.cert_sha256;
                t.tls_since = p.cert_since;
                t.pin_changed = true;
            }
            out.ok = true;
            out.key = std::move(key);
            out.message = answer.Get("trusted_key") != nullptr ? "The printer gave zslice a key, and trusts the prints that zslice signs."
                                                               : "The printer gave zslice a key.";
            return out;
        }
    }

    // The checks before G-code leaves this computer: the deck leads to the
    // printer that the user picked, and the certificate is the known one.
    static bool CheckBeforeFile(Target &t, std::string const &base, CancelPtr const &cancel, UploadResult &out)
    {
        if (t.kind == LinkKind::Printdeck)
        {
            // A deck with more printers: the address must lead to the one
            // that the user picked. A deck with no list cannot be checked.
            DeckList list;
            std::string ignored;
            if (ReadDeck(t, cancel, list, ignored))
            {
                std::string why = DeckRefusal(t, list);
                if (!why.empty())
                {
                    out.message = why;
                    return false;
                }
            }
            if (cancel != nullptr && cancel->Stopped())
            {
                out.cancelled = true;
                out.message = "Canceled.";
                return false;
            }
        }
        // On https: a small request first, to check the certificate before
        // the file goes out.
        if (StartsWith(Lower(base), "https://"))
        {
            http::Response r = Get(t, base, t.kind == LinkKind::Moonraker ? "/server/info" : "/api/version", cancel);
            if (r.status == 0)
            {
                out.cancelled = r.cancelled;
                out.message = r.error;
                return false;
            }
            std::string why;
            if (!CheckPin(t, r, why))
            {
                out.message = why;
                return false;
            }
        }
        return true;
    }

    static UploadResult Transfer(Target &t, std::string const &filename, std::string const &bytes, CancelPtr const &cancel,
                                 std::function<void(double)> const &progress, bool print)
    {
        UploadResult out;
        if (t.kind == LinkKind::Usb)
        {
            // A USB port has no upload: each line runs. See zs_usb.h.
            out.message = "A USB printer has no upload. Use Print over USB.";
            return out;
        }
        if (t.kind == LinkKind::None)
        {
            out.message = "This printer has no connection.";
            return out;
        }
        if (t.kind == LinkKind::Bambu)
        {
            // The app reads a Bambu Lab printer, and sends it nothing.
            out.message = "The Windows app cannot send files to a Bambu Lab printer. Export the G-code, or use Bambu Studio.";
            return out;
        }
        std::string base = BaseUrl(t.url);
        if (base.empty())
        {
            out.message = "Set the address of the printer.";
            return out;
        }
        if (!CheckBeforeFile(t, base, cancel, out))
            return out;
        http::Form form = http::NewForm();
        form.File("file", filename, bytes);
        // Only UploadAndPrint sets this.
        form.Field("print", print ? "true" : "false");
        http::Request req;
        req.method = "POST";
        req.url = base + (t.kind == LinkKind::Moonraker ? "/server/files/upload" : "/api/files/local");
        req.api_key = t.api_key;
        req.content_type = form.Finish();
        req.body = std::move(form.body);
        req.cancel = cancel;
        req.timeout_ms = 120000;
        req.sent = progress;
        http::Response r = http::Send(req);
        if (r.cancelled)
        {
            out.cancelled = true;
            out.message = "Canceled.";
            return out;
        }
        if (r.status == 0)
        {
            out.message = r.error;
            return out;
        }
        std::string warning;
        if (!CheckPin(t, r, warning))
        {
            out.message = warning + " (The file went to the printer before this check.)";
            return out;
        }
        if (r.status == 401 || r.status == 403)
        {
            out.message = "The printer refused the API key.";
            return out;
        }
        if (!r.Ok())
        {
            json::Value doc;
            std::string reason = json::Parse(r.body, doc) ? doc.Str("error") : std::string{};
            out.message = "The printer answered " + std::to_string(r.status) + (reason.empty() ? std::string(".") : ": " + reason);
            return out;
        }
        // An upload of OctoPrint and printdeck answers JSON with the stored
        // file. Any other 2xx answer (a web page, a proxy) stored nothing.
        if (t.kind != LinkKind::Moonraker && !StoredAnswer(r.body))
        {
            out.message = t.name + " answered " + std::to_string(r.status) +
                          ", but not with a stored file. The file may not be on the printer: check its address in Printers.";
            return out;
        }
        out.ok = true;
        if (!print)
            out.message = "Uploaded to " + t.name + " (" + LinkTitle(t.kind) + "). Start the print on the printer.";
        else if (t.kind == LinkKind::Printdeck)
            out.message = "Sent to " + t.name + ". It prints, or waits for a press of Print if the deck is set to ask.";
        else
            out.message = "Sent to " + t.name + "; it prints.";
        return out;
    }

    UploadResult Upload(Target &t, std::string const &filename, std::string const &bytes, CancelPtr const &cancel,
                        std::function<void(double)> const &progress)
    {
        return Transfer(t, filename, bytes, cancel, progress, false);
    }

    UploadResult UploadAndPrint(Target &t, std::string const &filename, std::string const &bytes, CancelPtr const &cancel,
                                std::function<void(double)> const &progress, PrintConfirmed)
    {
        return Transfer(t, filename, bytes, cancel, progress, true);
    }

    EstimateResult ReadEstimate(Target &t, std::string const &gcode, CancelPtr const &cancel)
    {
        EstimateResult out;
        if (t.kind != LinkKind::Printdeck)
        {
            out.message = "This printer has no estimates.";
            return out;
        }
        std::string base = BaseUrl(t.url);
        if (base.empty())
        {
            out.message = "Set the address of the printer.";
            return out;
        }
        UploadResult check;
        if (!CheckBeforeFile(t, base, cancel, check))
        {
            out.cancelled = check.cancelled;
            out.message = check.message;
            return out;
        }
        if (cancel != nullptr && cancel->Stopped())
        {
            out.cancelled = true;
            out.message = "Canceled.";
            return out;
        }
        uint8_t *zipped = nullptr;
        size_t zipped_len = 0;
        if (zs_gzip(reinterpret_cast<uint8_t const *>(gcode.data()), gcode.size(), &zipped, &zipped_len) != ZS_OK)
        {
            out.message = "The G-code could not be packed.";
            return out;
        }
        http::Request req;
        req.method = "POST";
        req.url = base + "/api/plugin/printdeck/estimate";
        req.api_key = t.api_key;
        req.content_type = "text/plain";
        req.content_encoding = "gzip";
        req.body.assign(reinterpret_cast<char const *>(zipped), zipped_len);
        zs_gzip_free(zipped, zipped_len);
        req.cancel = cancel;
        req.timeout_ms = 60000;
        http::Response r = http::Send(req);
        if (r.cancelled)
        {
            out.cancelled = true;
            out.message = "Canceled.";
            return out;
        }
        if (r.status == 0)
        {
            out.message = r.error;
            return out;
        }
        std::string warning;
        if (!CheckPin(t, r, warning))
        {
            out.message = warning;
            return out;
        }
        if (r.status != 200)
        {
            out.message = "The printer answered " + std::to_string(r.status) + ".";
            return out;
        }
        json::Value doc;
        if (!json::Parse(r.body, doc))
        {
            out.message = "The printer sent no estimate.";
            return out;
        }
        Estimate e;
        e.moves = doc.Num("moves");
        e.prep = doc.Num("prep");
        e.total = doc.Num("total");
        e.plan_prints = (int)std::clamp(doc.Num("plan_prints"), 0.0, 1000000.0);
        // A time of more than a year is no estimate.
        constexpr double longest = 366.0 * 24 * 3600;
        if (!std::isfinite(e.total) || !std::isfinite(e.prep) || e.total <= 0 || e.total > longest || e.prep < 0 || e.prep > longest)
        {
            out.message = "The printer sent no estimate.";
            return out;
        }
        out.ok = true;
        out.estimate = e;
        return out;
    }

    std::string TrustText(Target const &t)
    {
        switch (t.kind)
        {
        case LinkKind::Printdeck:
            return StartsWith(Lower(t.url), "https://")
                       ? "zslice signs each file. Turn on Settings > Signed prints on the deck to refuse files from other apps."
                       : "zslice signs each file. The address is http, so zslice cannot verify the deck: use its https address.";
        case LinkKind::OctoPrint:
        case LinkKind::Moonraker:
        case LinkKind::PrusaLink:
            return "Not verified: this printer does not check the signatures of files.";
        case LinkKind::Bambu:
            return "zslice trusts the certificate that it sees first, and only reads this printer.";
        default:
            return {};
        }
    }
}
