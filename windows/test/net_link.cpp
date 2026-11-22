// Tests the printer connections of the Windows shell against stub servers on
// 127.0.0.1. Nothing here contacts a real printer or sends a packet to the
// real network, and no test starts a print.
//
// The stubs: an HTTP server that plays OctoPrint, Moonraker, and a printdeck,
// a UDP server that answers the mDNS query with canned packets, and a TLS
// server with a self-signed certificate that plays the MQTT broker and the
// camera port of a Bambu Lab printer.
//
// The state goes to a scratch folder. The test key is a fixed text, and the
// test checks that it reaches no file in plain text and no error message.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define SECURITY_WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>
#include <wincrypt.h>
#include <schannel.h>
#include <security.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "zslice.h"
#include "zslice-app.h"

#include "zs_app_shell.h"
#include "zs_bambu.h"
#include "zs_open_link.h"
#include "zs_camera.h"
#include "zs_deck_filaments.h"
#include "zs_discovery_net.h"
#include "zs_http.h"
#include "zs_json.h"
#include "zs_printer_link.h"
#include "zs_model.h"
#include "zs_printer_store.h"
#include "zs_setup.h"
#include "zs_signing.h"
#include "zs_state.h"

using namespace zs;

namespace
{
    char const test_key[] = "TESTKEY-not-a-real-key-7f3a";
    char const test_code[] = "12345678";

    int failures = 0;
    int checks = 0;

    void Check(bool ok, char const *what, int line)
    {
        checks++;
        if (!ok)
        {
            failures++;
            fprintf(stderr, "FAIL line %d: %s\n", line, what);
        }
    }
#define CHECK(x) Check((x), #x, __LINE__)

    bool Has(std::string const &text, char const *part)
    {
        return text.find(part) != std::string::npos;
    }

    // ---- an HTTP stub ----

    struct Seen
    {
        std::string method, path, key, body, content_type;
    };

    struct Reply
    {
        int status = 200;
        std::string body;
        std::string headers;
    };

    class HttpStub
    {
    public:
        using Route = std::function<Reply(Seen const &)>;

        explicit HttpStub(Route route) : route_(std::move(route))
        {
            listen_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            addr.sin_port = 0;
            ::bind(listen_, reinterpret_cast<sockaddr *>(&addr), sizeof addr);
            int size = sizeof addr;
            ::getsockname(listen_, reinterpret_cast<sockaddr *>(&addr), &size);
            port_ = ntohs(addr.sin_port);
            ::listen(listen_, 16);
            thread_ = std::thread([this] { Loop(); });
        }

        ~HttpStub()
        {
            stop_ = true;
            ::closesocket(listen_);
            thread_.join();
        }

        int Port() const { return port_; }
        std::string Url() const { return "http://127.0.0.1:" + std::to_string(port_); }

        std::vector<Seen> Log()
        {
            std::lock_guard guard(lock_);
            return log_;
        }

        void Clear()
        {
            std::lock_guard guard(lock_);
            log_.clear();
        }

    private:
        void Loop()
        {
            while (!stop_)
            {
                SOCKET c = ::accept(listen_, nullptr, nullptr);
                if (c == INVALID_SOCKET)
                    return;
                Serve(c);
                ::closesocket(c);
            }
        }

        void Serve(SOCKET c)
        {
            std::string in;
            char buffer[65536];
            size_t head_end = std::string::npos;
            while (head_end == std::string::npos)
            {
                int n = ::recv(c, buffer, sizeof buffer, 0);
                if (n <= 0)
                    return;
                in.append(buffer, n);
                head_end = in.find("\r\n\r\n");
            }
            std::string head = in.substr(0, head_end);
            std::string lower = head;
            for (auto &ch : lower)
                ch = (char)tolower((unsigned char)ch);
            auto header = [&](char const *name) -> std::string {
                std::string key = std::string("\r\n") + name + ":";
                size_t at = lower.find(key);
                if (at == std::string::npos)
                    return {};
                size_t start = at + key.size();
                size_t end = head.find("\r\n", start);
                std::string v = head.substr(start, end == std::string::npos ? std::string::npos : end - start);
                size_t a = v.find_first_not_of(' ');
                return a == std::string::npos ? std::string{} : v.substr(a);
            };
            size_t length = (size_t)atoll(header("content-length").c_str());
            while (in.size() < head_end + 4 + length)
            {
                int n = ::recv(c, buffer, sizeof buffer, 0);
                if (n <= 0)
                    return;
                in.append(buffer, n);
            }
            Seen seen;
            size_t sp1 = head.find(' '), sp2 = head.find(' ', sp1 + 1);
            seen.method = head.substr(0, sp1);
            seen.path = head.substr(sp1 + 1, sp2 - sp1 - 1);
            seen.key = header("x-api-key");
            seen.content_type = header("content-type");
            seen.body = in.substr(head_end + 4, length);
            {
                std::lock_guard guard(lock_);
                log_.push_back(seen);
            }
            Reply r = route_(seen);
            std::string out = "HTTP/1.1 " + std::to_string(r.status) + " Stub\r\nContent-Length: " + std::to_string(r.body.size()) +
                              "\r\nConnection: close\r\n" + r.headers + "\r\n" + r.body;
            ::send(c, out.data(), (int)out.size(), 0);
            ::shutdown(c, SD_SEND);
            // Wait for the close of the client, so the reply is not reset.
            while (::recv(c, buffer, sizeof buffer, 0) > 0)
            {
            }
        }

        Route route_;
        SOCKET listen_ = INVALID_SOCKET;
        int port_ = 0;
        std::atomic<bool> stop_{ false };
        std::thread thread_;
        std::mutex lock_;
        std::vector<Seen> log_;
    };

    Reply Json(std::string body, int status = 200)
    {
        return Reply{ status, std::move(body), "Content-Type: application/json\r\n" };
    }

    // ---- the tests ----

    void TestStore()
    {
        PrinterStore store;
        store.Load();
        CHECK(store.FirstStart());
        CHECK(store.Count() == 1);
        SavedPrinter &a = store.Add("Deck printer");
        a.kind = LinkKind::Printdeck;
        a.url = "http://127.0.0.1:1";
        a.api_key = test_key;
        SavedPrinter &b = store.Add("Bambu");
        b.kind = LinkKind::Bambu;
        b.url = "127.0.0.1";
        b.serial = "01S00A000000001";
        b.api_key = test_code;
        std::string id_a = store.At(1).id;
        std::string id_b = store.At(2).id;
        store.SetCurrent(id_a);
        CHECK(store.Save());

        std::string ini;
        CHECK(state::ReadBytes(state::PathOf(L"app.ini"), ini));
        CHECK(!Has(ini, test_key));
        CHECK(!Has(ini, test_code));
        CHECK(Has(ini, "connection=printdeck"));

        std::string blob;
        CHECK(state::ReadBytes(state::PathOf(L"secrets\\printer-2.key"), blob));
        CHECK(!blob.empty() && !Has(blob, test_key));
        std::string code_blob;
        CHECK(state::ReadBytes(state::PathOf(L"bambu\\01S00A000000001.code"), code_blob));
        CHECK(!code_blob.empty() && !Has(code_blob, test_code));

        PrinterStore again;
        again.Load();
        CHECK(!again.FirstStart());
        CHECK(again.Count() == 3);
        CHECK(again.Current().id == id_a);
        CHECK(again.Find(id_a) != nullptr && again.Find(id_a)->api_key == test_key);
        CHECK(again.Find(id_b) != nullptr && again.Find(id_b)->api_key == test_code);

        // A cleared key leaves no file.
        again.Find(id_a)->api_key.clear();
        again.Save();
        CHECK(!state::Exists(state::PathOf(L"secrets\\printer-2.key")));
        again.Remove(id_b);
        CHECK(!state::Exists(state::PathOf(L"bambu\\01S00A000000001.code")));

        // A secret from another blob does not read.
        std::string plain;
        CHECK(!state::Unprotect("not a blob", plain));
    }

    void TestAddresses()
    {
        CHECK(link::BaseUrl("printer.local/") == "http://printer.local");
        CHECK(link::BaseUrl("https://x.y/") == "https://x.y");
        CHECK(link::DeckRoot("http://d/printers/x2d") == "http://d");
        CHECK(link::DeckRoot("http://d/printers/x2d/") == "http://d");
        CHECK(link::DeckRoot("http://d") == "http://d");
        CHECK(link::FixDoubled("http://d/printers/x/printers/x") == "http://d/printers/x");
        CHECK(link::FixDoubled("http://d/printers/x/printers/x/") == "http://d/printers/x/");
        CHECK(link::DeckAddress("http://d", "/printers/x") == "http://d/printers/x");
        // A base at a printer: the path goes on the root of the deck.
        CHECK(link::DeckAddress("http://d/printers/x", "/printers/y") == "http://d/printers/y");
        CHECK(link::DeckAddress("http://d", "").rfind("http://d", 0) == 0);
        // A path that could leave the deck gets no address.
        CHECK(link::DeckAddress("http://d", "//evil.example/").empty());
        CHECK(link::DeckAddress("http://d", "@evil.example/").empty());
        CHECK(link::DeckAddress("http://d", "/a b").empty());
        CHECK(link::DeckAddress("http://d", "/printers/../../x").empty());
        CHECK(link::SameOrigin("http://a:80/x", "http://A/y"));
        CHECK(!link::SameOrigin("http://a/x", "https://a/x"));
        CHECK(!link::SameOrigin("http://a@b/x", "http://b/x"));
    }

    void TestStatus()
    {
        HttpStub octo([](Seen const &s) -> Reply {
            if (s.key != test_key)
                return Json("{}", 403);
            if (s.path == "/api/printer")
                return Json(R"({"state":{"text":"Operational","flags":{"operational":true}},"temperature":{"tool0":{"actual":24.5,"target":0},"bed":{"actual":23.0,"target":0}}})");
            if (s.path == "/api/job")
                return Json(R"({"job":{"file":{"name":"part.gcode"}},"progress":{"completion":50.0,"printTimeLeft":600},"state":"Printing"})");
            return Json("{}", 404);
        });
        link::Target t;
        t.id = "a";
        t.name = "Octo";
        t.kind = LinkKind::OctoPrint;
        t.url = octo.Url();
        t.api_key = test_key;
        link::Snapshot snap;
        std::string error;
        CHECK(link::ReadStatus(t, nullptr, snap, error));
        CHECK(!snap.state.empty());
        CHECK(snap.core != nullptr);
        for (auto const &s : octo.Log())
            CHECK(s.method == "GET");

        // A key that the printer refuses: the message has no key.
        t.api_key = "WRONG-KEY-value";
        link::Snapshot none;
        CHECK(!link::ReadStatus(t, nullptr, none, error));
        CHECK(Has(error, "did not accept the API key"));
        CHECK(!Has(error, "WRONG-KEY-value"));

        // PrusaLink reads as OctoPrint.
        t.kind = LinkKind::PrusaLink;
        t.api_key = test_key;
        CHECK(link::ReadStatus(t, nullptr, snap, error));

        HttpStub moon([](Seen const &s) -> Reply {
            if (s.path.rfind("/printer/objects/query", 0) == 0)
                return Json(R"({"result":{"eventtime":1,"status":{"print_stats":{"state":"standby","filename":""},"toolhead":{"axis_minimum":[0,0,0,0],"axis_maximum":[350,350,340,0]},"extruder":{"temperature":25,"target":0},"heater_bed":{"temperature":24,"target":0}}}})");
            return Json("{}", 404);
        });
        link::Target k;
        k.name = "Voron";
        k.kind = LinkKind::Moonraker;
        k.url = moon.Url();
        link::Snapshot ks;
        CHECK(link::ReadStatus(k, nullptr, ks, error));
        CHECK(ks.state == "standby");
        CHECK(ks.bed_x > 340);

        // No answer: a port with nothing on it.
        link::Target gone = k;
        gone.url = "http://127.0.0.1:1";
        CHECK(!link::ReadStatus(gone, nullptr, ks, error));
        CHECK(!error.empty());
    }

    void TestKeyFlow()
    {
        std::atomic<int> polls{ 0 };
        HttpStub deck([&](Seen const &s) -> Reply {
            if (s.method == "POST" && s.path == "/plugin/appkeys/request")
                return Json(R"({"app_token":"tok en"})", 201);
            if (s.method == "GET" && s.path == "/plugin/appkeys/request/tok%20en")
            {
                if (polls.fetch_add(1) == 0)
                    return Json("{}", 202);
                return Json(std::string("{\"api_key\":\"") + test_key + "\",\"trusted_key\":\"abc\"}");
            }
            return Json("{}", 404);
        });
        link::Target t;
        t.id = "d";
        t.name = "Deck X2D";
        t.kind = LinkKind::Printdeck;
        // Pairing goes to the root of the deck, also from a printer address.
        t.url = deck.Url() + "/printers/x2d";
        int waits = 0;
        link::KeyResult r = link::RequestKey(t, nullptr, [&](int) { waits++; });
        CHECK(r.ok);
        CHECK(r.key == test_key);
        CHECK(waits >= 1);
        CHECK(Has(r.message, "trusts"));
        CHECK(!Has(r.message, test_key));
        auto log = deck.Log();
        CHECK(!log.empty() && log[0].path == "/plugin/appkeys/request");
        CHECK(!log.empty() && Has(log[0].body, "\"app\":\"zslice\""));
        CHECK(!log.empty() && Has(log[0].body, "public_key"));
        for (auto const &s : log)
            CHECK(s.key.empty());

        // Deny.
        HttpStub deny([](Seen const &s) -> Reply {
            if (s.method == "POST")
                return Json(R"({"app_token":"t"})", 201);
            return Json("{}", 404);
        });
        link::Target d = t;
        d.url = deny.Url();
        r = link::RequestKey(d, nullptr, nullptr);
        CHECK(!r.ok);
        CHECK(Has(r.message, "Deny"));

        // A cancel ends the wait.
        HttpStub wait([](Seen const &s) -> Reply {
            if (s.method == "POST")
                return Json(R"({"app_token":"t"})", 201);
            return Json("{}", 202);
        });
        link::Target w = t;
        w.url = wait.Url();
        auto cancel = std::make_shared<http::Cancel>();
        std::thread stopper([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
            cancel->Stop();
        });
        r = link::RequestKey(w, cancel, nullptr);
        stopper.join();
        CHECK(!r.ok && r.cancelled);

        link::Target m = t;
        m.kind = LinkKind::Moonraker;
        r = link::RequestKey(m, nullptr, nullptr);
        CHECK(!r.ok && Has(r.message, "Moonraker"));
    }

    void TestDeck()
    {
        std::string list = R"({"name":"Shop","https":"https://x.d.printdeck.beetlebug.org","printers":[
            {"id":"taz","name":"TAZ 6","label":"TAZ","color":"#ff0000","kind":"fdm","url":""},
            {"id":"x2d","name":"Bambu Lab X2D","label":"X2D","color":"#00ff00","kind":"fdm","url":"/printers/x2d","model":"bambu-lab-x2d"},
            {"id":"sla","name":"Resin","label":"Resin","kind":"resin","url":"/printers/sla"}]})";
        HttpStub deck([&](Seen const &s) -> Reply {
            if (s.path == "/slicer/printer.json")
                return s.key == test_key ? Json(list) : Json("{}", 403);
            return Json("{}", 404);
        });
        link::Target t;
        t.name = "Bambu Lab X2D";
        t.kind = LinkKind::Printdeck;
        t.url = deck.Url() + "/printers/x2d";
        t.api_key = test_key;
        link::DeckList got;
        std::string error;
        CHECK(link::ReadDeck(t, nullptr, got, error));
        CHECK(got.name == "Shop");
        CHECK(got.printers.size() == 3);
        CHECK(Has(got.https, "https://"));
        CHECK(got.printers[1].path == "/printers/x2d");
        CHECK(deck.Log().back().path == "/slicer/printer.json");

        // The right printer goes through.
        CHECK(link::DeckRefusal(t, got).empty());
        // A path the deck does not have.
        link::Target bad = t;
        bad.url = deck.Url() + "/printers/none";
        CHECK(Has(link::DeckRefusal(bad, got), "no printer at"));
        // The name of another printer at this address.
        link::Target other = t;
        other.name = "TAZ 6";
        CHECK(Has(link::DeckRefusal(other, got), "leads to"));
        // The address of the deck with a name that says nothing.
        link::Target root = t;
        root.url = deck.Url();
        root.name = "My printer";
        CHECK(Has(link::DeckRefusal(root, got), "the deck itself"));
        // A saved deck name that differs stops it.
        link::Target named = t;
        named.deck_name = "TAZ 6";
        CHECK(Has(link::DeckRefusal(named, got), "leads to"));
        link::DeckList one;
        one.printers.push_back(got.printers[0]);
        CHECK(link::DeckRefusal(root, one).empty());

        link::Target wrong = t;
        wrong.api_key = "OTHER-KEY";
        CHECK(!link::ReadDeck(wrong, nullptr, got, error));
        CHECK(Has(error, "refused the key"));
    }

    void TestUpload()
    {
        std::string answer = R"({"files":{"local":{"name":"a.gcode"}},"done":true})";
        std::atomic<int> sent{ 0 };
        HttpStub printer([&](Seen const &s) -> Reply {
            if (s.path == "/api/files/local" && s.method == "POST")
            {
                sent++;
                return Json(answer, 201);
            }
            return Json("{}", 404);
        });
        link::Target t;
        t.name = "Octo";
        t.kind = LinkKind::OctoPrint;
        t.url = printer.Url();
        t.api_key = test_key;
        std::string gcode = "G1 X1\n; the file\n";
        double last = 0;
        link::UploadResult r = link::Upload(t, "part\"x.gcode", gcode, nullptr, [&](double f) { last = f; });
        CHECK(r.ok);
        CHECK(last > 0.99);
        CHECK(sent == 1);
        auto log = printer.Log();
        CHECK(log.size() == 1);
        std::string const &body = log[0].body;
        CHECK(log[0].key == test_key);
        CHECK(Has(log[0].content_type, "multipart/form-data"));
        CHECK(Has(body, gcode.c_str()));
        CHECK(Has(body, "name=\"print\"\r\n\r\nfalse\r\n"));
        // The app has no way to start a print.
        CHECK(!Has(body, "\r\n\r\ntrue\r\n"));
        CHECK(Has(body, "filename=\"part_x.gcode\""));
        CHECK(!Has(r.message, test_key));

        // A 2xx answer that is no stored file is an error.
        answer = "<html>login</html>";
        r = link::Upload(t, "a.gcode", gcode, nullptr, nullptr);
        CHECK(!r.ok);
        CHECK(Has(r.message, "not with a stored file"));

        // The key does not follow a redirect to another address.
        HttpStub elsewhere([](Seen const &) { return Json("{\"done\":true}"); });
        HttpStub redirect([&](Seen const &) {
            return Reply{ 302, "", "Location: " + elsewhere.Url() + "/api/files/local\r\n" };
        });
        link::Target rt = t;
        rt.url = redirect.Url();
        r = link::Upload(rt, "a.gcode", gcode, nullptr, nullptr);
        CHECK(!r.ok);
        CHECK(elsewhere.Log().empty());
        CHECK(!Has(r.message, test_key));

        // Moonraker: its own path, also with print=false.
        HttpStub moon([](Seen const &s) -> Reply {
            return s.path == "/server/files/upload" ? Json("{\"result\":{}}", 201) : Json("{}", 404);
        });
        link::Target k;
        k.name = "Voron";
        k.kind = LinkKind::Moonraker;
        k.url = moon.Url();
        r = link::Upload(k, "a.gcode", gcode, nullptr, nullptr);
        CHECK(r.ok);
        CHECK(moon.Log().size() == 1 && Has(moon.Log()[0].body, "name=\"print\"\r\n\r\nfalse\r\n"));

        // A deck with more printers refuses an address that leads elsewhere,
        // and no file goes out.
        std::string list = R"({"printers":[{"name":"TAZ 6","label":"TAZ","url":""},{"name":"X2D","label":"X2D","url":"/printers/x2d"}]})";
        std::atomic<int> uploads{ 0 };
        HttpStub deck([&](Seen const &s) -> Reply {
            if (s.path == "/slicer/printer.json")
                return Json(list);
            if (s.method == "POST")
            {
                uploads++;
                return Json(R"({"files":{"local":{}}})", 201);
            }
            return Json("{}", 404);
        });
        link::Target d;
        d.name = "X2D";
        d.kind = LinkKind::Printdeck;
        d.url = deck.Url();
        d.api_key = test_key;
        r = link::Upload(d, "a.gcode", gcode, nullptr, nullptr);
        CHECK(!r.ok);
        CHECK(uploads == 0);
        d.url = deck.Url() + "/printers/x2d";
        r = link::Upload(d, "a.gcode", gcode, nullptr, nullptr);
        CHECK(r.ok);
        CHECK(uploads == 1);
        CHECK(Has(deck.Log().back().path, "/printers/x2d/api/files/local"));

        // No connection, and a Bambu Lab printer: nothing goes out.
        link::Target none;
        none.kind = LinkKind::None;
        CHECK(!link::Upload(none, "a", gcode, nullptr, nullptr).ok);
        link::Target bambu;
        bambu.kind = LinkKind::Bambu;
        bambu.url = "127.0.0.1";
        CHECK(!link::Upload(bambu, "a", gcode, nullptr, nullptr).ok);

        // A canceled upload ends.
        auto cancel = std::make_shared<http::Cancel>();
        cancel->Stop();
        t.url = printer.Url();
        r = link::Upload(t, "a", gcode, cancel, nullptr);
        CHECK(!r.ok && r.cancelled);
    }

    void TestDetect()
    {
        HttpStub deck([](Seen const &s) -> Reply {
            if (s.path == "/api/version")
                return Json(R"J({"api":"0.1","server":"1.11.0","text":"OctoPrint 1.11.0 (Printdeck v0.4.0-beta)"})J");
            return Json("{}", 404);
        });
        HttpStub octo([](Seen const &s) -> Reply {
            if (s.path == "/api/version")
                return Json(R"({"api":"0.1","server":"1.9.0","text":"OctoPrint 1.9.0"})");
            return Json("{}", 404);
        });
        HttpStub prusa([](Seen const &s) -> Reply {
            if (s.path == "/api/version")
                return Json(R"({"api":"2.0.0","server":"2.1.2","text":"PrusaLink"})");
            return Json("{}", 404);
        });
        HttpStub moon([](Seen const &s) -> Reply {
            if (s.path == "/server/info")
                return Json(R"({"result":{"klippy_state":"ready"}})");
            return Json("{}", 404);
        });
        LinkKind kind{};
        std::string error;
        CHECK(link::DetectKind(deck.Url(), nullptr, kind, error) && kind == LinkKind::Printdeck);
        CHECK(link::DetectKind(octo.Url(), nullptr, kind, error) && kind == LinkKind::OctoPrint);
        CHECK(link::DetectKind(prusa.Url(), nullptr, kind, error) && kind == LinkKind::PrusaLink);
        CHECK(link::DetectKind(moon.Url(), nullptr, kind, error) && kind == LinkKind::Moonraker);
        for (auto const &s : deck.Log())
            CHECK(s.key.empty());
        CHECK(!link::DetectKind("http://127.0.0.1:1", nullptr, kind, error));
    }

    void TestFilaments()
    {
        std::string body = R"({"filaments":[
            {"slot":"A1","material":"pla","color":"#FF0000","nozzle":"main"},
            {"slot":"A2","material":"PETG","color":"bad","nozzle":"main"},
            {"slot":"Ext","material":"TPU","color":"#00ff00","nozzle":"aux"},
            {"slot":"A3"}],
            "nozzles":[{"type":"HH01"}]})";
        DeckFilaments d;
        std::string error;
        CHECK(ParseDeckFilaments(body, false, "X2D", d, error));
        CHECK(d.use.size() == 2);
        CHECK(d.use[0].material == "PLA" && d.use[0].color == "#ff0000");
        CHECK(d.use[1].color.empty());
        CHECK(d.left_out.size() == 1);
        CHECK(d.nozzle_type == "hardened_steel" && d.nozzle_flow == "high_flow");
        std::string text = DeckFilamentsMessage(d, false, "X2D");
        CHECK(Has(text, "2 filaments from X2D: A1 PLA, A2 PETG."));
        CHECK(Has(text, "Not used: Ext TPU"));
        CHECK(ParseDeckFilaments(body, true, "X2D", d, error));
        CHECK(d.use.size() == 3 && d.left_out.empty());
        CHECK(!ParseDeckFilaments("{}", false, "X2D", d, error));
        CHECK(!ParseDeckFilaments("not json", false, "X2D", d, error));
        CHECK(!ParseDeckFilaments(R"({"filaments":[{"material":"PLA","nozzle":"aux"}]})", false, "X2D", d, error));
        CHECK(Has(error, "second nozzle"));
    }

    void TestSigning()
    {
        std::string pub = signing::PublicKey();
        CHECK(!pub.empty());
        CHECK(!signing::KeyId().empty());
        std::string blob;
        CHECK(state::ReadBytes(state::PathOf(L"signing.key"), blob));
        CHECK(!blob.empty());
        std::string gcode = "G1 X1\n";
        std::string done = signing::Sign(gcode);
        CHECK(done.size() > gcode.size());
        CHECK(done.rfind(gcode, 0) == 0);
        signing::Reset();
        CHECK(signing::PublicKey() == pub);
    }

    void TestMjpeg()
    {
        std::string jpeg1 = "\xFF\xD8one\xFF\xD9";
        std::string jpeg2 = "\xFF\xD8two\r\n--notboundary\xFF\xD9";
        std::string stream = "--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpeg1 + "\r\n--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpeg2 +
                             "\r\n--frame\r\nContent-Type: text/plain\r\n\r\nnot a picture\r\n--frame\r\n";
        // In small pieces, as a network gives them.
        MjpegParser parser("multipart/x-mixed-replace; boundary=frame");
        std::vector<std::string> frames;
        for (size_t i = 0; i < stream.size(); i += 7)
        {
            parser.Feed(stream.data() + i, std::min<size_t>(7, stream.size() - i));
            std::string f;
            while (parser.Next(f))
                frames.push_back(f);
        }
        CHECK(frames.size() == 2);
        CHECK(frames.size() == 2 && frames[0] == jpeg1 && frames[1] == jpeg2);
        // The boundary from the stream itself.
        MjpegParser found("");
        found.Feed(stream.data(), stream.size());
        std::string f;
        CHECK(found.Next(f) && f == jpeg1);
    }

    // ---- mDNS on the loopback address ----

    void PutName(std::string &out, std::string const &name)
    {
        size_t at = 0;
        while (at < name.size())
        {
            size_t dot = name.find('.', at);
            if (dot == std::string::npos)
                dot = name.size();
            out += (char)(dot - at);
            out.append(name, at, dot - at);
            at = dot + 1;
        }
        out += '\0';
    }

    void Put16(std::string &out, unsigned v)
    {
        out += (char)(v >> 8);
        out += (char)v;
    }

    void Put32(std::string &out, unsigned v)
    {
        Put16(out, v >> 16);
        Put16(out, v & 0xFFFF);
    }

    void PutRecord(std::string &out, std::string const &name, unsigned type, std::string const &data)
    {
        PutName(out, name);
        Put16(out, type);
        Put16(out, 1);
        Put32(out, 120);
        Put16(out, (unsigned)data.size());
        out += data;
    }

    // A full answer: PTR, SRV, TXT, and A.
    std::string MdnsAnswer(std::string const &service, std::string const &instance, std::string const &host, int port)
    {
        std::string out;
        Put16(out, 0);
        Put16(out, 0x8400);
        Put16(out, 0);
        Put16(out, 4);
        Put16(out, 0);
        Put16(out, 0);
        std::string full = instance + "." + service;
        std::string ptr;
        PutName(ptr, full);
        PutRecord(out, service, 12, ptr);
        std::string srv;
        Put16(srv, 0);
        Put16(srv, 0);
        Put16(srv, (unsigned)port);
        PutName(srv, host);
        PutRecord(out, full, 33, srv);
        std::string txt;
        for (char const *entry : { "path=/", "version=1.11.0" })
        {
            txt += (char)strlen(entry);
            txt += entry;
        }
        PutRecord(out, full, 16, txt);
        std::string a;
        a += (char)127;
        a += (char)0;
        a += (char)0;
        a += (char)1;
        PutRecord(out, host, 1, a);
        return out;
    }

    void TestDiscovery()
    {
        // The default of a test run: no packet goes out.
        int port = -1;
        ::SetEnvironmentVariableA("ZSLICE_DISCOVERY", nullptr);
        CHECK(SearchModeOfRun(port) == SearchMode::Off);
        ::SetEnvironmentVariableA("ZSLICE_DISCOVERY", "off");
        CHECK(SearchModeOfRun(port) == SearchMode::Off);
        ::SetEnvironmentVariableA("ZSLICE_DISCOVERY", "10.0.0.1:5353");
        CHECK(SearchModeOfRun(port) == SearchMode::Off);
        ::SetEnvironmentVariableA("ZSLICE_DISCOVERY", "127.0.0.1:5999");
        CHECK(SearchModeOfRun(port) == SearchMode::Loopback && port == 5999);
        ::SetEnvironmentVariableA("ZSLICE_DISCOVERY", nullptr);

        HttpStub deck([](Seen const &s) -> Reply {
            if (s.path == "/api/version")
                return Json(R"J({"api":"0.1","server":"1.11.0","text":"OctoPrint 1.11.0 (Printdeck v0.4.0-beta)"})J");
            return Json("{}", 404);
        });
        SOCKET udp = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        ::bind(udp, reinterpret_cast<sockaddr *>(&addr), sizeof addr);
        int size = sizeof addr;
        ::getsockname(udp, reinterpret_cast<sockaddr *>(&addr), &size);
        int stub_port = ntohs(addr.sin_port);
        DWORD timeout = 200;
        ::setsockopt(udp, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char const *>(&timeout), sizeof timeout);

        std::atomic<bool> stop{ false };
        std::atomic<int> queries{ 0 };
        std::string answer = MdnsAnswer("_octoprint._tcp.local", "Stub deck", "stubdeck.local", deck.Port());
        std::string bambu = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nServer: UPnP/1.0\r\nLocation: 127.0.0.1\r\n"
                            "NT: urn:bambulab-com:device:3dprinter:1\r\nUSN: 01P00A123456789\r\nCache-Control: max-age=1800\r\n"
                            "DevModel.bambu.com: C12\r\nDevName.bambu.com: Shop P1S\r\nDevConnect.bambu.com: lan\r\n\r\n";
        std::thread responder([&] {
            char buffer[2048];
            while (!stop)
            {
                sockaddr_in from{};
                int from_len = sizeof from;
                int n = ::recvfrom(udp, buffer, sizeof buffer, 0, reinterpret_cast<sockaddr *>(&from), &from_len);
                if (n <= 0)
                    continue;
                queries++;
                ::sendto(udp, answer.data(), (int)answer.size(), 0, reinterpret_cast<sockaddr *>(&from), from_len);
                ::sendto(udp, bambu.data(), (int)bambu.size(), 0, reinterpret_cast<sockaddr *>(&from), from_len);
            }
        });

        std::mutex lock;
        std::condition_variable cv;
        std::vector<FoundPrinter> found;
        bool ended = false;
        {
            PrinterSearch search(SearchMode::Loopback, stub_port, [&](std::vector<FoundPrinter> const &list, bool running) {
                std::lock_guard guard(lock);
                found = list;
                ended = !running;
                cv.notify_all();
            });
            std::unique_lock wait(lock);
            cv.wait_for(wait, std::chrono::seconds(10), [&] {
                bool deck_known = false;
                for (auto const &f : found)
                    deck_known = deck_known || f.kind == ZS_FOUND_PRINTDECK;
                return ended || (deck_known && found.size() >= 2);
            });
        }
        stop = true;
        responder.join();
        ::closesocket(udp);
        CHECK(queries >= 1);
        bool saw_deck = false, saw_bambu = false;
        for (auto const &f : found)
        {
            if (f.kind == ZS_FOUND_PRINTDECK && f.address == "127.0.0.1" && f.port == deck.Port())
                saw_deck = true;
            if (f.kind == ZS_FOUND_BAMBU && f.serial == "01P00A123456789")
                saw_bambu = true;
        }
        CHECK(saw_deck);
        CHECK(saw_bambu);
        for (auto const &s : deck.Log())
            CHECK(s.key.empty());
    }

    // ---- a TLS stub with a self-signed certificate ----

    class TestCert
    {
    public:
        TestCert()
        {
            wchar_t name[64];
            swprintf_s(name, L"zslice-test-%lu-%llu", ::GetCurrentProcessId(), (unsigned long long)::GetTickCount64());
            container_ = name;
            NCRYPT_PROV_HANDLE provider = 0;
            if (FAILED(::NCryptOpenStorageProvider(&provider, MS_KEY_STORAGE_PROVIDER, 0)))
                return;
            if (FAILED(::NCryptCreatePersistedKey(provider, &key_, BCRYPT_RSA_ALGORITHM, name, 0, 0)))
            {
                ::NCryptFreeObject(provider);
                return;
            }
            DWORD bits = 2048;
            ::NCryptSetProperty(key_, NCRYPT_LENGTH_PROPERTY, reinterpret_cast<PBYTE>(&bits), sizeof bits, 0);
            ::NCryptFinalizeKey(key_, 0);
            ::NCryptFreeObject(provider);
            BYTE encoded[256];
            DWORD encoded_len = sizeof encoded;
            if (!::CertStrToNameW(X509_ASN_ENCODING, L"CN=01S00A000000001", CERT_X500_NAME_STR, nullptr, encoded, &encoded_len, nullptr))
                return;
            CERT_NAME_BLOB subject{ encoded_len, encoded };
            CRYPT_KEY_PROV_INFO info{};
            info.pwszContainerName = name;
            info.pwszProvName = const_cast<wchar_t *>(MS_KEY_STORAGE_PROVIDER);
            info.dwProvType = 0;
            info.dwKeySpec = 0;
            cert_ = ::CertCreateSelfSignCertificate(key_, &subject, 0, &info, nullptr, nullptr, nullptr, nullptr);
        }

        ~TestCert()
        {
            if (cert_ != nullptr)
                ::CertFreeCertificateContext(cert_);
            // The test key does not stay on the machine.
            if (key_ != 0)
                ::NCryptDeleteKey(key_, 0);
        }

        PCCERT_CONTEXT Get() const { return cert_; }

    private:
        std::wstring container_;
        NCRYPT_KEY_HANDLE key_ = 0;
        PCCERT_CONTEXT cert_ = nullptr;
    };

    // One TLS connection at a time. `serve` gets a write function and each
    // byte chunk that comes after the handshake.
    class TlsStub
    {
    public:
        using Write = std::function<void(std::string const &)>;
        using Serve = std::function<void(std::string const &, Write const &)>;

        TlsStub(PCCERT_CONTEXT cert, Serve serve, std::string hello = {}) : serve_(std::move(serve)), hello_(std::move(hello))
        {
            SCHANNEL_CRED data{};
            data.dwVersion = SCHANNEL_CRED_VERSION;
            data.cCreds = 1;
            data.paCred = &cert;
            data.grbitEnabledProtocols = SP_PROT_TLS1_2_SERVER;
            wchar_t package[] = UNISP_NAME_W;
            TimeStamp expiry{};
            ok_ = ::AcquireCredentialsHandleW(nullptr, package, SECPKG_CRED_INBOUND, nullptr, &data, nullptr, nullptr, &cred_, &expiry) == SEC_E_OK;
            listen_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            ::bind(listen_, reinterpret_cast<sockaddr *>(&addr), sizeof addr);
            int size = sizeof addr;
            ::getsockname(listen_, reinterpret_cast<sockaddr *>(&addr), &size);
            port_ = ntohs(addr.sin_port);
            ::listen(listen_, 4);
            thread_ = std::thread([this] { Loop(); });
        }

        ~TlsStub()
        {
            stop_ = true;
            ::closesocket(listen_);
            thread_.join();
            if (ok_)
                ::FreeCredentialsHandle(&cred_);
        }

        bool Ok() const { return ok_; }
        int Port() const { return port_; }
        int Handshakes() const { return handshakes_.load(); }
        size_t BytesAfterHandshake() const { return app_bytes_.load(); }

    private:
        void Loop()
        {
            while (!stop_)
            {
                SOCKET c = ::accept(listen_, nullptr, nullptr);
                if (c == INVALID_SOCKET)
                    return;
                DWORD timeout = 300;
                ::setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char const *>(&timeout), sizeof timeout);
                Connection(c);
                ::closesocket(c);
            }
        }

        void Connection(SOCKET c)
        {
            CtxtHandle ctx{};
            bool has_ctx = false;
            std::vector<char> in;
            char chunk[16384];
            DWORD flags = ASC_REQ_SEQUENCE_DETECT | ASC_REQ_REPLAY_DETECT | ASC_REQ_CONFIDENTIALITY | ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM;
            bool done = false;
            auto t0 = std::chrono::steady_clock::now();
            while (!done && !stop_)
            {
                if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(10))
                    goto end;
                int n = ::recv(c, chunk, sizeof chunk, 0);
                if (n == 0 || (n < 0 && ::WSAGetLastError() != WSAETIMEDOUT))
                    goto end;
                if (n > 0)
                    in.insert(in.end(), chunk, chunk + n);
                while (!in.empty())
                {
                    SecBuffer in_buffers[2]{};
                    in_buffers[0] = { (unsigned long)in.size(), SECBUFFER_TOKEN, in.data() };
                    in_buffers[1] = { 0, SECBUFFER_EMPTY, nullptr };
                    SecBufferDesc in_desc{ SECBUFFER_VERSION, 2, in_buffers };
                    SecBuffer out_buffer{ 0, SECBUFFER_TOKEN, nullptr };
                    SecBufferDesc out_desc{ SECBUFFER_VERSION, 1, &out_buffer };
                    DWORD got = 0;
                    TimeStamp expiry{};
                    SECURITY_STATUS st = ::AcceptSecurityContext(&cred_, has_ctx ? &ctx : nullptr, &in_desc, flags, 0, has_ctx ? nullptr : &ctx, &out_desc, &got, &expiry);
                    if (st == SEC_E_INCOMPLETE_MESSAGE)
                        break;
                    if (st != SEC_E_OK && st != SEC_I_CONTINUE_NEEDED)
                        goto end;
                    has_ctx = true;
                    if (out_buffer.pvBuffer != nullptr)
                    {
                        ::send(c, static_cast<char *>(out_buffer.pvBuffer), out_buffer.cbBuffer, 0);
                        ::FreeContextBuffer(out_buffer.pvBuffer);
                    }
                    if (in_buffers[1].BufferType == SECBUFFER_EXTRA && in_buffers[1].cbBuffer > 0)
                    {
                        std::vector<char> extra(in.end() - in_buffers[1].cbBuffer, in.end());
                        in.swap(extra);
                    }
                    else
                        in.clear();
                    if (st == SEC_E_OK)
                    {
                        done = true;
                        break;
                    }
                }
            }
            if (done)
            {
                handshakes_++;
                SecPkgContext_StreamSizes sizes{};
                ::QueryContextAttributesW(&ctx, SECPKG_ATTR_STREAM_SIZES, &sizes);
                Write write = [&](std::string const &text) {
                    size_t at = 0;
                    while (at < text.size())
                    {
                        size_t piece = std::min<size_t>(text.size() - at, sizes.cbMaximumMessage);
                        std::vector<char> record(sizes.cbHeader + piece + sizes.cbTrailer);
                        memcpy(record.data() + sizes.cbHeader, text.data() + at, piece);
                        SecBuffer b[4]{};
                        b[0] = { sizes.cbHeader, SECBUFFER_STREAM_HEADER, record.data() };
                        b[1] = { (unsigned long)piece, SECBUFFER_DATA, record.data() + sizes.cbHeader };
                        b[2] = { sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, record.data() + sizes.cbHeader + piece };
                        b[3] = { 0, SECBUFFER_EMPTY, nullptr };
                        SecBufferDesc d{ SECBUFFER_VERSION, 4, b };
                        if (::EncryptMessage(&ctx, 0, &d, 0) != SEC_E_OK)
                            return;
                        ::send(c, record.data(), b[0].cbBuffer + b[1].cbBuffer + b[2].cbBuffer, 0);
                        at += piece;
                    }
                };
                if (!hello_.empty())
                    write(hello_);
                while (!stop_)
                {
                    while (!in.empty())
                    {
                        SecBuffer b[4]{};
                        b[0] = { (unsigned long)in.size(), SECBUFFER_DATA, in.data() };
                        SecBufferDesc d{ SECBUFFER_VERSION, 4, b };
                        SECURITY_STATUS st = ::DecryptMessage(&ctx, &d, 0, nullptr);
                        if (st == SEC_E_INCOMPLETE_MESSAGE)
                            break;
                        if (st != SEC_E_OK)
                            goto end;
                        std::string plain;
                        std::vector<char> extra;
                        for (auto const &x : b)
                        {
                            if (x.BufferType == SECBUFFER_DATA)
                                plain.assign(static_cast<char *>(x.pvBuffer), x.cbBuffer);
                            else if (x.BufferType == SECBUFFER_EXTRA)
                                extra.assign(static_cast<char *>(x.pvBuffer), static_cast<char *>(x.pvBuffer) + x.cbBuffer);
                        }
                        in.swap(extra);
                        if (!plain.empty())
                        {
                            app_bytes_ += plain.size();
                            serve_(plain, write);
                        }
                    }
                    int n = ::recv(c, chunk, sizeof chunk, 0);
                    if (n == 0 || (n < 0 && ::WSAGetLastError() != WSAETIMEDOUT))
                        break;
                    if (n > 0)
                        in.insert(in.end(), chunk, chunk + n);
                }
            }
        end:
            if (has_ctx)
                ::DeleteSecurityContext(&ctx);
        }

        Serve serve_;
        std::string hello_;
        CredHandle cred_{};
        bool ok_ = false;
        SOCKET listen_ = INVALID_SOCKET;
        int port_ = 0;
        std::atomic<bool> stop_{ false };
        std::atomic<int> handshakes_{ 0 };
        std::atomic<size_t> app_bytes_{ 0 };
        std::thread thread_;
    };

    std::string MqttPublish(std::string const &topic, std::string const &payload)
    {
        std::string body;
        Put16(body, (unsigned)topic.size());
        body += topic;
        body += payload;
        std::string out(1, (char)0x30);
        size_t n = body.size();
        do
        {
            unsigned char b = n % 128;
            n /= 128;
            if (n > 0)
                b |= 128;
            out += (char)b;
        } while (n > 0);
        return out + body;
    }

    void TestBambu()
    {
        TestCert cert;
        CHECK(cert.Get() != nullptr);
        if (cert.Get() == nullptr)
            return;

        std::mutex lock;
        std::vector<int> kinds;
        std::string connect_bytes;
        std::string report = R"({"print":{"gcode_state":"RUNNING","mc_percent":42,"mc_remaining_time":30,"subtask_name":"part","nozzle_temper":210.0,"bed_temper":55.0,"layer_num":3,"total_layer_num":10}})";
        TlsStub broker(cert.Get(), [&](std::string const &in, TlsStub::Write const &write) {
            std::lock_guard guard(lock);
            int type = (unsigned char)in[0] >> 4;
            kinds.push_back(type);
            if (type == 1)
            {
                connect_bytes = in;
                write(std::string("\x20\x02\x00\x00", 4));
            }
            else if (type == 8)
            {
                write(std::string("\x90\x03\x00\x01\x00", 5));
                write(MqttPublish("device/01S00A000000001/report", report));
            }
        });
        CHECK(broker.Ok());
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_MQTT_PORT", std::to_string(broker.Port()).c_str());

        // The serial number from the certificate, and the pin to trust.
        std::string serial, pin, error;
        CHECK(ReadBambuSerial("127.0.0.1", serial, pin, error));
        CHECK(serial == "01S00A000000001");
        CHECK(pin.size() == 64);

        link::Target t;
        t.id = "b";
        t.name = "Bambu";
        t.kind = LinkKind::Bambu;
        t.url = "127.0.0.1";
        t.api_key = test_code;

        std::condition_variable cv;
        link::Snapshot got;
        bool have = false;
        std::string trusted, watch_error;
        {
            BambuWatch watch(
                t, serial,
                [&](link::Snapshot const &s) {
                    std::lock_guard guard(lock);
                    got = s;
                    have = true;
                    cv.notify_all();
                },
                [&](std::string const &e) {
                    std::lock_guard guard(lock);
                    watch_error = e;
                },
                [&](std::string const &p) {
                    std::lock_guard guard(lock);
                    trusted = p;
                });
            std::unique_lock wait(lock);
            cv.wait_for(wait, std::chrono::seconds(10), [&] { return have; });
        }
        {
            std::lock_guard guard(lock);
            CHECK(have);
            CHECK(got.progress > 0.41 && got.progress < 0.43);
            CHECK(got.job == "part" || Has(got.job, "part"));
            CHECK(got.farm_state == ZS_FARM_PRINTING);
            CHECK(trusted == pin);
            CHECK(Has(connect_bytes, "bblp"));
            // The watch only reads: no PUBLISH (3) went to the printer.
            for (int k : kinds)
                CHECK(k != 3);
            CHECK(std::find(kinds.begin(), kinds.end(), 8) != kinds.end());
            CHECK(!Has(watch_error, test_code));
        }

        // Another certificate: the connection closes, and no byte of the
        // access code goes out.
        size_t before = broker.BytesAfterHandshake();
        link::Target pinned = t;
        pinned.tls_pin = std::string(64, 'a');
        std::string pin_error;
        bool errored = false;
        {
            BambuWatch watch(
                pinned, serial, [](link::Snapshot const &) {},
                [&](std::string const &e) {
                    std::lock_guard guard(lock);
                    pin_error = e;
                    errored = true;
                    cv.notify_all();
                },
                nullptr);
            std::unique_lock wait(lock);
            cv.wait_for(wait, std::chrono::seconds(10), [&] { return errored; });
        }
        CHECK(errored);
        CHECK(Has(pin_error, "not the one that zslice trusts"));
        CHECK(broker.BytesAfterHandshake() == before);

        // A wrong access code: the broker refuses, and the watch stops.
        TlsStub refuse(cert.Get(), [](std::string const &in, TlsStub::Write const &write) {
            if ((unsigned char)in[0] >> 4 == 1)
                write(std::string("\x20\x02\x00\x05", 4));
        });
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_MQTT_PORT", std::to_string(refuse.Port()).c_str());
        std::string refused;
        bool got_refused = false;
        {
            BambuWatch watch(
                t, serial, [](link::Snapshot const &) {},
                [&](std::string const &e) {
                    std::lock_guard guard(lock);
                    refused = e;
                    got_refused = true;
                    cv.notify_all();
                },
                nullptr);
            std::unique_lock wait(lock);
            cv.wait_for(wait, std::chrono::seconds(10), [&] { return got_refused; });
        }
        CHECK(Has(refused, "refused the access code"));
        CHECK(!Has(refused, test_code));
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_MQTT_PORT", nullptr);

        // The JPEG frames of port 6000.
        std::string jpeg = "\xFF\xD8picture\xFF\xD9";
        std::string frame(16, '\0');
        frame[0] = (char)jpeg.size();
        frame[4] = 0;
        frame[8] = 1;
        frame += jpeg;
        std::atomic<size_t> auth{ 0 };
        TlsStub camera(cert.Get(), [&](std::string const &in, TlsStub::Write const &write) {
            auth += in.size();
            write(frame);
        });
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_JPEG_PORT", std::to_string(camera.Port()).c_str());
        CameraSource source;
        source.bambu_host = "127.0.0.1";
        source.bambu_code = test_code;
        source.bambu_pin = pin;
        source.bambu_kind = 2;
        std::string shown;
        bool has_frame = false;
        {
            CameraFeed feed(
                source,
                [&](std::shared_ptr<std::string> const &j) {
                    std::lock_guard guard(lock);
                    shown = *j;
                    has_frame = true;
                    cv.notify_all();
                },
                [](std::string const &) {});
            std::unique_lock wait(lock);
            cv.wait_for(wait, std::chrono::seconds(10), [&] { return has_frame; });
        }
        CHECK(has_frame);
        CHECK(shown == jpeg);
        CHECK(auth >= 80);
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_JPEG_PORT", nullptr);
    }

    void TestCamera()
    {
        std::string jpeg = "\xFF\xD8shot\xFF\xD9";
        HttpStub printer([&](Seen const &s) -> Reply {
            if (s.path == "/api/settings")
                return Json(R"({"webcam":{"webcamEnabled":true,"streamUrl":"/webcam/?action=stream","snapshotUrl":"/webcam/?action=snapshot","flipH":true,"flipV":false,"rotate90":false}})");
            if (Has(s.path, "snapshot"))
                return Reply{ 200, jpeg, "Content-Type: image/jpeg\r\n" };
            return Json("{}", 404);
        });
        link::Target t;
        t.name = "Octo";
        t.kind = LinkKind::OctoPrint;
        t.url = printer.Url();
        t.api_key = test_key;
        link::Camera cam;
        std::string error;
        CHECK(link::ReadCamera(t, nullptr, cam, error));

        // A snapshot camera at the printer gets the key. One at another
        // address does not.
        HttpStub other([&](Seen const &) { return Reply{ 200, jpeg, "Content-Type: image/jpeg\r\n" }; });
        std::mutex lock;
        std::condition_variable cv;
        int frames = 0;
        for (std::string const &url : { printer.Url() + "/webcam/?action=snapshot", other.Url() + "/snap" })
        {
            CameraSource source;
            source.snapshot = url;
            source.api_key = test_key;
            source.printer_url = printer.Url();
            frames = 0;
            {
                CameraFeed feed(
                    source,
                    [&](std::shared_ptr<std::string> const &) {
                        std::lock_guard guard(lock);
                        frames++;
                        cv.notify_all();
                    },
                    [](std::string const &) {});
                std::unique_lock wait(lock);
                cv.wait_for(wait, std::chrono::seconds(5), [&] { return frames > 0; });
            }
            CHECK(frames > 0);
        }
        bool keyed = false;
        for (auto const &s : printer.Log())
            keyed = keyed || (Has(s.path, "snapshot") && s.key == test_key);
        CHECK(keyed);
        for (auto const &s : other.Log())
            CHECK(s.key.empty());
    }

    // The printer, filament, and quality of a plate, with no window.
    void TestSetup()
    {
        Model model([](Event const &) {});
        CHECK(model.Start() == ZS_OK);
        PrinterSetup setup(model);
        setup.Start();
        zs_printers *lib = model.Printers();
        CHECK(lib != nullptr);
        ptrdiff_t ender = zs_printers_find(lib, "creality-ender-3-v2");
        CHECK(ender >= 0);

        NewPrinter first;
        first.name = "Shop Ender";
        first.model = ender;
        first.nozzle = 0.6;
        first.bed_x = 200;
        first.bed_y = 210;
        first.height = 240;
        first.kind = LinkKind::OctoPrint;
        first.url = "http://127.0.0.1:1";
        first.api_key = test_key;
        std::string id_a, id_b, message;
        CHECK(setup.AddNewPrinter(first, false, id_a, message));
        CHECK(model.GetSetting("machine.name") == "Shop Ender");
        CHECK(atof(model.GetSetting("machine.nozzle_diameter").c_str()) == 0.6);
        CHECK(atof(model.GetSetting("machine.bed_size_y").c_str()) == 210);
        CHECK(Printers().Current().id == id_a);

        NewPrinter second;
        second.name = "Other";
        second.bed_x = 300;
        second.bed_y = 300;
        second.height = 300;
        CHECK(setup.AddNewPrinter(second, false, id_b, message));
        CHECK(atof(model.GetSetting("machine.bed_size_x").c_str()) == 300);

        // Each printer gets its own machine settings back.
        CHECK(setup.UsePrinter(id_a, message));
        CHECK(model.GetSetting("machine.name") == "Shop Ender");
        CHECK(atof(model.GetSetting("machine.bed_size_x").c_str()) == 200);
        CHECK(setup.UsePrinter(id_b, message));
        CHECK(atof(model.GetSetting("machine.bed_size_x").c_str()) == 300);
        CHECK(!setup.UsePrinter("no-such-printer", message));

        // Quality: a capital, and a detail line from the core.
        CHECK(zs_builtin_profile_count(ZS_GROUP_PROJECT) > 0);
        std::string quality = zs_builtin_profile_name(ZS_GROUP_PROJECT, 0);
        CHECK(setup.SetQuality(quality, false, message));
        std::string title = PrinterSetup::QualityTitle(quality);
        CHECK(!title.empty() && isupper((unsigned char)title[0]));
        CHECK(!PrinterSetup::QualitySummary(quality).empty());
        CHECK(Has(setup.QualityLabel(), "Quality: "));
        CHECK(PrinterSetup::QualityTitle("my-own") == "my-own");

        // A profile of the user.
        CHECK(setup.UseMaterial("PETG", message));
        CHECK(model.GetSetting("filament.material") == "PETG");
        CHECK(setup.SaveProfile(ZS_GROUP_FILAMENT, "my petg", message));
        auto names = setup.UserProfiles(ZS_GROUP_FILAMENT);
        CHECK(std::find(names.begin(), names.end(), "my-petg") != names.end());
        CHECK(setup.UseMaterial("PLA", message));
        CHECK(setup.LoadUserProfile(ZS_GROUP_FILAMENT, "my-petg", message));
        CHECK(model.GetSetting("filament.material") == "PETG");
        CHECK(PrinterSetup::ProfileFileName("..\\a b") == "___a-b");

        // The filaments of a printer.
        DeckFilaments spools;
        spools.use.push_back(Spool{ "A1", "PLA", "#ff0000", false });
        spools.use.push_back(Spool{ "A2", "PETG", "#00ff00", false });
        setup.ApplySpools(spools, false);
        CHECK(zs_app_filament_count(model.Active()) == 2);
        char color[16] = "";
        CHECK(zs_app_filament_get(model.Active(), 1, "filament.color", color, sizeof color, nullptr) == ZS_OK);
        CHECK(Has(color, "00ff00"));

        // The settings come back after a restart, with no key in them.
        setup.SaveState();
        Model again([](Event const &) {});
        CHECK(again.Start() == ZS_OK);
        PrinterSetup next(again);
        next.Start();
        CHECK(Printers().Current().id == id_b);
        CHECK(atof(again.GetSetting("machine.bed_size_x").c_str()) == 300);
        CHECK(Printers().Find(id_a) != nullptr && Printers().Find(id_a)->api_key == test_key);
        std::string machine;
        CHECK(state::ReadBytes(PrinterStore::ProfilePath(*Printers().Find(id_a)), machine));
        CHECK(!Has(machine, test_key));
    }

    // The rules of a link from a web page. Nothing here goes to the network.
    void TestOpenLink()
    {
        using namespace zs::openlink;
        ModelLink link;
        std::string why;
        CHECK(Parse(L"zslice://open?file=https%3A%2F%2Ffiles.printables.com%2Fmedia%2Fa%20b.stl", link, why));
        CHECK(link.host == "files.printables.com");
        CHECK(link.url == "https://files.printables.com/media/a%20b.stl" || link.url == "https://files.printables.com/media/a b.stl");
        CHECK(link.name == L"a b.stl");
        CHECK(Parse(L"ZSLICE://open/?x=1&file=https://example.com:443/m.3mf?v=2#top", link, why));
        CHECK(link.url == "https://example.com/m.3mf?v=2");
        CHECK(link.name == L"m.3mf");
        CHECK(Parse(L"zslice://open?file=https://example.com/download/42", link, why) && link.name.empty());
        wchar_t const *const refused[] = {
            L"zslice://open?file=http://example.com/a.stl",
            L"zslice://open?file=file:///C:/secret.stl",
            L"zslice://open?file=https://127.0.0.1/a.stl",
            L"zslice://open?file=https://2130706433/a.stl",
            L"zslice://open?file=https://0x7f.0.0.1/a.stl",
            L"zslice://open?file=https://[::1]/a.stl",
            L"zslice://open?file=https://localhost/a.stl",
            L"zslice://open?file=https://printer.local/a.stl",
            L"zslice://open?file=https://user:pw@example.com/a.stl",
            L"zslice://open?file=https://example.com:8080/a.stl",
            L"zslice://open?file=https://example.com%5C@evil.test/a.stl",
            L"zslice://open?file=https://a.test/a.stl&file=https://b.test/b.stl",
            L"zslice://open?file=https%3A%2F%2Fexample.com%2",
            L"zslice://print?file=https://example.com/a.stl",
            L"zslice://open",
            L"https://example.com/a.stl",
        };
        for (auto const *text : refused)
            CHECK(!Parse(text, link, why));
        // A mark that reverses the text cannot hide the real extension.
        CHECK(Parse(L"zslice://open?file=https://example.com/a%E2%80%AEexe.stl", link, why));
        CHECK(link.name == L"aexe.stl");

        CHECK(IsModelName(L"C:\\x\\Part.STL") && IsModelName(L"a.step") && IsModelName(L"a.stp") && IsModelName(L"a.obj") && IsModelName(L"a.3mf"));
        CHECK(!IsModelName(L"a.exe") && !IsModelName(L"stl") && !IsModelName(L".stl"));

        auto v4 = [](char const *text) {
            sockaddr_in a{};
            a.sin_family = AF_INET;
            ::inet_pton(AF_INET, text, &a.sin_addr);
            return IsPublicAddress(reinterpret_cast<sockaddr const *>(&a));
        };
        auto v6 = [](char const *text) {
            sockaddr_in6 a{};
            a.sin6_family = AF_INET6;
            ::inet_pton(AF_INET6, text, &a.sin6_addr);
            return IsPublicAddress(reinterpret_cast<sockaddr const *>(&a));
        };
        CHECK(v4("93.184.216.34"));
        for (char const *text : { "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.9.9", "192.168.1.5", "169.254.1.1", "100.64.0.1", "0.0.0.0", "224.0.0.1",
                                  "198.18.0.1", "192.0.0.1" })
            CHECK(!v4(text));
        CHECK(v6("2606:4700::1111"));
        for (char const *text : { "::1", "::", "fe80::1", "fc00::1", "fd12::1", "ff02::1", "::ffff:192.168.1.5", "2001:db8::1", "64:ff9b::7f00:1", "2002:7f00:1::" })
            CHECK(!v6(text));

        // A name that resolves to a local address gets no request.
        std::string local = zs_link_message(ZS_LINK_LOCAL_ADDRESS);
        ModelLink named;
        named.url = "https://localhost/a.stl";
        named.host = "localhost";
        named.name = L"a.stl";
        CHECK(Fetch(named, nullptr, nullptr).error == local);

        // An address that appears only when WinHTTP connects: the stub on
        // 127.0.0.1 must get no byte, so no TLS handshake starts.
        SOCKET server = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        sockaddr_in at{};
        at.sin_family = AF_INET;
        at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int at_size = sizeof at;
        CHECK(::bind(server, reinterpret_cast<sockaddr *>(&at), sizeof at) == 0);
        CHECK(::listen(server, 1) == 0);
        CHECK(::getsockname(server, reinterpret_cast<sockaddr *>(&at), &at_size) == 0);
        ModelLink changed;
        changed.url = "https://127.0.0.1/a.stl";
        changed.host = "127.0.0.1";
        changed.name = L"a.stl";
        FetchSeam seam;
        seam.port = ntohs(at.sin_port);
        seam.skip_resolve = true;
        CHECK(Fetch(changed, nullptr, nullptr, seam).error == local);
        fd_set ready;
        FD_ZERO(&ready);
        FD_SET(server, &ready);
        timeval wait{ 0, 300000 };
        if (::select(0, &ready, nullptr, nullptr, &wait) == 1)
        {
            SOCKET peer = ::accept(server, nullptr, nullptr);
            DWORD read_ms = 500;
            ::setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char const *>(&read_ms), sizeof read_ms);
            char first[16];
            CHECK(::recv(peer, first, sizeof first, 0) <= 0);
            ::closesocket(peer);
        }
        ::closesocket(server);
    }

    // The session of the old folder moves once, and replaces no file.
    void TestStateMove()
    {
        std::wstring base = state::PathOf(L"move-test");
        std::wstring appdata = base + L"\\Roaming";
        std::wstring old_dir = appdata + L"zslice", new_dir = appdata + L"\\zslice";
        ::CreateDirectoryW(base.c_str(), nullptr);
        ::CreateDirectoryW(appdata.c_str(), nullptr);
        ::CreateDirectoryW(old_dir.c_str(), nullptr);
        CHECK(state::WriteBytes(old_dir + L"\\session.zslice", "first"));
        zs::MoveOldStateFiles(appdata);
        std::string text;
        CHECK(state::ReadBytes(new_dir + L"\\session.zslice", text) && text == "first");
        CHECK(::GetFileAttributesW(old_dir.c_str()) == INVALID_FILE_ATTRIBUTES);
        ::CreateDirectoryW(old_dir.c_str(), nullptr);
        CHECK(state::WriteBytes(old_dir + L"\\session.zslice", "second"));
        zs::MoveOldStateFiles(appdata);
        CHECK(state::ReadBytes(new_dir + L"\\session.zslice", text) && text == "first");
        CHECK(state::ReadBytes(old_dir + L"\\session.zslice", text) && text == "second");
    }

    // The keys go to a scratch root. The real file types do not change.
    void TestRegisterApp()
    {
        std::wstring root = L"Software\\zslice-net-link-test-" + std::to_wstring(::GetCurrentProcessId());
        ::RegDeleteTreeW(HKEY_CURRENT_USER, root.c_str());
        std::wstring exe = L"C:\\Test Folder\\ZSlice.exe";
        CHECK(zs::appshell::RegisterApp(exe, root));
        CHECK(!zs::appshell::RegisterApp(exe, root));
        auto text = [&](std::wstring const &key, wchar_t const *name) {
            wchar_t value[512] = L"";
            DWORD size = sizeof value;
            ::RegGetValueW(HKEY_CURRENT_USER, (root + L"\\" + key).c_str(), name, RRF_RT_REG_SZ, nullptr, value, &size);
            return std::wstring(value);
        };
        std::wstring command = L"\"C:\\Test Folder\\ZSlice.exe\" \"%1\"";
        CHECK(text(L"Classes\\ZSlice.Model\\shell\\open\\command", nullptr) == command);
        CHECK(text(L"Classes\\zslice\\shell\\open\\command", nullptr) == command);
        CHECK(text(L"zslice\\Capabilities\\FileAssociations", L".step") == L"ZSlice.Model");
        CHECK(text(L"zslice\\Capabilities\\UrlAssociations", L"zslice") == L"zslice");
        CHECK(text(L"RegisteredApplications", L"zslice") == root + L"\\zslice\\Capabilities");
        DWORD type = 0;
        CHECK(::RegGetValueW(HKEY_CURRENT_USER, (root + L"\\Classes\\.stl\\OpenWithProgids").c_str(), L"ZSlice.Model", RRF_RT_ANY, &type, nullptr, nullptr) == ERROR_SUCCESS);
        // The default of the type stays with the user.
        CHECK(text(L"Classes\\.stl", nullptr).empty());
        CHECK(zs::appshell::RegisterApp(L"C:\\Moved\\ZSlice.exe", root));
        CHECK(text(L"Classes\\zslice\\shell\\open\\command", nullptr) == L"\"C:\\Moved\\ZSlice.exe\" \"%1\"");
        ::RegDeleteTreeW(HKEY_CURRENT_USER, root.c_str());
    }

    // A later start gives its argument to the first one.
    void TestHandOff()
    {
        std::wstring key = zs::appshell::InstanceKey(L"C:\\zslice-net-link-test\\" + std::to_wstring(::GetCurrentProcessId()));
        CHECK(key == zs::appshell::InstanceKey(L"c:/ZSLICE-net-link-test/" + std::to_wstring(::GetCurrentProcessId()) + L"/"));
        CHECK(zs::appshell::Claim(key));
        CHECK(!zs::appshell::Claim(key));
        std::mutex lock;
        std::vector<std::wstring> got;
        {
            zs::appshell::OpenServer server(key, [&](std::wstring text) {
                std::lock_guard guard(lock);
                got.push_back(std::move(text));
            });
            CHECK(zs::appshell::HandOff(key, L"C:\\a b\\part.stl"));
            CHECK(zs::appshell::HandOff(key, L""));
            CHECK(zs::appshell::HandOff(key, L"zslice://open?file=https://example.com/a.stl"));
            for (int i = 0; i < 100; i++)
            {
                {
                    std::lock_guard guard(lock);
                    if (got.size() >= 3)
                        break;
                }
                ::Sleep(10);
            }
        }
        CHECK(got.size() == 3);
        if (got.size() == 3)
        {
            CHECK(got[0] == L"C:\\a b\\part.stl");
            CHECK(got[1].empty());
            CHECK(got[2] == L"zslice://open?file=https://example.com/a.stl");
        }
    }

    void TestJson()
    {
        json::Value v;
        CHECK(json::Parse(R"({"a":{"b":[1,2,{"c":"xé\n"}]},"d":true,"e":null,"f":-1.5e2})", v));
        CHECK(v.Path("a.b") != nullptr && v.Path("a.b")->items.size() == 3);
        CHECK(v.Num("f") == -150);
        CHECK(v.Get("d")->boolean);
        CHECK(v.Path("a.b")->items[2].Str("c") == "x\xC3\xA9\n");
        CHECK(!json::Parse("{", v));
        CHECK(!json::Parse("[1,]", v));
        CHECK(!json::Parse("1 2", v));
        std::string deep(5000, '[');
        CHECK(!json::Parse(deep, v));
        CHECK(json::Quote("a\"b\\\n") == "\"a\\\"b\\\\\\u000a\"");
    }

    std::wstring ScratchDir()
    {
        wchar_t temp[MAX_PATH];
        ::GetTempPathW(MAX_PATH, temp);
        wchar_t name[128];
        swprintf_s(name, L"zslice-net-test-%lu", ::GetCurrentProcessId());
        return std::wstring(temp) + name;
    }

    void RemoveTree(std::wstring const &dir)
    {
        WIN32_FIND_DATAW data{};
        HANDLE find = ::FindFirstFileW((dir + L"\\*").c_str(), &data);
        if (find == INVALID_HANDLE_VALUE)
            return;
        do
        {
            std::wstring name = data.cFileName;
            if (name == L"." || name == L"..")
                continue;
            std::wstring path = dir + L"\\" + name;
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                RemoveTree(path);
            else
                ::DeleteFileW(path.c_str());
        } while (::FindNextFileW(find, &data));
        ::FindClose(find);
        ::RemoveDirectoryW(dir.c_str());
    }
}

int main()
{
    WSADATA wsa{};
    ::WSAStartup(MAKEWORD(2, 2), &wsa);
    std::wstring dir = ScratchDir();
    ::SetEnvironmentVariableW(L"ZSLICE_STATE_DIR", dir.c_str());
    state::EnsureDir(dir);

    struct Step
    {
        char const *name;
        void (*run)();
    };
    Step const steps[] = {
        { "json", TestJson }, { "store", TestStore }, { "addresses", TestAddresses }, { "signing", TestSigning },
        { "status", TestStatus }, { "key flow", TestKeyFlow }, { "deck", TestDeck }, { "upload", TestUpload },
        { "detect", TestDetect }, { "filaments", TestFilaments }, { "mjpeg", TestMjpeg }, { "camera", TestCamera },
        { "discovery", TestDiscovery }, { "bambu", TestBambu }, { "setup", TestSetup },
        { "open link", TestOpenLink }, { "file types", TestRegisterApp }, { "hand off", TestHandOff }, { "state move", TestStateMove },
    };
    for (auto const &step : steps)
    {
        int before = failures;
        step.run();
        printf("%-10s %s\n", step.name, failures == before ? "ok" : "FAILED");
        fflush(stdout);
    }
    RemoveTree(dir);
    printf("net_link: %d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
