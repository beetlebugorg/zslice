//! Throttle: runs an action at most once in each interval while its input
//! changes, and once more with the last input at the end. A slider drag
//! then slices during the drag (web/app/settings.js throttles to 90 ms), so
//! the view follows the drag, and the last value always slices.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

@MainActor
final class Throttle {
    private let interval: Duration
    private var waiting: Task<Void, Never>?
    private var pending: (() -> Void)?

    init(_ interval: Duration = .milliseconds(90)) {
        self.interval = interval
    }

    func run(_ action: @escaping () -> Void) {
        if waiting == nil {
            action()
            waiting = Task { @MainActor [weak self] in await self?.tick() }
        } else {
            pending = action
        }
    }

    private func tick() async {
        while true {
            try? await Task.sleep(for: interval)
            guard let next = pending else { break }
            pending = nil
            next()
        }
        waiting = nil
    }
}
