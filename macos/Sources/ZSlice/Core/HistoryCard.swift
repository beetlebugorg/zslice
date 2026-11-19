//! The card of a history step (web/app/history.js, showCard): a hover of
//! 350 ms on a bubble of the timeline opens it over the bubble, in the
//! style of the line card. It has the glyph of the step, "Change N", its
//! kind and time, each change in words, and "The value now:" with an
//! editor for each setting of the plate that the step changed (a change
//! there is a new step), and Go to This Step.
//!
//! The card stays while the pointer is on the bubble or on the card, or
//! while one of its editors has the focus; 400 ms after the pointer leaves
//! both, it closes. Another bubble moves it at once.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The step of the card, and the frame of its bubble (global).
struct HistoryCardState: Equatable {
    var step: Int
    var anchor: CGRect
}

extension Workspace {
    /// The pointer on (or off) the bubble of step i.
    func historyHover(_ i: Int, inside: Bool, frame: CGRect) {
        historyCardTask?.cancel()
        if inside {
            if historyCard?.step == i { return }
            let wait = historyCard == nil ? 350 : 0
            historyCardTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(wait))
                guard let self, !Task.isCancelled else { return }
                historyCard = HistoryCardState(step: i, anchor: frame)
            }
        } else {
            historyCardLater()
        }
    }

    /// The pointer on (or off) the card.
    func historyCardHover(_ inside: Bool) {
        historyCardHovered = inside
        historyCardTask?.cancel()
        if !inside { historyCardLater() }
    }

    /// Closes the card in 400 ms, unless the pointer is on it or one of
    /// its editors has the focus.
    func historyCardLater() {
        historyCardTask?.cancel()
        historyCardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, !historyCardHovered else { return }
            if let key = model.history.focusKey, let c = historyCard, historyCardKeys(c.step).contains(key) { return }
            historyCard = nil
        }
    }

    func closeHistoryCard() {
        historyCardTask?.cancel()
        historyCardHovered = false
        historyCard = nil
    }

    /// The settings of the plate that step i changed (the change lines
    /// "scope\tkey\tbefore\tafter" with a scope of no ":"), once each, in
    /// order.
    func historyCardKeys(_ i: Int) -> [String] {
        guard i > 0, let s = model.history.step(i) else { return [] }
        var seen = Set<String>()
        return s.changes.compactMap { line in
            // "scope\tkey\tbefore\tafter"
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].contains(":"), SettingInfo.byName[f[1]] != nil, seen.insert(f[1]).inserted else { return nil }
            return f[1]
        }
    }

    /// The settings pane at a setting.
    func openSetting(_ name: String) {
        guard let info = SettingInfo.byName[name] else { return }
        showSettings = true
        settingsPath = [.section(group: info.group, section: info.section), .setting(name)]
    }
}
