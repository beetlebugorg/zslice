// See zs_label.h.
//
// The ids, the filament, and the count of ticks are integers in the JSON of
// the core. The label writes its own top level, and the numbers of the items
// go through Windows.Data.Json.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "zs_label.h"

#include "zs_model.h"

#include <charconv>
#include <cmath>
#include <cstring>
#include <limits>

using namespace winrt;
using namespace winrt::Windows::Data::Json;

namespace zs
{
    char const *const label_kinds[label_kind_count] = { "text", "line", "bar", "ring", "ticks", "polyline" };
    wchar_t const *const label_kind_names[label_kind_count] = { L"Text", L"Line", L"Bar", L"Ring", L"Ticks", L"Free" };

    namespace
    {
        constexpr double pi = 3.14159265358979323846;

        LabelField const text_fields[] = {
            { "size", L"Size", L"mm", 0.5, 200, 0.1, L"The height of the capitals" },
            { "weight", L"Weight", L"mm", 0, 0.3, 0.01, L"Makes each stroke wider: small text prints better, small holes close" },
        };
        LabelField const line_fields[] = {
            { "length", L"Length", L"mm", 0.1, 500, 0.1, nullptr },
            { "width", L"Width", L"mm", 0.1, 100, 0.1, nullptr },
        };
        LabelField const bar_fields[] = {
            { "width", L"Width", L"mm", 0.1, 500, 0.1, nullptr },
            { "height", L"Height", L"mm", 0.1, 500, 0.1, nullptr },
            { "radius", L"Corners", L"mm", 0, 100, 0.1, L"The radius of the corners" },
        };
        LabelField const ring_fields[] = {
            { "outer", L"Outer radius", L"mm", 0.1, 250, 0.1, nullptr },
            { "inner", L"Inner radius", L"mm", 0, 250, 0.1, L"0 makes a disk" },
        };
        LabelField const ticks_fields[] = {
            { "count", L"Count", L"", 1, 360, 1, L"The number of ticks" },
            { "radius", L"Radius", L"mm", 0, 250, 0.1, L"The distance from the center to the inner end of each tick" },
            { "length", L"First length", L"mm", 0.1, 100, 0.1, L"The length of the first tick" },
            { "length_end", L"Last length", L"mm", 0, 100, 0.1, L"The length of the last tick (0: the same as the first). The ticks between grow evenly." },
            { "width", L"Width", L"mm", 0.1, 20, 0.05, L"The width of each tick" },
            { "start", L"Start", L"°", -360, 360, 1, L"The angle of the first tick (0: to the right, 90: up)" },
            { "sweep", L"Sweep", L"°", -360, 360, 1, L"The angle from the first tick to the last (negative: clockwise)" },
        };
        LabelField const poly_fields[] = {
            { "width", L"Width", L"mm", 0, 100, 0.1, L"The width of the line (0 with Filled)" },
        };

        hstring Key(char const *name)
        {
            return hstring(ToWide(name));
        }

        double Dot(double const *a, double const *b)
        {
            return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        }

        void Cross(double const *a, double const *b, double *out)
        {
            double c[3] = { a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
            std::memcpy(out, c, sizeof c);
        }

        bool Unit(double *a)
        {
            double l = std::sqrt(Dot(a, a));
            if (!(l > 1e-9))
                return false;
            for (int k = 0; k < 3; k++)
                a[k] /= l;
            return true;
        }

        void AppendNumber(std::string &out, double v)
        {
            char text[40];
            auto end = std::to_chars(text, text + sizeof text, v).ptr;
            out.append(text, end);
        }

        void AppendVector(std::string &out, double const *v, int n)
        {
            out += '[';
            for (int k = 0; k < n; k++)
            {
                if (k > 0)
                    out += ',';
                AppendNumber(out, v[k]);
            }
            out += ']';
        }

        bool VectorOf(JsonObject const &o, wchar_t const *name, double *out, uint32_t n)
        {
            if (!o.HasKey(name))
                return false;
            IJsonValue value = o.GetNamedValue(name);
            if (value.ValueType() != JsonValueType::Array)
                return false;
            JsonArray a = value.GetArray();
            if (a.Size() != n)
                return false;
            for (uint32_t k = 0; k < n; k++)
            {
                IJsonValue e = a.GetAt(k);
                if (e.ValueType() != JsonValueType::Number)
                    return false;
                out[k] = e.GetNumber();
                if (!std::isfinite(out[k]))
                    return false;
            }
            return true;
        }

        double NumberOf(JsonObject const &o, hstring const &name, double fallback)
        {
            if (o == nullptr || !o.HasKey(name))
                return fallback;
            IJsonValue value = o.GetNamedValue(name);
            if (value.ValueType() != JsonValueType::Number)
                return fallback;
            double v = value.GetNumber();
            return std::isfinite(v) ? v : fallback;
        }

        bool LabelOf(JsonObject const &o, Label &l)
        {
            l.id = (uint32_t)NumberOf(o, L"id", 0);
            l.filament = (int)NumberOf(o, L"filament", 1);
            l.depth = NumberOf(o, L"depth", 0);
            if (o.HasKey(L"name") && o.GetNamedValue(L"name").ValueType() == JsonValueType::String)
                l.name = ToUtf8(std::wstring(o.GetNamedString(L"name")));
            l.has_stretch = VectorOf(o, L"stretch", l.stretch, 2);
            if (!VectorOf(o, L"origin", l.origin, 3) || !VectorOf(o, L"normal", l.normal, 3) || !VectorOf(o, L"right", l.right, 3) ||
                !Unit(l.normal) || !Unit(l.right))
                return false;
            if (o.HasKey(L"items") && o.GetNamedValue(L"items").ValueType() == JsonValueType::Array)
                l.items = o.GetNamedArray(L"items");
            return true;
        }

        JsonArray PointArray(double x, double y)
        {
            JsonArray a;
            a.Append(JsonValue::CreateNumberValue(x));
            a.Append(JsonValue::CreateNumberValue(y));
            return a;
        }

        JsonObject CopyObject(JsonObject const &o)
        {
            JsonObject out{ nullptr };
            if (JsonObject::TryParse(o.Stringify(), out))
                return out;
            return JsonObject();
        }

        // The fields of each kind that are lengths: a scale changes them.
        std::vector<char const *> LengthFields(std::string const &kind)
        {
            if (kind == "text")
                return { "size", "spacing" };
            if (kind == "line")
                return { "length", "width" };
            if (kind == "bar")
                return { "width", "height", "radius" };
            if (kind == "ring")
                return { "outer", "inner" };
            if (kind == "ticks")
                return { "radius", "length", "length_end", "width" };
            if (kind == "polyline")
                return { "width" };
            return {};
        }
    }

    LabelField const *LabelFields(std::string_view kind, size_t &n)
    {
        struct Entry
        {
            std::string_view kind;
            LabelField const *fields;
            size_t count;
        };
        Entry const all[] = {
            { "text", text_fields, std::size(text_fields) },    { "line", line_fields, std::size(line_fields) },
            { "bar", bar_fields, std::size(bar_fields) },       { "ring", ring_fields, std::size(ring_fields) },
            { "ticks", ticks_fields, std::size(ticks_fields) }, { "polyline", poly_fields, std::size(poly_fields) },
        };
        for (auto const &e : all)
        {
            if (e.kind == kind)
            {
                n = e.count;
                return e.fields;
            }
        }
        n = 0;
        return nullptr;
    }

    bool LabelsParse(std::string const &json, std::vector<Label> &out)
    {
        out.clear();
        JsonValue root{ nullptr };
        if (!JsonValue::TryParse(ToWide(json), root))
            return false;
        if (root.ValueType() == JsonValueType::Array)
        {
            JsonArray a = root.GetArray();
            for (uint32_t i = 0; i < a.Size(); i++)
            {
                IJsonValue e = a.GetAt(i);
                if (e.ValueType() != JsonValueType::Object)
                    continue;
                Label l;
                if (LabelOf(e.GetObject(), l))
                    out.push_back(std::move(l));
            }
            return true;
        }
        if (root.ValueType() == JsonValueType::Object)
        {
            Label l;
            if (LabelOf(root.GetObject(), l))
                out.push_back(std::move(l));
            return true;
        }
        return false;
    }

    std::string LabelJson(Label const &l, bool shapes_only)
    {
        std::string s = "{";
        if (!shapes_only)
        {
            s += "\"id\":" + std::to_string(l.id) + ",";
            if (!l.name.empty())
                s += "\"name\":" + ToUtf8(std::wstring(JsonValue::CreateStringValue(ToWide(l.name)).Stringify())) + ",";
            s += "\"origin\":";
            AppendVector(s, l.origin, 3);
            s += ",\"normal\":";
            AppendVector(s, l.normal, 3);
            s += ",\"right\":";
            AppendVector(s, l.right, 3);
            s += ",\"filament\":" + std::to_string(l.filament) + ",\"depth\":";
            AppendNumber(s, l.depth);
            s += ",";
        }
        if (l.has_stretch)
        {
            s += "\"stretch\":";
            AppendVector(s, l.stretch, 2);
            s += ",";
        }
        s += "\"items\":" + ToUtf8(std::wstring(l.items.Stringify())) + "}";
        return s;
    }

    size_t LabelItemCount(Label const &l)
    {
        return l.items != nullptr ? l.items.Size() : 0;
    }

    JsonObject LabelItem(Label const &l, size_t i)
    {
        if (i >= LabelItemCount(l))
            return nullptr;
        IJsonValue value = l.items.GetAt((uint32_t)i);
        return value.ValueType() == JsonValueType::Object ? value.GetObject() : nullptr;
    }

    std::string LabelItemKind(JsonObject const &item)
    {
        if (item == nullptr || !item.HasKey(L"kind") || item.GetNamedValue(L"kind").ValueType() != JsonValueType::String)
            return {};
        return ToUtf8(std::wstring(item.GetNamedString(L"kind")));
    }

    double LabelItemNumber(JsonObject const &item, char const *field, double fallback)
    {
        return NumberOf(item, Key(field), fallback);
    }

    bool LabelItemFlag(JsonObject const &item, char const *field)
    {
        hstring key = Key(field);
        return item != nullptr && item.HasKey(key) && item.GetNamedValue(key).ValueType() == JsonValueType::Boolean &&
               item.GetNamedBoolean(key);
    }

    std::wstring LabelItemText(JsonObject const &item)
    {
        if (item == nullptr || !item.HasKey(L"text") || item.GetNamedValue(L"text").ValueType() != JsonValueType::String)
            return {};
        return std::wstring(item.GetNamedString(L"text"));
    }

    void LabelItemSetNumber(JsonObject const &item, char const *field, double value)
    {
        if (std::strcmp(field, "count") == 0)
            value = std::round(value);
        item.SetNamedValue(Key(field), JsonValue::CreateNumberValue(value));
    }

    void LabelItemSetFlag(JsonObject const &item, char const *field, bool value)
    {
        item.SetNamedValue(Key(field), JsonValue::CreateBooleanValue(value));
    }

    void LabelItemSetText(JsonObject const &item, std::wstring const &text)
    {
        item.SetNamedValue(L"text", JsonValue::CreateStringValue(text));
    }

    void LabelItemSetAt(JsonObject const &item, double x, double y)
    {
        item.SetNamedValue(L"at", PointArray(x, y));
    }

    double LabelItemAt(JsonObject const &item, int k)
    {
        double at[2] = { 0, 0 };
        if (item == nullptr || !VectorOf(item, L"at", at, 2))
            return 0;
        return at[k];
    }

    void LabelItemSetPoints(JsonObject const &item, std::vector<double> const &xy)
    {
        JsonArray points;
        for (size_t k = 0; k + 1 < xy.size(); k += 2)
            points.Append(PointArray(xy[k], xy[k + 1]));
        item.SetNamedValue(L"points", points);
    }

    JsonObject LabelNewItem(std::string const &kind, double size)
    {
        JsonObject o;
        auto number = [&](wchar_t const *name, double v) { o.SetNamedValue(name, JsonValue::CreateNumberValue(v)); };
        o.SetNamedValue(L"kind", JsonValue::CreateStringValue(ToWide(kind)));
        if (kind == "text")
        {
            o.SetNamedValue(L"text", JsonValue::CreateStringValue(L"LABEL"));
            number(L"size", size);
        }
        else if (kind == "line")
        {
            number(L"length", 4 * size);
            number(L"width", 1);
        }
        else if (kind == "bar")
        {
            number(L"width", 4 * size);
            number(L"height", std::max(1.0, 0.4 * size));
            number(L"radius", 0);
        }
        else if (kind == "ring")
        {
            number(L"outer", size);
            number(L"inner", std::max(0.0, size - 1));
        }
        else if (kind == "ticks")
        {
            number(L"count", 11);
            number(L"radius", 1.6 * size);
            number(L"length", 0.3 * size);
            number(L"length_end", 0.6 * size);
            number(L"width", 0.8);
            number(L"start", 225);
            number(L"sweep", -270);
        }
        else
        {
            o.SetNamedValue(L"kind", JsonValue::CreateStringValue(L"polyline"));
            JsonArray points;
            points.Append(PointArray(-2 * size, -size / 2));
            points.Append(PointArray(0, size / 2));
            points.Append(PointArray(2 * size, -size / 2));
            o.SetNamedValue(L"points", points);
            number(L"width", 1);
            o.SetNamedValue(L"closed", JsonValue::CreateBooleanValue(false));
            o.SetNamedValue(L"filled", JsonValue::CreateBooleanValue(false));
        }
        return o;
    }

    double LabelItemSize(JsonObject const &item)
    {
        std::string k = LabelItemKind(item);
        if (k == "text")
            return NumberOf(item, L"size", 0);
        if (k == "line")
            return NumberOf(item, L"length", 0);
        if (k == "bar")
            return NumberOf(item, L"width", 0);
        if (k == "ring")
            return 2 * NumberOf(item, L"outer", 0);
        if (k == "ticks")
            return 2 * (NumberOf(item, L"radius", 0) + std::max(NumberOf(item, L"length", 0), NumberOf(item, L"length_end", 0)));
        if (k == "polyline" && item.HasKey(L"points") && item.GetNamedValue(L"points").ValueType() == JsonValueType::Array)
        {
            JsonArray a = item.GetNamedArray(L"points");
            double lo = std::numeric_limits<double>::infinity(), hi = -lo;
            for (uint32_t i = 0; i < a.Size(); i++)
            {
                IJsonValue q = a.GetAt(i);
                if (q.ValueType() != JsonValueType::Array || q.GetArray().Size() < 2 || q.GetArray().GetAt(0).ValueType() != JsonValueType::Number)
                    continue;
                double x = q.GetArray().GetAt(0).GetNumber();
                lo = std::min(lo, x);
                hi = std::max(hi, x);
            }
            return hi >= lo ? hi - lo : 0;
        }
        return 0;
    }

    JsonObject LabelChangeShape(JsonObject const &item, std::string const &kind)
    {
        std::string now = LabelItemKind(item);
        if (now == kind)
            return CopyObject(item);
        double div = now == "text" ? 1 : now == "ring" ? 2 : 4;
        JsonObject out = LabelNewItem(kind, std::max(0.5, LabelItemSize(item) / div));
        double at[2];
        if (VectorOf(item, L"at", at, 2))
            LabelItemSetAt(out, at[0], at[1]);
        double angle = NumberOf(item, L"angle", 0);
        if (angle != 0)
            out.SetNamedValue(L"angle", JsonValue::CreateNumberValue(angle));
        return out;
    }

    void LabelOwnItems(Label &l)
    {
        JsonArray copy;
        for (size_t i = 0; i < LabelItemCount(l); i++)
        {
            JsonObject item = LabelItem(l, i);
            if (item != nullptr)
                copy.Append(CopyObject(item));
        }
        l.items = copy;
    }

    void LabelScale(Label &l, double k)
    {
        LabelOwnItems(l);
        for (size_t i = 0; i < LabelItemCount(l); i++)
        {
            JsonObject item = LabelItem(l, i);
            for (char const *field : LengthFields(LabelItemKind(item)))
            {
                hstring key = Key(field);
                if (item.HasKey(key))
                    item.SetNamedValue(key, JsonValue::CreateNumberValue(NumberOf(item, key, 0) * k));
            }
            double at[2];
            if (VectorOf(item, L"at", at, 2))
                LabelItemSetAt(item, at[0] * k, at[1] * k);
            if (item.HasKey(L"points") && item.GetNamedValue(L"points").ValueType() == JsonValueType::Array)
            {
                JsonArray a = item.GetNamedArray(L"points");
                JsonArray b;
                for (uint32_t j = 0; j < a.Size(); j++)
                {
                    IJsonValue q = a.GetAt(j);
                    if (q.ValueType() != JsonValueType::Array || q.GetArray().Size() < 2)
                        continue;
                    b.Append(PointArray(q.GetArray().GetAt(0).GetNumber() * k, q.GetArray().GetAt(1).GetNumber() * k));
                }
                item.SetNamedValue(L"points", b);
            }
        }
    }

    std::wstring LabelTitle(Label const &l)
    {
        if (!l.name.empty())
            return ToWide(l.name);
        for (size_t i = 0; i < LabelItemCount(l); i++)
        {
            JsonObject item = LabelItem(l, i);
            if (LabelItemKind(item) != "text")
                continue;
            std::wstring text = LabelItemText(item);
            size_t a = text.find_first_not_of(L" \t\r\n");
            if (a == std::wstring::npos)
                continue;
            size_t b = text.find_last_not_of(L" \t\r\n");
            return L"“" + text.substr(a, b - a + 1) + L"”";
        }
        std::wstring out;
        bool seen[label_kind_count] = {};
        for (size_t i = 0; i < LabelItemCount(l); i++)
        {
            std::string kind = LabelItemKind(LabelItem(l, i));
            for (size_t j = 0; j < label_kind_count; j++)
            {
                if (kind != label_kinds[j] || seen[j])
                    continue;
                seen[j] = true;
                if (!out.empty())
                    out += L" and ";
                out += label_kind_names[j];
            }
        }
        return out.empty() ? L"Empty label" : out;
    }

    void LabelUp(Label const &l, double up[3])
    {
        Cross(l.normal, l.right, up);
    }

    void LabelLevelRight(double const n[3], double out[3])
    {
        if (std::abs(n[2]) <= 0.7)
        {
            double r[3] = { -n[1], n[0], 0 };
            if (Unit(r))
            {
                std::memcpy(out, r, sizeof r);
                return;
            }
            out[0] = 1;
            out[1] = out[2] = 0;
            return;
        }
        double r[3] = { 1 - n[0] * n[0], -n[0] * n[1], -n[0] * n[2] };
        if (Unit(r))
        {
            std::memcpy(out, r, sizeof r);
            return;
        }
        double s[3] = { -n[1] * n[0], 1 - n[1] * n[1], -n[1] * n[2] };
        Unit(s);
        std::memcpy(out, s, sizeof s);
    }

    double LabelAngle(Label const &l)
    {
        double ref[3], ref_up[3];
        LabelLevelRight(l.normal, ref);
        Cross(l.normal, ref, ref_up);
        return std::atan2(Dot(l.right, ref_up), Dot(l.right, ref)) * 180 / pi;
    }

    void LabelSetAngle(Label &l, double degrees)
    {
        double a = degrees * pi / 180, ref[3], ref_up[3], r[3];
        LabelLevelRight(l.normal, ref);
        Cross(l.normal, ref, ref_up);
        for (int k = 0; k < 3; k++)
            r[k] = ref[k] * std::cos(a) + ref_up[k] * std::sin(a);
        if (Unit(r))
            std::memcpy(l.right, r, sizeof r);
    }

    void LabelTurn(Label &l, double degrees)
    {
        double a = degrees * pi / 180, up[3], r[3];
        LabelUp(l, up);
        for (int k = 0; k < 3; k++)
            r[k] = l.right[k] * std::cos(a) + up[k] * std::sin(a);
        if (Unit(r))
            std::memcpy(l.right, r, sizeof r);
    }

    void LabelMove(Label &l, double const origin[3], double const normal[3])
    {
        double n[3] = { normal[0], normal[1], normal[2] };
        if (!Unit(n))
            std::memcpy(n, l.normal, sizeof n);
        double d = Dot(l.right, n);
        double r[3] = { l.right[0] - d * n[0], l.right[1] - d * n[1], l.right[2] - d * n[2] };
        if (!Unit(r))
            LabelLevelRight(n, r);
        std::memcpy(l.origin, origin, sizeof l.origin);
        std::memcpy(l.normal, n, sizeof n);
        std::memcpy(l.right, r, sizeof r);
    }

    bool LabelPlaneHit(Label const &l, double const o[3], double const d[3], double p[3], double *x, double *y)
    {
        double den = Dot(d, l.normal);
        if (std::abs(den) < 1e-9)
            return false;
        double to[3] = { l.origin[0] - o[0], l.origin[1] - o[1], l.origin[2] - o[2] };
        double t = Dot(to, l.normal) / den;
        if (!(t > 0))
            return false;
        double up[3], v[3];
        LabelUp(l, up);
        for (int k = 0; k < 3; k++)
        {
            p[k] = o[k] + d[k] * t;
            v[k] = p[k] - l.origin[k];
        }
        *x = Dot(v, l.right);
        *y = Dot(v, up);
        return true;
    }

    void LabelToBed(Label const &l, double x, double y, double lift, double out[3])
    {
        double up[3];
        LabelUp(l, up);
        for (int k = 0; k < 3; k++)
            out[k] = l.origin[k] + x * l.right[k] + y * up[k] + lift * l.normal[k];
    }

    int LabelNextFilament(int base, int count)
    {
        if (count <= 1)
            return 1;
        if (base + 1 <= count)
            return base + 1;
        return base == 1 ? 2 : 1;
    }
}
