// See zs_signs.h. GDI+ keeps straight alpha in a 32bppARGB bitmap, which is
// the form that the core takes.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_signs.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cwchar>
#include <objidl.h>

namespace Gdiplus
{
    using std::max;
    using std::min;
}
#include <gdiplus.h>

#include "zs_model.h"

namespace zs
{
    namespace
    {
        using namespace Gdiplus;

        // The pixels of the image for one pixel of the sign, and the height
        // of a sign on the screen, as in the other shells.
        constexpr int sign_s = 2;
        constexpr double sign_screen_h = 46;
        constexpr float title_px = 15;
        constexpr float sub_px = 12.5f;

        wchar_t const *const status_text[] = { L"Empty", L"To slice", L"Slicing", L"", L"The slice failed", L"Resin: not yet" };

        void StartGdiPlus()
        {
            static ULONG_PTR token = [] {
                ULONG_PTR t = 0;
                GdiplusStartupInput input;
                GdiplusStartup(&t, &input, nullptr);
                return t;
            }();
            (void)token;
        }

        void SignLines(zs_set *set, size_t i, zs_plate_info const &info, std::wstring &title, std::wstring &sub)
        {
            title = std::to_wstring(i + 1) + L"  " + (info.name[0] ? ToWide(info.name) : L"Empty plate");
            sub.clear();
            char const *nl = info.printer_key ? strchr(info.printer_key, '\n') : nullptr;
            if (nl != nullptr && nl[1] != 0)
                sub = ToWide(nl + 1);
            zs_totals totals{};
            if (info.status == ZS_PLATE_STATUS_DONE && zs_set_plate_totals(set, i, &totals) == ZS_OK && totals.sliced > 0)
            {
                int minutes = (int)std::lround(totals.time_s / 60);
                wchar_t text[64];
                if (minutes >= 60)
                    swprintf_s(text, L"%d h %d min · %.1f g", minutes / 60, minutes % 60, totals.filament_g);
                else
                    swprintf_s(text, L"%d min · %.1f g", minutes, totals.filament_g);
                sub += (sub.empty() ? L"" : L" · ") + std::wstring(text);
            }
            else if (info.status >= 0 && info.status <= ZS_PLATE_STATUS_CANNOT && status_text[info.status][0] != 0)
            {
                sub += (sub.empty() ? L"" : L" · ") + std::wstring(status_text[info.status]);
            }
        }

        void RoundRect(GraphicsPath &path, REAL x, REAL y, REAL w, REAL h, REAL r)
        {
            REAL d = r * 2;
            path.AddArc(x + w - d, y, d, d, 270, 90);
            path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
            path.AddArc(x, y + h - d, d, d, 90, 90);
            path.AddArc(x, y, d, d, 180, 90);
            path.CloseFigure();
        }
    }

    bool DrawPlateSigns(zs_set *set, double dpi_scale, std::wstring &key, SignImage &out,
                        std::function<std::wstring(size_t)> const &print)
    {
        StartGdiPlus();
        size_t n = zs_set_count(set), active = zs_set_active(set);
        std::vector<std::wstring> titles(n), subs(n);
        std::vector<bool> valid(n, false);
        std::wstring next = std::to_wstring(dpi_scale);
        for (size_t i = 0; i < n; i++)
        {
            zs_plate_info info{};
            if (zs_set_plate_info(set, i, &info) != ZS_OK)
                continue;
            valid[i] = true;
            SignLines(set, i, info, titles[i], subs[i]);
            if (print)
            {
                std::wstring status = print(i);
                if (!status.empty())
                    subs[i] += (subs[i].empty() ? L"" : L" · ") + status;
            }
            next += L"\n" + titles[i] + L"\n" + subs[i] + (i == active && n > 1 ? L"\n1" : L"\n0");
        }
        if (next == key)
            return false;
        key = next;

        FontFamily family(L"Segoe UI");
        Font title_font(&family, title_px * sign_s, FontStyleBold, UnitPixel);
        Font sub_font(&family, sub_px * sign_s, FontStyleRegular, UnitPixel);
        StringFormat format(StringFormat::GenericTypographic());
        format.SetFormatFlags(format.GetFormatFlags() | StringFormatFlagsNoWrap | StringFormatFlagsMeasureTrailingSpaces);

        REAL const pad = 10.0f * sign_s, bar = 4.0f * sign_s;
        int const height = (int)std::lround(pad * 2 + (title_px * 1.25 + sub_px * 1.35) * sign_s);
        int const gap = 4;

        std::vector<int> widths(n, 0);
        int image_w = 1;
        {
            Bitmap probe(1, 1, PixelFormat32bppARGB);
            Graphics g(&probe);
            for (size_t i = 0; i < n; i++)
            {
                if (!valid[i])
                    continue;
                RectF box, sub_box;
                g.MeasureString(titles[i].c_str(), -1, &title_font, PointF(0, 0), &format, &box);
                if (!subs[i].empty())
                    g.MeasureString(subs[i].c_str(), -1, &sub_font, PointF(0, 0), &format, &sub_box);
                widths[i] = (int)std::ceil(std::max({ box.Width, sub_box.Width, 90.0f * sign_s }) + pad * 2 + bar);
                image_w = std::max(image_w, widths[i]);
            }
        }
        int image_h = std::max(1, (int)n * (height + gap));

        Bitmap bitmap(image_w, image_h, PixelFormat32bppARGB);
        out.rects.assign(4 * n, 0.0f);
        {
            Graphics g(&bitmap);
            g.SetSmoothingMode(SmoothingModeAntiAlias);
            g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
            g.SetPixelOffsetMode(PixelOffsetModeHalf);
            Color const accent(255, 54, 133, 227);
            SolidBrush fill(Color(235, 255, 255, 255));
            SolidBrush title_brush(Color(255, 0x24, 0x1f, 0x31));
            SolidBrush sub_brush(Color(255, 0x5e, 0x5c, 0x64));
            SolidBrush accent_brush(accent);
            Pen edge(Color(36, 0, 0, 0), (REAL)sign_s);
            Pen accent_edge(accent, (REAL)sign_s);
            for (size_t i = 0; i < n; i++)
            {
                if (!valid[i])
                    continue;
                REAL y = (REAL)(i * (height + gap));
                REAL w = (REAL)widths[i];
                bool lit = i == active && n > 1;
                GraphicsPath path;
                RoundRect(path, 1, y + 1, w - 3, (REAL)height - 2, 9.0f * sign_s);
                g.FillPath(&fill, &path);
                if (lit)
                {
                    Region clip(&path);
                    g.SetClip(&clip);
                    g.FillRectangle(&accent_brush, (REAL)0, y, bar + 1, (REAL)height);
                    g.ResetClip();
                }
                g.DrawPath(lit ? &accent_edge : &edge, &path);
                g.DrawString(titles[i].c_str(), -1, &title_font, PointF(bar + pad, y + pad), &format, &title_brush);
                if (!subs[i].empty())
                    g.DrawString(subs[i].c_str(), -1, &sub_font,
                                 PointF(bar + pad, y + pad + title_px * 1.25f * sign_s), &format, &sub_brush);
                out.rects[4 * i + 1] = y;
                out.rects[4 * i + 2] = w;
                out.rects[4 * i + 3] = (REAL)height;
            }
        }

        BitmapData data{};
        Rect all(0, 0, image_w, image_h);
        if (bitmap.LockBits(&all, ImageLockModeRead, PixelFormat32bppARGB, &data) != Ok)
            return false;
        out.rgba.resize((size_t)image_w * image_h * 4);
        for (int y = 0; y < image_h; y++)
        {
            auto const *src = static_cast<uint8_t const *>(data.Scan0) + (ptrdiff_t)y * data.Stride;
            uint8_t *dst = out.rgba.data() + (size_t)y * image_w * 4;
            for (int x = 0; x < image_w; x++, src += 4, dst += 4)
            {
                dst[0] = src[2];
                dst[1] = src[1];
                dst[2] = src[0];
                dst[3] = src[3];
            }
        }
        bitmap.UnlockBits(&data);
        out.width = (uint32_t)image_w;
        out.height = (uint32_t)image_h;
        out.scale = (float)(height / (sign_screen_h * dpi_scale));
        return true;
    }
}
