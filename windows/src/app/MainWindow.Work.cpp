// The work bar of the view, as in linux/src/ui/window.c.
//
// A bar of 2 px at the top edge of the view shows the draft slice, the exact
// slice, and the simulated print, with the progress of the core. It fades in
// after 150 ms of work, so a fast slice shows no bar, and it takes no clicks.
// Small dim text at the top right says what runs and its time, then the
// times of the last slices for 2.5 s.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    using Clock = std::chrono::steady_clock;

    double const text_opacity = 0.6;
    auto const last_times = std::chrono::milliseconds(2500);

    // "480 ms" or "1.47 s".
    std::wstring WorkTime(double ms)
    {
        wchar_t text[32];
        if (ms < 1000)
            swprintf_s(text, L"%.0f ms", ms);
        else
            swprintf_s(text, L"%.2f s", ms / 1000);
        return text;
    }
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::WireWork()
    {
        settle_timer = queue.CreateTimer();
        settle_timer.IsRepeating(false);
        settle_timer.Interval(std::chrono::milliseconds(300));
        settle_timer.Tick([this](auto &&, auto &&) {
            // A draft that still runs: the exact slice waits for its result.
            if (model != nullptr && !model->SettleDue())
                settle_timer.Start();
        });
        model->SetSettleTimer([this] {
            settle_timer.Stop();
            settle_timer.Start();
        });
        work_show = queue.CreateTimer();
        work_show.IsRepeating(false);
        work_show.Interval(std::chrono::milliseconds(150));
        work_show.Tick([this](auto &&, auto &&) {
            if (work_kind != 0)
                WorkBar().Opacity(1);
        });
        work_poll = queue.CreateTimer();
        work_poll.Interval(std::chrono::milliseconds(100));
        work_poll.Tick([this](auto &&, auto &&) { WorkTick(); });
    }

    void MainWindow::StopWork()
    {
        if (settle_timer != nullptr)
            settle_timer.Stop();
        if (work_show != nullptr)
            work_show.Stop();
        if (work_poll != nullptr)
            work_poll.Stop();
        if (model != nullptr)
            model->SetSettleTimer(nullptr);
    }

    // kind: 1 a draft, 2 an exact slice, 3 the simulation.
    void MainWindow::WorkBegin(int kind)
    {
        if (work_kind != kind)
        {
            work_kind = kind;
            work_start = Clock::now();
            work_fraction = 0;
            WorkBar().Value(0);
        }
        if (!work_show.IsRunning() && WorkBar().Opacity() == 0)
            work_show.Start();
        if (!work_poll.IsRunning())
            work_poll.Start();
    }

    void MainWindow::WorkEnd()
    {
        work_kind = 0;
        work_ended = Clock::now();
        work_has_ended = true;
        work_show.Stop();
        WorkBar().Opacity(0);
        ShowWorkText();
    }

    void MainWindow::WorkProgress(double fraction)
    {
        WorkBegin(model->SlicesDraft() ? 1 : 2);
        work_fraction = fraction;
        WorkBar().Value(fraction);
    }

    // A slice ended, or failed. The tick shows the simulation of an exact
    // slice, and the text.
    void MainWindow::WorkSliceEnded(bool draft)
    {
        work_draft = draft;
#ifdef ZS_DEV_HOOKS
        zs::Log("dev: slice ended, draft %d, draft ms %.0f, exact ms %.0f, gcode %d\n", draft ? 1 : 0, model->DraftMs(), model->ExactMs(), [&] {
            uint8_t const *g = nullptr;
            size_t n = 0;
            return zs_app_gcode(model->Active(), &g, &n);
        }());
#endif
        if (work_kind != 3)
            WorkEnd();
        if (!work_poll.IsRunning())
            work_poll.Start();
    }

    void MainWindow::WorkTick()
    {
        if (model == nullptr)
            return;
        double fraction = 0;
        if (zs_app_sim_work(model->Active(), &fraction) != 0)
        {
            WorkBegin(3);
            work_fraction = fraction;
            WorkBar().Value(fraction);
        }
        else if (work_kind == 3)
        {
            WorkEnd();
        }
        ShowWorkText();
        // The last times stay for a moment. A draft keeps its note until
        // the exact slice.
        if (work_kind == 0 && !work_draft && (!work_has_ended || Clock::now() - work_ended > last_times + std::chrono::milliseconds(100)))
            work_poll.Stop();
    }

    void MainWindow::ShowWorkText()
    {
        if (model == nullptr)
            return;
        std::wstring text;
        bool show = true;
        auto now = Clock::now();
        double run = std::chrono::duration<double>(now - work_start).count();
        if (work_kind == 3)
        {
            wchar_t line[48];
            swprintf_s(line, L"Simulation %.0f %%", work_fraction * 100);
            text = line;
        }
        else if (work_kind != 0)
        {
            wchar_t line[64];
            swprintf_s(line, L"%s%s %.*f s", work_draft && work_kind == 2 ? L"Draft · " : L"", work_kind == 1 ? L"Draft" : L"Slice", work_kind == 1 ? 2 : 1, run);
            text = line;
            // A fast slice shows no text.
            show = run >= 0.15 || work_draft;
        }
        else if (work_draft)
        {
            text = L"Draft · " + WorkTime(model->DraftMs());
        }
        else if (work_has_ended && now - work_ended < last_times && model->ExactMs() > 0)
        {
            // The times of the last slices, for a moment.
            text = model->DraftMs() > 0 ? L"Draft " + WorkTime(model->DraftMs()) + L" · Exact " + WorkTime(model->ExactMs())
                                        : L"Exact " + WorkTime(model->ExactMs());
        }
        if (!text.empty())
            WorkText().Text(text);
        WorkText().Opacity(!text.empty() && show ? text_opacity : 0);
    }
}
