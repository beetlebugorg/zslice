#pragma once
// The loaded filaments of a printdeck printer.
//
// GET <printer>/api/plugin/printdeck returns JSON with "filaments" ([{slot,
// material, color "#rrggbb", nozzle "main" or "aux"}]) and "nozzles"
// ([{type "HS01"}]). This file reads that JSON into the filaments for the
// plate. It has no network code. It follows linux/src/net/deck-filaments.c.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <string>
#include <vector>

namespace zs
{
    struct Spool
    {
        std::string slot;     // "A1", or ""
        std::string material; // upper case
        std::string color;    // "#rrggbb", or ""
        bool aux = false;     // it feeds the second nozzle
    };

    struct DeckFilaments
    {
        // The filaments of the plate, in the order of the printer (16 at
        // most).
        std::vector<Spool> use;
        // The spools of the second nozzle on a printer with one nozzle in
        // the settings: the plate does not use them.
        std::vector<Spool> left_out;
        // machine.nozzle_type and machine.nozzle_flow, or "".
        std::string nozzle_type, nozzle_flow;
    };

    // False on an error, with the reason in `error`.
    bool ParseDeckFilaments(std::string const &json, bool two_nozzles, std::string const &printer, DeckFilaments &out, std::string &error);
    // "2 filaments from X1C: A1 PLA, A2 PETG."
    std::string DeckFilamentsMessage(DeckFilaments const &d, bool two_nozzles, std::string const &printer);
    // The nozzle of a Bambu Lab code: H hardened_steel, S stainless_steel,
    // T tungsten_carbide, and then H high_flow, S standard.
    bool NozzleOfCode(std::string const &code, std::string &type, std::string &flow);
}
