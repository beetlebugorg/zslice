// See zs_discovery_net.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_discovery_net.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <chrono>
#include <cstdlib>
#include <cstring>

#include "zslice.h"
#include "zslice-app.h"

namespace zs
{
    namespace
    {
        constexpr int search_ms = 6000;
        char const mdns_group[] = "224.0.0.251";

        void StartWinsock()
        {
            static bool started = [] {
                WSADATA data{};
                return ::WSAStartup(MAKEWORD(2, 2), &data) == 0;
            }();
            (void)started;
        }

        struct Socket
        {
            SOCKET s = INVALID_SOCKET;
            ~Socket()
            {
                if (s != INVALID_SOCKET)
                    ::closesocket(s);
            }
        };

        // port 0: a port of our own. group: port 5353 in the mDNS group. A
        // fixed port is shared with other programs.
        bool OpenUdp(Socket &out, uint32_t address, uint16_t port, bool group)
        {
            SOCKET s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
            if (s == INVALID_SOCKET)
                return false;
            BOOL on = TRUE;
            if (port != 0)
            {
                ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<char const *>(&on), sizeof on);
                ::setsockopt(s, SOL_SOCKET, SO_BROADCAST, reinterpret_cast<char const *>(&on), sizeof on);
            }
            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(address);
            addr.sin_port = htons(port);
            bool ok = ::bind(s, reinterpret_cast<sockaddr *>(&addr), sizeof addr) == 0;
            if (ok && group)
            {
                ip_mreq join{};
                ::inet_pton(AF_INET, mdns_group, &join.imr_multiaddr);
                join.imr_interface.s_addr = htonl(INADDR_ANY);
                ok = ::setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, reinterpret_cast<char const *>(&join), sizeof join) == 0;
            }
            u_long nonblocking = 1;
            ok = ok && ::ioctlsocket(s, FIONBIO, &nonblocking) == 0;
            if (!ok)
            {
                ::closesocket(s);
                return false;
            }
            out.s = s;
            return true;
        }

        std::string Text(char const *t)
        {
            return t != nullptr ? t : "";
        }

        bool IsLoopback(std::string const &address)
        {
            return address.rfind("127.", 0) == 0;
        }
    }

    SearchMode SearchModeOfRun(int &port)
    {
        port = 0;
        char value[64];
        DWORD n = ::GetEnvironmentVariableA("ZSLICE_DISCOVERY", value, sizeof value);
        std::string mode = n > 0 && n < sizeof value ? std::string(value, n) : std::string{};
        if (mode == "off")
            return SearchMode::Off;
        if (mode == "network")
            return SearchMode::Network;
        if (mode.rfind("127.0.0.1:", 0) == 0)
        {
            int p = atoi(mode.c_str() + 10);
            if (p > 0 && p < 65536)
            {
                port = p;
                return SearchMode::Loopback;
            }
            return SearchMode::Off;
        }
        // A run with its own state folder is a test: it stays off the
        // network unless it asks for it.
        char state[8];
        return ::GetEnvironmentVariableA("ZSLICE_STATE_DIR", state, sizeof state) > 0 ? SearchMode::Off : SearchMode::Network;
    }

    PrinterSearch::PrinterSearch(SearchMode mode, int loopback_port, Changed changed)
        : mode_(mode), port_(loopback_port), changed_(std::move(changed))
    {
        StartWinsock();
        zs_discovery_new(&core_);
        Restart();
    }

    PrinterSearch::~PrinterSearch()
    {
        stop_.store(true);
        if (cancel_ != nullptr)
            cancel_->Stop();
        if (worker_.joinable())
            worker_.join();
        for (auto &t : askers_)
            if (t.joinable())
                t.join();
        if (core_ != nullptr)
            zs_discovery_free(core_);
    }

    void PrinterSearch::Restart()
    {
        stop_.store(true);
        if (cancel_ != nullptr)
            cancel_->Stop();
        if (worker_.joinable())
            worker_.join();
        for (auto &t : askers_)
            if (t.joinable())
                t.join();
        askers_.clear();
        replies_.clear();
        stop_.store(false);
        cancel_ = std::make_shared<http::Cancel>();
        worker_ = std::thread([this] { Run(); });
    }

    void PrinterSearch::Publish(bool running)
    {
        std::vector<FoundPrinter> list;
        size_t n = core_ != nullptr ? zs_discovery_count(core_) : 0;
        for (size_t i = 0; i < n; i++)
        {
            zs_found_printer f{};
            if (zs_discovery_get(core_, i, &f) != ZS_OK)
                continue;
            FoundPrinter p;
            p.name = Text(f.name);
            p.kind = f.kind;
            p.kind_title = Text(f.kind_title);
            p.host = Text(f.host);
            p.address = Text(f.address);
            p.port = f.port;
            p.url = Text(f.url);
            p.model = Text(f.model);
            p.version = Text(f.version);
            p.serial = Text(f.serial);
            p.bed_x = f.bed_x;
            p.bed_y = f.bed_y;
            p.height = f.height;
            list.push_back(std::move(p));
        }
        if (changed_)
            changed_(list, running);
    }

    // The kind and the bed of a new printer, with no key.
    void PrinterSearch::Ask(size_t index)
    {
        zs_found_printer f{};
        if (zs_discovery_get(core_, index, &f) != ZS_OK || f.kind == ZS_FOUND_BAMBU)
            return;
        // A loopback search reaches nothing outside this computer.
        if (mode_ == SearchMode::Loopback && !IsLoopback(Text(f.address)))
            return;
        bool klipper = f.kind == ZS_FOUND_MOONRAKER;
        std::string url = Text(f.url) + (klipper ? "/printer/objects/query?toolhead" : "/api/version");
        int what = klipper ? ZS_FOUND_REPLY_TOOLHEAD : ZS_FOUND_REPLY_VERSION;
        auto cancel = cancel_;
        askers_.emplace_back([this, url, index, what, cancel] {
            http::Request req;
            req.url = url;
            req.timeout_ms = 4000;
            req.cancel = cancel;
            http::Response r = http::Send(req);
            if (r.status != 200)
                return;
            std::lock_guard guard(replies_lock_);
            replies_.push_back(Reply{ index, what, std::move(r.body) });
        });
    }

    void PrinterSearch::Run()
    {
        if (mode_ == SearchMode::Off || core_ == nullptr)
        {
            Publish(false);
            return;
        }
        Socket own, group, bambu;
        sockaddr_in target{};
        target.sin_family = AF_INET;
        bool opened;
        if (mode_ == SearchMode::Loopback)
        {
            opened = OpenUdp(own, INADDR_LOOPBACK, 0, false);
            target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            target.sin_port = htons((u_short)port_);
        }
        else
        {
            opened = OpenUdp(own, INADDR_ANY, 0, false);
            // These two are optional: the unicast answers come to `own`.
            OpenUdp(group, INADDR_ANY, 5353, true);
            OpenUdp(bambu, INADDR_ANY, ZS_DISCOVERY_BAMBU_PORT, false);
            ::inet_pton(AF_INET, mdns_group, &target.sin_addr);
            target.sin_port = htons(5353);
        }
        if (!opened)
        {
            Publish(false);
            return;
        }
        auto send_query = [&] {
            uint8_t const *q = nullptr;
            size_t len = 0;
            if (zs_discovery_query(core_, &q, &len) != ZS_OK)
                return;
            for (SOCKET s : { own.s, group.s })
                if (s != INVALID_SOCKET)
                    ::sendto(s, reinterpret_cast<char const *>(q), (int)len, 0, reinterpret_cast<sockaddr *>(&target), sizeof target);
        };
        Publish(true);
        send_query();
        auto t0 = std::chrono::steady_clock::now();
        auto ms = [&] { return (int)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count(); };
        bool sent_1s = false, sent_3s = false;
        int follow_at = -1;
        char buffer[9000];
        while (!stop_.load() && ms() < search_ms)
        {
            fd_set read{};
            FD_ZERO(&read);
            for (SOCKET s : { own.s, group.s, bambu.s })
                if (s != INVALID_SOCKET)
                    FD_SET(s, &read);
            timeval wait{ 0, 50000 };
            int ready = ::select(0, &read, nullptr, nullptr, &wait);
            bool changed = false;
            if (ready > 0)
            {
                for (SOCKET s : { own.s, group.s, bambu.s })
                {
                    if (s == INVALID_SOCKET || !FD_ISSET(s, &read))
                        continue;
                    for (;;)
                    {
                        int n = ::recv(s, buffer, sizeof buffer, 0);
                        if (n <= 0)
                            break;
                        if (zs_discovery_feed(core_, reinterpret_cast<uint8_t const *>(buffer), (size_t)n) == 1)
                            changed = true;
                    }
                }
            }
            if (changed)
            {
                size_t count = zs_discovery_count(core_);
                for (; asked_ < count; asked_++)
                    Ask(asked_);
                // The next questions (SRV, TXT, A), after the other answers
                // of this round.
                if (follow_at < 0)
                    follow_at = ms() + 150;
            }
            std::vector<Reply> replies;
            {
                std::lock_guard guard(replies_lock_);
                replies.swap(replies_);
            }
            for (auto const &r : replies)
                if (zs_discovery_reply(core_, r.index, r.what, r.body.data(), r.body.size()) == 1)
                    changed = true;
            if (changed)
                Publish(true);
            if (follow_at >= 0 && ms() >= follow_at)
            {
                follow_at = -1;
                send_query();
            }
            if (!sent_1s && ms() >= 1000)
            {
                sent_1s = true;
                send_query();
            }
            if (!sent_3s && ms() >= 3000)
            {
                sent_3s = true;
                send_query();
            }
        }
        if (!stop_.load())
            Publish(false);
    }
}
