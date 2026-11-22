#pragma once
// The active printer of the Cura app on this computer, for "Compare with
// Cura". It has the steps of linux/src/prefs/cura-stack.c, with the folders
// of Cura on Windows (see docs/references/cura.md):
//
// 1. The newest version folder in %APPDATA%\cura (for example 5.14). Cura
//    keeps its configuration and its data in this one folder on Windows.
// 2. cura.cfg there: `active_machine` in [general] or [cura].
// 3. machine_instances\<name>.global.cfg, and the extruder stack in
//    extruders\ whose [metadata] machine is the same name. Their
//    [containers] list the layers from the top: user, quality_changes,
//    intent, quality, material, variant, definition_changes, definition.
// 4. The file of each layer, in the user folder or in the resources of
//    Cura: ZSLICE_CURA_RESOURCES, or share\cura\resources in a Cura folder
//    of Program Files. A file name has the id of its container with URL
//    escapes ("%7C" for "|", "+" for a space).
//
// The result is a cura.json text in the layout of the Cura import, with
// absolute paths. Read gives it as "cura.json", finds
// "definitions/<id>.def.json" in the definition folders, and reads only the
// files that cura.json names. Of a global stack file, only [containers] is
// parsed: its [metadata] can hold a password or an API key.
//
// It has no WinRT, so a test program can link it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstddef>
#include <deque>
#include <filesystem>
#include <memory>
#include <set>
#include <string>

namespace zs::cura
{
    class Stack
    {
    public:
        // The stack of the active Cura printer. nullptr with a text in
        // `error` if Cura has no configuration or no active printer.
        static std::unique_ptr<Stack> Find(std::string &error);

        // A line for people: "Cura 5.14: <printer>, <profile>, <material>".
        std::string const &Title() const { return title_; }

        // The read callback for zs_app_cura_compare, with the stack as ctx.
        // The bytes stay valid as long as the stack.
        static char const *Read(void *ctx, char const *path, size_t *len);

    private:
        std::filesystem::path data_dir_;
        std::filesystem::path resources_;
        std::string title_;
        std::string json_;
        std::set<std::string> files_;
        std::deque<std::string> bytes_;
    };
}
