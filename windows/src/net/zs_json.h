#pragma once
// A small JSON reader for the replies of printers (RFC 8259). The core reads
// the status replies itself. The shell reads only the few fields of a key
// request, a deck list, and an upload answer.
//
// The reader limits the depth, so a bad reply cannot overflow the stack.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <string>
#include <utility>
#include <vector>

namespace zs::json
{
    enum class Type
    {
        Null,
        Bool,
        Number,
        String,
        Array,
        Object,
    };

    struct Value
    {
        Type type = Type::Null;
        bool boolean = false;
        double number = 0;
        std::string text;
        std::vector<Value> items;
        std::vector<std::pair<std::string, Value>> members;

        // The member of an object, or nullptr.
        Value const *Get(char const *name) const;
        // The member by a dotted path ("files.local"), or nullptr.
        Value const *Path(char const *dotted) const;
        // The text of a string member, or "".
        std::string Str(char const *name) const;
        double Num(char const *name) const;
        bool IsObject() const { return type == Type::Object; }
        bool IsArray() const { return type == Type::Array; }
    };

    // False if the text is not one JSON value.
    bool Parse(char const *text, size_t len, Value &out);
    inline bool Parse(std::string const &text, Value &out) { return Parse(text.data(), text.size(), out); }

    // The text as a JSON string with its quotes.
    std::string Quote(std::string const &text);
}
