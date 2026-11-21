// See zs_json.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_json.h"

#include <charconv>
#include <cstdio>
#include <cstring>

namespace zs::json
{
    namespace
    {
        constexpr int max_depth = 64;

        struct Reader
        {
            char const *at;
            char const *end;

            void Space()
            {
                while (at < end && (*at == ' ' || *at == '\t' || *at == '\n' || *at == '\r'))
                    at++;
            }

            bool Word(char const *word)
            {
                size_t n = strlen(word);
                if ((size_t)(end - at) < n || memcmp(at, word, n) != 0)
                    return false;
                at += n;
                return true;
            }

            static void Utf8(std::string &out, unsigned c)
            {
                if (c < 0x80)
                    out += (char)c;
                else if (c < 0x800)
                {
                    out += (char)(0xC0 | (c >> 6));
                    out += (char)(0x80 | (c & 63));
                }
                else if (c < 0x10000)
                {
                    out += (char)(0xE0 | (c >> 12));
                    out += (char)(0x80 | ((c >> 6) & 63));
                    out += (char)(0x80 | (c & 63));
                }
                else
                {
                    out += (char)(0xF0 | (c >> 18));
                    out += (char)(0x80 | ((c >> 12) & 63));
                    out += (char)(0x80 | ((c >> 6) & 63));
                    out += (char)(0x80 | (c & 63));
                }
            }

            bool Hex4(unsigned &out)
            {
                if (end - at < 4)
                    return false;
                out = 0;
                for (int i = 0; i < 4; i++)
                {
                    char c = *at++;
                    out <<= 4;
                    if (c >= '0' && c <= '9')
                        out |= (unsigned)(c - '0');
                    else if (c >= 'a' && c <= 'f')
                        out |= (unsigned)(c - 'a' + 10);
                    else if (c >= 'A' && c <= 'F')
                        out |= (unsigned)(c - 'A' + 10);
                    else
                        return false;
                }
                return true;
            }

            bool String(std::string &out)
            {
                if (at >= end || *at != '"')
                    return false;
                at++;
                while (at < end)
                {
                    char c = *at++;
                    if (c == '"')
                        return true;
                    if ((unsigned char)c < 0x20)
                        return false;
                    if (c != '\\')
                    {
                        out += c;
                        continue;
                    }
                    if (at >= end)
                        return false;
                    char e = *at++;
                    switch (e)
                    {
                    case '"': out += '"'; break;
                    case '\\': out += '\\'; break;
                    case '/': out += '/'; break;
                    case 'b': out += '\b'; break;
                    case 'f': out += '\f'; break;
                    case 'n': out += '\n'; break;
                    case 'r': out += '\r'; break;
                    case 't': out += '\t'; break;
                    case 'u': {
                        unsigned c1 = 0;
                        if (!Hex4(c1))
                            return false;
                        if (c1 >= 0xD800 && c1 < 0xDC00 && end - at >= 6 && at[0] == '\\' && at[1] == 'u')
                        {
                            at += 2;
                            unsigned c2 = 0;
                            if (!Hex4(c2) || c2 < 0xDC00 || c2 >= 0xE000)
                                return false;
                            c1 = 0x10000 + ((c1 - 0xD800) << 10) + (c2 - 0xDC00);
                        }
                        Utf8(out, c1);
                        break;
                    }
                    default:
                        return false;
                    }
                }
                return false;
            }

            bool Number(double &out)
            {
                char const *start = at;
                if (at < end && *at == '-')
                    at++;
                while (at < end && ((*at >= '0' && *at <= '9') || *at == '.' || *at == 'e' || *at == 'E' || *at == '+' || *at == '-'))
                    at++;
                auto r = std::from_chars(start, at, out);
                return r.ec == std::errc{} && r.ptr == at && at > start;
            }

            bool Parse(Value &v, int depth)
            {
                if (depth > max_depth)
                    return false;
                Space();
                if (at >= end)
                    return false;
                char c = *at;
                if (c == '{')
                {
                    at++;
                    v.type = Type::Object;
                    Space();
                    if (at < end && *at == '}')
                    {
                        at++;
                        return true;
                    }
                    for (;;)
                    {
                        Space();
                        std::string name;
                        if (!String(name))
                            return false;
                        Space();
                        if (at >= end || *at++ != ':')
                            return false;
                        Value item;
                        if (!Parse(item, depth + 1))
                            return false;
                        v.members.emplace_back(std::move(name), std::move(item));
                        Space();
                        if (at >= end)
                            return false;
                        char d = *at++;
                        if (d == '}')
                            return true;
                        if (d != ',')
                            return false;
                    }
                }
                if (c == '[')
                {
                    at++;
                    v.type = Type::Array;
                    Space();
                    if (at < end && *at == ']')
                    {
                        at++;
                        return true;
                    }
                    for (;;)
                    {
                        Value item;
                        if (!Parse(item, depth + 1))
                            return false;
                        v.items.push_back(std::move(item));
                        Space();
                        if (at >= end)
                            return false;
                        char d = *at++;
                        if (d == ']')
                            return true;
                        if (d != ',')
                            return false;
                    }
                }
                if (c == '"')
                {
                    v.type = Type::String;
                    return String(v.text);
                }
                if (Word("true"))
                {
                    v.type = Type::Bool;
                    v.boolean = true;
                    return true;
                }
                if (Word("false"))
                {
                    v.type = Type::Bool;
                    return true;
                }
                if (Word("null"))
                    return true;
                v.type = Type::Number;
                return Number(v.number);
            }
        };
    }

    Value const *Value::Get(char const *name) const
    {
        if (type != Type::Object)
            return nullptr;
        for (auto const &m : members)
            if (m.first == name)
                return &m.second;
        return nullptr;
    }

    Value const *Value::Path(char const *dotted) const
    {
        Value const *v = this;
        std::string part;
        for (char const *c = dotted;; c++)
        {
            if (*c == '.' || *c == 0)
            {
                v = v->Get(part.c_str());
                if (v == nullptr || *c == 0)
                    return v;
                part.clear();
            }
            else
                part += *c;
        }
    }

    std::string Value::Str(char const *name) const
    {
        Value const *v = Get(name);
        return v != nullptr && v->type == Type::String ? v->text : std::string{};
    }

    double Value::Num(char const *name) const
    {
        Value const *v = Get(name);
        return v != nullptr && v->type == Type::Number ? v->number : 0;
    }

    bool Parse(char const *text, size_t len, Value &out)
    {
        Reader r{ text, text + len };
        out = Value{};
        if (!r.Parse(out, 0))
            return false;
        r.Space();
        return r.at == r.end;
    }

    std::string Quote(std::string const &text)
    {
        std::string out = "\"";
        for (char c : text)
        {
            if (c == '"' || c == '\\')
            {
                out += '\\';
                out += c;
            }
            else if ((unsigned char)c < 0x20)
            {
                char hex[8];
                snprintf(hex, sizeof hex, "\\u%04x", (unsigned)(unsigned char)c);
                out += hex;
            }
            else
                out += c;
        }
        return out + "\"";
    }
}
