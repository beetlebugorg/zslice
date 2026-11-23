#pragma once
// A Bambu Lab printer in LAN mode: its status over MQTT, read only.
//
// A thread of its own runs the MQTT client over TLS (port 8883, the user
// "bblp", the access code as the password). The core makes the packets and
// reads them (zs_mqtt_*). This file moves the bytes. It sends CONNECT,
// SUBSCRIBE, PINGREQ, and DISCONNECT. IT SENDS NO PUBLISH, so it cannot start
// a print or change anything on the printer. It follows
// linux/src/net/bambu-link.c. See docs/references/bambu-studio.md.
//
// ZSLICE_BAMBU_MQTT_PORT and ZSLICE_BAMBU_JPEG_PORT move the ports, for a
// stub server in a test.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

#include "zs_printer_link.h"

namespace zs
{
    // The port, or the one in ZSLICE_BAMBU_<name>_PORT.
    int BambuPort(char const *name, int port);
    // The host of an address that can have a scheme or a port.
    std::string BambuHost(std::string const &address);
    // The wait before the next connection, after `failures` refused or
    // dropped connections in a row: 15 s, then twice as long each time, to
    // 5 minutes. A printer in LAN mode takes few clients.
    int BambuRetrySeconds(int failures);

    class BambuWatch
    {
    public:
        // `report` and `error` run on the thread of the watch, at most once
        // a second. `trusted` gets the hash of the first certificate.
        using Report = std::function<void(link::Snapshot const &)>;
        using Error = std::function<void(std::string const &)>;
        using Trusted = std::function<void(std::string const &)>;

        BambuWatch(link::Target const &target, std::string serial, Report report, Error error, Trusted trusted);
        ~BambuWatch();
        BambuWatch(BambuWatch const &) = delete;
        BambuWatch &operator=(BambuWatch const &) = delete;

    private:
        void Run();
        bool Session();

        std::string host_, serial_, code_, pin_;
        Report report_;
        Error error_;
        Trusted trusted_;
        std::atomic<bool> stop_{ false };
        // The session told a status of the printer.
        bool reached_ = false;
        std::thread thread_;
    };

    // Connects once, and reads the serial number from the certificate of
    // the printer. It sends nothing. `pin` gets the hash to trust.
    bool ReadBambuSerial(std::string const &address, std::string &serial, std::string &pin, std::string &error);
}
