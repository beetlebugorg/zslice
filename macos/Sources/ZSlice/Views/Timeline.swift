//! The timeline of the history (linux/src/ui/history.c, zg_timeline_new;
//! web/app/history.js, renderTimeline): Undo and Redo, a mark for each
//! step (the oldest at the left, in the color of its kind), and the count.
//! The pointer over a mark shows its changes in words; a click goes to that
//! step, and the plate slices as it was then. The later steps stay, faint,
//! until the next change.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct Timeline: View {
    let history: History
    /// Opens the History popover.
    var showHistory: () -> Void = {}

    var body: some View {
        let n = history.count
        let now = history.current
        HStack(spacing: 6) {
            if n > 1 {
                Button { history.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!history.undoManager.canUndo)
                    .help("Undo (⌘Z)")
                Button { history.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!history.undoManager.canRedo)
                    .help("Redo (⇧⌘Z)")
                Divider().frame(height: 14)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(0 ..< n, id: \.self) { i in
                                if let s = history.step(i) {
                                    let look = History.look(s.kind)
                                    Button { history.go(to: i) } label: {
                                        Circle()
                                            .fill(look.color)
                                            .frame(width: i == now ? 12 : 9, height: i == now ? 12 : 9)
                                            .overlay(Circle().strokeBorder(.white, lineWidth: i == now ? 2 : 0))
                                            .opacity(i > now ? 0.35 : 1)
                                            .frame(width: 14, height: 14)
                                    }
                                    .buttonStyle(.plain)
                                    .help(([i == 0 ? "Start" : "Change \(i) · \(look.label)"] + s.words.map { $0.replacingOccurrences(of: "\t", with: ": ") })
                                        .joined(separator: "\n"))
                                    .id(i)
                                }
                            }
                        }
                    }
                    // As wide as its marks, up to a limit; it scrolls past it.
                    .frame(width: min(260, CGFloat(n) * 17))
                    .onAppear { proxy.scrollTo(now) }
                    .onChange(of: now) { proxy.scrollTo(now) }
                }
                Text("\(now) / \(n - 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Divider().frame(height: 14)
            }
            Button("History", action: showHistory)
                .font(.caption)
                .help("All the changes of the plate, the line edits, and undo of one change (⌘Y)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}
