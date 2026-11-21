// See zs_bambu.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_bambu.h"

#include "zs_tls.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>

namespace zs
{
    namespace
    {
        constexpr int keepalive_s = 60;
        constexpr int ping_s = 30;
        constexpr int retry_s = 15;

        std::string ConnackText(int code)
        {
            return code == 4 || code == 5
                       ? "The printer refused the access code. Check the code on the screen of the printer (Settings > LAN Only Mode)."
                       : "The printer refused the connection.";
        }

        bool WritePacket(TlsClient &tls, uint8_t *packet, size_t len)
        {
            bool ok = tls.Write(packet, len);
            zs_buffer_free(packet, len);
            return ok;
        }
    }

    int BambuPort(char const *name, int port)
    {
        std::string var = std::string("ZSLICE_BAMBU_") + name + "_PORT";
        char value[16];
        DWORD n = ::GetEnvironmentVariableA(var.c_str(), value, sizeof value);
        int p = n > 0 && n < sizeof value ? atoi(value) : 0;
        return p > 0 && p < 65536 ? p : port;
    }

    std::string BambuHost(std::string const &address)
    {
        std::string a = address;
        size_t s = a.find("://");
        if (s != std::string::npos)
            a = a.substr(s + 3);
        return a.substr(0, a.find_first_of("/:"));
    }

    BambuWatch::BambuWatch(link::Target const &target, std::string serial, Report report, Error error, Trusted trusted)
        : host_(BambuHost(target.url)), serial_(std::move(serial)), code_(target.api_key), pin_(target.tls_pin),
          report_(std::move(report)), error_(std::move(error)), trusted_(std::move(trusted))
    {
        thread_ = std::thread([this] { Run(); });
    }

    BambuWatch::~BambuWatch()
    {
        stop_.store(true);
        if (thread_.joinable())
            thread_.join();
        ::SecureZeroMemory(code_.data(), code_.size());
    }

    void BambuWatch::Run()
    {
        while (!stop_.load())
        {
            // False: a wrong code stays wrong, so it does not try again.
            if (!Session())
                return;
            for (int i = 0; i < retry_s * 10 && !stop_.load(); i++)
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }

    bool BambuWatch::Session()
    {
        TlsClient tls;
        std::string seen, common_name, why;
        if (!tls.Connect(host_, BambuPort("MQTT", 8883), pin_, seen, common_name, &stop_, why))
        {
            if (!stop_.load())
                error_("The printer did not answer (" + why + "). Check that it is on, in LAN mode, and at this address.");
            return true;
        }
        if (pin_.empty() && !seen.empty())
        {
            // The first connection: the next ones need this certificate.
            pin_ = seen;
            if (trusted_)
                trusted_(seen);
        }
        std::unique_ptr<zs_mqtt_reader, decltype(&zs_mqtt_reader_free)> reader(zs_mqtt_reader_new(), zs_mqtt_reader_free);
        std::unique_ptr<zs_printer_status, decltype(&zs_printer_status_free)> status(zs_printer_status_new(), zs_printer_status_free);
        uint32_t random = 0;
        ::BCryptGenRandom(nullptr, reinterpret_cast<PUCHAR>(&random), sizeof random, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        char id[32];
        snprintf(id, sizeof id, "zslice-%08x", random);
        uint8_t *packet = nullptr;
        size_t len = 0;
        if (zs_mqtt_connect_packet(id, "bblp", code_.c_str(), keepalive_s, &packet, &len) != ZS_OK || !WritePacket(tls, packet, len))
        {
            if (!stop_.load())
                error_("The printer did not answer the login.");
            return true;
        }
        bool subscribed = false, dirty = false, shown = false;
        auto last_ping = std::chrono::steady_clock::now();
        auto last_show = std::chrono::steady_clock::time_point{};
        auto started = std::chrono::steady_clock::now();
        char buffer[16384];
        while (!stop_.load())
        {
            zs_mqtt_packet pk{};
            int got;
            while ((got = zs_mqtt_reader_next(reader.get(), &pk)) == 1)
            {
                if (pk.kind == 2)
                {
                    if (pk.return_code != 0)
                    {
                        error_(ConnackText(pk.return_code));
                        return false;
                    }
                    std::string topic = "device/" + serial_ + "/report";
                    if (zs_mqtt_subscribe_packet(topic.c_str(), 1, &packet, &len) != ZS_OK || !WritePacket(tls, packet, len))
                    {
                        error_("The printer did not take the subscription.");
                        return true;
                    }
                    subscribed = true;
                }
                else if (pk.kind == 3 && pk.payload != nullptr)
                {
                    zs_printer_status_feed(status.get(), 4, "report", reinterpret_cast<char const *>(pk.payload), pk.payload_len);
                    dirty = true;
                }
            }
            if (got < 0)
            {
                error_("The printer did not answer as an MQTT broker.");
                return true;
            }
            auto now = std::chrono::steady_clock::now();
            // At most one report each second. The first shows at once.
            if (dirty && (!shown || now - last_show >= std::chrono::seconds(1)))
            {
                dirty = false;
                shown = true;
                last_show = now;
                report_(link::SnapshotOf(status.get()));
            }
            if (subscribed && now - last_ping > std::chrono::seconds(ping_s))
            {
                static uint8_t const ping[2] = { 0xC0, 0 };
                if (!tls.Write(ping, 2))
                {
                    error_("The printer closed the connection.");
                    return true;
                }
                last_ping = now;
            }
            if (!subscribed && now - started > std::chrono::seconds(15))
            {
                error_("The printer did not answer the login.");
                return true;
            }
            int n = tls.Read(buffer, sizeof buffer, 250);
            if (n < 0)
            {
                if (!stop_.load())
                    error_("The printer closed the connection.");
                return true;
            }
            if (n > 0 && zs_mqtt_reader_feed(reader.get(), reinterpret_cast<uint8_t const *>(buffer), (size_t)n) != ZS_OK)
            {
                error_("The printer did not answer as an MQTT broker.");
                return true;
            }
        }
        static uint8_t const bye[2] = { 0xE0, 0 };
        tls.Write(bye, 2);
        return false;
    }

    bool ReadBambuSerial(std::string const &address, std::string &serial, std::string &pin, std::string &error)
    {
        TlsClient tls;
        std::string common_name;
        // No pin: the user reads the serial number to trust this printer.
        if (!tls.Connect(BambuHost(address), BambuPort("MQTT", 8883), {}, pin, common_name, nullptr, error))
            return false;
        tls.Close();
        // The serial number goes in an MQTT topic and a file name.
        bool ok = !common_name.empty() && common_name.size() <= 64;
        for (unsigned char c : common_name)
            ok = ok && ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'));
        if (!ok)
        {
            error = "The certificate of the printer has no serial number.";
            return false;
        }
        serial = common_name;
        return true;
    }
}
