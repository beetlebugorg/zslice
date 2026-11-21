#pragma once
// A TLS client over a TCP socket, with Schannel, for a printer with a
// certificate of its own.
//
// A Bambu Lab printer signs its own certificate, so no authority can vouch
// for it. The client turns the chain check off and pins the certificate: the
// hash of the first one that it sees (trust on first use), and after that
// only that hash. On another certificate it closes the connection before it
// sends anything, so a device that claims the address gets no access code.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <atomic>
#include <memory>
#include <string>

namespace zs
{
    class TlsClient
    {
    public:
        TlsClient();
        ~TlsClient();
        TlsClient(TlsClient const &) = delete;
        TlsClient &operator=(TlsClient const &) = delete;

        // Connects and checks `pin` (hex SHA-256, empty: trust any). `seen`
        // gets the hash of the certificate of the peer, and `common_name`
        // its CN. `stop` ends a connect or a read that waits.
        bool Connect(std::string const &host, int port, std::string const &pin, std::string &seen, std::string &common_name,
                     std::atomic<bool> const *stop, std::string &error);
        bool Write(void const *data, size_t len);
        // The count of bytes, 0 when none came in `timeout_ms`, or -1 when
        // the connection ended.
        int Read(void *data, size_t cap, int timeout_ms);
        void Close();

    private:
        struct Impl;
        std::unique_ptr<Impl> impl_;
    };
}
