#pragma once
// The search of the network for printers.
//
// The core builds and reads the packets (zs_discovery_*). This file moves
// them: it sends the mDNS query to 224.0.0.251 port 5353, listens there and
// on port 2021 (the SSDP packets of Bambu Lab), and asks each new printer for
// /api/version or its Klipper toolhead. It follows
// linux/src/net/discovery.c. See docs/references/formats-and-protocols.md.
//
// The search goes on the real network only in a normal run. A run with
// ZSLICE_STATE_DIR is a test: it sends nothing unless ZSLICE_DISCOVERY says
// so. ZSLICE_DISCOVERY is "off", "network", or "127.0.0.1:<port>" (a stub
// that answers on the loopback address).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "zs_http.h"

struct zs_discovery;

namespace zs
{
    struct FoundPrinter
    {
        std::string name, kind_title, host, address, url, model, version, serial;
        int kind = 0; // enum zs_found_kind
        int port = 0;
        double bed_x = 0, bed_y = 0, height = 0;
    };

    enum class SearchMode
    {
        Off,
        Network,
        Loopback,
    };
    // The mode of this run, from the environment. For Loopback, `port` is
    // the port of the stub.
    SearchMode SearchModeOfRun(int &port);

    class PrinterSearch
    {
    public:
        // `changed` runs on a worker thread, with the list and whether the
        // search still runs.
        using Changed = std::function<void(std::vector<FoundPrinter> const &, bool running)>;

        PrinterSearch(SearchMode mode, int loopback_port, Changed changed);
        ~PrinterSearch();
        PrinterSearch(PrinterSearch const &) = delete;
        PrinterSearch &operator=(PrinterSearch const &) = delete;

        // Searches again. The printers found so far stay.
        void Restart();

    private:
        void Run();
        void Publish(bool running);
        void Ask(size_t index);

        struct Reply
        {
            size_t index;
            int what;
            std::string body;
        };

        SearchMode mode_;
        int port_;
        Changed changed_;
        zs_discovery *core_ = nullptr;
        std::thread worker_;
        std::atomic<bool> stop_{ false };
        http::CancelPtr cancel_;
        std::mutex replies_lock_;
        std::vector<Reply> replies_;
        std::vector<std::thread> askers_;
        size_t asked_ = 0;
    };
}
