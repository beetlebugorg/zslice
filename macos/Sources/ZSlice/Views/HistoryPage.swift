//! The History page of the drawer (linux/src/ui/history.c,
//! web/app/history.js): the steps of the undo list of the plate, the newest
//! first. Each step has the badge of its kind, its number and time, and its
//! changes in words. A click on a step goes to it, and the plate slices at
//! that step. Each change of the step now or an earlier step has an undo
//! button that undoes only that change and keeps the later ones. The menu
//! of a step clears the history after it. Line Edits at the top lists the
//! edits of single lines (zs_app_edit_*), each with × to remove it, and
//! marks an edit whose line is not in this slice.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct HistoryPage: View {
    let history: History
    var workspace: Workspace? = nil
    @State private var error: String?

    var body: some View {
        let n = history.count
        let now = history.current
        List {
            if let workspace, !workspace.lineEdits.isEmpty {
                let edits = workspace.lineEdits
                Section("Line Edits (\(edits.count))") {
                    ForEach(edits) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.text)
                                if e.waits {
                                    Text("Waits: its line is not in this slice.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button { workspace.removeEdit(e.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
                                .help("Remove this edit")
                        }
                    }
                }
            }
            if n <= 1 {
                Text("No changes yet. Each change of a setting or of the plate shows here, and you can go back to it.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach((0 ..< n).reversed(), id: \.self) { i in
                    if let s = history.step(i) {
                        StepRow(history: history, step: s, now: now, error: $error)
                            .contentShape(Rectangle())
                            .onTapGesture { if i != now { history.go(to: i) } }
                            .contextMenu {
                                Button("Go to This Change") { history.go(to: i) }
                                    .disabled(i == now)
                                Button(i < now ? "Go Here and Clear the Later Changes" : "Clear the Later Changes") {
                                    history.truncate(after: i)
                                }
                                .disabled(i + 1 >= n)
                            }
                    }
                }
            }
        }
        .alert("The change was not undone", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

private struct StepRow: View {
    let history: History
    let step: History.Step
    let now: Int
    @Binding var error: String?

    var body: some View {
        let i = step.id
        let look = History.look(step.kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(look.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(look.color, in: Capsule())
                Text(i == 0 ? "Start" : "Change \(i)").font(.headline)
                Text(step.time, style: .time).foregroundStyle(.secondary).font(.caption)
                Spacer()
                if i == now {
                    Text("Now").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            if i == 0 {
                Text("The settings and the plate when the history started.").foregroundStyle(.secondary)
            } else if step.words.isEmpty {
                Text("Other changes (formulas, global settings, or the plate).").foregroundStyle(.secondary)
            }
            ForEach(Array(zip(step.words, step.changes).enumerated()), id: \.offset) { _, pair in
                let (words, line) = pair
                let parts = words.split(separator: "\t", maxSplits: 1).map(String.init)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(parts.first ?? "").font(.caption).foregroundStyle(.secondary)
                        Text(parts.count > 1 ? parts[1] : "")
                    }
                    Spacer()
                    if i <= now && History.revertible(line) {
                        Button {
                            error = history.revert(line)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Undo only this change. The later changes stay.")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(i > now ? 0.5 : 1)
    }
}
