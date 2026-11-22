//! The History list (linux/src/ui/history.c, web/app/history.js), in the
//! popover of the history button of the bottom bar: the steps of the undo
//! list of the plate, the newest first. The head says how many changes
//! there are, and the step now when it is not the last. Each step has the
//! glyph of its kind on its color, its number and kind, its time, and Now
//! or Go to. Go to slices the plate as it was at that step; the later steps
//! stay until the next change. Each change of the step now or an earlier
//! step has an undo button that undoes only that change and keeps the later
//! ones, and a double-click on a change opens its setting. The menu of a
//! step clears the history after it, and so does the button at the foot.
//! ↑ and ↓ go to the next and the previous step. Line Edits at the top
//! lists the edits of single lines (zs_app_edit_*), each with × to remove
//! it, and marks an edit whose line is not in this slice.
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
        VStack(spacing: 0) {
            head(n: n, now: now)
            Divider()
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
                            StepRow(history: history, workspace: workspace, step: s, now: now, error: $error)
                                .contentShape(Rectangle())
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
            // The steps after the step now: one button clears them.
            if now + 1 < n {
                let later = n - 1 - now
                Divider()
                HStack {
                    Spacer()
                    Button(later == 1 ? "Clear the Later Change" : "Clear the \(later) Later Changes") {
                        history.truncate(after: now)
                    }
                    .help("The changes after the step now go from the history. Redo cannot bring them back.")
                }
                .padding(8)
            }
        }
        .focusable()
        .focusEffectDisabled()
        // ↑: the next step; ↓: the step before.
        .onKeyPress(.upArrow) {
            guard now + 1 < n else { return .ignored }
            history.go(to: now + 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard now > 0 else { return .ignored }
            history.go(to: now - 1)
            return .handled
        }
        .alert("The change was not undone", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// "History", "5 changes, at change 3", and ×.
    private func head(n: Int, now: Int) -> some View {
        let changes = max(0, n - 1)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("History").font(.headline)
            if changes > 0 {
                Text(HistoryTools.words(changes) + (now + 1 < n ? ", at change \(now)" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let workspace {
                Button { workspace.historyOpen = false } label: { CloseMark() }
                    .buttonStyle(.borderless)
                    .help("Close the history (Esc)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct StepRow: View {
    let history: History
    let workspace: Workspace?
    let step: History.Step
    let now: Int
    @Binding var error: String?

    var body: some View {
        let i = step.id
        let kind = i == 0 ? "start" : step.kind
        let look = History.look(kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The glyph of the kind on its color.
                Circle()
                    .fill(look.color)
                    .overlay(HistoryGlyph(kind: kind, size: 14))
                    .frame(width: 22, height: 22)
                Text(i == 0 ? "Start" : "Change \(i)").font(.headline)
                if i > 0 {
                    Text(look.label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(step.time, style: .time).foregroundStyle(.secondary).font(.caption)
                if i == now {
                    Text("Now").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                } else {
                    Button("Go to") { history.go(to: i) }
                        .controlSize(.small)
                        .help("Go to this step: the print slices as it was then. The later changes stay until you edit something.")
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
                // "scope\tkey\tbefore\tafter": a key with a dot is a setting.
                let key = line.split(separator: "\t", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
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
                            ToolGlyph(name: "undo", size: 14)
                        }
                        .buttonStyle(.borderless)
                        .help("Undo only this change. The later changes stay.")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard let workspace, key.contains("."), SettingInfo.byName[key] != nil else { return }
                    workspace.historyOpen = false
                    workspace.openSetting(key)
                }
                .help(key.contains(".") ? "Double-click to open this setting." : "")
            }
        }
        .padding(.vertical, 4)
        .opacity(i > now ? 0.5 : 1)
    }
}

extension Workspace {
    /// The settings pane at a setting.
    func openSetting(_ name: String) {
        guard let info = SettingInfo.byName[name] else { return }
        showSettings = true
        settingsPath = [.section(group: info.group, section: info.section), .setting(name)]
    }
}
