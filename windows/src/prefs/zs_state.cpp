// See zs_state.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_state.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dpapi.h>
#include <shlobj.h>

#include <algorithm>

namespace zs::state
{
    namespace
    {
        // Mixed into each blob: another program of this user that calls
        // CryptUnprotectData needs it too.
        char const entropy_text[] = "zslice printer secret v1";

        DATA_BLOB EntropyBlob()
        {
            DATA_BLOB blob{};
            blob.pbData = reinterpret_cast<BYTE *>(const_cast<char *>(entropy_text));
            blob.cbData = (DWORD)(sizeof entropy_text - 1);
            return blob;
        }
    }

    std::wstring Dir()
    {
        wchar_t env[MAX_PATH];
        DWORD n = ::GetEnvironmentVariableW(L"ZSLICE_STATE_DIR", env, MAX_PATH);
        if (n > 0 && n < MAX_PATH)
        {
            std::wstring dir(env, n);
            while (!dir.empty() && (dir.back() == L'\\' || dir.back() == L'/'))
                dir.pop_back();
            return dir;
        }
        PWSTR roaming = nullptr;
        std::wstring dir;
        if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &roaming)))
            dir = std::wstring(roaming) + L"\\zslice";
        ::CoTaskMemFree(roaming);
        return dir;
    }

    std::wstring PathOf(std::wstring const &relative)
    {
        return Dir() + L"\\" + relative;
    }

    bool EnsureDir(std::wstring const &dir)
    {
        if (dir.empty())
            return false;
        DWORD attr = ::GetFileAttributesW(dir.c_str());
        if (attr != INVALID_FILE_ATTRIBUTES)
            return (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
        size_t at = dir.find_last_of(L"\\/");
        if (at != std::wstring::npos && at > 2 && !EnsureDir(dir.substr(0, at)))
            return false;
        return ::CreateDirectoryW(dir.c_str(), nullptr) != 0 || ::GetLastError() == ERROR_ALREADY_EXISTS;
    }

    bool EnsureParent(std::wstring const &path)
    {
        size_t at = path.find_last_of(L"\\/");
        return at != std::wstring::npos && EnsureDir(path.substr(0, at));
    }

    bool ReadBytes(std::wstring const &path, std::string &bytes)
    {
        bytes.clear();
        HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                    FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            return false;
        LARGE_INTEGER size{};
        bool ok = ::GetFileSizeEx(file, &size) != 0 && size.QuadPart < (1LL << 31);
        if (ok)
        {
            bytes.resize((size_t)size.QuadPart);
            size_t done = 0;
            while (ok && done < bytes.size())
            {
                DWORD got = 0;
                ok = ::ReadFile(file, bytes.data() + done, (DWORD)(bytes.size() - done), &got, nullptr) != 0 && got > 0;
                done += got;
            }
        }
        ::CloseHandle(file);
        return ok;
    }

    bool WriteBytes(std::wstring const &path, std::string const &bytes)
    {
        if (!EnsureParent(path))
            return false;
        std::wstring temp = path + L".new";
        HANDLE file = ::CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            return false;
        bool ok = true;
        size_t done = 0;
        while (ok && done < bytes.size())
        {
            DWORD wrote = 0;
            DWORD piece = (DWORD)std::min<size_t>(bytes.size() - done, 1u << 30);
            ok = ::WriteFile(file, bytes.data() + done, piece, &wrote, nullptr) != 0 && wrote > 0;
            done += wrote;
        }
        ok = ::FlushFileBuffers(file) != 0 && ok;
        ::CloseHandle(file);
        if (ok)
            ok = ::MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
        if (!ok)
            ::DeleteFileW(temp.c_str());
        return ok;
    }

    bool Exists(std::wstring const &path)
    {
        return ::GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
    }

    void Remove(std::wstring const &path)
    {
        ::DeleteFileW(path.c_str());
    }

    std::vector<std::wstring> ListNames(std::wstring const &dir, std::wstring const &suffix)
    {
        std::vector<std::wstring> names;
        WIN32_FIND_DATAW data{};
        HANDLE find = ::FindFirstFileW((dir + L"\\*" + suffix).c_str(), &data);
        if (find == INVALID_HANDLE_VALUE)
            return names;
        do
        {
            std::wstring name = data.cFileName;
            if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 && name.size() > suffix.size())
                names.push_back(name.substr(0, name.size() - suffix.size()));
        } while (::FindNextFileW(find, &data));
        ::FindClose(find);
        std::sort(names.begin(), names.end());
        return names;
    }

    bool Protect(std::string const &plain, std::string &blob)
    {
        DATA_BLOB in{ (DWORD)plain.size(), reinterpret_cast<BYTE *>(const_cast<char *>(plain.data())) };
        DATA_BLOB extra = EntropyBlob();
        DATA_BLOB out{};
        if (!::CryptProtectData(&in, L"zslice", &extra, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out))
            return false;
        blob.assign(reinterpret_cast<char const *>(out.pbData), out.cbData);
        ::LocalFree(out.pbData);
        return true;
    }

    bool Unprotect(std::string const &blob, std::string &plain)
    {
        DATA_BLOB in{ (DWORD)blob.size(), reinterpret_cast<BYTE *>(const_cast<char *>(blob.data())) };
        DATA_BLOB extra = EntropyBlob();
        DATA_BLOB out{};
        if (!::CryptUnprotectData(&in, nullptr, &extra, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out))
            return false;
        plain.assign(reinterpret_cast<char const *>(out.pbData), out.cbData);
        ::SecureZeroMemory(out.pbData, out.cbData);
        ::LocalFree(out.pbData);
        return true;
    }

    bool WriteSecret(std::wstring const &path, std::string const &secret)
    {
        if (secret.empty())
        {
            Remove(path);
            return true;
        }
        std::string blob;
        return Protect(secret, blob) && WriteBytes(path, blob);
    }

    bool ReadSecret(std::wstring const &path, std::string &secret)
    {
        secret.clear();
        std::string blob;
        return ReadBytes(path, blob) && Unprotect(blob, secret);
    }

    void Wipe(std::string &secret)
    {
        if (!secret.empty())
            ::SecureZeroMemory(secret.data(), secret.size());
        secret.clear();
    }
}
