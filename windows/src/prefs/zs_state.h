#pragma once
// The folder of the app state, its files, and its secrets.
//
// The state lives in %APPDATA%\zslice. ZSLICE_STATE_DIR moves it, for tests.
// A write goes to a new file and renames it, so a crash leaves the old file
// or the new file, and never half of one.
//
// A secret (an API key, a printer access code, the signing key) is encrypted
// for this Windows user with DPAPI (CryptProtectData). It never goes to a
// file in plain text. This file has no WinRT, so a test program can link it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <string>
#include <vector>

namespace zs::state
{
    // The state folder, with no slash at the end. It need not exist yet.
    std::wstring Dir();
    // Dir() and a relative path.
    std::wstring PathOf(std::wstring const &relative);
    // Makes a folder and its parents.
    bool EnsureDir(std::wstring const &dir);
    // Makes the parent folder of a file.
    bool EnsureParent(std::wstring const &path);

    bool ReadBytes(std::wstring const &path, std::string &bytes);
    // Writes the file through a rename in its folder.
    bool WriteBytes(std::wstring const &path, std::string const &bytes);
    bool Exists(std::wstring const &path);
    void Remove(std::wstring const &path);
    // The names of the files in a folder with this suffix, sorted, with the
    // suffix cut.
    std::vector<std::wstring> ListNames(std::wstring const &dir, std::wstring const &suffix);

    // DPAPI for the current user. The result is a blob for a file.
    bool Protect(std::string const &plain, std::string &blob);
    bool Unprotect(std::string const &blob, std::string &plain);
    // A secret in a file, encrypted. An empty secret removes the file.
    bool WriteSecret(std::wstring const &path, std::string const &secret);
    bool ReadSecret(std::wstring const &path, std::string &secret);
    // Overwrites the bytes of a string that held a secret.
    void Wipe(std::string &secret);
}
