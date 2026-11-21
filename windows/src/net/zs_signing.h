#pragma once
// The signature of each G-code file that the app exports or sends.
//
// The key of this install is in <state>\signing.key, encrypted for this
// Windows user with DPAPI. The core does the Ed25519 and the SHA-256
// (zs_sign_gcode). See docs/references/formats-and-protocols.md. The flow
// follows linux/src/net/signing.c.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <string>

namespace zs::signing
{
    // The public key of this install, or "".
    std::string PublicKey();
    // The short id that a printdeck shows for the key, or "".
    std::string KeyId();
    // The G-code with its signature line. With no key it is the G-code.
    std::string Sign(std::string const &gcode);
    // Forgets the key in memory, for a test that moves the state folder.
    void Reset();
}
