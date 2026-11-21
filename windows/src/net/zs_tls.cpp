// See zs_tls.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_tls.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define SECURITY_WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <schannel.h>
#include <security.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <vector>

namespace zs
{
    namespace
    {
        constexpr int connect_timeout_ms = 10000;

        void StartWinsock()
        {
            static bool started = [] {
                WSADATA data{};
                return ::WSAStartup(MAKEWORD(2, 2), &data) == 0;
            }();
            (void)started;
        }

        std::wstring Wide(std::string const &text)
        {
            if (text.empty())
                return {};
            int n = ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0);
            std::wstring out(n, L'\0');
            ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n);
            return out;
        }

        std::string Sha256Hex(BYTE const *data, DWORD len)
        {
            UCHAR hash[32];
            if (!BCRYPT_SUCCESS(::BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, const_cast<PUCHAR>(data), len, hash, sizeof hash)))
                return {};
            std::string hex;
            char two[3];
            for (UCHAR b : hash)
            {
                snprintf(two, sizeof two, "%02x", b);
                hex += two;
            }
            return hex;
        }

        bool SameHex(std::string const &a, std::string const &b)
        {
            return a.size() == b.size() && _stricmp(a.c_str(), b.c_str()) == 0;
        }
    }

    struct TlsClient::Impl
    {
        SOCKET sock = INVALID_SOCKET;
        CredHandle cred{};
        CtxtHandle ctx{};
        bool has_cred = false;
        bool has_ctx = false;
        SecPkgContext_StreamSizes sizes{};
        std::vector<char> incoming; // encrypted bytes not decrypted yet
        std::vector<char> plain;    // decrypted bytes not read yet
        size_t plain_at = 0;

        ~Impl() { Close(); }

        void Close()
        {
            if (has_ctx)
                ::DeleteSecurityContext(&ctx);
            if (has_cred)
                ::FreeCredentialsHandle(&cred);
            has_ctx = has_cred = false;
            if (sock != INVALID_SOCKET)
                ::closesocket(sock);
            sock = INVALID_SOCKET;
            incoming.clear();
            plain.clear();
            plain_at = 0;
        }

        // Waits for the socket. 1 ready, 0 timeout, -1 error.
        int WaitRead(int ms)
        {
            fd_set set{};
            FD_ZERO(&set);
            FD_SET(sock, &set);
            timeval tv{ ms / 1000, (ms % 1000) * 1000 };
            return ::select(0, &set, nullptr, nullptr, &tv);
        }

        bool SendAll(char const *data, size_t len)
        {
            size_t done = 0;
            while (done < len)
            {
                int n = ::send(sock, data + done, (int)std::min<size_t>(len - done, 1 << 20), 0);
                if (n <= 0)
                    return false;
                done += (size_t)n;
            }
            return true;
        }

        bool TcpConnect(std::string const &host, int port, std::atomic<bool> const *stop, std::string &error)
        {
            addrinfoW hints{};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;
            addrinfoW *list = nullptr;
            if (::GetAddrInfoW(Wide(host).c_str(), std::to_wstring(port).c_str(), &hints, &list) != 0 || list == nullptr)
            {
                error = "The name of the printer does not resolve.";
                return false;
            }
            sock = ::socket(list->ai_family, list->ai_socktype, list->ai_protocol);
            bool ok = sock != INVALID_SOCKET;
            if (ok)
            {
                u_long on = 1;
                ::ioctlsocket(sock, FIONBIO, &on);
                int rc = ::connect(sock, list->ai_addr, (int)list->ai_addrlen);
                if (rc != 0 && ::WSAGetLastError() != WSAEWOULDBLOCK)
                    ok = false;
                auto t0 = std::chrono::steady_clock::now();
                while (ok && rc != 0)
                {
                    if (stop != nullptr && stop->load())
                    {
                        ok = false;
                        break;
                    }
                    fd_set write{}, fail{};
                    FD_ZERO(&write);
                    FD_ZERO(&fail);
                    FD_SET(sock, &write);
                    FD_SET(sock, &fail);
                    timeval tv{ 0, 100000 };
                    int ready = ::select(0, nullptr, &write, &fail, &tv);
                    if (ready > 0)
                    {
                        ok = FD_ISSET(sock, &write) != 0;
                        break;
                    }
                    if (ready < 0 || std::chrono::steady_clock::now() - t0 > std::chrono::milliseconds(connect_timeout_ms))
                        ok = false;
                }
                u_long off = 0;
                ::ioctlsocket(sock, FIONBIO, &off);
                int nodelay = 1;
                ::setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<char const *>(&nodelay), sizeof nodelay);
            }
            ::FreeAddrInfoW(list);
            if (!ok)
                error = "The connection to the printer failed.";
            return ok;
        }

        bool Handshake(std::string const &host, std::atomic<bool> const *stop, std::string &error)
        {
            SCHANNEL_CRED data{};
            data.dwVersion = SCHANNEL_CRED_VERSION;
            // The pin decides, after the handshake.
            data.dwFlags = SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS | SCH_CRED_NO_SERVERNAME_CHECK;
            TimeStamp expiry{};
            wchar_t package[] = UNISP_NAME_W;
            if (::AcquireCredentialsHandleW(nullptr, package, SECPKG_CRED_OUTBOUND, nullptr, &data, nullptr, nullptr, &cred, &expiry) != SEC_E_OK)
            {
                error = "TLS did not start.";
                return false;
            }
            has_cred = true;
            DWORD flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
            std::wstring target = Wide(host);
            std::vector<char> in;
            bool first = true;
            auto t0 = std::chrono::steady_clock::now();
            for (;;)
            {
                SecBuffer in_buffers[2]{};
                in_buffers[0].BufferType = SECBUFFER_TOKEN;
                in_buffers[0].pvBuffer = in.data();
                in_buffers[0].cbBuffer = (unsigned long)in.size();
                in_buffers[1].BufferType = SECBUFFER_EMPTY;
                SecBufferDesc in_desc{ SECBUFFER_VERSION, 2, in_buffers };
                SecBuffer out_buffer{ 0, SECBUFFER_TOKEN, nullptr };
                SecBufferDesc out_desc{ SECBUFFER_VERSION, 1, &out_buffer };
                DWORD got_flags = 0;
                SECURITY_STATUS st = ::InitializeSecurityContextW(&cred, first ? nullptr : &ctx, first ? target.data() : nullptr, flags, 0, 0,
                                                                   first ? nullptr : &in_desc, 0, first ? &ctx : nullptr, &out_desc, &got_flags, &expiry);
                if (first && (st == SEC_E_OK || st == SEC_I_CONTINUE_NEEDED || st == SEC_E_INCOMPLETE_MESSAGE))
                    has_ctx = true;
                first = false;
                if (out_buffer.pvBuffer != nullptr)
                {
                    bool sent = out_buffer.cbBuffer == 0 || SendAll(static_cast<char const *>(out_buffer.pvBuffer), out_buffer.cbBuffer);
                    ::FreeContextBuffer(out_buffer.pvBuffer);
                    if (!sent)
                    {
                        error = "The connection to the printer stopped.";
                        return false;
                    }
                }
                if (st == SEC_E_OK)
                {
                    if (in_buffers[1].BufferType == SECBUFFER_EXTRA && in_buffers[1].cbBuffer > 0)
                        incoming.assign(in.end() - in_buffers[1].cbBuffer, in.end());
                    return true;
                }
                if (st == SEC_I_CONTINUE_NEEDED)
                {
                    if (in_buffers[1].BufferType == SECBUFFER_EXTRA && in_buffers[1].cbBuffer > 0)
                    {
                        std::vector<char> extra(in.end() - in_buffers[1].cbBuffer, in.end());
                        in.swap(extra);
                        // The next record of the handshake is here already.
                        continue;
                    }
                    else
                        in.clear();
                }
                else if (st != SEC_E_INCOMPLETE_MESSAGE)
                {
                    error = "The TLS handshake with the printer failed.";
                    return false;
                }
                // More bytes of the peer.
                for (;;)
                {
                    if (stop != nullptr && stop->load())
                    {
                        error = "Canceled.";
                        return false;
                    }
                    if (std::chrono::steady_clock::now() - t0 > std::chrono::milliseconds(connect_timeout_ms))
                    {
                        error = "The printer did not answer the TLS handshake.";
                        return false;
                    }
                    int ready = WaitRead(100);
                    if (ready < 0)
                    {
                        error = "The connection to the printer stopped.";
                        return false;
                    }
                    if (ready > 0)
                        break;
                }
                char chunk[16384];
                int n = ::recv(sock, chunk, sizeof chunk, 0);
                if (n <= 0)
                {
                    error = "The printer closed the connection.";
                    return false;
                }
                in.insert(in.end(), chunk, chunk + n);
            }
        }

        // Decrypts what `incoming` has. False when the stream ended.
        bool Decrypt()
        {
            while (!incoming.empty() && plain_at >= plain.size())
            {
                SecBuffer buffers[4]{};
                buffers[0].BufferType = SECBUFFER_DATA;
                buffers[0].pvBuffer = incoming.data();
                buffers[0].cbBuffer = (unsigned long)incoming.size();
                buffers[1].BufferType = SECBUFFER_EMPTY;
                buffers[2].BufferType = SECBUFFER_EMPTY;
                buffers[3].BufferType = SECBUFFER_EMPTY;
                SecBufferDesc desc{ SECBUFFER_VERSION, 4, buffers };
                SECURITY_STATUS st = ::DecryptMessage(&ctx, &desc, 0, nullptr);
                if (st == SEC_E_INCOMPLETE_MESSAGE)
                    return true;
                if (st != SEC_E_OK && st != SEC_I_RENEGOTIATE)
                    return false;
                plain.clear();
                plain_at = 0;
                std::vector<char> extra;
                for (auto const &b : buffers)
                {
                    if (b.BufferType == SECBUFFER_DATA && b.cbBuffer > 0)
                        plain.assign(static_cast<char *>(b.pvBuffer), static_cast<char *>(b.pvBuffer) + b.cbBuffer);
                    else if (b.BufferType == SECBUFFER_EXTRA && b.cbBuffer > 0)
                        extra.assign(static_cast<char *>(b.pvBuffer), static_cast<char *>(b.pvBuffer) + b.cbBuffer);
                }
                incoming.swap(extra);
                if (st == SEC_I_RENEGOTIATE)
                    return false;
            }
            return true;
        }
    };

    TlsClient::TlsClient() : impl_(std::make_unique<Impl>())
    {
        StartWinsock();
    }

    TlsClient::~TlsClient() = default;

    bool TlsClient::Connect(std::string const &host, int port, std::string const &pin, std::string &seen, std::string &common_name,
                            std::atomic<bool> const *stop, std::string &error)
    {
        impl_->Close();
        seen.clear();
        common_name.clear();
        if (!impl_->TcpConnect(host, port, stop, error) || !impl_->Handshake(host, stop, error))
        {
            impl_->Close();
            return false;
        }
        PCCERT_CONTEXT cert = nullptr;
        if (::QueryContextAttributesW(&impl_->ctx, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &cert) != SEC_E_OK || cert == nullptr)
        {
            error = "The printer showed no certificate.";
            impl_->Close();
            return false;
        }
        seen = Sha256Hex(cert->pbCertEncoded, cert->cbCertEncoded);
        char name[256] = "";
        char oid[] = szOID_COMMON_NAME;
        if (::CertGetNameStringA(cert, CERT_NAME_ATTR_TYPE, 0, oid, name, sizeof name) > 1)
            common_name = name;
        ::CertFreeCertificateContext(cert);
        if (seen.empty() || (!pin.empty() && !SameHex(pin, seen)))
        {
            // Nothing went out yet: no access code reaches this device.
            error = "The certificate of the printer is not the one that zslice trusts. A device on the network can claim to be "
                    "the printer, so zslice sent no access code. If the printer was reset, read its serial number again to trust it.";
            impl_->Close();
            return false;
        }
        if (::QueryContextAttributesW(&impl_->ctx, SECPKG_ATTR_STREAM_SIZES, &impl_->sizes) != SEC_E_OK)
        {
            error = "TLS did not start.";
            impl_->Close();
            return false;
        }
        return true;
    }

    bool TlsClient::Write(void const *data, size_t len)
    {
        if (impl_->sock == INVALID_SOCKET)
            return false;
        auto const &sizes = impl_->sizes;
        char const *from = static_cast<char const *>(data);
        std::vector<char> record(sizes.cbHeader + sizes.cbMaximumMessage + sizes.cbTrailer);
        while (len > 0)
        {
            size_t piece = std::min<size_t>(len, sizes.cbMaximumMessage);
            memcpy(record.data() + sizes.cbHeader, from, piece);
            SecBuffer buffers[4]{};
            buffers[0] = { sizes.cbHeader, SECBUFFER_STREAM_HEADER, record.data() };
            buffers[1] = { (unsigned long)piece, SECBUFFER_DATA, record.data() + sizes.cbHeader };
            buffers[2] = { sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, record.data() + sizes.cbHeader + piece };
            buffers[3] = { 0, SECBUFFER_EMPTY, nullptr };
            SecBufferDesc desc{ SECBUFFER_VERSION, 4, buffers };
            if (::EncryptMessage(&impl_->ctx, 0, &desc, 0) != SEC_E_OK)
                return false;
            if (!impl_->SendAll(record.data(), buffers[0].cbBuffer + buffers[1].cbBuffer + buffers[2].cbBuffer))
                return false;
            from += piece;
            len -= piece;
        }
        return true;
    }

    int TlsClient::Read(void *data, size_t cap, int timeout_ms)
    {
        if (impl_->sock == INVALID_SOCKET)
            return -1;
        auto t0 = std::chrono::steady_clock::now();
        for (;;)
        {
            if (!impl_->Decrypt())
                return -1;
            if (impl_->plain_at < impl_->plain.size())
            {
                size_t n = std::min(cap, impl_->plain.size() - impl_->plain_at);
                memcpy(data, impl_->plain.data() + impl_->plain_at, n);
                impl_->plain_at += n;
                return (int)n;
            }
            int left = timeout_ms - (int)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
            if (left <= 0)
                return 0;
            int ready = impl_->WaitRead(left);
            if (ready < 0)
                return -1;
            if (ready == 0)
                return 0;
            char chunk[16384];
            int n = ::recv(impl_->sock, chunk, sizeof chunk, 0);
            if (n <= 0)
                return -1;
            impl_->incoming.insert(impl_->incoming.end(), chunk, chunk + n);
        }
    }

    void TlsClient::Close()
    {
        impl_->Close();
    }
}
