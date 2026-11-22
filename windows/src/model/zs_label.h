#pragma once
// The model of a label of the Label tool: its JSON, its frame, and its
// shapes. It follows linux/src/ui/label-model.c.
//
// A label is a 2D shape on the surface of a part (include/zslice-app.h,
// "the labels of a part"). Its frame is an origin, a normal (out of the
// part), and a right (the +x axis of the shape). up = normal x right is its
// +y axis. Its items stay JSON objects, so a field that the card does not
// show goes back to the core as it came.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include <winrt/Windows.Data.Json.h>

namespace zs
{
    namespace Json = winrt::Windows::Data::Json;

    // The face curves more than this (degrees) under a label: the label
    // stretches, and the card says so.
    inline constexpr double label_curve_limit = 60.0;
    inline constexpr wchar_t label_curve_text[] = L"The face curves too much here; the label stretches.";

    // The kinds of the shapes, in the order of the chips of the card.
    inline constexpr size_t label_kind_count = 6;
    extern char const *const label_kinds[label_kind_count];
    extern wchar_t const *const label_kind_names[label_kind_count];

    // The modes of a label: their names in the JSON and on the card.
    enum LabelMode { label_ink, label_raised, label_cut, label_mode_count };
    extern char const *const label_modes[label_mode_count];
    extern wchar_t const *const label_mode_names[label_mode_count];
    // The relief of a raised or cut label with a relief of 0 (the core).
    inline constexpr double label_default_relief = 0.6;
    // The height of a new SVG shape, mm.
    inline constexpr double label_svg_size = 15.0;
    // The snap distance of the smart guides, points of the screen.
    inline constexpr double label_snap_px = 6.0;

    // A number field of a kind: its name on the card, unit, range, and tip.
    struct LabelField
    {
        char const *field;
        wchar_t const *name;
        wchar_t const *unit;
        double min, max, step;
        wchar_t const *tip;
    };
    LabelField const *LabelFields(std::string_view kind, size_t &n);

    struct Label
    {
        uint32_t id = 0;
        std::string name;
        double origin[3] = { 0, 0, 0 };
        double normal[3] = { 0, 0, 1 };
        double right[3] = { 1, 0, 0 };
        int filament = 1; // from 1
        double depth = 0; // mm; 0 is one line width
        bool has_stretch = false;
        double stretch[2] = { 1, 1 };
        int mode = label_ink;
        double relief = 0; // mm; 0 is label_default_relief
        // The shapes. A copy of a Label shares them until LabelOwnItems.
        Json::JsonArray items;
    };

    // The labels of a JSON array, or of one label (an object). A label with
    // a bad frame is left out. False for bad JSON.
    bool LabelsParse(std::string const &json, std::vector<Label> &out);
    // The whole label, or with `shapes_only` its items and its stretch (for
    // zs_label_outline, and as the key of an outline).
    std::string LabelJson(Label const &l, bool shapes_only);

    size_t LabelItemCount(Label const &l);
    // Item i, or null.
    Json::JsonObject LabelItem(Label const &l, size_t i);
    std::string LabelItemKind(Json::JsonObject const &item);
    double LabelItemNumber(Json::JsonObject const &item, char const *field, double fallback);
    bool LabelItemFlag(Json::JsonObject const &item, char const *field);
    std::wstring LabelItemText(Json::JsonObject const &item);
    void LabelItemSetNumber(Json::JsonObject const &item, char const *field, double value);
    void LabelItemSetFlag(Json::JsonObject const &item, char const *field, bool value);
    void LabelItemSetText(Json::JsonObject const &item, std::wstring const &text);
    void LabelItemSetAt(Json::JsonObject const &item, double x, double y);
    double LabelItemAt(Json::JsonObject const &item, int k);
    void LabelItemSetPoints(Json::JsonObject const &item, std::vector<double> const &xy);
    // A new item of a kind. size is the cap height of the label's text, mm.
    Json::JsonObject LabelNewItem(std::string const &kind, double size);
    // An item of another kind at the same place, with about the same size.
    Json::JsonObject LabelChangeShape(Json::JsonObject const &item, std::string const &kind);
    double LabelItemSize(Json::JsonObject const &item);
    // Replaces the items with copies, so an edit leaves the original alone.
    void LabelOwnItems(Label &l);
    // Scales the lengths, places, and points of all items by k.
    void LabelScale(Label &l, double k);
    // Its name, its text in quotes, or the names of its shapes.
    std::wstring LabelTitle(Label const &l);

    void LabelUp(Label const &l, double up[3]);
    // The right at a turn of 0 for normal n: level on a side face, else the
    // X axis of the bed in the plane.
    void LabelLevelRight(double const n[3], double out[3]);
    double LabelAngle(Label const &l);
    void LabelSetAngle(Label &l, double degrees);
    // Turns the label about its normal, counterclockwise from the front.
    void LabelTurn(Label &l, double degrees);
    // A new point and normal of the surface. Right keeps its direction, put
    // into the new plane.
    void LabelMove(Label &l, double const origin[3], double const normal[3]);
    // The point of the plane on a ray: p in the frame of the bed, and x, y
    // along right and up. False if the ray misses it.
    bool LabelPlaneHit(Label const &l, double const o[3], double const d[3], double p[3], double *x, double *y);
    // A point of the plane in the frame of the bed, lift mm out of the face.
    void LabelToBed(Label const &l, double x, double y, double lift, double out[3]);
    // The filament of a new label on a part in filament base (from 1).
    int LabelNextFilament(int base, int count);

    // ---- the handles and the smart guides ----
    //
    // The selected label has a frame on the surface, a square at each
    // corner (a drag resizes it), and a round handle over it (a drag turns
    // it). The sizes are points of the screen. mpp is the mm of the plane in
    // one point.
    struct LabelHandles
    {
        double box[4]; // the frame: s0, t0, s1, t1 (mm)
        double hs;     // the half side of a corner square
        double turn[2], r; // the turn handle
    };
    void LabelHandlesOf(double const box[4], double mpp, LabelHandles &g);
    // The handle at (x, y) of the plane: 1 a corner (corner gets [sx, sy],
    // +1 the high side), 2 the turn handle, 0 none.
    int LabelHandleHit(LabelHandles const &g, double x, double y, int corner[2]);
    // A resize from a corner of box b0 to the point p of the plane. The
    // opposite corner (anchor) stays. free: each axis on its own, else one
    // scale. box gets the new box, and k the scales.
    void LabelResizeBox(double const b0[4], int const corner[2], double const p[2], bool free, double box[4], double anchor[2], double k[2]);
    // Resizes a label by k about the point anchor of its plane. One scale
    // changes the sizes of the shapes. Two scales change the stretch.
    void LabelResize(Label &l, double const anchor[2], double const k[2], bool free);
    // Turns the label by degrees about the point c of its plane.
    void LabelTurnAbout(Label &l, double degrees, double const c[2]);
    // An SVG shape of a source, at the height of a new shape.
    Json::JsonObject LabelSvgItem(std::wstring const &svg);
    // The SVG source as a shape of the label: in place of the new text
    // "LABEL", else under the shapes. box is the outline box, or null.
    void LabelAddSvg(Label &l, std::wstring const &svg, double const box[4]);
    // The name of a label of an SVG file: the file name with no ".svg", at
    // most 120 bytes of UTF-8.
    std::string LabelSvgName(std::wstring const &path);
    // Label l is in the plane of (origin, normal): the normals within 2.5
    // degrees, and the origin within 0.2 mm of the plane.
    bool LabelSamePlane(double const origin[3], double const normal[3], Label const &l);

    // Another label for the snap: its frame and its outline box.
    struct LabelSnapOther
    {
        Label const *label;
        double box[4];
    };
    // The JSON of zs_label_snap. corner is null for a move. face is the JSON
    // of zs_label_face, or null.
    std::string LabelSnapJson(Label const &l, double const box[4], char const *op, int const *corner, bool aspect, double tol,
                              std::vector<LabelSnapOther> const &others, std::string const *face);
    // The answer of zs_label_snap: the box, the move, and the guide lines
    // (s0, t0, s1, t1 each). False for bad JSON.
    bool LabelSnapParse(std::string const &json, double box[4], double d[2], std::vector<double> &guides);
}
