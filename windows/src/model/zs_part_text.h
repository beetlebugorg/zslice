#pragma once
// Reads the text of zs_app_part_settings: the values of the part, then the
// values of each modifier volume. A value of a volume is not a value of the
// part, so the two stay apart.
//
// Each body region stores "project.wall_count = 0", so that it has no walls
// of its own. The user did not set this, so it does not show. The rules
// follow partSettingsText in web/app/core.js.
//
// It has no WinRT, so a test program can use it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cctype>
#include <string>
#include <utility>
#include <vector>

namespace zs
{
    struct PartVolume
    {
        std::string name;
        std::vector<std::pair<std::string, std::string>> values;
    };

    struct PartText
    {
        std::vector<std::pair<std::string, std::string>> part;
        std::vector<PartVolume> volumes;
    };

    namespace part_text
    {
        // "Region 3" or "Pick 3".
        inline bool IsRegionName(std::string const &name)
        {
            size_t digits = name.rfind("Region ", 0) == 0 ? 7 : name.rfind("Pick ", 0) == 0 ? 5 : 0;
            if (digits == 0 || digits >= name.size())
                return false;
            for (size_t i = digits; i < name.size(); i++)
                if (!isdigit((unsigned char)name[i]))
                    return false;
            return true;
        }

        // Two spaces or more, then "group.name = value".
        inline bool ReadValue(std::string const &line, std::string &name, std::string &value)
        {
            size_t at = 0;
            while (at < line.size() && (line[at] == ' ' || line[at] == '\t'))
                at++;
            if (at == 0)
                return false;
            size_t equals = line.find(" = ", at);
            if (equals == std::string::npos)
                return false;
            std::string key = line.substr(at, equals - at);
            size_t dot = key.find('.');
            if (dot == std::string::npos || dot == 0 || dot + 1 == key.size())
                return false;
            for (size_t i = 0; i < key.size(); i++)
            {
                unsigned char c = (unsigned char)key[i];
                bool word = i < dot ? (c >= 'a' && c <= 'z') : (c >= 'a' && c <= 'z') || isdigit(c) || c == '_';
                if (i != dot && !word)
                    return false;
            }
            name = std::move(key);
            value = line.substr(equals + 3);
            return true;
        }
    }

    inline PartText ReadPartText(std::string const &text)
    {
        PartText out;
        std::vector<std::pair<std::string, std::string>> *list = &out.part;
        bool region = false;
        for (size_t at = 0; at < text.size();)
        {
            size_t end = text.find('\n', at);
            if (end == std::string::npos)
                end = text.size();
            std::string line = text.substr(at, end - at);
            at = end + 1;
            if (!line.empty() && line.back() == '\r')
                line.pop_back();
            if (line.rfind("Volume \"", 0) == 0 && line.size() >= 10 && line.compare(line.size() - 2, 2, "\":") == 0)
            {
                PartVolume volume;
                volume.name = line.substr(8, line.size() - 10);
                region = part_text::IsRegionName(volume.name);
                out.volumes.push_back(std::move(volume));
                list = &out.volumes.back().values;
                continue;
            }
            std::string name, value;
            if (line.find(": not used") != std::string::npos || !part_text::ReadValue(line, name, value))
                continue;
            if (region && name == "project.wall_count" && value == "0")
                continue;
            list->emplace_back(std::move(name), std::move(value));
        }
        return out;
    }
}
