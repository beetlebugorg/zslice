// See zs_signing.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_signing.h"

#include "zs_state.h"

#include "zslice.h"
#include "zslice-app.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>

#include <cstdio>
#include <cstring>
#include <mutex>

namespace zs::signing
{
    namespace
    {
        std::mutex lock;
        bool loaded = false;
        char secret[ZS_SIGN_TEXT_MAX];
        char public_key[ZS_SIGN_TEXT_MAX];
        char key_id[17];

        void Clear()
        {
            ::SecureZeroMemory(secret, sizeof secret);
            public_key[0] = 0;
            key_id[0] = 0;
        }

        // Reads the key file, or makes a new key and writes it.
        void Load()
        {
            if (loaded)
                return;
            loaded = true;
            std::wstring path = state::PathOf(L"signing.key");
            std::string text;
            bool ok = false;
            if (state::Exists(path))
            {
                ok = state::ReadSecret(path, text) && text.size() < sizeof secret &&
                     zs_sign_public_key(text.c_str(), public_key, sizeof public_key) == ZS_OK;
                if (ok)
                    memcpy(secret, text.c_str(), text.size() + 1);
                else
                    fprintf(stderr, "shell: the signing key does not read: prints go out with no signature\n");
            }
            else
            {
                uint8_t seed[32];
                if (BCRYPT_SUCCESS(::BCryptGenRandom(nullptr, seed, sizeof seed, BCRYPT_USE_SYSTEM_PREFERRED_RNG)) &&
                    zs_sign_key_from_seed(seed, sizeof seed, secret, sizeof secret) == ZS_OK)
                {
                    ok = state::WriteSecret(path, secret) && zs_sign_public_key(secret, public_key, sizeof public_key) == ZS_OK;
                    if (!ok)
                        fprintf(stderr, "shell: the signing key was not saved\n");
                }
                ::SecureZeroMemory(seed, sizeof seed);
            }
            if (ok && zs_sign_key_id(public_key, key_id, sizeof key_id) != ZS_OK)
                ok = false;
            if (!ok)
                Clear();
            state::Wipe(text);
        }
    }

    std::string PublicKey()
    {
        std::lock_guard guard(lock);
        Load();
        return public_key;
    }

    std::string KeyId()
    {
        std::lock_guard guard(lock);
        Load();
        return key_id;
    }

    std::string Sign(std::string const &gcode)
    {
        std::lock_guard guard(lock);
        Load();
        if (secret[0] == 0)
            return gcode;
        uint8_t *out = nullptr;
        size_t len = 0;
        if (zs_sign_gcode(secret, reinterpret_cast<uint8_t const *>(gcode.data()), gcode.size(), &out, &len) != ZS_OK)
        {
            fprintf(stderr, "shell: the G-code was not signed\n");
            return gcode;
        }
        std::string text(reinterpret_cast<char const *>(out), len);
        zs_buffer_free(out, len);
        return text;
    }

    void Reset()
    {
        std::lock_guard guard(lock);
        Clear();
        loaded = false;
    }
}
