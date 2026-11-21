// See zs_deck_filaments.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_deck_filaments.h"

#include "zs_json.h"

#include <algorithm>
#include <cctype>

namespace zs
{
    namespace
    {
        // The most filaments of a plate (src/app/filament_slots.zig).
        constexpr size_t max_filaments = 16;

        std::string Upper(std::string text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return (char)std::toupper(c); });
            return text;
        }

        std::string Lower(std::string text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            return text;
        }

        bool IsColor(std::string const &s)
        {
            if (s.size() != 7 || s[0] != '#')
                return false;
            return std::all_of(s.begin() + 1, s.end(), [](unsigned char c) { return std::isxdigit(c) != 0; });
        }

        void AppendSpools(std::string &out, std::vector<Spool> const &list, char const *no_slot, bool mark_aux)
        {
            for (size_t i = 0; i < list.size(); i++)
            {
                if (i > 0)
                    out += ", ";
                out += (list[i].slot.empty() ? std::string(no_slot) : list[i].slot) + " " + list[i].material;
                if (mark_aux && list[i].aux)
                    out += " (2nd nozzle)";
            }
        }

        std::string Spaced(std::string text)
        {
            std::replace(text.begin(), text.end(), '_', ' ');
            return text;
        }
    }

    bool NozzleOfCode(std::string const &raw, std::string &type, std::string &flow)
    {
        size_t a = raw.find_first_not_of(" \t\r\n");
        if (a == std::string::npos)
            return false;
        std::string code = raw.substr(a, raw.find_last_not_of(" \t\r\n") - a + 1);
        if (code.size() < 2)
            return false;
        for (size_t i = 2; i < code.size(); i++)
            if (!std::isdigit((unsigned char)code[i]))
                return false;
        char m = (char)std::toupper((unsigned char)code[0]);
        char f = (char)std::toupper((unsigned char)code[1]);
        if ((m != 'H' && m != 'S' && m != 'T') || (f != 'S' && f != 'H'))
            return false;
        type = m == 'H' ? "hardened_steel" : m == 'S' ? "stainless_steel" : "tungsten_carbide";
        flow = f == 'H' ? "high_flow" : "standard";
        return true;
    }

    bool ParseDeckFilaments(std::string const &text, bool two_nozzles, std::string const &printer, DeckFilaments &out, std::string &error)
    {
        out = DeckFilaments{};
        json::Value root;
        if (!json::Parse(text, root) || !root.IsObject())
        {
            error = "The deck sent no valid answer.";
            return false;
        }
        size_t loaded = 0;
        if (json::Value const *list = root.Get("filaments"); list != nullptr && list->IsArray())
        {
            for (auto const &e : list->items)
            {
                std::string material = e.Str("material");
                if (!e.IsObject() || material.empty())
                    continue;
                loaded++;
                Spool s;
                s.slot = e.Str("slot");
                s.material = Upper(material);
                std::string color = e.Str("color");
                if (IsColor(color))
                    s.color = Lower(color);
                s.aux = e.Str("nozzle") == "aux";
                // A spool of the second nozzle needs a printer with two
                // nozzles in the settings.
                if (s.aux && !two_nozzles)
                    out.left_out.push_back(std::move(s));
                else if (out.use.size() < max_filaments)
                    out.use.push_back(std::move(s));
            }
        }
        if (json::Value const *nozzles = root.Get("nozzles"); nozzles != nullptr && nozzles->IsArray())
        {
            for (auto const &e : nozzles->items)
                if (e.IsObject() && NozzleOfCode(e.Str("type"), out.nozzle_type, out.nozzle_flow))
                    break;
        }
        if (loaded == 0)
        {
            error = "The printer tells no loaded filaments. Update the deck, or load a spool.";
            return false;
        }
        if (out.use.empty())
        {
            error = "The spools of " + printer + " feed its second nozzle only. Pick the printer profile of " + printer +
                    " (two nozzles), or load a spool in the AMS.";
            return false;
        }
        return true;
    }

    std::string DeckFilamentsMessage(DeckFilaments const &d, bool two_nozzles, std::string const &printer)
    {
        std::string out = std::to_string(d.use.size()) + (d.use.size() == 1 ? " filament" : " filaments") + " from " + printer + ": ";
        AppendSpools(out, d.use, "roll", two_nozzles);
        out += ".";
        if (!d.left_out.empty())
        {
            out += " Not used: ";
            AppendSpools(out, d.left_out, "spool", false);
            out += " (the second nozzle: pick the printer profile of " + printer + ", with two nozzles).";
        }
        if (!d.nozzle_type.empty())
            out += " Nozzles: " + Spaced(d.nozzle_type) + ", " + Spaced(d.nozzle_flow) + ".";
        return out;
    }
}
