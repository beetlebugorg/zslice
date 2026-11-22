//! Undo, Redo, and the history button of the bottom bar (web/app/history.js,
//! renderButton; linux/src/ui/history.c, zg_history_tools_new). The button
//! is a clock with an arrow against the clock. Its badge counts the changes
//! since the window opened its file or saved it (History.unsaved). A click
//! opens the History list in a popover over the button (HistoryPage.swift).
//! ⌘Y opens it too; Esc closes it.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct HistoryTools: View {
    let workspace: Workspace
    private var model: SliceModel { workspace.model }

    var body: some View {
        let history = model.history
        let n = history.count
        let now = history.current
        let changes = max(0, n - 1)
        let unsaved = history.unsaved(since: model.savedAt)
        HStack(spacing: 4) {
            Button { history.undoManager.undo() } label: { ToolGlyph(name: "undo") }
                .disabled(now == 0)
                .help("Undo (⌘Z)")
                .accessibilityLabel("Undo")
            Button { history.undoManager.redo() } label: { ToolGlyph(name: "redo") }
                .disabled(now + 1 >= n)
                .help("Redo (⇧⌘Z)")
                .accessibilityLabel("Redo")
            Button { workspace.historyOpen.toggle() } label: {
                ToolGlyph(name: "history")
                    .overlay(alignment: .topTrailing) {
                        if unsaved > 0 {
                            Text(unsaved > 9 ? "9+" : "\(unsaved)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 13, minHeight: 13)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .help("History (\(Self.words(changes))).\(unsaved > 0 ? " \(unsaved) since you opened or saved." : "") ⌘Y")
            .accessibilityLabel("History, \(Self.words(changes))\(unsaved > 0 ? ", \(unsaved) not saved" : "")")
            .popover(isPresented: Bindable(workspace).historyOpen, arrowEdge: .top) {
                HistoryPage(history: history, workspace: workspace)
                    .frame(width: 400, height: 480)
            }
        }
        .buttonStyle(.borderless)
    }

    static func words(_ k: Int) -> String { "\(k) change\(k == 1 ? "" : "s")" }
}
