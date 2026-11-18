//! The editor of the start and the end G-code (web/app/settings.js): the
//! text over the width of the drawer, in a monospaced font, with a row of
//! the variables that the core fills (src/gcode_vars.zig). A variable
//! button inserts "{name}" at the cursor and commits. "Show the Result"
//! shows that G-code as the last slice wrote it: for the start G-code the
//! text before ";LAYER:0" (with the thumbnails as one line), for the end
//! G-code the last 40 lines before ";Filament used:".
//!
//! SwiftUI has no cursor for a TextEditor on macOS 14, so the text is an
//! NSTextView.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

struct GcodeEditor: View {
    static let names: Set<String> = ["machine.start_gcode", "machine.end_gcode"]
    static let variables = ["nozzle_temp", "first_layer_nozzle_temp", "bed_temp", "standby_temp", "layer_height",
                            "first_layer_height", "first_layer_speed", "nozzle_diameter", "filament_diameter",
                            "filament_name", "machine_name", "job_name"]

    let model: SliceModel
    let info: SettingInfo
    let entry: SettingEntry
    @State private var handle = CodeTextView.Handle()
    // ZSLICE_GCODE_RESULT=1 opens the result, for tests.
    @State private var showResult = ProcessInfo.processInfo.environment["ZSLICE_GCODE_RESULT"] != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeTextView(text: entry.value, handle: handle,
                         commit: { model.set(info.name, $0) },
                         focus: { model.history.setFocus($0 ? info.name : nil) })
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text("Insert:").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(Self.variables, id: \.self) { v in
                    Button("{\(v)}") { handle.insert("{\(v)}") }
                        .controlSize(.small)
                        .font(.caption.monospaced())
                }
            }
            Toggle("Show the Result", isOn: $showResult)
                .help("The G-code as the last slice wrote it, with each variable filled")
            if showResult {
                ScrollView {
                    Text(result)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 220)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// The part of the G-code of the last slice that this setting wrote.
    private var result: String {
        _ = model.stats
        guard let data = model.gcode() else { return "No slice yet." }
        let text = String(decoding: data, as: UTF8.self)
        if info.name == "machine.start_gcode" {
            let head = text.range(of: ";LAYER:0").map { String(text[..<$0.lowerBound]) } ?? String(text.prefix(4000))
            return dropThumbnails(head)
        }
        let body = text.range(of: ";Filament used:", options: .backwards).map { String(text[..<$0.lowerBound]) } ?? text
        return body.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
    }

    /// The thumbnail blocks (base64 PNG lines) as one line.
    private func dropThumbnails(_ s: String) -> String {
        var out: [Substring] = []
        var inside = false
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("; thumbnail begin") || line.hasPrefix("; thumbnail_JPG begin") || line.hasPrefix("; thumbnail_QOI begin") {
                if !inside { out.append("; (thumbnails)") }
                inside = true
                continue
            }
            if inside {
                if line.contains("thumbnail end") || line.contains("thumbnail_JPG end") || line.contains("thumbnail_QOI end") { inside = false }
                continue
            }
            out.append(line)
        }
        // Thumbnails one after the other show as one line.
        var merged: [Substring] = []
        for l in out where !(l == "; (thumbnails)" && merged.last == "; (thumbnails)") {
            merged.append(l)
        }
        return merged.joined(separator: "\n")
    }
}

/// An NSTextView for code: monospaced, no smart quotes or dashes. It
/// commits when it loses the focus, and `handle` inserts text at the
/// cursor (then commits).
struct CodeTextView: NSViewRepresentable {
    @MainActor
    final class Handle {
        weak var view: NSTextView?
        var commit: ((String) -> Void)?

        func insert(_ s: String) {
            guard let v = view else { return }
            v.window?.makeFirstResponder(v)
            v.insertText(s, replacementRange: v.selectedRange())
            commit?(v.string)
        }
    }

    let text: String
    let handle: Handle
    let commit: (String) -> Void
    let focus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let v = scroll.documentView as! NSTextView
        v.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        v.isAutomaticQuoteSubstitutionEnabled = false
        v.isAutomaticDashSubstitutionEnabled = false
        v.isAutomaticTextReplacementEnabled = false
        v.isAutomaticSpellingCorrectionEnabled = false
        v.isRichText = false
        v.allowsUndo = true
        v.string = text
        v.delegate = context.coordinator
        handle.view = v
        handle.commit = commit
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        handle.commit = commit
        guard let v = scroll.documentView as? NSTextView else { return }
        // A new value from the core (an undo, a profile), while the user
        // does not type.
        if v.window?.firstResponder !== v, v.string != text { v.string = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ p: CodeTextView) { parent = p }

        func textDidBeginEditing(_ notification: Notification) { parent.focus(true) }

        func textDidEndEditing(_ notification: Notification) {
            guard let v = notification.object as? NSTextView else { return }
            if v.string != parent.text { parent.commit(v.string) }
            parent.focus(false)
        }
    }
}
