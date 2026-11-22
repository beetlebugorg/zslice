//! The work bar of the view (as the GTK and web apps): a bar 2 points
//! tall at the top edge of the view, under the toolbar, for the draft
//! slice, the exact slice, and the simulated print, with the progress of
//! the core. It shows after 150 ms of work, so a fast slice does not flash
//! it. Small dim text at the right says what runs ("Draft 0.06 s",
//! "Simulation 62 %"), then the times of the last slices ("Draft 161 ms ·
//! Exact 461 ms") for 2.5 s. It takes no clicks and moves nothing.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Observation
import SwiftUI

@MainActor
@Observable
final class WorkState {
    enum Kind { case none, draft, exact, simulation }

    private(set) var kind = Kind.none
    private(set) var fraction = 0.0
    /// The bar shows (after 150 ms of work).
    private(set) var shown = false
    /// The text at the right, and whether it shows.
    private(set) var text = ""
    private(set) var textShown = false

    @ObservationIgnored private var start = Date()
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var poll: Timer?
    /// The times of the last draft and the last exact slice, ms (0: none).
    @ObservationIgnored private var draftMs = 0.0
    @ObservationIgnored private var exactMs = 0.0

    private func begin(_ k: Kind) {
        guard kind != k else { return }
        kind = k
        start = Date()
        hideTask?.cancel()
        showTask?.cancel()
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, self.kind != .none else { return }
            self.shown = true
            self.textShown = true
        }
    }

    private var elapsed: String { String(format: "%.2f s", Date().timeIntervalSince(start)) }

    /// A progress event of a slice.
    func slicing(draft: Bool, fraction f: Double) {
        poll?.invalidate()
        begin(draft ? .draft : .exact)
        fraction = max(0, min(1, f))
        text = (draft ? "Draft " : "Exact ") + elapsed
    }

    /// A slice is done. After an exact slice the simulated print runs on
    /// the worker: the bar follows it (zs_app_sim_work, each 0.1 s), then
    /// the times show.
    func sliced(draft: Bool, seconds: Double, model: SliceModel) {
        if draft { draftMs = seconds * 1000 } else { exactMs = seconds * 1000 }
        fraction = 1
        if draft {
            // The exact slice follows: the bar stays for it.
            text = String(format: "Draft %.0f ms", draftMs)
            return
        }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let model else {
                    self.poll?.invalidate()
                    return
                }
                var f = 0.0
                if zs_app_sim_work(model.core, &f) == 1 {
                    self.begin(.simulation)
                    self.fraction = f
                    self.text = String(format: "Simulation %.0f %%", f * 100)
                } else {
                    self.poll?.invalidate()
                    self.finish()
                }
            }
        }
    }

    /// The end of the work: the times of the last slices, then nothing.
    private func finish() {
        kind = .none
        shown = false
        showTask?.cancel()
        var parts: [String] = []
        if draftMs > 0 { parts.append(String(format: "Draft %.0f ms", draftMs)) }
        if exactMs > 0 { parts.append(String(format: "Exact %.0f ms", exactMs)) }
        text = parts.joined(separator: " · ")
        textShown = !text.isEmpty
        draftMs = 0
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.kind == .none else { return }
            self.textShown = false
        }
    }

    /// A failed slice: no bar.
    func stop() {
        poll?.invalidate()
        showTask?.cancel()
        kind = .none
        shown = false
        textShown = false
    }
}

/// The bar and its text, over the top edge of the view.
struct WorkBar: View {
    let work: WorkState

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            GeometryReader { g in
                Rectangle()
                    .fill(work.kind == .draft ? Color.secondary : Color.accentColor)
                    .frame(width: g.size.width * work.fraction, height: 2)
            }
            .frame(height: 2)
            .opacity(work.shown ? 1 : 0)
            Text(work.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(work.textShown ? 0.6 : 0)
                .padding(.trailing, 96)
        }
        .animation(.easeInOut(duration: 0.2), value: work.shown)
        .animation(.easeInOut(duration: 0.2), value: work.textShown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
