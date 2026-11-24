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
#include <winioctl.h>
#include <bcrypt.h>
#include <ncrypt.h>
#include <wincrypt.h>
#include <schannel.h>
#include <security.h>

#include <algorithm>
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
#include "zs_h264.h"
#include "zs_usb.h"

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
#include "zs_project_source.h"
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

        // An empty key in memory keeps the file: a read can have failed.
        again.Find(id_a)->api_key.clear();
        CHECK(again.Save());
        CHECK(state::Exists(state::PathOf(L"secrets\\printer-2.key")));
        PrinterStore kept;
        kept.Load();
        CHECK(kept.Find(id_a) != nullptr && kept.Find(id_a)->api_key == test_key);
        // Only ForgetKey deletes it.
        again.ForgetKey(*again.Find(id_a));
        CHECK(!state::Exists(state::PathOf(L"secrets\\printer-2.key")));
        CHECK(again.Find(id_a)->api_key.empty());
        again.Remove(id_b);
        CHECK(!state::Exists(state::PathOf(L"bambu\\01S00A000000001.code")));

        // An app.ini that does not read is not replaced by the default.
        std::wstring ini_path = state::PathOf(L"app.ini");
        HANDLE held = ::CreateFileW(ini_path.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        CHECK(held != INVALID_HANDLE_VALUE);
        {
            PrinterStore locked;
            locked.Load();
            CHECK(locked.ReadFailed());
            CHECK(!locked.FirstStart());
            CHECK(!locked.Save());
        }
        ::CloseHandle(held);
        PrinterStore after;
        after.Load();
        CHECK(!after.ReadFailed());
        CHECK(after.Find(id_a) != nullptr);

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

        // The first printer has no path: its address is the root, also from
        // the address of another printer of the deck.
        CHECK(link::DeckAddress(deck.Url() + "/printers/x2d", "") == deck.Url());
        CHECK(link::DeckRepairedUrl(deck.Url() + "/printers/x2d", "TAZ 6", got) == deck.Url());
        CHECK(link::DeckRepairedUrl(deck.Url(), "Bambu Lab X2D", got) == deck.Url() + "/printers/x2d");
        CHECK(link::DeckRepairedUrl(deck.Url() + "/printers/x2d", "bambu lab x2d", got).empty());
        CHECK(link::DeckRepairedUrl(deck.Url(), "TAZ 6", got).empty());
        CHECK(link::DeckRepairedUrl(deck.Url() + "/printers/x2d", "", got).empty());
        CHECK(link::DeckRepairedUrl(deck.Url() + "/printers/x2d", "Not on the deck", got).empty());
        link::DeckList twice = got;
        twice.printers.push_back(got.printers[0]);
        twice.printers.back().path = "/printers/copy";
        CHECK(link::DeckRepairedUrl(deck.Url() + "/printers/x2d", "TAZ 6", twice).empty());
        // A path that leaves the deck never becomes the address.
        link::DeckList away = got;
        away.printers[0].path = "//evil.example/";
        CHECK(link::DeckRepairedUrl(deck.Url() + "/printers/x2d", "TAZ 6", away).empty());

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

    // The one call that starts a print. It runs only against stubs.
    void TestPrintNet()
    {
        std::string answer = R"({"files":{"local":{"name":"a.gcode"}},"done":true})";
        int status = 201;
        std::atomic<int> posts{ 0 };
        HttpStub printer([&](Seen const &s) -> Reply {
            if (s.path == "/api/files/local" && s.method == "POST")
            {
                posts++;
                return Json(answer, status);
            }
            return Json("{}", 404);
        });
        link::Target t;
        t.name = "Octo";
        t.kind = LinkKind::OctoPrint;
        t.url = printer.Url();
        t.api_key = test_key;
        std::string gcode = "G1 X1\n; the file\n";
        char const *const yes_field = "name=\"print\"\r\n\r\ntrue\r\n";
        char const *const no_field = "name=\"print\"\r\n\r\nfalse\r\n";
        link::UploadResult r = link::UploadAndPrint(t, "a.gcode", gcode, nullptr, nullptr, link::PrintConfirmed{});
        CHECK(r.ok);
        CHECK(posts == 1);
        CHECK(printer.Log().size() == 1 && Has(printer.Log()[0].body, yes_field) && !Has(printer.Log()[0].body, no_field));
        CHECK(r.message == "Sent to Octo; it prints.");
        CHECK(!Has(r.message, test_key));
        // The next upload of the same target starts nothing.
        r = link::Upload(t, "a.gcode", gcode, nullptr, nullptr);
        CHECK(r.ok);
        CHECK(printer.Log().size() == 2 && Has(printer.Log()[1].body, no_field) && !Has(printer.Log()[1].body, yes_field));

        // A refusal is one request. A print is never sent twice.
        posts = 0;
        status = 500;
        r = link::UploadAndPrint(t, "a.gcode", gcode, nullptr, nullptr, link::PrintConfirmed{});
        CHECK(!r.ok);
        CHECK(posts == 1);
        status = 201;
        // A 2xx answer that is no stored file is an error.
        answer = "<html>login</html>";
        r = link::UploadAndPrint(t, "a.gcode", gcode, nullptr, nullptr, link::PrintConfirmed{});
        CHECK(!r.ok);
        answer = R"({"files":{"local":{"name":"a.gcode"}},"done":true})";

        // A print does not follow a redirect to another address.
        HttpStub elsewhere([](Seen const &) { return Json("{\"done\":true}"); });
        HttpStub redirect([&](Seen const &) {
            return Reply{ 307, "", "Location: " + elsewhere.Url() + "/api/files/local\r\n" };
        });
        link::Target rt = t;
        rt.url = redirect.Url();
        r = link::UploadAndPrint(rt, "a.gcode", gcode, nullptr, nullptr, link::PrintConfirmed{});
        CHECK(!r.ok);
        CHECK(elsewhere.Log().empty());

        // Moonraker: its own path.
        HttpStub moon([](Seen const &s) -> Reply {
            return s.path == "/server/files/upload" ? Json("{\"result\":{}}", 201) : Json("{}", 404);
        });
        link::Target k;
        k.name = "Voron";
        k.kind = LinkKind::Moonraker;
        k.url = moon.Url();
        r = link::UploadAndPrint(k, "a.gcode", gcode, nullptr, nullptr, link::PrintConfirmed{});
        CHECK(r.ok);
        CHECK(moon.Log().size() == 1 && Has(moon.Log()[0].body, yes_field));

        // A deck: an address that leads to another printer gets no file.
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
        r = link::UploadAndPrint(d, "a.gcode", gcode, nullptr, nullptr, link::PrintConfirmed{});
        CHECK(!r.ok);
        CHECK(uploads == 0);
        d.url = deck.Url() + "/printers/x2d";
        r = link::UploadAndPrint(d, "a.gcode", gcode, nullptr, nullptr, link::PrintConfirmed{});
        CHECK(r.ok);
        CHECK(uploads == 1);
        CHECK(Has(r.message, "waits for a press of Print"));
        CHECK(Has(deck.Log().back().path, "/printers/x2d/api/files/local") && Has(deck.Log().back().body, yes_field));

        // No connection, Bambu Lab, and USB: nothing goes out.
        for (LinkKind kind : { LinkKind::None, LinkKind::Bambu, LinkKind::Usb })
        {
            link::Target no;
            no.kind = kind;
            no.url = printer.Url();
            size_t before = printer.Log().size();
            CHECK(!link::UploadAndPrint(no, "a", gcode, nullptr, nullptr, link::PrintConfirmed{}).ok);
            CHECK(printer.Log().size() == before);
        }

        // A canceled print sends no file.
        auto cancel = std::make_shared<http::Cancel>();
        cancel->Stop();
        posts = 0;
        r = link::UploadAndPrint(t, "a", gcode, cancel, nullptr, link::PrintConfirmed{});
        CHECK(!r.ok && r.cancelled);
        CHECK(posts == 0);
    }

    // The time of a printdeck printer. It runs only against stubs.
    void TestEstimate()
    {
        std::string reply = R"({"moves":1000,"prep":120,"total":1120,"plan_prints":4})";
        int status = 200;
        HttpStub deck([&](Seen const &s) -> Reply {
            if (s.path == "/api/plugin/printdeck/estimate" && s.method == "POST")
                return Json(reply, status);
            return Json("{}", 404);
        });
        link::Target t;
        t.name = "Deck";
        t.kind = LinkKind::Printdeck;
        t.url = deck.Url();
        t.api_key = test_key;
        std::string gcode;
        for (int i = 0; i < 2000; i++)
            gcode += "G1 X" + std::to_string(i % 50) + " Y10 E0.5\n";
        auto posts = [](HttpStub &stub) {
            std::vector<Seen> out;
            for (auto const &s : stub.Log())
                if (s.method == "POST")
                    out.push_back(s);
            return out;
        };
        link::EstimateResult r = link::ReadEstimate(t, gcode, nullptr);
        CHECK(r.ok);
        CHECK(r.estimate.total == 1120 && r.estimate.prep == 120 && r.estimate.moves == 1000 && r.estimate.plan_prints == 4);
        auto sent = posts(deck);
        CHECK(sent.size() == 1);
        CHECK(sent[0].path == "/api/plugin/printdeck/estimate");
        CHECK(sent[0].key == test_key);
        CHECK(Has(sent[0].content_type, "text/plain"));
        // The body is gzip, smaller than the G-code, and no upload form.
        CHECK(sent[0].body.size() > 2 && (unsigned char)sent[0].body[0] == 0x1f && (unsigned char)sent[0].body[1] == 0x8b);
        CHECK(sent[0].body.size() < gcode.size() / 2);
        CHECK(!Has(sent[0].body, "name=\"print\""));
        CHECK(!Has(r.message, test_key));

        // An answer with no usable time is no estimate.
        for (char const *bad : { "{\"total\":0}", "not json", "{}", "{\"total\":-5}", "{\"total\":1e300}", "{\"total\":100,\"prep\":-1}", "{\"total\":100,\"prep\":1e300}" })
        {
            reply = bad;
            CHECK(!link::ReadEstimate(t, gcode, nullptr).ok);
        }
        reply = R"({"moves":1000,"prep":120,"total":1120,"plan_prints":4})";
        // An older printdeck has no such path.
        status = 404;
        CHECK(!link::ReadEstimate(t, gcode, nullptr).ok);
        status = 200;

        // A redirect takes the G-code nowhere.
        HttpStub elsewhere([](Seen const &) { return Json("{\"total\":5}"); });
        HttpStub redirect([&](Seen const &) {
            return Reply{ 307, "", "Location: " + elsewhere.Url() + "/api/plugin/printdeck/estimate\r\n" };
        });
        link::Target rt = t;
        rt.url = redirect.Url();
        CHECK(!link::ReadEstimate(rt, gcode, nullptr).ok);
        CHECK(elsewhere.Log().empty());

        // A deck: an address that leads to another printer gets no G-code.
        std::string list = R"({"printers":[{"name":"TAZ 6","label":"TAZ","url":""},{"name":"X2D","label":"X2D","url":"/printers/x2d"}]})";
        HttpStub many([&](Seen const &s) -> Reply {
            if (s.path == "/slicer/printer.json")
                return Json(list);
            if (s.method == "POST")
                return Json(R"({"total":900,"prep":60})");
            return Json("{}", 404);
        });
        link::Target d;
        d.name = "X2D";
        d.kind = LinkKind::Printdeck;
        d.url = many.Url();
        d.api_key = test_key;
        CHECK(!link::ReadEstimate(d, gcode, nullptr).ok);
        CHECK(posts(many).empty());
        d.url = many.Url() + "/printers/x2d";
        CHECK(link::ReadEstimate(d, gcode, nullptr).ok);
        CHECK(posts(many).size() == 1 && posts(many)[0].path == "/printers/x2d/api/plugin/printdeck/estimate");

        // Each other kind of printer gets no request.
        for (LinkKind kind : { LinkKind::None, LinkKind::OctoPrint, LinkKind::Moonraker, LinkKind::Bambu, LinkKind::Usb })
        {
            link::Target no;
            no.kind = kind;
            no.url = deck.Url();
            size_t before = deck.Log().size();
            CHECK(!link::ReadEstimate(no, gcode, nullptr).ok);
            CHECK(deck.Log().size() == before);
        }

        // A canceled estimate sends no G-code.
        auto cancel = std::make_shared<http::Cancel>();
        cancel->Stop();
        size_t count = posts(deck).size();
        r = link::ReadEstimate(t, gcode, cancel);
        CHECK(!r.ok && r.cancelled);
        CHECK(posts(deck).size() == count);
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

        // The wait before the next connection.
        CHECK(BambuRetrySeconds(0) == 15);
        CHECK(BambuRetrySeconds(1) == 15);
        CHECK(BambuRetrySeconds(2) == 30);
        CHECK(BambuRetrySeconds(3) == 60);
        CHECK(BambuRetrySeconds(6) == 300);
        CHECK(BambuRetrySeconds(100) == 300);

        // A printer that is full: the next CONNECT comes 15 s later, and
        // not sooner.
        std::vector<std::chrono::steady_clock::time_point> busy_connects;
        TlsStub busy(cert.Get(), [&](std::string const &in, TlsStub::Write const &write) {
            if ((unsigned char)in[0] >> 4 != 1)
                return;
            {
                std::lock_guard guard(lock);
                busy_connects.push_back(std::chrono::steady_clock::now());
                cv.notify_all();
            }
            write(std::string("\x20\x02\x00\x03", 4));
        });
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_MQTT_PORT", std::to_string(busy.Port()).c_str());
        {
            BambuWatch watch(t, serial, [](link::Snapshot const &) {}, [](std::string const &) {}, nullptr);
            std::unique_lock wait(lock);
            cv.wait_for(wait, std::chrono::seconds(20), [&] { return busy_connects.size() >= 2; });
        }
        {
            std::lock_guard guard(lock);
            CHECK(busy_connects.size() == 2);
            if (busy_connects.size() >= 2)
                CHECK(busy_connects[1] - busy_connects[0] >= std::chrono::milliseconds(14900));
        }
        // A new watch of that printer keeps the wait: no CONNECT comes now.
        size_t busy_before = 0;
        {
            std::lock_guard guard(lock);
            busy_before = busy_connects.size();
        }
        {
            BambuWatch again(t, serial, [](link::Snapshot const &) {}, [](std::string const &) {}, nullptr);
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
        {
            std::lock_guard guard(lock);
            CHECK(busy_connects.size() == busy_before);
        }

        // Two watches of one printer: it gets one connection.
        std::atomic<int> single_connects{ 0 };
        TlsStub single(cert.Get(), [&single_connects](std::string const &in, TlsStub::Write const &write) {
            if ((unsigned char)in[0] >> 4 == 1)
            {
                single_connects++;
                write(std::string("\x20\x02\x00\x00", 4));
            }
        });
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_MQTT_PORT", std::to_string(single.Port()).c_str());
        {
            BambuWatch first(t, serial, [](link::Snapshot const &) {}, [](std::string const &) {}, nullptr);
            BambuWatch second(t, serial, [](link::Snapshot const &) {}, [](std::string const &) {}, nullptr);
            std::this_thread::sleep_for(std::chrono::seconds(2));
            CHECK(single_connects.load() == 1);
        }

        // A wrong access code: the broker refuses, and the watch stops.
        std::atomic<int> refused_connects{ 0 };
        TlsStub refuse(cert.Get(), [&refused_connects](std::string const &in, TlsStub::Write const &write) {
            if ((unsigned char)in[0] >> 4 == 1)
            {
                refused_connects++;
                write(std::string("\x20\x02\x00\x05", 4));
            }
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
        CHECK(refused_connects.load() == 1);
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
                [&](std::shared_ptr<CameraPicture const> const &j) {
                    std::lock_guard guard(lock);
                    shown = j->bytes;
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

    // ---- H.264 pictures for the tests: exact colors, with no encoder ----

    class Bits
    {
    public:
        void Bit(int b)
        {
            cur_ = (cur_ << 1) | (b & 1);
            if (++used_ == 8)
            {
                out_.push_back((char)cur_);
                cur_ = used_ = 0;
            }
        }
        void U(unsigned value, int count)
        {
            for (int i = count - 1; i >= 0; i--)
                Bit((value >> i) & 1);
        }
        void Ue(unsigned value)
        {
            value++;
            int top = 0;
            for (unsigned x = value; x > 1; x >>= 1)
                top++;
            U(0, top);
            U(value, top + 1);
        }
        void Align()
        {
            while (used_ != 0)
                Bit(0);
        }
        void Raw(uint8_t value, size_t count) { out_.append(count, (char)value); }
        std::string Trail()
        {
            Bit(1);
            Align();
            return out_;
        }

    private:
        std::string out_;
        unsigned cur_ = 0;
        int used_ = 0;
    };

    // A NAL unit after its start code, with the emulation prevention bytes.
    std::string NalUnit(uint8_t header, std::string const &rbsp)
    {
        std::string out("\0\0\0\1", 4);
        out.push_back((char)header);
        int zeros = 0;
        for (char c : rbsp)
        {
            if (zeros >= 2 && (uint8_t)c <= 3)
            {
                out.push_back(3);
                zeros = 0;
            }
            out.push_back(c);
            zeros = c == 0 ? zeros + 1 : 0;
        }
        return out;
    }

    struct Yuv
    {
        uint8_t y, u, v;
    };
    constexpr Yuv yuv_red{ 81, 90, 240 }, yuv_green{ 145, 54, 34 }, yuv_blue{ 41, 240, 110 };

    // A key frame: its SPS and PPS, and an IDR slice of I_PCM macroblocks,
    // the left half in one color and the right half in another.
    std::string H264Key(int mb_width, int mb_height, int crop_lines, Yuv left, Yuv right, unsigned idr)
    {
        Bits sps;
        sps.U(66, 8);
        sps.U(0xC0, 8);
        sps.U(40, 8);
        sps.Ue(0);
        sps.Ue(0); // frame_num of 4 bits
        sps.Ue(2); // output in decoding order
        sps.Ue(1);
        sps.Bit(0);
        sps.Ue(mb_width - 1);
        sps.Ue(mb_height - 1);
        sps.Bit(1);
        sps.Bit(1);
        sps.Bit(crop_lines > 0);
        if (crop_lines > 0)
        {
            sps.Ue(0);
            sps.Ue(0);
            sps.Ue(0);
            sps.Ue(crop_lines / 2);
        }
        sps.Bit(0);
        Bits pps;
        pps.Ue(0);
        pps.Ue(0);
        pps.Bit(0);
        pps.Bit(0);
        pps.Ue(0);
        pps.Ue(0);
        pps.Ue(0);
        pps.Bit(0);
        pps.U(0, 2);
        pps.Ue(0);
        pps.Ue(0);
        pps.Ue(0);
        pps.Bit(1);
        pps.Bit(0);
        pps.Bit(0);
        Bits slice;
        slice.Ue(0);
        slice.Ue(7);
        slice.Ue(0);
        slice.U(0, 4);
        slice.Ue(idr);
        slice.Bit(0);
        slice.Bit(0);
        slice.Ue(0);
        slice.Ue(1); // no deblocking
        for (int y = 0; y < mb_height; y++)
            for (int x = 0; x < mb_width; x++)
            {
                Yuv c = x < mb_width / 2 ? left : right;
                slice.Ue(25); // I_PCM
                slice.Align();
                slice.Raw(c.y, 256);
                slice.Raw(c.u, 64);
                slice.Raw(c.v, 64);
            }
        return NalUnit(0x67, sps.Trail()) + NalUnit(0x68, pps.Trail()) + NalUnit(0x65, slice.Trail());
    }

    // A P frame where each macroblock repeats the last picture.
    std::string H264Skip(int mb_width, int mb_height, unsigned frame_num)
    {
        Bits slice;
        slice.Ue(0);
        slice.Ue(5);
        slice.Ue(0);
        slice.U(frame_num, 4);
        slice.Bit(0);
        slice.Bit(0);
        slice.Bit(0);
        slice.Ue(0);
        slice.Ue(1);
        slice.Ue(mb_width * mb_height);
        return NalUnit(0x41, slice.Trail());
    }

    bool PixelIs(CameraPicture const &p, int x, int y, char channel)
    {
        if (p.width <= 0 || x >= p.width || y >= p.height || p.bytes.size() < (size_t)p.width * p.height * 4)
            return false;
        auto const *at = reinterpret_cast<uint8_t const *>(p.bytes.data()) + ((size_t)y * p.width + x) * 4;
        int b = at[0], g = at[1], r = at[2];
        if (at[3] != 255)
            return false;
        int high = channel == 'r' ? r : channel == 'g' ? g : b;
        int rest = channel == 'r' ? std::max(g, b) : channel == 'g' ? std::max(r, b) : std::max(r, g);
        return high >= 200 && rest <= 60;
    }

    void TestH264()
    {
        H264Decoder decoder;
        if (!decoder.Ready())
        {
            printf("h264: this Windows has no decoder, skipped\n");
            return;
        }
        std::vector<CameraPicture> shown;
        auto keep = [&](std::string &&bgra, int w, int h) {
            CameraPicture p;
            p.bytes = std::move(bgra);
            p.width = w;
            p.height = h;
            shown.push_back(std::move(p));
        };
        auto yes = [] { return true; };
        auto decode = [&](std::string const &au, bool tile = false) {
            decoder.Decode(reinterpret_cast<uint8_t const *>(au.data()), au.size(), tile, yes, keep);
        };
        // 320 x 192 rows, cropped to 180.
        decode(H264Key(20, 12, 12, yuv_red, yuv_blue, 0));
        decode(H264Skip(20, 12, 1));
        decode(H264Skip(20, 12, 2));
        decode(H264Key(20, 12, 12, yuv_green, yuv_red, 1));
        CHECK(decoder.Errors() == 0);
        CHECK(shown.size() == 4);
        if (shown.size() == 4)
        {
            CHECK(shown[0].width == 320);
            CHECK(shown[0].height == 180);
            CHECK(PixelIs(shown[0], 40, 90, 'r'));
            CHECK(PixelIs(shown[0], 280, 90, 'b'));
            CHECK(PixelIs(shown[0], 280, 179, 'b'));
            CHECK(PixelIs(shown[2], 40, 90, 'r'));
            CHECK(PixelIs(shown[2], 280, 90, 'b'));
            CHECK(PixelIs(shown[3], 40, 90, 'g'));
            CHECK(PixelIs(shown[3], 280, 90, 'r'));
        }
        // `want` says no: the frame still decodes, and no picture comes.
        size_t before = shown.size();
        std::string skip = H264Skip(20, 12, 1);
        decoder.Decode(reinterpret_cast<uint8_t const *>(skip.data()), skip.size(), false, [] { return false; }, keep);
        CHECK(shown.size() == before);
        CHECK(decoder.Errors() == 0);
        // A new size in the stream, and a card that halves a wide picture.
        shown.clear();
        decode(H264Key(80, 45, 0, yuv_blue, yuv_green, 2), true);
        CHECK(shown.size() == 1);
        if (shown.size() == 1)
        {
            CHECK(shown[0].width == 640);
            CHECK(shown[0].height == 360);
            CHECK(PixelIs(shown[0], 80, 180, 'b'));
            CHECK(PixelIs(shown[0], 560, 180, 'g'));
        }
        // Bytes that are no video do not stop the decoder.
        std::string junk(64, '\x55');
        decoder.Decode(reinterpret_cast<uint8_t const *>(junk.data()), junk.size(), false, yes, keep);
        shown.clear();
        decode(H264Key(20, 12, 12, yuv_red, yuv_red, 3));
        CHECK(!shown.empty());
        if (!shown.empty())
        {
            CHECK(shown.back().width == 320);
            CHECK(PixelIs(shown.back(), 160, 90, 'r'));
        }
    }

    // ---- a stub of the RTSP camera, with a Digest login ----

    struct RtspStub
    {
        std::mutex lock;
        std::string code, in, seen;
        std::vector<std::string> frames;
        int logins = 0, bad_logins = 0, plays = 0, teardowns = 0;
        // Seconds of frames after PLAY, at 10 a second. 0: each frame once.
        int play_seconds = 0;
    };

    std::string Md5Hex(std::string const &text)
    {
        char out[33] = "";
        zs_bambu_md5(reinterpret_cast<uint8_t const *>(text.data()), text.size(), out);
        // The core gives upper case for Bambu Lab. Digest has lower case.
        std::string hex = out;
        for (char &c : hex)
            c = (char)tolower((unsigned char)c);
        return hex;
    }

    std::string DigestField(std::string const &head, std::string const &name)
    {
        std::string key = " " + name + "=\"";
        size_t at = head.find(key);
        if (at == std::string::npos)
            return {};
        at += key.size();
        size_t end = head.find('"', at);
        return end == std::string::npos ? std::string() : head.substr(at, end - at);
    }

    // The packets of a frame, interleaved on channel 0 (RFC 6184: a single
    // NAL unit, or FU-A fragments).
    std::string RtpFrame(std::string const &au, uint32_t stamp, uint16_t &sequence)
    {
        std::string out;
        auto packet = [&](std::string const &payload, bool marker) {
            sequence++;
            size_t size = payload.size() + 12;
            out += '$';
            out += '\0';
            out += (char)(size >> 8);
            out += (char)size;
            out += (char)0x80;
            out += (char)(96 | (marker ? 0x80 : 0));
            out += (char)(sequence >> 8);
            out += (char)sequence;
            for (int s = 24; s >= 0; s -= 8)
                out += (char)(stamp >> s);
            out.append("\xBA\x5E\x00\x01", 4);
            out += payload;
        };
        std::string const start("\0\0\0\1", 4);
        std::vector<std::string> units;
        for (size_t at = au.find(start); at != std::string::npos;)
        {
            size_t next = au.find(start, at + 4);
            units.push_back(au.substr(at + 4, next == std::string::npos ? std::string::npos : next - at - 4));
            at = next;
        }
        for (size_t i = 0; i < units.size(); i++)
        {
            std::string const &unit = units[i];
            bool last = i + 1 == units.size();
            if (unit.size() <= 1400)
            {
                packet(unit, last);
                continue;
            }
            uint8_t head = (uint8_t)unit[0];
            for (size_t off = 1; off < unit.size(); off += 1400)
            {
                bool first = off == 1, end = off + 1400 >= unit.size();
                std::string part;
                part += (char)((head & 0xE0) | 28);
                part += (char)((first ? 0x80 : 0) | (end ? 0x40 : 0) | (head & 31));
                part += unit.substr(off, 1400);
                packet(part, last && end);
            }
        }
        return out;
    }

    TlsStub::Serve ServeRtsp(std::shared_ptr<RtspStub> stub)
    {
        return [stub](std::string const &chunk, TlsStub::Write const &write) {
            bool play = false;
            {
                std::lock_guard guard(stub->lock);
                stub->seen += chunk;
                stub->in += chunk;
                for (;;)
                {
                    size_t end = stub->in.find("\r\n\r\n");
                    if (end == std::string::npos)
                        break;
                    std::string head = stub->in.substr(0, end + 4);
                    stub->in.erase(0, end + 4);
                    std::string method = head.substr(0, head.find(' '));
                    size_t c = head.find("CSeq: ");
                    std::string cseq = c == std::string::npos ? "0" : head.substr(c + 6, head.find("\r\n", c) - c - 6);
                    std::string uri = DigestField(head, "uri");
                    std::string expect = Md5Hex(Md5Hex("bblp:zslice:" + stub->code) + ":f00d:" + Md5Hex(method + ":" + uri));
                    bool login = head.find("Authorization: Digest") != std::string::npos && DigestField(head, "response") == expect;
                    if (!login)
                    {
                        if (head.find("Authorization:") != std::string::npos)
                            stub->bad_logins++;
                        write("RTSP/1.0 401 Unauthorized\r\nCSeq: " + cseq + "\r\nWWW-Authenticate: Digest realm=\"zslice\", nonce=\"f00d\"\r\n\r\n");
                        continue;
                    }
                    stub->logins++;
                    if (method == "DESCRIBE")
                    {
                        std::string sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=test\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\n"
                                          "a=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\r\na=control:track1\r\n";
                        write("RTSP/1.0 200 OK\r\nCSeq: " + cseq + "\r\nContent-Base: rtsps://127.0.0.1/streaming/live/1/\r\nContent-Type: application/sdp\r\nContent-Length: " +
                              std::to_string(sdp.size()) + "\r\n\r\n" + sdp);
                    }
                    else if (method == "SETUP")
                        write("RTSP/1.0 200 OK\r\nCSeq: " + cseq + "\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nSession: 4F2A;timeout=65\r\n\r\n");
                    else if (method == "PLAY")
                    {
                        write("RTSP/1.0 200 OK\r\nCSeq: " + cseq + "\r\nSession: 4F2A\r\n\r\n");
                        stub->plays++;
                        play = true;
                    }
                    else
                    {
                        if (method == "TEARDOWN")
                            stub->teardowns++;
                        write("RTSP/1.0 200 OK\r\nCSeq: " + cseq + "\r\nSession: 4F2A\r\n\r\n");
                    }
                }
            }
            if (!play)
                return;
            uint16_t sequence = 0;
            int count = stub->play_seconds > 0 ? stub->play_seconds * 10 : (int)stub->frames.size();
            for (int i = 0; i < count; i++)
            {
                write(RtpFrame(stub->frames[i % stub->frames.size()], (uint32_t)i * 9000, sequence));
                if (stub->play_seconds > 0)
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        };
    }

    struct FeedLog
    {
        std::mutex lock;
        std::condition_variable cv;
        int pictures = 0;
        std::shared_ptr<CameraPicture const> last;
        std::vector<std::string> notes;

        CameraFeed::Frame Frame()
        {
            return [this](std::shared_ptr<CameraPicture const> const &p) {
                std::lock_guard guard(lock);
                pictures++;
                last = p;
                cv.notify_all();
            };
        }
        CameraFeed::Note Note()
        {
            return [this](std::string const &text) {
                std::lock_guard guard(lock);
                notes.push_back(text);
                cv.notify_all();
            };
        }
        bool WaitPicture(int seconds)
        {
            std::unique_lock wait(lock);
            return cv.wait_for(wait, std::chrono::seconds(seconds), [&] { return pictures > 0; });
        }
        bool WaitNote(int seconds)
        {
            std::unique_lock wait(lock);
            return cv.wait_for(wait, std::chrono::seconds(seconds), [&] { return !notes.empty(); });
        }
    };

    void TestRtsp()
    {
        {
            H264Decoder probe;
            if (!probe.Ready())
            {
                printf("rtsp: this Windows has no decoder, skipped\n");
                return;
            }
        }
        TestCert cert;
        CHECK(cert.Get() != nullptr);
        if (cert.Get() == nullptr)
            return;
        std::string const code = "87654321";
        auto stub = std::make_shared<RtspStub>();
        stub->code = code;
        stub->frames = { H264Key(20, 12, 12, yuv_red, yuv_blue, 0), H264Skip(20, 12, 1), H264Skip(20, 12, 2) };
        TlsStub server(cert.Get(), ServeRtsp(stub));
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_RTSPS_PORT", std::to_string(server.Port()).c_str());
        CameraSource source;
        source.bambu_host = "127.0.0.1";
        source.bambu_code = code;
        source.bambu_kind = 1;
        source.large = true;

        // A whole session: the login, the frames, and the teardown.
        {
            FeedLog log;
            {
                CameraFeed feed(source, log.Frame(), log.Note());
                CHECK(log.WaitPicture(10));
            }
            CHECK(log.last != nullptr && log.last->width == 320 && log.last->height == 180);
            if (log.last != nullptr)
            {
                CHECK(PixelIs(*log.last, 40, 90, 'r'));
                CHECK(PixelIs(*log.last, 280, 90, 'b'));
            }
            for (auto const &note : log.notes)
                CHECK(note.find(code) == std::string::npos);
        }
        for (int i = 0; i < 40; i++)
        {
            {
                std::lock_guard guard(stub->lock);
                if (stub->teardowns > 0)
                    break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        {
            std::lock_guard guard(stub->lock);
            CHECK(stub->plays == 1);
            CHECK(stub->teardowns == 1);
            CHECK(stub->logins >= 3);
            CHECK(stub->bad_logins == 0);
            // Digest: the code never crosses the connection.
            CHECK(stub->seen.find(code) == std::string::npos);
        }

        // A wrong code: a note with no code in it, and no picture.
        {
            CameraSource wrong = source;
            wrong.bambu_code = "11112222";
            FeedLog log;
            {
                CameraFeed feed(wrong, log.Frame(), log.Note());
                CHECK(log.WaitNote(10));
            }
            CHECK(log.pictures == 0);
            CHECK(!log.notes.empty() && log.notes[0].find("11112222") == std::string::npos);
        }

        // One stream to a printer: a second feed waits for the first.
        {
            int before = server.Handshakes();
            FeedLog first_log, second_log;
            auto first = std::make_unique<CameraFeed>(source, first_log.Frame(), first_log.Note());
            CHECK(first_log.WaitPicture(10));
            CameraFeed second(source, second_log.Frame(), second_log.Note());
            CHECK(second_log.WaitNote(5));
            CHECK(server.Handshakes() == before + 1);
            CHECK(second_log.pictures == 0);
            first.reset();
            CHECK(second_log.WaitPicture(10));
            CHECK(server.Handshakes() == before + 2);
        }

        // A model that is not known, with no RTSP port: the JPEG port.
        {
            SOCKET closed = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            ::bind(closed, reinterpret_cast<sockaddr *>(&addr), sizeof addr);
            int size = sizeof addr;
            ::getsockname(closed, reinterpret_cast<sockaddr *>(&addr), &size);
            int free_port = ntohs(addr.sin_port);
            ::closesocket(closed);
            ::SetEnvironmentVariableA("ZSLICE_BAMBU_RTSPS_PORT", std::to_string(free_port).c_str());
            std::string jpeg = "\xFF\xD8picture\xFF\xD9";
            std::string frame(16, '\0');
            frame[0] = (char)jpeg.size();
            frame[8] = 1;
            frame += jpeg;
            TlsStub port6000(cert.Get(), [&](std::string const &, TlsStub::Write const &write) { write(frame); });
            ::SetEnvironmentVariableA("ZSLICE_BAMBU_JPEG_PORT", std::to_string(port6000.Port()).c_str());
            CameraSource unknown = source;
            unknown.bambu_kind = 0;
            FeedLog log;
            {
                CameraFeed feed(unknown, log.Frame(), log.Note());
                CHECK(log.WaitPicture(10));
            }
            CHECK(log.last != nullptr && log.last->width == 0 && log.last->bytes == jpeg);
            ::SetEnvironmentVariableA("ZSLICE_BAMBU_JPEG_PORT", nullptr);
        }
        ::SetEnvironmentVariableA("ZSLICE_BAMBU_RTSPS_PORT", nullptr);
    }

    // For a look at the app: a camera on 127.0.0.1 for 40 seconds. It writes
    // its port to `path`, and it has only a test code.
    int RunRtspStub(char const *path)
    {
        TestCert cert;
        if (cert.Get() == nullptr)
            return 1;
        auto stub = std::make_shared<RtspStub>();
        stub->code = "87654321";
        stub->play_seconds = 30;
        stub->frames.push_back(H264Key(40, 23, 4, yuv_red, yuv_blue, 0));
        for (unsigned i = 1; i < 10; i++)
            stub->frames.push_back(H264Skip(40, 23, i));
        TlsStub server(cert.Get(), ServeRtsp(stub));
        FILE *f = nullptr;
        if (fopen_s(&f, path, "w") != 0 || f == nullptr)
            return 1;
        fprintf(f, "%d\n", server.Port());
        fclose(f);
        std::this_thread::sleep_for(std::chrono::seconds(40));
        return 0;
    }

    // ---- a stub printer on a USB port: no test opens a real port ----

    class StubPrinter final : public usb::Port
    {
    public:
        // The answer to each command, from the rules of the test.
        std::function<std::string(std::string const &, size_t)> answer = [](std::string const &, size_t) { return std::string("ok\n"); };
        std::vector<std::string> lines;
        std::function<void(size_t)> on_line;
        bool dead = false;
        int flushes = 0;
        size_t chunk = 1000;

        bool Write(char const *data, size_t len) override
        {
            if (dead)
                return false;
            std::string text(data, len);
            CHECK(!text.empty() && text.back() == '\n');
            text.pop_back();
            lines.push_back(text);
            pending_ += answer(text, lines.size());
            if (on_line)
                on_line(lines.size());
            return true;
        }

        int Read(char *data, size_t cap, int timeout_ms) override
        {
            if (dead)
                return -1;
            if (pending_.empty())
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(std::min(timeout_ms, 5)));
                return 0;
            }
            size_t n = std::min({ cap, chunk, pending_.size() });
            memcpy(data, pending_.data(), n);
            pending_.erase(0, n);
            return (int)n;
        }

        void Flush() override
        {
            flushes++;
            pending_.clear();
        }

    private:
        std::string pending_;
    };

    void TestUsb()
    {
        // Only a plain COM name passes, so no other device can open.
        for (char const *good : { "COM1", "COM3", "COM10", "COM256" })
            CHECK(usb::ValidPort(good));
        for (char const *bad : { "", "COM", "COM0", "COM01", "COM257", "COM3:", "COM3 ", " COM3", "com3", "\\\\.\\COM3", "LPT1", "NUL", "CON", "COM3\\x", "..\\COM3", "COMx", "COM1000" })
            CHECK(!usb::ValidPort(bad));
        for (int baud : usb::bauds)
            CHECK(usb::ValidBaud(baud));
        CHECK(!usb::ValidBaud(0));
        CHECK(!usb::ValidBaud(9));
        std::string error;
        CHECK(usb::OpenPort("\\\\.\\PhysicalDrive0", 250000, error) == nullptr);
        CHECK(error.find("Pick a serial port") != std::string::npos);
        error.clear();
        CHECK(usb::OpenPort("NUL", 250000, error) == nullptr);
        // The list reads the registry and opens no port.
        for (std::string const &name : usb::Ports())
            CHECK(usb::ValidPort(name));

        usb::Timing fast{ 1, 300, 300 };
        std::atomic<bool> stop{ false };
        // Comments, blank lines, spaces, and CR LF do not reach the printer.
        {
            StubPrinter p;
            std::vector<double> seen;
            std::string gcode = "; a comment\nG28\r\n\n  G1 X1 Y2  ; to the corner\n\t\n;x\nM104 S200";
            usb::Result r = usb::Stream(p, gcode, stop, [&](double f) { seen.push_back(f); }, fast);
            CHECK(r.ok);
            CHECK(!r.cancelled);
            CHECK(p.flushes == 1);
            CHECK((p.lines == std::vector<std::string>{ "G28", "G1 X1 Y2", "M104 S200" }));
            CHECK(!seen.empty() && seen.back() == 1.0);
            for (size_t i = 1; i < seen.size(); i++)
                CHECK(seen[i] >= seen[i - 1]);
        }
        // Other lines of the printer, and an answer in small pieces.
        {
            StubPrinter p;
            p.chunk = 1;
            p.answer = [](std::string const &, size_t) { return std::string("echo:busy: processing\r\n T:200.0 /200.0 B:60.0\nok T:200\r\n"); };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\nG1 X3\n", stop, nullptr, fast);
            CHECK(r.ok);
            CHECK(p.lines.size() == 3);
        }
        // Each command waits for its "ok": a line that only has it inside
        // is no answer.
        {
            StubPrinter p;
            p.answer = [](std::string const &, size_t) { return std::string("echo: not ok\n"); };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\n", stop, nullptr, usb::Timing{ 1, 60, 60 });
            CHECK(!r.ok);
            CHECK(r.message == "The printer did not answer.");
            CHECK(p.lines.size() == 1);
        }
        // An error of the printer ends the print at that command.
        for (char const *text : { "Error:Printer halted. kill() called!\n", "!! thermal runaway\n" })
        {
            StubPrinter p;
            std::string said = text;
            p.answer = [said](std::string const &, size_t n) { return n == 2 ? said : std::string("ok\n"); };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\nG1 X3\nG1 X4\n", stop, nullptr, fast);
            CHECK(!r.ok);
            CHECK(!r.cancelled);
            CHECK(r.message.find("The printer said: ") == 0);
            CHECK(p.lines.size() == 2);
        }
        // A port that goes away.
        {
            StubPrinter p;
            p.on_line = [&p](size_t n) {
                if (n == 2)
                    p.dead = true;
            };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\nG1 X3\n", stop, nullptr, fast);
            CHECK(!r.ok);
            CHECK(r.message == "The port stopped.");
            CHECK(p.lines.size() == 2);
        }
        // A stop with a command in flight: its "ok", then the three cooling
        // commands in order, and no move.
        {
            StubPrinter p;
            std::atomic<bool> halt{ false };
            p.on_line = [&halt](size_t n) {
                if (n == 3)
                    halt.store(true);
            };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\nG1 X3\nG1 X4\nG1 X5\n", halt, nullptr, fast);
            CHECK(!r.ok);
            CHECK(r.cancelled);
            CHECK(r.sent);
            CHECK(r.cooled);
            CHECK((p.lines == std::vector<std::string>{ "G1 X1", "G1 X2", "G1 X3", "M104 S0", "M140 S0", "M107" }));
        }
        // The nozzles that a stop turns off. Each case stops at line `at`.
        {
            auto stopped = [&](std::string const &gcode, size_t at, int nozzles) {
                StubPrinter p;
                std::atomic<bool> halt{ false };
                p.on_line = [&halt, at](size_t n) {
                    if (n >= at)
                        halt.store(true);
                };
                usb::Result r = usb::Stream(p, gcode, halt, nullptr, fast, nozzles);
                CHECK(r.cancelled);
                CHECK(r.cooled);
                return std::vector<std::string>(p.lines.begin() + (std::ptrdiff_t)std::min(at, p.lines.size()), p.lines.end());
            };
            using Lines = std::vector<std::string>;
            std::string const plain = "G1 X1\nG1 X2\nG1 X3\n";
            // One nozzle.
            CHECK((stopped(plain, 1, 1) == Lines{ "M104 S0", "M140 S0", "M107" }));
            // Two nozzles: each one by its number, with no tool change.
            CHECK((stopped(plain, 1, 2) == Lines{ "M104 T0 S0", "M104 T1 S0", "M140 S0", "M107" }));
            // A file that selects T1 on a machine set to one nozzle.
            CHECK((stopped("G1 X1\nT1\nG1 X2\nG1 X3\n", 3, 1) == Lines{ "M104 T0 S0", "M104 T1 S0", "M140 S0", "M107" }));
            // The tool line in flight counts, also with a comment.
            CHECK((stopped("G1 X1\n  T1 ; the second nozzle\nG1 X2\n", 2, 1) == Lines{ "M104 T0 S0", "M104 T1 S0", "M140 S0", "M107" }));
            // T0 is the one nozzle.
            CHECK((stopped("T0\nG1 X1\nG1 X2\n", 2, 1) == Lines{ "M104 S0", "M140 S0", "M107" }));
            // A tool past the setting raises the count, and a lower one does not.
            CHECK((stopped("T2\nT0\nG1 X1\nG1 X2\n", 3, 2) == Lines{ "M104 T0 S0", "M104 T1 S0", "M104 T2 S0", "M140 S0", "M107" }));
            CHECK((stopped("T1\nG1 X1\nG1 X2\n", 2, 3) == Lines{ "M104 T0 S0", "M104 T1 S0", "M104 T2 S0", "M140 S0", "M107" }));
            // A tool with two digits.
            CHECK(stopped("T11\nG1 X1\nG1 X2\n", 2, 1).size() == 12 + 2);
            // A tool line that the print did not reach does not count.
            CHECK((stopped("G1 X1\nG1 X2\nT3\n", 1, 1) == Lines{ "M104 S0", "M140 S0", "M107" }));
            // Words that are no tool line.
            CHECK((stopped("T\nTX\nT1 S2\nT123\nM117 T1\nG1 X1\nG1 X2\nG1 X3\n", 6, 1) == Lines{ "M104 S0", "M140 S0", "M107" }));
            // The T word of a heater command, in any place on the line.
            Lines const two{ "M104 T0 S0", "M104 T1 S0", "M140 S0", "M107" };
            for (char const *line : { "M109 T1 S200", "M104 S200 T1", "M104 T1", "M109 R180 T1", "M104T1S200", "M104 S200T1", "M109 T01 S200" })
                CHECK((stopped(std::string(line) + "\nG1 X1\nG1 X2\n", 2, 1) == two));
            // It raises the count and never lowers it.
            CHECK(stopped("M104 T2 S200\nM104 T0 S200\nG1 X1\nG1 X2\n", 3, 1).size() == 3 + 2);
            CHECK(stopped("M104 T0 S200\nG1 X1\nG1 X2\n", 2, 3).size() == 3 + 2);
            // T0 on one nozzle stays the plain command.
            CHECK((stopped("M104 T0 S200\nG1 X1\nG1 X2\n", 2, 1) == Lines{ "M104 S0", "M140 S0", "M107" }));
            // It stays in 16 nozzles.
            CHECK(stopped("T16\nG1 X1\nG1 X2\n", 2, 1).size() == 16 + 2);
            CHECK(stopped("T99\nG1 X1\nG1 X2\n", 2, 1).size() == 16 + 2);
            CHECK(stopped("M104 T15 S200\nG1 X1\nG1 X2\n", 2, 1).size() == 16 + 2);
            CHECK(stopped("M109 T99 S200\nG1 X1\nG1 X2\n", 2, 1).size() == 16 + 2);
            CHECK(stopped("M104 T999999999999 S200\nG1 X1\nG1 X2\n", 2, 1).size() == 16 + 2);
            // A heater line that the print did not reach does not count.
            CHECK((stopped("G1 X1\nG1 X2\nM104 T3 S200\n", 1, 1) == Lines{ "M104 S0", "M140 S0", "M107" }));
            // Words that only look like a tool.
            for (char const *line : { "TEST", "TEST1", "M104 TEST S200", "M104 TEST1", "M104 XT1 S200", "M104 T S200", "M104 S200", "M117 T1 ready", "M140 T1 S60", "M1040 T1", "M1090 T1", "G1 T1", "M104 S200 ; T3", "; M104 T3" })
                CHECK((stopped(std::string(line) + "\nG1 X1\nG1 X2\nG1 X3\n", 2, 1) == Lines{ "M104 S0", "M140 S0", "M107" }));
            // The count stays in 1 to 16.
            CHECK((stopped(plain, 1, 0) == Lines{ "M104 S0", "M140 S0", "M107" }));
            CHECK(stopped(plain, 1, 99).size() == 16 + 2);
        }
        // A nozzle with no answer ends the stop, and it is no success.
        {
            StubPrinter p;
            std::atomic<bool> halt{ false };
            p.answer = [&halt](std::string const &text, size_t) {
                halt.store(true);
                return text == "M104 T1 S0" ? std::string() : std::string("ok\n");
            };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\n", halt, nullptr, usb::Timing{ 1, 300, 60 }, 3);
            CHECK(r.cancelled);
            CHECK(!r.cooled);
            CHECK((p.lines == std::vector<std::string>{ "G1 X1", "M104 T0 S0", "M104 T1 S0" }));
        }
        // A stop between two commands: the cooling commands follow.
        {
            StubPrinter p;
            std::atomic<bool> halt{ false };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\n", halt, [&halt](double) { halt.store(true); }, fast);
            CHECK(r.cancelled);
            CHECK(r.cooled);
            CHECK((p.lines == std::vector<std::string>{ "G1 X1", "M104 S0", "M140 S0", "M107" }));
        }
        // The command in flight never answers: nothing goes after it.
        {
            StubPrinter p;
            std::atomic<bool> halt{ false };
            p.answer = [&halt](std::string const &, size_t n) {
                if (n == 2)
                {
                    halt.store(true);
                    return std::string();
                }
                return std::string("ok\n");
            };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\nG1 X3\n", halt, nullptr, usb::Timing{ 1, 60, 60 });
            CHECK(r.cancelled);
            CHECK(!r.cooled);
            CHECK(r.message == "The printer did not answer.");
            CHECK(p.lines.size() == 2);
        }
        // The command in flight ends with an error of the printer.
        {
            StubPrinter p;
            std::atomic<bool> halt{ false };
            p.answer = [&halt](std::string const &, size_t) {
                halt.store(true);
                return std::string("Error:Printer halted\n");
            };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\n", halt, nullptr, fast);
            CHECK(r.cancelled);
            CHECK(!r.cooled);
            CHECK(r.message.find("The printer said: ") == 0);
            CHECK(p.lines.size() == 1);
        }
        // A cooling command with no "ok" ends the stop, and it is no success.
        {
            StubPrinter p;
            std::atomic<bool> halt{ false };
            p.answer = [&halt](std::string const &text, size_t) {
                halt.store(true);
                return text == "M140 S0" ? std::string() : std::string("ok\n");
            };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\n", halt, nullptr, usb::Timing{ 1, 300, 60 });
            CHECK(r.cancelled);
            CHECK(!r.cooled);
            CHECK(r.message == "The printer did not answer.");
            CHECK((p.lines == std::vector<std::string>{ "G1 X1", "M104 S0", "M140 S0" }));
        }
        // The port goes away during the cooling commands.
        {
            StubPrinter p;
            std::atomic<bool> halt{ false };
            p.on_line = [&p, &halt](size_t n) {
                halt.store(true);
                if (n == 2)
                    p.dead = true;
            };
            usb::Result r = usb::Stream(p, "G1 X1\nG1 X2\n", halt, nullptr, fast);
            CHECK(r.cancelled);
            CHECK(!r.cooled);
            CHECK(r.message == "The port stopped.");
        }
        // A stop during the wait for the board sends nothing at all.
        {
            StubPrinter p;
            std::atomic<bool> halt{ true };
            usb::Result r = usb::Stream(p, "G28\n", halt, nullptr, usb::Timing{ 5000, 300, 300 });
            CHECK(r.cancelled);
            CHECK(!r.sent);
            CHECK(!r.cooled);
            CHECK(p.lines.empty());
            CHECK(p.flushes == 0);
        }
        // Text with no command sends nothing.
        {
            StubPrinter p;
            CHECK(usb::Stream(p, "; only\n\n  ; comments\n", stop, nullptr, fast).ok);
            CHECK(p.lines.empty());
        }
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
                    [&](std::shared_ptr<CameraPicture const> const &) {
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

    // The filament settings of each roll in the printer.
    void TestRolls()
    {
        Model model([](Event const &) {});
        CHECK(model.Start() == ZS_OK);
        PrinterSetup setup(model);
        setup.Start();
        std::string const original = Printers().Current().id;
        std::string message, note, printer, other;
        NewPrinter added;
        added.name = "Roll printer";
        added.model = zs_printers_find(model.Printers(), "creality-ender-3-v2");
        added.nozzle = 0.4;
        added.bed_x = 220;
        added.bed_y = 220;
        added.height = 250;
        CHECK(setup.AddNewPrinter(added, false, other, message));
        added.name = "Roll printer two";
        CHECK(setup.AddNewPrinter(added, false, printer, message));
        auto temp = [&model] { return atoi(model.GetSetting("filament.nozzle_temp").c_str()); };
        auto set_temp = [&model](char const *value) { CHECK(zs_app_setting_set(model.Active(), "filament.nozzle_temp", value) == ZS_OK); };
        auto key = [&printer](RollFacts const &r) { return PrinterSetup::RollKey(printer, r.id); };

        CHECK(PrinterSetup::RollKey("a b", "c/d..") == "a-b-c-d--");
        CHECK(setup.UseMaterial("PLA", message));
        set_temp("211");
        RollFacts one{ "r1", "Roll one", "PLA", "#ff0000", 1.75 };
        RollFacts two{ "r2", "Roll two", "PLA", "#00ff00", 1.75 };
        RollFacts three{ "r3", "Roll three", "PETG", "#0000ff", 0 };

        // The preference off: the settings stay.
        CHECK(!setup.FollowRoll(printer, one, false, note));
        CHECK(setup.Roll().empty());
        // A roll with no id: the settings stay.
        CHECK(!setup.FollowRoll(printer, RollFacts{ "", "No id", "PETG", "", 0 }, true, note));
        CHECK(setup.Roll().empty());
        // The first roll: the settings now become its settings.
        CHECK(!setup.FollowRoll(printer, one, true, note));
        CHECK(setup.Roll() == key(one));
        CHECK(temp() == 211);
        CHECK(note.empty());
        // The same roll again changes nothing.
        set_temp("212");
        CHECK(!setup.FollowRoll(printer, one, true, note));
        CHECK(temp() == 212);
        setup.SaveState();
        // A new roll of the material: the tuning stays, with its name and color.
        CHECK(setup.FollowRoll(printer, two, true, note));
        CHECK(setup.Roll() == key(two));
        CHECK(temp() == 212);
        CHECK(model.GetSetting("filament.name") == "Roll two");
        CHECK(Has(model.GetSetting("filament.color"), "00ff00"));
        CHECK(Has(note, "Roll two"));
        set_temp("222");
        setup.SaveState();
        // A known roll gets its own settings back.
        CHECK(setup.FollowRoll(printer, one, true, note));
        CHECK(temp() == 212);
        CHECK(setup.FollowRoll(printer, two, true, note));
        CHECK(temp() == 222);
        CHECK(model.GetSetting("filament.name") == "Roll two");
        // Another material starts from its built-in profile. The diameter stays.
        CHECK(zs_app_setting_set(model.Active(), "filament.diameter", "2.85") == ZS_OK);
        setup.SaveState();
        CHECK(setup.FollowRoll(printer, three, true, note));
        CHECK(model.GetSetting("filament.material") == "PETG");
        CHECK(model.GetSetting("filament.name") == "Roll three");
        CHECK(temp() != 222);
        CHECK(atof(model.GetSetting("filament.diameter").c_str()) == 2.85);
        CHECK(zs_app_setting_set(model.Active(), "filament.diameter", "1.75") == ZS_OK);
        setup.SaveState();

        // The text of a printer cannot add a line to a profile.
        set_temp("233");
        RollFacts bad{ "r4", "Bad\nG28", "PLA\"\nnozzle_temp = 123\nx = \"", "", 0 };
        CHECK(setup.FollowRoll(printer, bad, true, note));
        CHECK(temp() == 233);
        CHECK(!Has(model.GetSetting("filament.material"), "123"));
        CHECK(!Has(model.GetSetting("filament.name"), "\n"));
        CHECK(!Has(note, "\n"));

        // A project: its settings go to no roll, and no roll loads over them.
        CHECK(setup.FollowRoll(printer, two, true, note));
        setup.SetProjectPlates(true);
        setup.ForgetRoll();
        set_temp("199");
        setup.SaveState();
        CHECK(!setup.FollowRoll(printer, one, true, note));
        CHECK(temp() == 199);
        setup.EndProject();
        CHECK(setup.Roll().empty());
        setup.SaveState();
        CHECK(setup.FollowRoll(printer, one, true, note));
        CHECK(temp() == 212);
        CHECK(setup.FollowRoll(printer, two, true, note));
        CHECK(temp() == 222);

        // A material that the user picks ends the roll, and the same roll
        // in the printer does not take the settings back.
        CHECK(setup.UseMaterial("PLA", message));
        CHECK(setup.Roll().empty());
        set_temp("205");
        CHECK(!setup.FollowRoll(printer, two, true, note));
        CHECK(setup.Roll().empty());
        CHECK(temp() == 205);
        // A pick of a roll in the menu.
        setup.UseRoll(printer, one);
        CHECK(setup.Roll() == key(one));
        CHECK(temp() == 212);
        // A pick of a roll with no file: its name and color.
        RollFacts fresh{ "r5", "Roll five", "PLA", "#112233", 0 };
        setup.UseRoll(printer, fresh);
        CHECK(setup.Roll() == key(fresh));
        CHECK(temp() == 212);
        CHECK(model.GetSetting("filament.name") == "Roll five");

        // Another printer ends the roll. Back on this printer, its roll wins.
        CHECK(setup.UsePrinter(other, message));
        CHECK(setup.Roll().empty());
        CHECK(setup.UsePrinter(printer, message));
        CHECK(setup.Roll().empty());
        CHECK(setup.FollowRoll(printer, two, true, note));
        CHECK(setup.Roll() == key(two));
        CHECK(temp() == 222);
        CHECK(note.empty());

        // The settings of a roll stay after a restart.
        setup.SaveState();
        {
            Model again([](Event const &) {});
            CHECK(again.Start() == ZS_OK);
            PrinterSetup next(again);
            next.Start();
            CHECK(next.Roll().empty());
            CHECK(next.FollowRoll(printer, one, true, note));
            CHECK(atoi(again.GetSetting("filament.nozzle_temp").c_str()) == 212);
        }
        CHECK(setup.UsePrinter(original, message));
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

        // A plate of a project: the machine profile of the printer stays.
        std::string profile_before, profile_now;
        CHECK(state::ReadBytes(PrinterStore::ProfilePath(*Printers().Find(id_b)), profile_before));
        setup.SetProjectPlates(true);
        CHECK(zs_app_setting_set(model.Active(), "machine.bed_size_x", "123") == ZS_OK);
        setup.SaveState();
        CHECK(state::ReadBytes(PrinterStore::ProfilePath(*Printers().Find(id_b)), profile_now) && profile_now == profile_before);
        // A switch of the printer writes no machine for the printer before.
        CHECK(setup.UsePrinter(id_a, message));
        CHECK(!setup.ProjectPlates());
        CHECK(state::ReadBytes(PrinterStore::ProfilePath(*Printers().Find(id_b)), profile_now) && profile_now == profile_before);
        CHECK(atof(model.GetSetting("machine.bed_size_x").c_str()) == 200);
        CHECK(setup.UsePrinter(id_b, message));
        // The end of project mode puts the machine of the printer back.
        setup.SetProjectPlates(true);
        CHECK(zs_app_setting_set(model.Active(), "machine.bed_size_x", "123") == ZS_OK);
        setup.EndProject();
        CHECK(!setup.ProjectPlates());
        CHECK(atof(model.GetSetting("machine.bed_size_x").c_str()) == 300);
        // With another plate of the project, a pick keeps the guard: a
        // switch to that plate writes its machine to no printer.
        CHECK(model.AddPlate());
        setup.SetProjectPlates(true);
        CHECK(zs_app_setting_set(zs_set_app(model.Set(), 0), "machine.bed_size_x", "123") == ZS_OK);
        std::string profile_a;
        CHECK(state::ReadBytes(PrinterStore::ProfilePath(*Printers().Find(id_a)), profile_a));
        CHECK(setup.UsePrinter(id_a, message));
        CHECK(setup.ProjectPlates());
        CHECK(atof(model.GetSetting("machine.bed_size_x").c_str()) == 200);
        CHECK(model.SelectPlate(0));
        setup.SaveState();
        CHECK(state::ReadBytes(PrinterStore::ProfilePath(*Printers().Find(id_a)), profile_now) && profile_now == profile_a);
        setup.EndProject();
        CHECK(model.RemovePlate(1));
        CHECK(setup.UsePrinter(id_b, message));
        CHECK(atof(model.GetSetting("machine.bed_size_x").c_str()) == 300);

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
        std::string spools = R"({"filaments":[{"slot":"A1","tray":0,"nozzle":"main","material":"PLA","color":"#ff0000"},{"slot":"A2","tray":1,"nozzle":"main","material":"PETG","color":"#00ff00"}]})";
        CHECK(setup.FilamentsFromPrinter("X1", spools, 1, message));
        CHECK(Has(message, "X1"));
        CHECK(zs_app_filament_count(model.Active()) == 2);
        char color[16] = "";
        CHECK(zs_app_filament_get(model.Active(), 1, "filament.color", color, sizeof color, nullptr) == ZS_OK);
        CHECK(Has(color, "00ff00"));
        // The same spools change nothing.
        CHECK(!setup.FilamentsFromPrinter("X1", spools, 1, message));
        // The automatic follow changes a printer that pauses for a filament
        // not at all.
        std::string other = R"({"filaments":[{"slot":"A1","tray":0,"nozzle":"main","material":"PLA","color":"#0000ff"}]})";
        CHECK(!setup.FilamentsFromPrinter("X1", other, 2, message));
        CHECK(zs_app_filament_count(model.Active()) == 2);

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

    // The rules of a project source. No check here goes to the network.
    void TestProjectSource()
    {
        using namespace zs::project;
        GithubRepo repo;
        CHECK(ParseGithub("owner/repo", repo) && repo.owner == "owner" && repo.repo == "repo" && repo.ref.empty());
        CHECK(ParseGithub(" https://github.com/Owner/my.repo.git ", repo) && repo.owner == "Owner" && repo.repo == "my.repo");
        CHECK(ParseGithub("github.com/a/b/tree/feature/x", repo) && repo.repo == "b" && repo.ref == "feature/x");
        CHECK(ParseGithub("https://www.github.com/a/b/", repo) && repo.owner == "a" && repo.ref.empty());
        char const *const bad_repos[] = {
            "http://github.com/a/b", "https://evil.test/a/b", "https://github.com.evil.test/a/b", "https://user@github.com/a/b",
            "https://github.com:8443/a/b", "file:///C:/a/b", "a", "a/b/c", "../b", "a/..", "a/b/tree/x..y", "a/b/tree/", "a/b?x=1", "a/b#c",
            "a b/c", "a%2Fb/c", "a\\b/c", "",
        };
        for (auto const *text : bad_repos)
            CHECK(!ParseGithub(text, repo));

        char const *const good_urls[] = {
            "https://api.github.com/repos/a/b", "https://raw.githubusercontent.com/a/b/c/d.stl", "https://media.githubusercontent.com/media/a/b/c/d.stl",
            "https://github.com/a/b", "https://API.GitHub.com:443/repos/a/b",
        };
        for (auto const *url : good_urls)
            CHECK(IsAllowedUrl(url));
        char const *const bad_urls[] = {
            "http://api.github.com/repos/a/b", "https://evil.test/a", "https://api.github.com.evil.test/a", "https://api.github.com@evil.test/a",
            "https://user:pw@api.github.com/a", "https://api.github.com:8443/a", "https://objects.githubusercontent.com/a", "https://127.0.0.1/a",
            "https://raw.githubusercontent.com\\@evil.test/a", "ftp://github.com/a", "https://",
        };
        for (auto const *url : bad_urls)
            CHECK(!IsAllowedUrl(url));
        CHECK(IsCommit(std::string(40, 'a')));
        CHECK(!IsCommit(std::string(40, 'g')));
        CHECK(!IsCommit("main"));

        // A folder: the list has its files, with no .git and no junction.
        std::wstring root = state::PathOf(L"project-test"), outside = state::PathOf(L"project-outside");
        CHECK(state::WriteBytes(root + L"\\printdeck.yml", "project: x\n"));
        CHECK(state::WriteBytes(root + L"\\models\\a b.stl", "solid"));
        CHECK(state::WriteBytes(root + L"\\.git\\config", "no"));
        CHECK(state::WriteBytes(outside + L"\\secret.txt", "secret"));
        std::wstring link = L"mklink /J \"" + root + L"\\link\" \"" + outside + L"\" >nul";
        CHECK(_wsystem(link.c_str()) == 0);
        // A sparse file over the limit: it uses no space on the disk.
        HANDLE big = ::CreateFileW((root + L"\\big.stl").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        CHECK(big != INVALID_HANDLE_VALUE);
        DWORD returned = 0;
        ::DeviceIoControl(big, FSCTL_SET_SPARSE, nullptr, 0, nullptr, 0, &returned, nullptr);
        LARGE_INTEGER big_size{};
        big_size.QuadPart = (LONGLONG)max_file + 1;
        CHECK(::SetFilePointerEx(big, big_size, nullptr, FILE_BEGIN) != 0 && ::SetEndOfFile(big) != 0);
        ::CloseHandle(big);
        std::string error, bytes;
        auto source = OpenFolder(root + L"\\", nullptr, error);
        CHECK(source != nullptr);
        if (source != nullptr)
        {
            CHECK(source->Has("printdeck.yml"));
            CHECK(source->Has("models/a b.stl"));
            CHECK(!source->Has(".git/config"));
            CHECK(!source->Has("link/secret.txt"));
            CHECK(source->List("models").size() == 1);
            CHECK(source->Read("models/a b.stl", bytes, error, nullptr) && bytes == "solid");
            CHECK(!source->Read("link/secret.txt", bytes, error, nullptr));
            CHECK(!source->Read("../project-outside/secret.txt", bytes, error, nullptr));
            error.clear();
            CHECK(source->Has("big.stl") && !source->Read("big.stl", bytes, error, nullptr));
            CHECK(Has(error, "larger than 256 MB"));
        }
        ::RemoveDirectoryW((root + L"\\link").c_str());
        CHECK(OpenFolder(root + L"\\none", nullptr, error) == nullptr);
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

int main(int argc, char **argv)
{
    WSADATA wsa{};
    ::WSAStartup(MAKEWORD(2, 2), &wsa);
    if (argc == 3 && strcmp(argv[1], "--rtsp-stub") == 0)
        return RunRtspStub(argv[2]);
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
        { "status", TestStatus }, { "key flow", TestKeyFlow }, { "deck", TestDeck }, { "upload", TestUpload }, { "print", TestPrintNet }, { "estimate", TestEstimate },
        { "detect", TestDetect }, { "filaments", TestFilaments }, { "mjpeg", TestMjpeg }, { "camera", TestCamera },
        { "discovery", TestDiscovery }, { "bambu", TestBambu }, { "setup", TestSetup }, { "rolls", TestRolls },
        { "usb", TestUsb }, { "h264", TestH264 }, { "rtsp", TestRtsp }, { "open link", TestOpenLink }, { "project", TestProjectSource }, { "file types", TestRegisterApp }, { "hand off", TestHandOff }, { "state move", TestStateMove },
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
