// The Support tool (S) of the main window, the support editor. It follows
// the GTK shell (linux/src/ui/support-tool.c) and has the same words.
//
// - A click on an overhang puts support under it. Alt and a click draw an
//   area point by point. Click the first point again, or press Enter, to
//   close the area. Backspace removes the last point. Esc stops.
// - A click on an outline selects its area. A drag of a point moves it.
//   The outline follows the pointer at once, and the slices wait for the
//   release, so a drag is one slice and one step of the history.
// - The nodes of the trees show as dots. A drag of a dot moves the node, a
//   drag of the ring of the selected node makes the branch wider or
//   narrower, and a drag of a segment moves the branch. The core keeps each
//   edit within the rules, and an edit that a rule limited shows red.
// - The Select tool can pick a support line with this tool off. The card
//   then says what the support is, and has Remove this support.
//
// The core keeps the areas and the trees (zs_app_support_*). This file keeps
// a copy for the view, and reads it again after a change, an undo, a load of
// the view, and a switch of the plate. During a drag the copy leads.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>
#include <cstdarg>
#include <cwchar>
#include <limits>
#include <unordered_set>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Primitives = Microsoft::UI::Xaml::Controls::Primitives;
using Microsoft::UI::Input::InputSystemCursor;
using Microsoft::UI::Input::InputSystemCursorShape;
using Windows::System::VirtualKey;

namespace
{
    // The most points of an area (support_areas.max_points in the core).
    constexpr size_t max_points = 256;
    // The distance from a point or an outline that still hits it, in points.
    constexpr double near_dist = 10.0;
    // The smallest distance on the screen between two dots that the view
    // draws, in points. More dots add no help.
    constexpr double dot_cell = 7.0;

    enum
    {
        kind_grid = ZS_MARK_GRID,
        kind_tree = ZS_MARK_TREE,
        kind_block = ZS_MARK_BLOCK,
        // The kind of the view for a tree that a rule limited: red.
        kind_red = ZS_MARK_BLOCK,
    };

    // The flags of zs_view_support_add.
    enum
    {
        flag_closed = 1,
        flag_selected = 2,
        flag_points = 4,
        flag_bare = 8,
    };

    // The drag of a tree element.
    enum
    {
        hit_none = 0,
        hit_node,
        hit_ring,
        hit_seg,
    };

    struct KindInfo
    {
        int kind;
        wchar_t const *name;
        wchar_t const *tip;
    };

    KindInfo const kinds[] = {
        { kind_grid, L"Support grid", L"Support grid: support under all of the part in this area that faces down" },
        { kind_tree, L"Support tree", L"Support tree: support under all of the part in this area that faces down" },
        { kind_block, L"Block", L"No support under this area" },
    };

    // The clamp bits (enum zs_tree_clamp), in words.
    struct ClampText
    {
        uint32_t bit;
        wchar_t const *text;
    };

    ClampText const clamp_text[] = {
        { ZS_TREE_CLAMP_PART, L"it stays out of the part" },
        { ZS_TREE_CLAMP_LEAN, L"a segment leans at most the tree angle" },
        { ZS_TREE_CLAMP_RADIUS_MIN, L"the rules need this width" },
        { ZS_TREE_CLAMP_RADIUS_MAX, L"this is the largest width" },
        { ZS_TREE_CLAMP_REACH, L"the foot moved nearer, so the branch can reach the tip" },
    };

    std::wstring Format(wchar_t const *format, ...)
    {
        wchar_t text[1024];
        va_list args;
        va_start(args, format);
        int n = vswprintf_s(text, format, args);
        va_end(args);
        return n > 0 ? std::wstring(text, (size_t)n) : std::wstring();
    }

    // The distance from x, y to the segment a-b.
    double SegDist(double x, double y, double ax, double ay, double bx, double by)
    {
        double dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
        double t = l2 > 0 ? std::clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0.0, 1.0) : 0;
        return std::hypot(x - ax - t * dx, y - ay - t * dy);
    }

    // The points of the ring of a node: on its circle, at its z.
    void RingPoints(zs_tree_node const &nd, int count, double *out)
    {
        double const pi = 3.14159265358979323846;
        for (int k = 0; k < count; k++)
        {
            double a = 2 * pi * k / count;
            out[3 * k] = nd.x + nd.r * std::cos(a);
            out[3 * k + 1] = nd.y + nd.r * std::sin(a);
            out[3 * k + 2] = nd.z;
        }
    }

    void SetShown(UIElement const &element, bool shown)
    {
        element.Visibility(shown ? Visibility::Visible : Visibility::Collapsed);
    }

    Media::SolidColorBrush Brush(uint8_t r, uint8_t g, uint8_t b)
    {
        return Media::SolidColorBrush(Windows::UI::Color{ 255, r, g, b });
    }

    // The buttons of the card take no focus, so the keys stay with the view.
    template <typename T>
    void NoFocus(T const &control)
    {
        control.IsTabStop(false);
        control.AllowFocusOnInteraction(false);
    }

    TextBlock InfoText()
    {
        TextBlock text;
        text.TextWrapping(TextWrapping::WrapWholeWords);
        text.FontSize(12);
        text.Foreground(Brush(0x5B, 0x61, 0x68));
        return text;
    }
}

namespace winrt::ZSlice::implementation
{
    struct MainWindow::SupportTool
    {
        struct Area
        {
            int kind = 0;
            double z_lo = 0, z_hi = 0;
            std::vector<double> pts;
            size_t Count() const { return pts.size() / 3; }
        };

        // The trees of a part.
        struct Tree
        {
            size_t part = 0;
            bool edited = false;
            std::vector<zs_tree_node> nodes;
        };

        using Clock = std::chrono::steady_clock;

        explicit SupportTool(MainWindow &owner) : w(owner) {}

        MainWindow &w;
        std::vector<Area> areas;
        std::vector<double> draft;
        int sel = -1;
        int kind = kind_grid; // the kind of the next area
        bool see = true;      // the support lines are faint while the tool is on
        bool on = false;
        bool focus_set = false;
        // A message on the card until the next change, or null.
        wchar_t const *note = nullptr;
        // The drag of a point: the area (-1: none) and the point.
        int drag_area = -1, drag_point = 0;
        bool drag_moved = false;
        // The overhang under the pointer. A click puts support under it.
        bool hot = false;
        std::vector<double> hot_pts;
        double hot_lo = 0, hot_hi = 0;
        // The app of the plate of the areas: a new plate drops the draft.
        zs_app *core = nullptr;

        // The trees by part, the selected node (tsel_part -1: none), the
        // rules that limited the last edit, and "Add a branch".
        std::vector<Tree> trees;
        zs_app *trees_core = nullptr;
        int64_t tsel_part = -1;
        uint32_t tsel_node = 0;
        uint32_t tclamp = 0;
        bool adding = false, has_foot = false;
        double foot[2] = {};
        std::wstring tree_note;

        // The drag of a tree element: its kind, part, and node, the height
        // of its plane, the start point on it, the nodes that move and
        // their places at the start, the move that the core applied, the
        // move or radius that the pointer wants, and the time of the last
        // edit sent (60 ms apart).
        int td = hit_none;
        size_t td_part = 0;
        uint32_t td_node = 0;
        double td_z = 0, td_start[2] = {}, td_applied[2] = {}, want_r = 0, want_dx = 0, want_dy = 0;
        std::vector<uint32_t> td_branch;
        std::vector<double> td_orig;
        bool td_moved = false, td_dirty = false, td_releasing = false;
        Clock::time_point td_sent{}, td_live{};
        Microsoft::UI::Dispatching::DispatcherQueueTimer td_timer{ nullptr };

        // The support that the Select tool picked, with the tool off:
        // lite_tree for a tree (tsel is its node), and the overhang over
        // the line for a grid.
        bool lite = false, lite_tree = false;
        double lite_pt[3] = {};
        std::vector<double> lite_pts;
        double lite_lo = 0, lite_hi = 0;

        // The card.
        Border card{ nullptr };
        TextBlock title{ nullptr }, info{ nullptr }, tree_info{ nullptr };
        Grid kinds_row{ nullptr }, tree_row{ nullptr };
        std::vector<Primitives::ToggleButton> kind_buttons;
        CheckBox see_box{ nullptr };
        Primitives::ToggleButton tree_add{ nullptr };
        Button tree_reset{ nullptr }, tree_del{ nullptr }, del{ nullptr };
        int64_t reset_part = -1;
        int cursor_shape = -1;

        zs_app *App() const { return w.model != nullptr ? w.model->Active() : nullptr; }
        bool Live() const { return on || lite; }
        bool Holding() const { return drag_area >= 0 || td != hit_none; }
        Area *AreaAt(int i) { return i >= 0 && (size_t)i < areas.size() ? &areas[(size_t)i] : nullptr; }

        Tree *TreeOf(size_t part)
        {
            for (auto &t : trees)
                if (t.part == part)
                    return &t;
            return nullptr;
        }

        zs_tree_node *NodeOf(size_t part, uint32_t i)
        {
            Tree *t = TreeOf(part);
            return t != nullptr && i < t->nodes.size() ? &t->nodes[i] : nullptr;
        }

        bool TselOk() { return tsel_part >= 0 && NodeOf((size_t)tsel_part, tsel_node) != nullptr; }

        // ---- the history and the slice ----

        void Commit()
        {
            w.history_timer.Stop();
            if (w.model->HistoryCommit())
                w.RefreshHistoryButtons();
        }

        // A change of the support: a slice, and a step of the history (at
        // the release of a drag).
        void Changed()
        {
            w.model->RequestSlice();
            if (!Holding())
                Commit();
        }

        // An edit that can take away what holds a part: it falls.
        void ChangedMayFall()
        {
            Changed();
            if (!Holding())
                w.CheckFall();
        }

        // A change before this edit is its own step of the history.
        void Flush()
        {
            if (zs_app_history_pending(App()))
                Commit();
        }

        void BeginHold()
        {
            Flush();
            w.model->Hold(true);
        }

        void EndHold()
        {
            w.model->Hold(false);
            if (zs_app_history_pending(App()))
                Commit();
            w.CheckFall();
        }

        // ---- the areas of the core ----

        void ReadAreas()
        {
            zs_app *app = App();
            if (app != core)
            {
                core = app;
                draft.clear();
                sel = -1;
            }
            size_t n = app != nullptr ? zs_app_support_area_count(app) : 0;
            areas.clear();
            std::vector<double> buffer(3 * max_points);
            for (size_t i = 0; i < n; i++)
            {
                Area a;
                size_t count = 0;
                if (zs_app_support_area_get(app, i, &a.kind, buffer.data(), max_points, &count, &a.z_lo, &a.z_hi) != ZS_OK)
                    continue;
                count = std::min(count, max_points);
                a.pts.assign(buffer.begin(), buffer.begin() + (ptrdiff_t)(3 * count));
                areas.push_back(std::move(a));
            }
            if (sel >= (int)areas.size())
                sel = -1;
        }

        // ---- the trees ----

        // The trees of a part from the core (none with no nodes). While a
        // slice runs, the core has none to give, and the last ones stay.
        void ReadTree(size_t part)
        {
            zs_app *app = App();
            ptrdiff_t n = app != nullptr ? zs_app_support_tree_nodes(app, part, nullptr, 0) : 0;
            if (n < 0)
                return;
            Tree *t = TreeOf(part);
            if (n == 0)
            {
                if (t != nullptr)
                    trees.erase(trees.begin() + (t - trees.data()));
                return;
            }
            if (t == nullptr)
            {
                trees.emplace_back();
                t = &trees.back();
                t->part = part;
            }
            t->nodes.resize((size_t)n);
            ptrdiff_t got = zs_app_support_tree_nodes(app, part, t->nodes.data(), (size_t)n);
            t->nodes.resize(got < 0 ? 0 : std::min((size_t)got, (size_t)n));
            t->edited = zs_app_support_tree_edited(app, part) == 1;
        }

        // The trees of each part, only while they show.
        void ReadTrees()
        {
            if (td != hit_none)
                return;
            zs_app *app = App();
            if (!Live() || app == nullptr || app != trees_core)
                trees.clear();
            trees_core = app;
            if (!Live() || app == nullptr)
                return;
            size_t parts = zs_app_part_count(app);
            trees.erase(std::remove_if(trees.begin(), trees.end(), [parts](Tree const &t) { return t.part >= parts; }), trees.end());
            for (size_t i = 0; i < parts; i++)
                ReadTree(i);
            char text[512];
            if (zs_app_support_tree_note(app, text, sizeof text) > 0)
                tree_note = zs::ToWide(text);
            if (!TselOk())
                tsel_part = -1;
            // The picked tree went (an undo): the pick ends.
            if (!on && lite && lite_tree && tsel_part < 0)
                lite = false;
        }

        // With the tool off: a mask of the nodes of the tree of the
        // selected node. A tree is all nodes with the same root, the node
        // at the bottom of the chain of `down` links. False with the tool
        // on: all nodes count.
        bool LiteMask(std::vector<uint8_t> &mask, size_t &part)
        {
            if (on || !lite || !lite_tree || !TselOk())
                return false;
            Tree const *t = TreeOf((size_t)tsel_part);
            size_t n = t->nodes.size();
            std::vector<int32_t> root(n, -1);
            for (size_t k = 0; k < n; k++)
            {
                uint32_t r = (uint32_t)k;
                for (size_t steps = 0; steps <= n; steps++)
                {
                    if (root[r] >= 0)
                    {
                        r = (uint32_t)root[r];
                        break;
                    }
                    int32_t d = t->nodes[r].down;
                    if (d < 0 || (size_t)d >= n)
                        break;
                    r = (uint32_t)d;
                }
                // The chain from k gets the root.
                for (uint32_t c = (uint32_t)k; root[c] < 0;)
                {
                    root[c] = (int32_t)r;
                    int32_t d = t->nodes[c].down;
                    if (d < 0 || (size_t)d >= n)
                        break;
                    c = (uint32_t)d;
                }
            }
            mask.assign(n, 0);
            int32_t want = root[tsel_node];
            for (size_t k = 0; k < n; k++)
                mask[k] = root[k] == want ? 1 : 0;
            part = (size_t)tsel_part;
            return true;
        }

        // The nodes of the branch of node i.
        std::vector<uint32_t> BranchOf(size_t part, uint32_t i)
        {
            std::vector<uint32_t> out;
            Tree *t = TreeOf(part);
            zs_tree_node *nd = NodeOf(part, i);
            if (t == nullptr || nd == nullptr)
                return out;
            for (size_t k = 0; k < t->nodes.size(); k++)
                if (t->nodes[k].branch == nd->branch)
                    out.push_back((uint32_t)k);
            return out;
        }

        static bool InBranch(std::vector<uint32_t> const &b, uint32_t k)
        {
            return std::find(b.begin(), b.end(), k) != b.end();
        }

        // ---- picks ----

        // The point (in points of the view) of a point of the world.
        bool PixelOf(double const *p, double &x, double &y)
        {
            float qx, qy;
            if (w.view == nullptr || !zs_view_pixel_of(w.view, p[0], p[1], p[2], &qx, &qy))
                return false;
            double s = w.Scale();
            x = qx / s;
            y = qy / s;
            return true;
        }

        // The point of the part under x, y. snap: to the end of a line.
        bool SurfacePoint(double x, double y, bool snap, double out[3])
        {
            double s = w.Scale();
            return w.view != nullptr && zs_view_surface_point(w.view, (float)(x * s), (float)(y * s), snap ? 1 : 0, out) != 0;
        }

        // The point of the level plane at height z under x, y.
        bool PlanePoint(double x, double y, double z, double out[2])
        {
            double s = w.Scale();
            return w.view != nullptr && zs_view_plane_point(w.view, (float)(x * s), (float)(y * s), z, &out[0], &out[1]) != 0;
        }

        // The point of an area near x, y, the selected area first.
        bool PointAt(double x, double y, int &area, int &point)
        {
            for (int pass = 0; pass < 2; pass++)
            {
                for (size_t i = 0; i < areas.size(); i++)
                {
                    if ((pass == 0) != ((int)i == sel))
                        continue;
                    Area const &a = areas[i];
                    for (size_t j = 0; j < a.Count(); j++)
                    {
                        double qx, qy;
                        if (PixelOf(&a.pts[3 * j], qx, qy) && std::hypot(qx - x, qy - y) < near_dist)
                        {
                            area = (int)i;
                            point = (int)j;
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        // The area whose outline is near x, y, or -1.
        int OutlineAt(double x, double y)
        {
            int best = -1;
            double best_d = near_dist;
            for (size_t i = 0; i < areas.size(); i++)
            {
                Area const &a = areas[i];
                size_t n = a.Count();
                for (size_t j = 0; j < n; j++)
                {
                    double ax, ay, bx, by;
                    if (!PixelOf(&a.pts[3 * j], ax, ay) || !PixelOf(&a.pts[3 * ((j + 1) % n)], bx, by))
                        continue;
                    double d = SegDist(x, y, ax, ay, bx, by);
                    if (d < best_d)
                    {
                        best_d = d;
                        best = (int)i;
                    }
                }
            }
            return best;
        }

        // The tree element under x, y: the ring of the selected node
        // first, then the dots, then the segments (node to its down node).
        int TreeAt(double x, double y, size_t &part, uint32_t &node)
        {
            if (trees.empty())
                return hit_none;
            double cx, cy;
            // The ring of a thin node is near its dot: the dot wins near
            // its center.
            if (TselOk())
            {
                zs_tree_node const &nd = *NodeOf((size_t)tsel_part, tsel_node);
                if (!(PixelOf(&nd.x, cx, cy) && std::hypot(cx - x, cy - y) < near_dist * 0.5))
                {
                    double ring[3 * 16];
                    RingPoints(nd, 16, ring);
                    for (int k = 0; k < 16; k++)
                    {
                        double ax, ay, bx, by;
                        if (PixelOf(&ring[3 * k], ax, ay) && PixelOf(&ring[3 * ((k + 1) % 16)], bx, by) &&
                            SegDist(x, y, ax, ay, bx, by) < near_dist * 0.7)
                        {
                            part = (size_t)tsel_part;
                            node = tsel_node;
                            return hit_ring;
                        }
                    }
                }
            }
            int found = hit_none;
            double best = near_dist;
            size_t only = 0;
            std::vector<uint8_t> mask;
            bool masked = LiteMask(mask, only);
            for (auto const &t : trees)
            {
                if (masked && t.part != only)
                    continue;
                for (size_t k = 0; k < t.nodes.size(); k++)
                {
                    if (masked && !mask[k])
                        continue;
                    double qx, qy;
                    if (!PixelOf(&t.nodes[k].x, qx, qy))
                        continue;
                    double d = std::hypot(qx - x, qy - y);
                    if (d < best)
                    {
                        best = d;
                        found = hit_node;
                        part = t.part;
                        node = (uint32_t)k;
                    }
                }
            }
            if (found != hit_none)
                return found;
            best = near_dist * 0.7;
            for (auto const &t : trees)
            {
                if (masked && t.part != only)
                    continue;
                for (size_t k = 0; k < t.nodes.size(); k++)
                {
                    if (masked && !mask[k])
                        continue;
                    zs_tree_node const &nd = t.nodes[k];
                    if (nd.down < 0 || (size_t)nd.down >= t.nodes.size())
                        continue;
                    double ax, ay, bx, by;
                    if (!PixelOf(&nd.x, ax, ay) || !PixelOf(&t.nodes[(size_t)nd.down].x, bx, by))
                        continue;
                    double d = SegDist(x, y, ax, ay, bx, by);
                    if (d < best)
                    {
                        best = d;
                        found = hit_seg;
                        part = t.part;
                        node = (uint32_t)k;
                    }
                }
            }
            return found;
        }

        // ---- the view ----

        // Dots: at most 256 to a call of the view.
        void AddDots(std::vector<double> const &pts, int dot_kind, int flags)
        {
            size_t n = pts.size() / 3;
            for (size_t i = 0; i < n; i += 256)
                zs_view_support_add(w.view, &pts[3 * i], std::min<size_t>(256, n - i), dot_kind, flag_bare | flag_points | flags);
        }

        // The trees to the core view: a dot for each node (one dot for
        // nodes closer than dot_cell on the screen), the segments of the
        // selected branch and into it, the ring of the selected node, and
        // the foot of a new branch.
        void ShowTrees()
        {
            if (!Live() || w.view == nullptr)
                return;
            int line_kind = tclamp != 0 ? kind_red : kind_tree;
            std::vector<uint32_t> branch;
            bool has_branch = TselOk();
            if (has_branch)
            {
                size_t part = (size_t)tsel_part;
                Tree const &t = *TreeOf(part);
                branch = BranchOf(part, tsel_node);
                for (size_t k = 0; k < t.nodes.size(); k++)
                {
                    zs_tree_node const &nd = t.nodes[k];
                    if (nd.down < 0 || (size_t)nd.down >= t.nodes.size())
                        continue;
                    bool inb = InBranch(branch, (uint32_t)k);
                    if (!inb && !InBranch(branch, (uint32_t)nd.down))
                        continue;
                    zs_tree_node const &dn = t.nodes[(size_t)nd.down];
                    double seg[6] = { nd.x, nd.y, nd.z, dn.x, dn.y, dn.z };
                    zs_view_support_add(w.view, seg, 2, line_kind, flag_bare | (inb ? flag_selected : 0));
                }
                std::vector<double> dots;
                for (uint32_t k : branch)
                {
                    if (k == tsel_node)
                        continue;
                    dots.insert(dots.end(), { t.nodes[k].x, t.nodes[k].y, t.nodes[k].z });
                }
                AddDots(dots, line_kind, 0);
                zs_tree_node const &sn = t.nodes[tsel_node];
                zs_view_support_add(w.view, &sn.x, 1, line_kind, flag_bare | flag_points | flag_selected);
                double ring[3 * 24];
                RingPoints(sn, 24, ring);
                zs_view_support_add(w.view, ring, 24, line_kind, flag_bare | flag_closed | flag_selected);
            }
            std::unordered_set<int64_t> seen;
            std::vector<double> dots;
            size_t only = 0;
            std::vector<uint8_t> mask;
            bool masked = LiteMask(mask, only);
            for (auto const &t : trees)
            {
                if (masked && t.part != only)
                    continue;
                for (size_t k = 0; k < t.nodes.size(); k++)
                {
                    if (masked && !mask[k])
                        continue;
                    if (has_branch && (int64_t)t.part == tsel_part && InBranch(branch, (uint32_t)k))
                        continue;
                    zs_tree_node const &nd = t.nodes[k];
                    double qx, qy;
                    if (!PixelOf(&nd.x, qx, qy))
                        continue;
                    int64_t key = (int64_t)std::floor(qx / dot_cell) * 65536 + (int64_t)std::floor(qy / dot_cell);
                    if (!seen.insert(key).second)
                        continue;
                    dots.insert(dots.end(), { nd.x, nd.y, nd.z });
                }
            }
            AddDots(dots, kind_tree, 0);
            if (adding && has_foot)
            {
                double f[3] = { foot[0], foot[1], 0 };
                zs_view_support_add(w.view, f, 1, kind_tree, flag_bare | flag_points | flag_selected);
            }
        }

        // The areas and the draft to the core view, and the card.
        void Show()
        {
            if (w.view != nullptr)
            {
                zs_view_support_clear(w.view);
                for (size_t i = 0; i < areas.size(); i++)
                {
                    Area const &a = areas[i];
                    int flags = flag_closed | ((int)i == sel ? flag_selected : 0) | (on ? flag_points : 0);
                    zs_view_support_add(w.view, a.pts.data(), a.Count(), a.kind, flags);
                }
                if (on && !draft.empty())
                    zs_view_support_add(w.view, draft.data(), draft.size() / 3, kind, flag_points);
                if (on && hot && draft.empty())
                    zs_view_support_add(w.view, hot_pts.data(), hot_pts.size() / 3, kind, flag_closed | flag_selected | flag_points);
                // The overhang of a grid support that the Select tool picked.
                if (!on && lite && !lite_tree && lite_pts.size() >= 9)
                    zs_view_support_add(w.view, lite_pts.data(), lite_pts.size() / 3, kind_grid, flag_closed | flag_selected);
                ShowTrees();
            }
            UpdateCard();
            w.RequestDraw();
        }

        void Reload()
        {
            // During a drag the copy leads: the view gets it again.
            if (Holding())
            {
                Show();
                return;
            }
            ReadAreas();
            ReadTrees();
            Show();
        }

        // See through the support: a focus on all features but the support.
        void ApplyFocus()
        {
            if (w.view == nullptr)
                return;
            uint32_t mask = 0;
            if (on && see)
                mask = ((1u << ZS_FEATURE_COUNT) - 1) & ~((1u << ZS_FEATURE_SUPPORT) | (1u << ZS_FEATURE_SUPPORT_INTERFACE));
            // No focus of this tool: the focus of another tool stays.
            if (mask == 0 && !focus_set)
                return;
            focus_set = mask != 0;
            zs_view_focus(w.view, mask, -1);
            w.RequestDraw();
        }

        // ---- the card ----

        void BuildCard()
        {
            card = Border();
            card.Width(300);
            card.Padding(ThicknessHelper::FromUniformLength(12));
            card.Background(Media::SolidColorBrush(Windows::UI::Color{ 0xFA, 0xFF, 0xFF, 0xFF }));
            card.BorderBrush(Brush(0xDD, 0xE0, 0xE4));
            card.BorderThickness(ThicknessHelper::FromUniformLength(1));
            card.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
            card.Visibility(Visibility::Collapsed);
            card.RequestedTheme(ElementTheme::Light);
            Automation::AutomationProperties::SetName(card, L"Support");

            StackPanel body;
            body.Spacing(6);
            title = TextBlock();
            title.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            title.Text(L"Draw support");
            body.Children().Append(title);

            kinds_row = Grid();
            kinds_row.ColumnSpacing(2);
            for (size_t k = 0; k < std::size(kinds); k++)
            {
                ColumnDefinition column;
                column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                kinds_row.ColumnDefinitions().Append(column);
                Primitives::ToggleButton b;
                b.Content(box_value(kinds[k].name));
                b.FontSize(12);
                b.Padding(ThicknessHelper::FromLengths(4, 4, 4, 4));
                b.HorizontalAlignment(HorizontalAlignment::Stretch);
                NoFocus(b);
                Automation::AutomationProperties::SetName(b, kinds[k].name);
                ToolTipService::SetToolTip(b, box_value(kinds[k].tip));
                Grid::SetColumn(b, (int32_t)k);
                int value = kinds[k].kind;
                b.Click([this, value](auto &&, auto &&) { SetKind(value); });
                kind_buttons.push_back(b);
                kinds_row.Children().Append(b);
            }
            body.Children().Append(kinds_row);

            see_box = CheckBox();
            see_box.Content(box_value(L"See through the support"));
            see_box.IsChecked(true);
            NoFocus(see_box);
            ToolTipService::SetToolTip(see_box, box_value(L"Show the support lines faint while the tool is on, so the outlines of the areas show through them"));
            see_box.Click([this](auto &&, auto &&) { SetSee(see_box.IsChecked().GetBoolean()); });
            body.Children().Append(see_box);

            info = InfoText();
            body.Children().Append(info);

            // The trees: Add a branch, Reset support, the text, Delete branch.
            tree_row = Grid();
            tree_row.ColumnSpacing(2);
            tree_row.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
            for (int k = 0; k < 2; k++)
            {
                ColumnDefinition column;
                column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                tree_row.ColumnDefinitions().Append(column);
            }
            tree_add = Primitives::ToggleButton();
            tree_add.Content(box_value(L"Add a branch"));
            tree_add.FontSize(12);
            tree_add.HorizontalAlignment(HorizontalAlignment::Stretch);
            NoFocus(tree_add);
            ToolTipService::SetToolTip(tree_add, box_value(L"Tap a spot on the bed, then the place on the part that needs support"));
            tree_add.Click([this](auto &&, auto &&) { SetAdding(tree_add.IsChecked().GetBoolean()); });
            tree_row.Children().Append(tree_add);
            tree_reset = Button();
            tree_reset.Content(box_value(L"Reset support"));
            tree_reset.FontSize(12);
            tree_reset.HorizontalAlignment(HorizontalAlignment::Stretch);
            NoFocus(tree_reset);
            ToolTipService::SetToolTip(tree_reset, box_value(L"Plan the support trees of this part again"));
            Grid::SetColumn(tree_reset, 1);
            tree_reset.Click([this](auto &&, auto &&) { ResetTrees(); });
            tree_row.Children().Append(tree_reset);
            body.Children().Append(tree_row);

            tree_info = InfoText();
            body.Children().Append(tree_info);

            tree_del = Button();
            tree_del.Content(box_value(L"Delete branch"));
            tree_del.FontSize(12);
            tree_del.Foreground(Brush(0xC4, 0x2B, 0x1C));
            NoFocus(tree_del);
            ToolTipService::SetToolTip(tree_del, box_value(L"Delete this branch and the branches over it (Delete)"));
            tree_del.Click([this](auto &&, auto &&) { DeleteBranch(); });
            body.Children().Append(tree_del);

            del = Button();
            del.Content(box_value(L"Delete"));
            del.FontSize(12);
            del.Foreground(Brush(0xC4, 0x2B, 0x1C));
            NoFocus(del);
            ToolTipService::SetToolTip(del, box_value(L"Delete this area (Delete)"));
            del.Click([this](auto &&, auto &&) {
                if (!on && lite)
                    RemoveLite();
                else
                    RemoveSelected();
            });
            body.Children().Append(del);

            card.Child(body);
            Canvas::SetLeft(card, 64);
            Canvas::SetTop(card, 10);
            w.CardLayer().Children().Append(card);

            td_timer = w.queue.CreateTimer();
            td_timer.IsRepeating(false);
            td_timer.Tick([this](auto &&, auto &&) { OnTreeTimer(); });
        }

        // The card of a support that the Select tool picked: what it is,
        // and Delete.
        void UpdateLiteCard()
        {
            SetShown(kinds_row, false);
            SetShown(see_box, false);
            SetShown(tree_row, false);
            SetShown(tree_info, false);
            title.Text(lite_tree ? L"Support tree" : L"Support");
            std::wstring text;
            if (lite_tree && TselOk())
            {
                zs_tree_node const &nd = *NodeOf((size_t)tsel_part, tsel_node);
                text = Format(L"A branch, %.1f mm wide, z %.1f mm. Drag a dot, a ring, or a segment to pull it. Right click a dot for Delete.", 2 * nd.r, nd.z);
            }
            else if (lite_pts.size() >= 9)
            {
                text = Format(L"It holds up the overhang in blue, z %.1f to %.1f mm.", lite_lo, lite_hi);
            }
            else
            {
                text = L"zslice found no overhang over this support.";
            }
            info.Text(text);
            SetShown(info, true);
            SetShown(tree_del, lite_tree && TselOk());
            del.Content(box_value(L"Remove this support"));
            ToolTipService::SetToolTip(del, box_value(L"No support under this overhang (Delete)"));
            SetShown(del, !lite_tree && lite_pts.size() >= 9);
        }

        void UpdateTreeCard()
        {
            bool any = !trees.empty() || adding;
            SetShown(tree_row, any);
            SetShown(tree_info, any);
            SetShown(tree_del, any && TselOk());
            if (!any)
                return;
            tree_add.IsChecked(adding);
            // Reset: the part of the selection, else the one part with edits.
            int64_t part = TselOk() ? tsel_part : -1;
            if (part < 0)
            {
                int edited = 0;
                for (auto const &t : trees)
                {
                    if (t.edited)
                    {
                        edited++;
                        part = (int64_t)t.part;
                    }
                }
                if (edited != 1)
                    part = -1;
            }
            Tree const *pt = part >= 0 ? TreeOf((size_t)part) : nullptr;
            SetShown(tree_reset, pt != nullptr && pt->edited);
            reset_part = part;
            std::wstring text;
            if (!tree_note.empty())
                text += tree_note + L" ";
            if (adding)
            {
                text += has_foot ? L"Now tap the place on the part that needs support. Esc stops."
                                 : L"Tap a spot on the bed for the foot of the branch. Esc stops.";
            }
            else if (TselOk())
            {
                zs_tree_node const &nd = *NodeOf((size_t)tsel_part, tsel_node);
                size_t count = BranchOf((size_t)tsel_part, tsel_node).size();
                text += Format(L"Branch: %zu node%s. This node: %.1f mm wide (at least %.1f mm), z %.2f mm. Drag a dot to move it, the ring to make it wider or narrower, a segment to move the branch. Delete removes the branch.",
                               count, count == 1 ? L"" : L"s", 2 * nd.r, 2 * nd.r_min, nd.z);
            }
            else
            {
                text += L"Click a dot or a segment of a tree to select its branch.";
            }
            if (tclamp != 0)
            {
                text += L" Limited: ";
                bool first = true;
                for (auto const &c : clamp_text)
                {
                    if ((tclamp & c.bit) == 0)
                        continue;
                    if (!first)
                        text += L"; ";
                    text += c.text;
                    first = false;
                }
                text += L".";
                tree_info.Foreground(Brush(0xB4, 0x53, 0x09));
            }
            else
            {
                tree_info.Foreground(Brush(0x5B, 0x61, 0x68));
            }
            tree_info.Text(text);
        }

        void UpdateCard()
        {
            if (card == nullptr)
                return;
            if (!on && lite)
            {
                SetShown(card, true);
                UpdateLiteCard();
                return;
            }
            SetShown(card, on);
            if (!on)
                return;
            SetShown(kinds_row, true);
            SetShown(see_box, true);
            del.Content(box_value(L"Delete"));
            ToolTipService::SetToolTip(del, box_value(L"Delete this area (Delete)"));
            Area const *a = AreaAt(sel);
            title.Text(a != nullptr ? Format(L"Support area %d", sel + 1) : std::wstring(L"Draw support"));
            int shown_kind = a != nullptr ? a->kind : kind;
            for (size_t k = 0; k < kind_buttons.size(); k++)
                kind_buttons[k].IsChecked(kinds[k].kind == shown_kind);
            see_box.IsChecked(see);
            UpdateTreeCard();
            std::wstring text;
            bool has_text = true;
            size_t n = draft.size() / 3;
            if (a != nullptr)
                text = Format(L"%zu points, z %.2f to %.2f mm. Drag a point to move it.", a->Count(), a->z_lo, a->z_hi);
            else if (note != nullptr)
                text = note;
            else if (adding || TselOk())
                has_text = false;
            else if (n == 0)
                text = L"Point at an overhang: it lights up, and a click puts support under it. Alt and a click draw an area point by point (Shift: no snap). Click an outline to select its area.";
            else if (n < 3)
                text = Format(L"%zu point%s. Click more points (at least 3). Backspace removes the last one; Esc stops.", n, n == 1 ? L"" : L"s");
            else
                text = Format(L"%zu points. Click the first point, or press Enter, to close the area.", n);
            info.Text(text);
            SetShown(info, has_text);
            SetShown(del, a != nullptr);
        }

        void SetKind(int next)
        {
            note = nullptr;
            if (sel >= 0)
            {
                Flush();
                if (zs_app_support_area_set_kind(App(), (size_t)sel, next) == ZS_OK)
                    ChangedMayFall();
                Reload();
            }
            else
            {
                kind = next;
                Show();
            }
        }

        void SetSee(bool value)
        {
            see = value;
            ApplyFocus();
        }

        void SetAdding(bool value)
        {
            if (value == adding)
                return;
            adding = value;
            has_foot = false;
            tsel_part = -1;
            note = nullptr;
            Show();
        }

        bool RemoveSelected()
        {
            if (sel < 0)
                return false;
            int i = sel;
            sel = -1;
            Flush();
            if (zs_app_support_area_remove(App(), (size_t)i) == ZS_OK)
                ChangedMayFall();
            Reload();
            return true;
        }

        int64_t AddArea(int area_kind, double const *pts, size_t n, double lo, double hi)
        {
            Flush();
            ptrdiff_t i = zs_app_support_area_add(App(), area_kind, pts, n, lo, hi);
            if (i < 0)
                return -1;
            Changed();
            return i;
        }

        // ---- the edits of the trees ----

        // The result of an edit of the core: the trees of the part again,
        // the clamp bits, and a slice.
        void TreeDone(size_t part, bool done, ptrdiff_t rc, uint32_t clamp)
        {
            tclamp = clamp;
            tree_note.clear();
            if (!done)
                note = rc == -ZS_BUSY || rc == ZS_BUSY ? L"Slice first: the edits of the trees need a slice." : L"The trees cannot change like that.";
            else
                ChangedMayFall();
            ReadTree(part);
            if (!TselOk())
                tsel_part = -1;
        }

        bool DeleteBranch()
        {
            if (!TselOk())
                return false;
            size_t part = (size_t)tsel_part;
            Flush();
            ptrdiff_t n = zs_app_support_tree_delete_branch(App(), part, tsel_node);
            tsel_part = -1;
            TreeDone(part, n >= 0, n, 0);
            if (!on)
                lite = false;
            Show();
            return true;
        }

        void ResetTrees()
        {
            if (reset_part < 0)
                return;
            size_t part = (size_t)reset_part;
            tsel_part = -1;
            Flush();
            bool done = zs_app_support_tree_reset(App(), part) == 1;
            TreeDone(part, true, 0, 0);
            if (!done)
                ReadTree(part);
            Show();
        }

        // "Add a branch": a tap on the bed (the foot), then on the part.
        void AddClick(double x, double y)
        {
            double s = w.Scale();
            if (!has_foot)
            {
                if (!zs_view_bed_point(w.view, (float)(x * s), (float)(y * s), &foot[0], &foot[1]))
                    return;
                has_foot = true;
                Show();
                return;
            }
            double t[3];
            if (!SurfacePoint(x, y, false, t))
            {
                note = L"Tap the place on the part that needs support.";
                Show();
                return;
            }
            adding = false;
            zs_app *app = App();
            ptrdiff_t part = zs_app_part_at(app, t[0], t[1]);
            if (part < 0)
            {
                note = L"No room for a branch there: tap under an overhang, higher than the bed.";
                Show();
                return;
            }
            uint32_t clamp = 0;
            Flush();
            ptrdiff_t tip = zs_app_support_tree_add_branch(app, (size_t)part, foot[0], foot[1], t[0], t[1], t[2], &clamp);
            TreeDone((size_t)part, tip >= 0, tip, clamp);
            if (tip >= 0)
            {
                tsel_part = part;
                tsel_node = (uint32_t)tip;
            }
            else
            {
                note = L"No room for a branch there: tap under an overhang, higher than the bed.";
            }
            Show();
        }

        // ---- drag a node, a ring, or a branch ----

        bool TreePress(double x, double y)
        {
            size_t part = 0;
            uint32_t node = 0;
            int found = TreeAt(x, y, part, node);
            if (found == hit_none)
                return false;
            zs_tree_node const *nd = NodeOf(part, node);
            // A segment: the branch moves with the point of the plane at
            // the height of the middle of the segment.
            double z = nd->z;
            if (found == hit_seg && nd->down >= 0)
                z = (nd->z + NodeOf(part, (uint32_t)nd->down)->z) / 2;
            if (!PlanePoint(x, y, z, td_start))
                return false;
            td_branch.clear();
            if (found == hit_seg)
                td_branch = BranchOf(part, node);
            else
                td_branch.push_back(node);
            td_orig.clear();
            for (uint32_t k : td_branch)
            {
                zs_tree_node const *q = NodeOf(part, k);
                td_orig.push_back(q->x);
                td_orig.push_back(q->y);
            }
            BeginHold();
            td = found;
            td_part = part;
            td_node = node;
            td_z = z;
            td_applied[0] = td_applied[1] = 0;
            td_moved = td_dirty = td_releasing = false;
            td_sent = td_live = Clock::now();
            // The drag selects the branch of the node.
            tsel_part = (int64_t)part;
            tsel_node = node;
            sel = -1;
            note = nullptr;
            Show();
            return true;
        }

        // The nodes follow the pointer at once. The core clamps them when
        // it gets the edit.
        void TreePreview()
        {
            if (TreeOf(td_part) == nullptr)
                return;
            if (td == hit_ring)
            {
                if (zs_tree_node *nd = NodeOf(td_part, td_node))
                    nd->r = want_r;
                return;
            }
            for (size_t i = 0; i < td_branch.size(); i++)
            {
                zs_tree_node *q = NodeOf(td_part, td_branch[i]);
                if (q == nullptr)
                    continue;
                q->x = td_orig[2 * i] + want_dx;
                q->y = td_orig[2 * i + 1] + want_dy;
            }
        }

        // The edit of the drag now, to the core: true if the core made it.
        bool TreeSend()
        {
            zs_app *app = App();
            uint32_t clamp = 0;
            int rc;
            if (td == hit_ring)
                rc = zs_app_support_tree_set_radius(app, td_part, td_node, want_r, &clamp);
            else if (td == hit_node)
                rc = zs_app_support_tree_move_node(app, td_part, td_node, td_orig[0] + want_dx, td_orig[1] + want_dy, &clamp);
            else // A branch: the core moves it from where it is now.
                rc = zs_app_support_tree_move_branch(app, td_part, td_node, want_dx - td_applied[0], want_dy - td_applied[1], &clamp);
            td_sent = Clock::now();
            // A slice runs: the edit goes again a moment later.
            if (rc == ZS_BUSY)
                return false;
            td_dirty = false;
            tclamp = clamp;
            if (rc != ZS_OK)
                return false;
            ChangedMayFall();
            // The support follows the drag: a slice at most each 150 ms,
            // with the step of the history still open.
            if (!td_releasing && td_sent - td_live > std::chrono::milliseconds(150))
            {
                td_live = td_sent;
                zs_set_release(w.model->Set());
            }
            ReadTree(td_part);
            if (td == hit_seg && !td_branch.empty())
            {
                if (zs_tree_node const *q = NodeOf(td_part, td_branch[0]))
                {
                    td_applied[0] = q->x - td_orig[0];
                    td_applied[1] = q->y - td_orig[1];
                }
            }
            return true;
        }

        void StartTreeTimer(int ms)
        {
            if (td_timer.IsRunning())
                return;
            td_timer.Interval(std::chrono::milliseconds(ms));
            td_timer.Start();
        }

        void OnTreeTimer()
        {
            if (w.model == nullptr)
                return;
            if (td_releasing)
            {
                TreeFinish();
                return;
            }
            if (td != hit_none && td_dirty)
            {
                TreeSend();
                if (td_dirty)
                    StartTreeTimer(30);
                Show();
            }
        }

        void TreeDrag(double x, double y)
        {
            if (td_releasing)
                return;
            double p[2];
            if (!PlanePoint(x, y, td_z, p))
                return;
            td_moved = true;
            if (td == hit_ring)
            {
                zs_tree_node const *nd = NodeOf(td_part, td_node);
                if (nd == nullptr)
                    return;
                want_r = std::max(0.05, std::hypot(p[0] - nd->x, p[1] - nd->y));
            }
            else
            {
                want_dx = p[0] - td_start[0];
                want_dy = p[1] - td_start[1];
            }
            td_dirty = true;
            // The core gets the edit at most each 60 ms.
            if (Clock::now() - td_sent >= std::chrono::milliseconds(60))
                TreeSend();
            else
                StartTreeTimer(60);
            TreePreview();
            Show();
        }

        // The end of the drag: the last edit (again a moment later while a
        // slice runs), then the slice that waited starts, the step of the
        // history ends, and the fall check runs.
        void TreeFinish()
        {
            if (td_moved && td_dirty && !TreeSend() && td_dirty)
            {
                StartTreeTimer(30);
                return;
            }
            td = hit_none;
            td_releasing = false;
            EndHold();
            ReadTrees();
            Show();
        }

        void TreeRelease()
        {
            if (td == hit_none || td_releasing)
                return;
            td_timer.Stop();
            td_releasing = true;
            // The last place of the pointer goes to the core.
            if (td_moved)
                td_dirty = true;
            TreeFinish();
        }

        // ---- draw ----

        void CloseDraft()
        {
            size_t n = draft.size() / 3;
            if (n < 3)
                return;
            double const nan = std::numeric_limits<double>::quiet_NaN();
            int64_t i = AddArea(kind, draft.data(), n, nan, nan);
            draft.clear();
            note = i < 0 ? L"The area needs 3 points or more, at most 256." : nullptr;
            sel = (int)i;
            Reload();
        }

        void Click(double x, double y, bool shift, bool alt)
        {
            if (!on || w.view == nullptr)
                return;
            note = nullptr;
            if (adding)
            {
                AddClick(x, y);
                return;
            }
            // A dot or a segment of a tree: select its branch.
            if (draft.empty())
            {
                size_t part = 0;
                uint32_t node = 0;
                int found = TreeAt(x, y, part, node);
                if (found == hit_node || found == hit_seg)
                {
                    tsel_part = (int64_t)part;
                    tsel_node = node;
                    tclamp = 0;
                    sel = -1;
                    Show();
                    return;
                }
                if (found == hit_none && tsel_part >= 0)
                {
                    tsel_part = -1;
                    tclamp = 0;
                }
            }
            // The overhang under the pointer: support under it, in one
            // click. Alt and a click draw a point.
            if (draft.empty() && !alt && OutlineAt(x, y) < 0)
            {
                Hover(x, y);
                if (hot)
                {
                    hot = false;
                    int64_t i = AddArea(kind, hot_pts.data(), hot_pts.size() / 3, hot_lo, hot_hi);
                    sel = (int)i;
                    Reload();
                    return;
                }
            }
            // The first point of the draft closes it.
            if (draft.size() >= 9)
            {
                double qx, qy;
                if (PixelOf(draft.data(), qx, qy) && std::hypot(qx - x, qy - y) < near_dist)
                {
                    CloseDraft();
                    return;
                }
            }
            // With no draft, a click on an outline selects its area.
            if (draft.empty())
            {
                int i = OutlineAt(x, y);
                if (i >= 0)
                {
                    sel = i;
                    Show();
                    return;
                }
            }
            double p[3];
            if (!SurfacePoint(x, y, !shift, p))
                return;
            // A click elsewhere ends the selection, and starts an area.
            if (draft.empty())
                sel = -1;
            if (draft.size() / 3 >= max_points)
            {
                note = L"An area has at most 256 points. Press Enter to close it.";
                Show();
                return;
            }
            draft.insert(draft.end(), p, p + 3);
            Show();
        }

        bool Key(VirtualKey key)
        {
            if (!on)
            {
                if (!lite)
                    return false;
                if (key == VirtualKey::Delete || key == VirtualKey::Back)
                    return RemoveLite();
                if (key == VirtualKey::Escape)
                {
                    ClearPick();
                    return true;
                }
                return false;
            }
            switch (key)
            {
            case VirtualKey::Enter:
                if (draft.size() < 9)
                    return false;
                CloseDraft();
                return true;
            case VirtualKey::Back:
                if (!draft.empty())
                {
                    draft.resize(draft.size() - 3);
                    note = nullptr;
                    Show();
                    return true;
                }
                return RemoveSelected() || DeleteBranch();
            case VirtualKey::Delete:
                return RemoveSelected() || DeleteBranch();
            case VirtualKey::Escape:
                if (adding)
                {
                    adding = false;
                    Show();
                    return true;
                }
                if (tsel_part >= 0)
                {
                    tsel_part = -1;
                    tclamp = 0;
                    Show();
                    return true;
                }
                if (!draft.empty())
                {
                    draft.clear();
                    note = nullptr;
                    Show();
                    return true;
                }
                if (sel >= 0)
                {
                    sel = -1;
                    Show();
                    return true;
                }
                return false;
            default:
                return false;
            }
        }

        // ---- drag a point ----

        bool Press(double x, double y)
        {
            // The last edit of a drag can still wait for a slice.
            if (Holding())
                return false;
            if (!on && lite && lite_tree && w.view != nullptr)
                return TreePress(x, y);
            if (!on || w.view == nullptr || !draft.empty() || adding)
                return false;
            int area = 0, point = 0;
            if (!PointAt(x, y, area, point))
                return TreePress(x, y);
            BeginHold();
            sel = area;
            drag_area = area;
            drag_point = point;
            drag_moved = false;
            note = nullptr;
            Show();
            return true;
        }

        void Drag(double x, double y, bool shift)
        {
            if (td != hit_none)
            {
                TreeDrag(x, y);
                return;
            }
            Area *a = AreaAt(drag_area);
            double p[3];
            if (a == nullptr || !SurfacePoint(x, y, !shift, p))
                return;
            std::copy(p, p + 3, a->pts.begin() + (ptrdiff_t)(3 * (size_t)drag_point));
            a->z_lo = std::numeric_limits<double>::infinity();
            a->z_hi = -a->z_lo;
            for (size_t j = 0; j < a->Count(); j++)
            {
                a->z_lo = std::min(a->z_lo, a->pts[3 * j + 2]);
                a->z_hi = std::max(a->z_hi, a->pts[3 * j + 2]);
            }
            drag_moved = true;
            // The outline follows at once. The core holds the slice.
            double const nan = std::numeric_limits<double>::quiet_NaN();
            if (zs_app_support_area_set(App(), (size_t)drag_area, a->pts.data(), a->Count(), nan, nan) == ZS_OK)
                Changed();
            Show();
        }

        void Release()
        {
            TreeRelease();
            if (drag_area < 0)
                return;
            drag_area = -1;
            // The end: the slice that waited, and the step of the drag.
            EndHold();
            Reload();
        }

        // A plate switch ends a drag with no more edits.
        void CancelDrag()
        {
            if (!Holding())
                return;
            td_timer.Stop();
            td = hit_none;
            td_releasing = false;
            td_dirty = false;
            drag_area = -1;
            w.model->Hold(false);
        }

        // The overhang under the pointer lights up: the faces that face
        // down and connect to the face under the pointer. Not while an area
        // is drawn, or over a point or an outline.
        void Hover(double x, double y)
        {
            bool was = hot;
            size_t was_n = hot_pts.size();
            double was_lo = hot_lo;
            hot = false;
            int area, point;
            size_t tp;
            uint32_t tn;
            double p[3];
            if (on && w.view != nullptr && core != nullptr && draft.empty() && drag_area < 0 && td == hit_none && !adding &&
                !PointAt(x, y, area, point) && TreeAt(x, y, tp, tn) == hit_none && OutlineAt(x, y) < 0 && SurfacePoint(x, y, false, p))
            {
                std::vector<double> pts(3 * max_points);
                size_t n = 0;
                double lo = 0, hi = 0;
                ptrdiff_t part = zs_app_support_pick(core, p[0], p[1], p[2], 4, pts.data(), max_points, &n, &lo, &hi);
                if (part >= 0 && n >= 3)
                {
                    pts.resize(3 * std::min(n, max_points));
                    hot_pts = std::move(pts);
                    hot = true;
                    hot_lo = lo;
                    hot_hi = hi;
                }
            }
            if (was != hot || (hot && (was_n != hot_pts.size() || was_lo != hot_lo)))
                Show();
        }

        // The shape of the pointer at x, y, or -1 for the plain arrow.
        int CursorAt(double x, double y)
        {
            int const grab = (int)InputSystemCursorShape::Hand;
            int const grabbing = (int)InputSystemCursorShape::SizeAll;
            int const resize = (int)InputSystemCursorShape::SizeWestEast;
            int const cross = (int)InputSystemCursorShape::Cross;
            if (Holding())
                return grabbing;
            size_t tp;
            uint32_t tn;
            if (!on)
            {
                int found = lite && lite_tree ? TreeAt(x, y, tp, tn) : (int)hit_none;
                return found == hit_ring ? resize : found != hit_none ? grab : -1;
            }
            int area, point;
            if (draft.empty() && !adding)
            {
                int found = TreeAt(x, y, tp, tn);
                if (found == hit_ring)
                    return resize;
                if (found != hit_none)
                    return grab;
            }
            return draft.empty() && PointAt(x, y, area, point) ? grab : cross;
        }

        void SetCursor(int shape)
        {
            if (shape == cursor_shape)
                return;
            auto panel = w.ViewPanel().try_as<IUIElementProtected>();
            if (panel == nullptr)
                return;
            cursor_shape = shape;
            if (shape < 0)
                panel.ProtectedCursor(nullptr);
            else
                panel.ProtectedCursor(InputSystemCursor::Create(static_cast<InputSystemCursorShape>(shape)));
        }

        // ---- the tool on and off ----

        void ToolChanged()
        {
            bool next = w.tool == Tool::Support;
            if (next == on && !lite)
                return;
            on = next;
            lite = false;
            if (w.view != nullptr)
                zs_view_pick_skip_support(w.view, on ? 1 : 0);
            if (!on)
            {
                Release();
                draft.clear();
                sel = -1;
                note = nullptr;
                adding = false;
                tsel_part = -1;
                tclamp = 0;
                hot = false;
                SetCursor(-1);
            }
            ReadAreas();
            ReadTrees();
            Show();
            ApplyFocus();
        }

        void Loaded()
        {
            if (w.view == nullptr)
                return;
            // zs_view_load drew the areas of the core as plain outlines,
            // and ended the focus. During a drag the copy here leads.
            zs_view_pick_skip_support(w.view, on ? 1 : 0);
            focus_set = false;
            if (drag_area < 0)
                ReadAreas();
            if (Live() || drag_area >= 0)
            {
                ReadTrees();
                Show();
            }
            ApplyFocus();
        }

        // ---- the support of the Select tool ----

        bool SelectAt(double x, double y, double z)
        {
            if (on || App() == nullptr)
                return false;
            zs_app *app = App();
            lite = true;
            lite_pt[0] = x;
            lite_pt[1] = y;
            lite_pt[2] = z;
            tsel_part = -1;
            tclamp = 0;
            note = nullptr;
            lite_tree = w.model->GetSetting("project.support_style") == "tree";
            // The overhang over the line: up from it, half a millimeter a
            // step, to the first surface that faces down.
            lite_pts.clear();
            zs_toolpaths tp{};
            double top = zs_app_toolpaths(app, &tp) == ZS_OK && tp.layer_count > 0 ? tp.layer_z[tp.layer_count - 1] : z;
            std::vector<double> pts(3 * max_points);
            for (double zz = z; zz <= top + 0.5; zz += 0.5)
            {
                size_t n = 0;
                if (zs_app_support_pick(app, x, y, zz, 2, pts.data(), max_points, &n, &lite_lo, &lite_hi) >= 0 && n >= 3)
                {
                    pts.resize(3 * std::min(n, max_points));
                    lite_pts = std::move(pts);
                    break;
                }
            }
            if (lite_tree)
            {
                // No check of the pick in ReadTrees: no node is selected yet.
                lite_tree = false;
                ReadTrees();
                lite_tree = true;
                // The node nearest to the point: a node over it counts
                // more than a node beside it.
                double best = std::numeric_limits<double>::infinity();
                for (auto const &t : trees)
                {
                    for (size_t k = 0; k < t.nodes.size(); k++)
                    {
                        zs_tree_node const &nd = t.nodes[k];
                        double d = std::hypot(nd.x - x, nd.y - y) + 0.25 * std::abs(nd.z - z);
                        if (d < best)
                        {
                            best = d;
                            tsel_part = (int64_t)t.part;
                            tsel_node = (uint32_t)k;
                        }
                    }
                }
                // No tree there: the overhang, as for a grid.
                if (tsel_part < 0)
                    lite_tree = false;
            }
            Show();
            return true;
        }

        void ClearPick()
        {
            if (on || !lite)
                return;
            lite = false;
            tsel_part = -1;
            tclamp = 0;
            trees.clear();
            SetCursor(-1);
            Show();
        }

        // Delete: the branch of a tree, or a block area over the overhang
        // of a grid support, and the marks near the line.
        bool RemoveLite()
        {
            if (on || !lite)
                return false;
            if (lite_tree)
                return DeleteBranch();
            zs_app *app = App();
            Flush();
            bool changed = zs_app_mark_remove_near(app, lite_pt[0], lite_pt[1], lite_pt[2], 3) > 0;
            if (changed)
                w.model->RequestSlice();
            if (lite_pts.size() >= 9 && AddArea(kind_block, lite_pts.data(), lite_pts.size() / 3, lite_lo, lite_hi) >= 0)
                changed = true;
            else if (changed)
                Commit();
            if (!changed)
                zs::Log("shell: found no overhang over this support\n");
            lite = false;
            Reload();
            return true;
        }

        // A right click: true on a dot or a segment of the picked tree. It
        // selects that node.
        bool MenuAt(double x, double y)
        {
            if (on || !lite || !lite_tree)
                return false;
            size_t part = 0;
            uint32_t node = 0;
            if (TreeAt(x, y, part, node) == hit_none)
                return false;
            tsel_part = (int64_t)part;
            tsel_node = node;
            Show();
            return true;
        }

#ifdef ZS_DEV_HOOKS
        void DevLog()
        {
            std::string text = "dev: support: " + std::to_string(areas.size()) + " areas";
            for (auto const &a : areas)
            {
                text += " [kind " + std::to_string(a.kind) + ", " + std::to_string(a.Count()) + " points";
                char range[64];
                snprintf(range, sizeof range, ", z %.2f to %.2f, at", a.z_lo, a.z_hi);
                text += range;
                for (size_t j = 0; j < a.Count() && j < 4; j++)
                {
                    double x = 0, y = 0;
                    if (PixelOf(&a.pts[3 * j], x, y))
                    {
                        char at[32];
                        snprintf(at, sizeof at, " %.0f,%.0f", x, y);
                        text += at;
                    }
                }
                text += "]";
            }
            for (auto const &t : trees)
                text += " [tree of part " + std::to_string(t.part) + ": " + std::to_string(t.nodes.size()) + " nodes" + (t.edited ? ", edited]" : "]");
            if (TselOk())
            {
                zs_tree_node const &nd = *NodeOf((size_t)tsel_part, tsel_node);
                double x = 0, y = 0;
                PixelOf(&nd.x, x, y);
                char node[160];
                snprintf(node, sizeof node, ", node %u at %.2f,%.2f,%.2f (pixel %.0f,%.0f) r %.2f (min %.2f)", tsel_node, nd.x, nd.y, nd.z, x, y, nd.r, nd.r_min);
                text += node;
            }
            zs_app *app = App();
            char tail[220];
            snprintf(tail, sizeof tail, ", clamp %u, selected %d, draft %zu, hot %d (%zu), on %d lite %d/%d, see %d, adding %d foot %d, holding %d, history %zu of %zu pending %d, cursor %d\n",
                     tclamp, sel, draft.size() / 3, hot ? 1 : 0, hot ? hot_pts.size() / 3 : 0, on ? 1 : 0, lite ? 1 : 0, lite_tree ? 1 : 0, see ? 1 : 0, adding ? 1 : 0, has_foot ? 1 : 0,
                     Holding() ? 1 : 0, zs_app_history_current(app) + 1, zs_app_history_count(app), zs_app_history_pending(app), cursor_shape);
            text += tail;
            // zs::Log cuts a line at 1024 bytes.
            for (size_t at = 0; at < text.size(); at += 1000)
                zs::Log("%s", text.substr(at, 1000).c_str());
            if (card.Visibility() == Visibility::Visible)
            {
                std::string words = "dev: card: " + to_string(title.Text()) + " | " + to_string(info.Text());
                if (tree_info.Visibility() == Visibility::Visible)
                    words += " | " + to_string(tree_info.Text());
                if (del.Visibility() == Visibility::Visible)
                    words += " | [" + to_string(unbox_value<hstring>(del.Content())) + "]";
                if (tree_del.Visibility() == Visibility::Visible)
                    words += " | [Delete branch]";
                if (tree_row.Visibility() == Visibility::Visible && tree_reset.Visibility() == Visibility::Visible)
                    words += " | [Reset support]";
                words += "\n";
                for (size_t at = 0; at < words.size(); at += 1000)
                    zs::Log("%s", words.substr(at, 1000).c_str());
            }
        }

        // A drag through the code of the pointer, in six moves 70 ms apart,
        // so the edits go to the core as they do in a real drag.
        void DevDrag(double x0, double y0, double x1, double y1)
        {
            if (!w.ToolPress(x0, y0, false))
            {
                zs::Log("dev: support: no press at %.0f,%.0f\n", x0, y0);
                return;
            }
            for (int k = 1; k <= 6; k++)
            {
                w.ToolDrag(x0 + (x1 - x0) * k / 6, y0 + (y1 - y0) * k / 6, false);
                ::Sleep(70);
            }
            int before = zs_app_state(App());
            w.ToolRelease();
            zs::Log("dev: support: state before the release %d, after it %d\n", before, zs_app_state(App()));
        }

        // Finds a pixel of the view where a test holds, on a grid of 8 points.
        template <typename F>
        bool DevScan(F const &test, double &found_x, double &found_y)
        {
            double width = w.ViewPanel().ActualWidth(), height = w.ViewPanel().ActualHeight();
            for (double y = 8; y < height; y += 8)
                for (double x = 72; x < width; x += 8)
                    if (test(x, y))
                    {
                        found_x = x;
                        found_y = y;
                        return true;
                    }
            return false;
        }

        bool DevStep(std::wstring const &verb, std::vector<std::wstring> const &words)
        {
            auto number = [&](size_t i) { return i < words.size() ? _wtof(words[i].c_str()) : 0.0; };
            auto first_node = [&](size_t k) -> zs_tree_node * {
                return !trees.empty() && k < trees[0].nodes.size() ? &trees[0].nodes[k] : nullptr;
            };
            if (verb == L"orbit")
            {
                zs_view_orbit(w.view, (float)number(0), (float)number(1));
                Show();
            }
            else if (verb == L"zoom")
            {
                // Toward the middle of part 0. Under 1 zooms in.
                zs_part p{};
                float cx = 0, cy = 0;
                if (zs_app_part_get(App(), 0, &p) == ZS_OK && zs_view_pixel_of(w.view, p.x, p.y, p.size_z / 2, &cx, &cy))
                    zs_view_zoom_at(w.view, (float)number(0), cx, cy);
                w.StartAnimation();
            }
            else if (verb == L"alt")
            {
                w.pointer_alt = true;
                w.ToolClick(number(0), number(1), false, false);
                w.pointer_alt = false;
            }
            else if (verb == L"findover")
            {
                // The first point of the view with an overhang under it.
                double x = 0, y = 0;
                bool any = DevScan([&](double px, double py) {
                    Hover(px, py);
                    return hot;
                }, x, y);
                zs::Log("dev: support: overhang %s at %.0f,%.0f, sign %lld\n", any ? "found" : "not found", x, y,
                        (long long)zs_view_sign_at(w.view, (float)(x * w.Scale()), (float)(y * w.Scale())));
                if (any && !words.empty() && words[0] == L"click")
                    w.ToolClick(x, y, false, false);
            }
            else if (verb == L"sdrag")
            {
                Area const *a = AreaAt((int)number(0));
                size_t j = (size_t)number(1);
                double x0, y0;
                if (a != nullptr && j < a->Count() && PixelOf(&a->pts[3 * j], x0, y0))
                    DevDrag(x0, y0, x0 + number(2), y0 + number(3));
                else
                    zs::Log("dev: support: no point %zu\n", j);
            }
            else if (verb == L"sclick")
            {
                // A click on the outline of area i, between two points.
                Area const *a = AreaAt((int)number(0));
                double ax, ay, bx, by;
                if (a != nullptr && a->Count() >= 2 && PixelOf(&a->pts[0], ax, ay) && PixelOf(&a->pts[3], bx, by))
                    w.ToolClick((ax + bx) / 2, (ay + by) / 2, false, false);
            }
            else if (verb == L"dclick")
            {
                // A click on point k of the draft.
                size_t k = (size_t)number(0);
                double x, y;
                if (3 * k + 2 < draft.size() && PixelOf(&draft[3 * k], x, y))
                    w.ToolClick(x, y, false, false);
            }
            else if (verb == L"tclick")
            {
                zs_tree_node const *nd = first_node((size_t)number(0));
                double x, y;
                if (nd != nullptr && PixelOf(&nd->x, x, y))
                    w.ToolClick(x, y, false, false);
                else
                    zs::Log("dev: support: no node\n");
            }
            else if (verb == L"tdrag" || verb == L"tseg")
            {
                zs_tree_node const *nd = first_node((size_t)number(0));
                double x0, y0;
                if (nd == nullptr)
                {
                    zs::Log("dev: support: no node\n");
                }
                else
                {
                    double p[3] = { nd->x, nd->y, nd->z };
                    if (verb == L"tseg" && nd->down >= 0)
                    {
                        zs_tree_node const &dn = trees[0].nodes[(size_t)nd->down];
                        p[0] = (nd->x + dn.x) / 2;
                        p[1] = (nd->y + dn.y) / 2;
                        p[2] = (nd->z + dn.z) / 2;
                    }
                    if (PixelOf(p, x0, y0))
                        DevDrag(x0, y0, x0 + number(1), y0 + number(2));
                }
            }
            else if (verb == L"tbig")
            {
                // Selects the widest node of the first tree.
                if (!trees.empty())
                {
                    auto const &nodes = trees[0].nodes;
                    auto widest = std::max_element(nodes.begin(), nodes.end(), [](auto const &a, auto const &b) { return a.r < b.r; });
                    tsel_part = (int64_t)trees[0].part;
                    tsel_node = (uint32_t)(widest - nodes.begin());
                    Show();
                }
            }
            else if (verb == L"tring")
            {
                double x0, y0;
                if (TselOk())
                {
                    zs_tree_node const &nd = *NodeOf((size_t)tsel_part, tsel_node);
                    double p[3] = { nd.x + nd.r, nd.y, nd.z };
                    if (PixelOf(p, x0, y0))
                        DevDrag(x0, y0, x0 + number(0), y0);
                }
                else
                {
                    zs::Log("dev: support: no node selected\n");
                }
            }
            else if (verb == L"tadd")
            {
                SetAdding(true);
                Click(number(0), number(1), false, false);
                Click(number(2), number(3), false, false);
            }
            else if (verb == L"tmenu")
            {
                // A negative k: the selected node.
                zs_tree_node const *nd = number(0) < 0 ? (TselOk() ? NodeOf((size_t)tsel_part, tsel_node) : nullptr) : first_node((size_t)number(0));
                double x, y;
                if (nd != nullptr && PixelOf(&nd->x, x, y))
                {
                    bool shown = w.SupportMenu(x, y);
                    zs::Log("dev: support: menu %d\n", shown ? 1 : 0);
                }
            }
            else if (verb == L"tdel")
            {
                DeleteBranch();
            }
            else if (verb == L"treset")
            {
                if (tree_reset.Visibility() == Visibility::Visible)
                    ResetTrees();
                else
                    zs::Log("dev: support: no Reset support\n");
            }
            else if (verb == L"kind")
            {
                size_t k = (size_t)number(0);
                if (k < std::size(kinds))
                    SetKind(kinds[k].kind);
            }
            else if (verb == L"see")
            {
                see_box.IsChecked(number(0) != 0);
                SetSee(number(0) != 0);
            }
            else if (verb == L"undo")
            {
                w.history_timer.Stop();
                w.AfterRestore(w.model->Undo());
            }
            else if (verb == L"redo")
            {
                w.history_timer.Stop();
                w.AfterRestore(w.model->Redo());
            }
            else if (verb == L"set" && words.size() >= 2)
            {
                w.CommitSetting(zs::ToUtf8(words[0]), zs::ToUtf8(words[1]));
            }
            else if (verb == L"plate")
            {
                if (!words.empty() && words[0] == L"add")
                {
                    if (w.model->AddPlate())
                        w.ShowPlate();
                }
                else
                {
                    w.SelectPlate((size_t)number(0));
                }
            }
            else if (verb == L"pickline")
            {
                // Select tool: a click on the first support line in the view.
                double x = 0, y = 0;
                double s = w.Scale();
                bool any = DevScan([&](double px, double py) {
                    size_t seg = 0;
                    size_t path = zs_view_pick_segment(w.view, (float)(px * s), (float)(py * s), &seg);
                    if (path == (size_t)-1)
                        return false;
                    int feature = zs_view_path_feature(w.view, path);
                    return feature == ZS_FEATURE_SUPPORT || feature == ZS_FEATURE_SUPPORT_INTERFACE;
                }, x, y);
                zs::Log("dev: support: line %s at %.0f,%.0f\n", any ? "found" : "not found", x, y);
                if (any)
                    w.ToolClick(x, y, false, false);
            }
            else
            {
                return false;
            }
            return true;
        }
#endif
    };

    void MainWindow::WireSupport()
    {
        support = std::make_shared<SupportTool>(*this);
        support->BuildCard();
    }

    void MainWindow::SupportToolChanged()
    {
        support->ToolChanged();
    }

    void MainWindow::SupportLoaded()
    {
        support->Loaded();
    }

    // Another focus of the view ended: the see-through of the tool again.
    void MainWindow::SupportRefocus()
    {
        support->focus_set = true;
        support->ApplyFocus();
    }

    // An undo, a redo, or a switch of the plate: the areas of the core again.
    void MainWindow::SupportReload()
    {
        if (support->core != model->Active())
            support->CancelDrag();
        support->Reload();
    }

    bool MainWindow::SupportPress(double x, double y)
    {
        return support->Press(x, y);
    }

    bool MainWindow::SupportDragging()
    {
        return support->Holding();
    }

    void MainWindow::SupportDrag(double x, double y, bool shift)
    {
        support->Drag(x, y, shift);
    }

    void MainWindow::SupportRelease()
    {
        support->Release();
    }

    void MainWindow::SupportClick(double x, double y, bool shift, bool alt)
    {
        support->Click(x, y, shift, alt);
    }

    // The pointer moves with no button down.
    void MainWindow::SupportPointer(double x, double y)
    {
        if (tool == Tool::Support)
        {
            support->SetCursor(support->CursorAt(x, y));
            support->Hover(x, y);
        }
        else if (tool == Tool::Select && support->lite)
        {
            support->SetCursor(support->CursorAt(x, y));
        }
    }

    bool MainWindow::SupportKey(VirtualKey key)
    {
        return support->Key(key);
    }

    bool MainWindow::SupportPicked()
    {
        return !support->on && support->lite;
    }

    void MainWindow::SupportClearPick()
    {
        support->ClearPick();
    }

    // The Select tool: a click on a support line selects that support.
    bool MainWindow::SupportSelectLine(size_t path, size_t segment)
    {
        int feature = zs_view_path_feature(view, path);
        if (feature != ZS_FEATURE_SUPPORT && feature != ZS_FEATURE_SUPPORT_INTERFACE)
            return false;
        // The middle of the segment, on its layer.
        zs_toolpaths tp{};
        if (zs_app_toolpaths(model->Active(), &tp) != ZS_OK || path >= tp.path_count)
            return false;
        uint32_t a = path == 0 ? 0 : tp.path_ends[path - 1], b = tp.path_ends[path];
        if (b <= a)
            return false;
        uint32_t i = a + (uint32_t)segment + 1 < b ? a + (uint32_t)segment : a + (b - a) / 2 - ((b - a) > 1 ? 1 : 0);
        uint32_t j = i + 1 < b ? i + 1 : i;
        size_t layer = 0;
        while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path)
            layer++;
        double z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
        ClearSelection();
        return support->SelectAt((tp.points[2 * i] + tp.points[2 * j]) / 2, (tp.points[2 * i + 1] + tp.points[2 * j + 1]) / 2, z);
    }

    // A right click on a dot of a picked support tree: Delete branch.
    bool MainWindow::SupportMenu(double x, double y)
    {
        if (!support->MenuAt(x, y))
            return false;
        MenuFlyout menu;
        MenuFlyoutItem item;
        item.Text(L"Delete branch");
        item.Click([this](auto &&, auto &&) { support->DeleteBranch(); });
        menu.Items().Append(item);
        menu.ShowAt(ViewPanel(), Windows::Foundation::Point{ (float)x, (float)y });
        return true;
    }

#ifdef ZS_DEV_HOOKS
    bool MainWindow::SupportDevStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        return support->DevStep(verb, words);
    }

    void MainWindow::SupportDevLog()
    {
        support->DevLog();
    }
#endif
}
