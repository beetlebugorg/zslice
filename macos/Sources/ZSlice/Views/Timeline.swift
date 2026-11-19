//! The timeline of the history (linux/src/ui/history.c, zg_timeline_new;
//! web/app/history.js, renderTimeline): Undo and Redo, a mark for each
//! step (the oldest at the left: a bubble in the color of its kind, with
//! its glyph, HistoryGlyph.swift), and the count. A hover on a bubble opens
//! the card of its step (HistoryCard.swift); a click goes to that step, and
//! the plate slices as it was then. The later steps stay, faint,
//! until the next change.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct Timeline: View {
    let history: History
    /// In the dock: no capsule of its own, and a narrower row of bubbles.
    var bare = false
    /// The window of the timeline: its card of a step over a bubble.
    var workspace: Workspace?
    /// Opens the History popover.
    var showHistory: () -> Void = {}
    @State private var frames: [Int: CGRect] = [:]

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
                        HStack(spacing: 0) {
                            ForEach(0 ..< n, id: \.self) { i in
                                if let s = history.step(i) {
                                    if i > 0 {
                                        // The line between two bubbles.
                                        Capsule().fill(.secondary.opacity(i > now ? 0.15 : 0.4)).frame(width: 10, height: 2)
                                    }
                                    let look = History.look(i == 0 ? "start" : s.kind)
                                    Button {
                                        workspace?.closeHistoryCard()
                                        history.go(to: i)
                                    } label: {
                                        StepBubble(kind: i == 0 ? "start" : s.kind, now: i == now, later: i > now)
                                            .frame(height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[i] = $0; workspace?.historyBubbles[i] = $0 }
                                    .onHover { inside in workspace?.historyHover(i, inside: inside, frame: frames[i] ?? .zero) }
                                    // With no card (a window of tests), the words as a tip.
                                    .help(workspace == nil ? ([i == 0 ? "Start" : "Change \(i) · \(look.label)"] + s.words.map { $0.replacingOccurrences(of: "\t", with: ": ") }).joined(separator: "\n") : "")
                                    .accessibilityLabel(i == 0 ? "Start" : "Change \(i) · \(look.label)")
                                    .id(i)
                                }
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                    // As wide as its bubbles, up to a limit; it scrolls past it.
                    .frame(width: min(bare ? 220 : 320, CGFloat(n) * 32))
                    .onAppear { proxy.scrollTo(now, anchor: .center) }
                    .onChange(of: now) { proxy.scrollTo(now, anchor: .center) }
                }
                Text("\(now) / \(n - 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Divider().frame(height: 14)
            }
            Button("History", action: showHistory)
                .font(.caption)
                .help("All the changes of the plate, the line edits, and undo of one change (⌘Y)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, bare ? 0 : 12)
        .padding(.vertical, bare ? 0 : 6)
        .background(bare ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial), in: Capsule())
    }
}
