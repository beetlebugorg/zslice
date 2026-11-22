// See zs_cura_stack.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_cura_stack.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <array>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cwctype>
#include <fstream>
#include <string_view>
#include <system_error>

namespace fs = std::filesystem;

namespace zs::cura
{
    namespace
    {
        // The layers of a [containers] list, from the top.
        enum
        {
            L_USER,
            L_QUALITY_CHANGES,
            L_INTENT,
            L_QUALITY,
            L_MATERIAL,
            L_VARIANT,
            L_DEFINITION_CHANGES,
            L_DEFINITION,
            L_COUNT
        };
        using Ids = std::array<std::string, L_COUNT>;

        struct Layer
        {
            char const *json_key;
            wchar_t const *sub, *ext;
        };
        Layer const layers[L_DEFINITION] = {
            { "user", L"user", L".inst.cfg" },
            { "quality_changes", L"quality_changes", L".inst.cfg" },
            { "intent", L"intent", L".inst.cfg" },
            { "quality", L"quality", L".inst.cfg" },
            { "material", L"materials", L".xml.fdm_material" },
            { "variant", L"variants", L".inst.cfg" },
            { "definition_changes", L"definition_changes", L".inst.cfg" },
        };

        std::wstring Wide(std::string_view text)
        {
            if (text.empty())
                return {};
            int n = ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0);
            std::wstring out((size_t)n, L'\0');
            ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n);
            return out;
        }

        std::string Utf8(std::wstring_view text)
        {
            if (text.empty())
                return {};
            int n = ::WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0, nullptr, nullptr);
            std::string out((size_t)n, '\0');
            ::WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n, nullptr, nullptr);
            return out;
        }

        std::wstring Env(wchar_t const *name)
        {
            wchar_t text[MAX_PATH * 2];
            DWORD n = ::GetEnvironmentVariableW(name, text, ARRAYSIZE(text));
            return n > 0 && n < ARRAYSIZE(text) ? std::wstring(text, n) : std::wstring();
        }

        bool ReadAll(fs::path const &path, std::string &out)
        {
            std::ifstream in(path, std::ios::binary);
            if (!in)
                return false;
            out.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
            return !in.bad();
        }

        std::string_view Trim(std::string_view text)
        {
            size_t a = text.find_first_not_of(" \t\r\n\f\v");
            if (a == std::string_view::npos)
                return {};
            size_t b = text.find_last_not_of(" \t\r\n\f\v");
            return text.substr(a, b - a + 1);
        }

        // The value of `key` in `section` of an INI text, or "". Only the
        // first line of a value.
        std::string IniGet(std::string_view text, std::string_view section, std::string_view key)
        {
            bool in = false;
            for (size_t at = 0; at <= text.size();)
            {
                size_t end = text.find('\n', at);
                if (end == std::string_view::npos)
                    end = text.size();
                std::string_view line = Trim(text.substr(at, end - at));
                at = end + 1;
                if (!line.empty() && line[0] == '[')
                {
                    size_t close = line.find(']');
                    in = close != std::string_view::npos && line.substr(1, close - 1) == section;
                    continue;
                }
                if (!in)
                    continue;
                size_t eq = line.find('=');
                if (eq != std::string_view::npos && Trim(line.substr(0, eq)) == key)
                    return std::string(Trim(line.substr(eq + 1)));
            }
            return {};
        }

        // The ids of the [containers] list of a stack file, by layer. Only
        // this section is read.
        Ids ReadContainers(std::string_view text)
        {
            Ids ids;
            for (int i = 0; i < L_COUNT; i++)
                ids[i] = IniGet(text, "containers", std::to_string(i));
            return ids;
        }

        // The file name of a container id, as Cura writes it (Python
        // urllib.parse.quote_plus).
        std::string EscapeId(std::string_view id)
        {
            std::string out;
            for (unsigned char c : id)
            {
                bool alnum = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
                if (alnum || c == '_' || c == '.' || c == '-' || c == '~')
                {
                    out.push_back((char)c);
                }
                else if (c == ' ')
                {
                    out.push_back('+');
                }
                else
                {
                    char hex[4];
                    snprintf(hex, sizeof hex, "%%%02X", c);
                    out += hex;
                }
            }
            return out;
        }

        int HexValue(char c)
        {
            if (c >= '0' && c <= '9')
                return c - '0';
            if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
            if (c >= 'A' && c <= 'F')
                return c - 'A' + 10;
            return -1;
        }

        // The text of a file name that Cura escaped.
        std::string UnescapeName(std::string_view name)
        {
            std::string out;
            for (size_t i = 0; i < name.size(); i++)
            {
                if (name[i] == '+')
                {
                    out.push_back(' ');
                }
                else if (name[i] == '%' && i + 2 < name.size() && HexValue(name[i + 1]) >= 0 && HexValue(name[i + 2]) >= 0)
                {
                    out.push_back((char)(HexValue(name[i + 1]) * 16 + HexValue(name[i + 2])));
                    i += 2;
                }
                else
                {
                    out.push_back(name[i]);
                }
            }
            return out;
        }

        // True for a plain file name. An id in a Cura file cannot leave its
        // folder or name a stream.
        bool PlainName(std::wstring_view name)
        {
            return !name.empty() && name != L"." && name != L".." && name.find_first_of(L"/\\:") == std::wstring_view::npos;
        }

        // Finds `name` in `dir` and, with `deep`, in its subfolders.
        fs::path FindIn(fs::path const &dir, std::wstring const &name, bool deep)
        {
            std::error_code ec;
            fs::path path = dir / name;
            if (fs::is_regular_file(path, ec))
                return path;
            if (!deep)
                return {};
            fs::directory_iterator it(dir, fs::directory_options::skip_permission_denied, ec), end;
            for (; !ec && it != end; it.increment(ec))
            {
                std::error_code entry;
                if (it->is_symlink(entry) || !it->is_directory(entry))
                    continue;
                fs::path found = FindIn(it->path(), name, true);
                if (!found.empty())
                    return found;
            }
            return {};
        }

        // The file of container `id` with extension `ext`: first in the
        // user folder `sub`, then in the same folder of the resources (with
        // its subfolders).
        fs::path FindContainer(fs::path const &data_dir, fs::path const &resources, wchar_t const *sub, std::string const &id, wchar_t const *ext)
        {
            std::array<std::wstring, 2> names{ Wide(EscapeId(id)) + ext, Wide(id) + ext };
            for (auto const &name : names)
                if (PlainName(name))
                    if (fs::path found = FindIn(data_dir / sub, name, false); !found.empty())
                        return found;
            if (resources.empty())
                return {};
            for (auto const &name : names)
                if (PlainName(name))
                    if (fs::path found = FindIn(resources / sub, name, true); !found.empty())
                        return found;
            return {};
        }

        // The file of a material. The id of a material for one printer is
        // the id of its base file with more words after it
        // ("generic_pla_175_<printer>"), so the longest start of the id that
        // names a file is the base file.
        fs::path FindMaterial(fs::path const &data_dir, fs::path const &resources, std::string id)
        {
            for (;;)
            {
                fs::path found = FindContainer(data_dir, resources, L"materials", id, L".xml.fdm_material");
                if (!found.empty())
                    return found;
                size_t cut = id.rfind('_');
                if (cut == std::string::npos)
                    return {};
                id.resize(cut);
            }
        }

        bool IsEmptyId(std::string const &id)
        {
            return id.empty() || id.rfind("empty_", 0) == 0;
        }

        // "5.14" gives 5 and 14. False for any other form.
        bool ParseVersion(std::wstring_view name, int &major, int &minor)
        {
            size_t dot = name.find(L'.');
            if (dot == std::wstring_view::npos || dot == 0 || dot + 1 == name.size())
                return false;
            auto digits = [](std::wstring_view part) { return std::all_of(part.begin(), part.end(), [](wchar_t c) { return c >= L'0' && c <= L'9'; }); };
            if (!digits(name.substr(0, dot)) || !digits(name.substr(dot + 1)) || name.size() > 12)
                return false;
            major = _wtoi(std::wstring(name.substr(0, dot)).c_str());
            minor = _wtoi(std::wstring(name.substr(dot + 1)).c_str());
            return true;
        }

        // The newest version folder ("5.14") in `dir`, or "".
        std::wstring NewestVersion(fs::path const &dir)
        {
            std::wstring best;
            int best_major = -1, best_minor = -1;
            std::error_code ec;
            fs::directory_iterator it(dir, fs::directory_options::skip_permission_denied, ec), end;
            for (; !ec && it != end; it.increment(ec))
            {
                std::wstring name = it->path().filename().wstring();
                int major = 0, minor = 0;
                if (!ParseVersion(name, major, minor))
                    continue;
                if (major > best_major || (major == best_major && minor > best_minor))
                {
                    best_major = major;
                    best_minor = minor;
                    best = name;
                }
            }
            return best;
        }

        // The first "a.b" in the name of an install folder
        // ("UltiMaker Cura 5.14.0"): a * 1000 + b, or 0.
        int FolderVersion(std::wstring const &name)
        {
            for (size_t i = 0; i < name.size(); i++)
            {
                if (name[i] < L'0' || name[i] > L'9' || (i > 0 && name[i - 1] >= L'0' && name[i - 1] <= L'9'))
                    continue;
                wchar_t *after = nullptr;
                long major = wcstol(name.c_str() + i, &after, 10);
                if (*after != L'.' || after[1] < L'0' || after[1] > L'9')
                    continue;
                long minor = wcstol(after + 1, nullptr, 10);
                return (int)std::min(major, 100000L) * 1000 + (int)std::min(minor, 999L);
            }
            return 0;
        }

        // The resources of Cura. The install of the same version as the
        // configuration comes first, then the newest.
        fs::path FindResources(std::wstring const &version)
        {
            std::wstring env = Env(L"ZSLICE_CURA_RESOURCES");
            if (!env.empty())
                return env;
            int major = 0, minor = 0;
            ParseVersion(version, major, minor);
            int wanted = major * 1000 + minor;
            fs::path best;
            int best_rank = -1;
            for (wchar_t const *var : { L"ProgramW6432", L"ProgramFiles" })
            {
                std::wstring root = Env(var);
                if (root.empty())
                    continue;
                std::error_code ec;
                fs::directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end;
                for (; !ec && it != end; it.increment(ec))
                {
                    std::wstring name = it->path().filename().wstring();
                    std::wstring lower = name;
                    std::transform(lower.begin(), lower.end(), lower.begin(), [](wchar_t c) { return (wchar_t)std::towlower(c); });
                    if (lower.find(L"cura") == std::wstring::npos)
                        continue;
                    fs::path resources = it->path() / L"share" / L"cura" / L"resources";
                    std::error_code file;
                    if (!fs::is_regular_file(resources / L"definitions" / L"fdmprinter.def.json", file))
                        continue;
                    int at = FolderVersion(name);
                    int rank = at == wanted ? INT_MAX : at;
                    if (rank > best_rank)
                    {
                        best_rank = rank;
                        best = resources;
                    }
                }
            }
            return best;
        }

        // The extruder stack of `machine` with the lowest position, or "".
        fs::path FindExtruderStack(fs::path const &data_dir, std::string const &machine)
        {
            fs::path best;
            int best_pos = INT_MAX;
            std::error_code ec;
            fs::directory_iterator it(data_dir / L"extruders", fs::directory_options::skip_permission_denied, ec), end;
            for (; !ec && it != end; it.increment(ec))
            {
                std::wstring name = it->path().filename().wstring();
                if (!name.ends_with(L".extruder.cfg"))
                    continue;
                std::string text;
                if (!ReadAll(it->path(), text))
                    continue;
                int pos = atoi(IniGet(text, "metadata", "position").c_str());
                if (IniGet(text, "metadata", "machine") == machine && pos < best_pos)
                {
                    best_pos = pos;
                    best = it->path();
                }
            }
            return best;
        }

        // The global stack file of `machine`: the file whose name is the
        // escaped name of the printer.
        fs::path FindGlobalStack(fs::path const &data_dir, std::string const &machine)
        {
            std::wstring const suffix = L".global.cfg";
            std::error_code ec;
            fs::directory_iterator it(data_dir / L"machine_instances", fs::directory_options::skip_permission_denied, ec), end;
            for (; !ec && it != end; it.increment(ec))
            {
                std::wstring name = it->path().filename().wstring();
                if (!name.ends_with(suffix))
                    continue;
                if (UnescapeName(Utf8(name.substr(0, name.size() - suffix.size()))) == machine)
                    return it->path();
            }
            return {};
        }

        // The [general] name of an .inst.cfg file, or "".
        std::string ContainerName(fs::path const &path)
        {
            std::string text;
            if (path.empty() || !ReadAll(path, text))
                return {};
            return IniGet(text, "general", "name");
        }

        void AppendJsonString(std::string &out, std::string_view text)
        {
            out.push_back('"');
            for (char c : text)
            {
                if (c == '"' || c == '\\')
                {
                    out.push_back('\\');
                    out.push_back(c);
                }
                else if ((unsigned char)c < 0x20)
                {
                    char hex[8];
                    snprintf(hex, sizeof hex, "\\u%04x", (unsigned char)c);
                    out += hex;
                }
                else
                {
                    out.push_back(c);
                }
            }
            out.push_back('"');
        }

        // Builds one JSON object. A member with no value is left out.
        struct JsonObject
        {
            std::string &out;
            bool first = true;

            explicit JsonObject(std::string &text) : out(text) { out.push_back('{'); }
            void Key(std::string_view key)
            {
                if (!first)
                    out.push_back(',');
                first = false;
                AppendJsonString(out, key);
                out.push_back(':');
            }
            void Text(std::string_view key, std::string const &value)
            {
                if (value.empty())
                    return;
                Key(key);
                AppendJsonString(out, value);
            }
            void End() { out.push_back('}'); }
        };
    }

    std::unique_ptr<Stack> Stack::Find(std::string &error)
    {
        fs::path config_root = fs::path(Env(L"APPDATA")) / L"cura";
        std::wstring version = NewestVersion(config_root);
        if (version.empty())
        {
            error = "Cura has no settings in " + Utf8(config_root.wstring()) + ".";
            return nullptr;
        }
        fs::path data_dir = config_root / version;
        fs::path cfg_path = data_dir / L"cura.cfg";
        std::string cfg, machine;
        if (ReadAll(cfg_path, cfg))
        {
            machine = IniGet(cfg, "general", "active_machine");
            if (machine.empty())
                machine = IniGet(cfg, "cura", "active_machine");
        }
        if (machine.empty())
        {
            error = Utf8(cfg_path.wstring()) + " names no active printer.";
            return nullptr;
        }

        auto st = std::make_unique<Stack>();
        st->data_dir_ = data_dir;
        st->resources_ = FindResources(version);
        std::string version_text = Utf8(version);

        fs::path global_path = FindGlobalStack(data_dir, machine);
        if (global_path.empty())
        {
            error = "Cura " + version_text + " has no stack file for the printer \"" + machine + "\".";
            return nullptr;
        }
        fs::path extruder_path = FindExtruderStack(data_dir, machine);
        Ids global_ids, extruder_ids;
        std::string text;
        if (ReadAll(global_path, text))
            global_ids = ReadContainers(text);
        if (!extruder_path.empty() && ReadAll(extruder_path, text))
            extruder_ids = ReadContainers(text);

        // The files of the layers: [0] global, [1] extruder.
        std::array<std::string, L_COUNT> files[2];
        fs::path paths[2][L_COUNT];
        Ids const *ids[2] = { &global_ids, &extruder_ids };
        for (int s = 0; s < 2; s++)
        {
            for (int l = 0; l < L_DEFINITION; l++)
            {
                std::string const &id = (*ids[s])[l];
                if (IsEmptyId(id))
                    continue;
                paths[s][l] = l == L_MATERIAL ? FindMaterial(data_dir, st->resources_, id)
                                              : FindContainer(data_dir, st->resources_, layers[l].sub, id, layers[l].ext);
                files[s][l] = Utf8(paths[s][l].wstring());
                if (!files[s][l].empty())
                    st->files_.insert(files[s][l]);
            }
        }

        std::string json;
        JsonObject top(json);
        top.Text("cura", version_text);
        top.Text("machine", global_ids[L_DEFINITION]);
        top.Text("extruder", extruder_ids[L_DEFINITION]);
        top.Text("definition_changes", files[0][L_DEFINITION_CHANGES]);
        top.Text("definition_changes_extruder", files[1][L_DEFINITION_CHANGES]);
        top.Text("variant", !files[1][L_VARIANT].empty() ? files[1][L_VARIANT] : files[0][L_VARIANT]);
        std::string const &material = !files[1][L_MATERIAL].empty() ? files[1][L_MATERIAL] : files[0][L_MATERIAL];
        top.Key("profiles");
        {
            JsonObject profiles(json);
            profiles.Key("active");
            JsonObject active(json);
            active.Text("material", material);
            for (int l = L_QUALITY; l >= L_USER; l--)
            {
                active.Text(layers[l].json_key, files[0][l]);
                active.Text(std::string(layers[l].json_key) + "_extruder", files[1][l]);
            }
            active.End();
            profiles.End();
        }
        if (!material.empty())
        {
            top.Key("materials");
            JsonObject materials(json);
            materials.Key("active");
            JsonObject active(json);
            active.Text("file", material);
            active.End();
            materials.End();
        }
        top.End();
        st->json_ = std::move(json);

        // The title: the printer, the profile, and the material.
        std::string profile = ContainerName(paths[0][L_QUALITY_CHANGES]);
        if (profile.empty())
            profile = ContainerName(paths[0][L_QUALITY]);
        std::string const &mat_id = !IsEmptyId(extruder_ids[L_MATERIAL]) ? extruder_ids[L_MATERIAL] : global_ids[L_MATERIAL];
        st->title_ = "Cura " + version_text + ": " + machine + ", " + (profile.empty() ? "no profile" : profile) + ", " +
                     (!IsEmptyId(mat_id) ? mat_id : std::string("no material"));
        return st;
    }

    char const *Stack::Read(void *ctx, char const *path, size_t *len)
    {
        auto *st = static_cast<Stack *>(ctx);
        std::string_view want(path);
        if (want == "cura.json")
        {
            *len = st->json_.size();
            return st->json_.c_str();
        }
        fs::path found;
        constexpr std::string_view prefix = "definitions/", suffix = ".def.json";
        if (want.starts_with(prefix) && want.ends_with(suffix))
        {
            // A definition: the user folders, then the resources.
            std::wstring name = Wide(want.substr(prefix.size()));
            if (!PlainName(name))
                return nullptr;
            for (wchar_t const *sub : { L"definitions", L"extruders" })
                if (found.empty())
                    found = FindIn(st->data_dir_ / sub, name, false);
            if (!st->resources_.empty())
                for (wchar_t const *sub : { L"definitions", L"extruders" })
                    if (found.empty())
                        found = FindIn(st->resources_ / sub, name, true);
        }
        else if (st->files_.count(std::string(want)) != 0)
        {
            found = Wide(want);
        }
        if (found.empty())
            return nullptr;
        std::string bytes;
        if (!ReadAll(found, bytes))
            return nullptr;
        st->bytes_.push_back(std::move(bytes));
        *len = st->bytes_.back().size();
        return st->bytes_.back().c_str();
    }
}
