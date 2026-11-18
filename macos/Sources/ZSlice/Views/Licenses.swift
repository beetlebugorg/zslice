//! The licenses of zslice and of the parts in the app (Help > Licenses):
//! the components of the core (zs_license_*), and the system frameworks of
//! macOS that the app links (see REFERENCES.md, "Libraries that the app
//! shells link"). Each license text shows whole.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct LicensesView: View {
    @State private var selected = 0

    private struct Entry: Hashable {
        var name: String
        var license: String
        var text: String
    }

    private var entries: [Entry] {
        let core = (0 ..< zs_license_count()).compactMap { i -> Entry? in
            var l = zs_license()
            guard zs_license_get(i, &l) == 0 else { return nil }
            return Entry(name: coreText(l.name), license: coreText(l.license), text: coreText(l.text))
        }
        return core + [Entry(name: "macOS frameworks (SwiftUI, AppKit, Metal, QuartzCore, Compression, Security)",
                             license: "Apple system frameworks, part of macOS",
                             text: "The app links these frameworks of macOS from the system. Their code is not in the app.")]
    }

    var body: some View {
        let list = entries
        HSplitView {
            List(selection: $selected) {
                ForEach(list.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(list[i].name)
                        Text(list[i].license).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(i)
                }
            }
            .frame(minWidth: 220, maxWidth: 300)
            ScrollView {
                Text(list.indices.contains(selected) ? list[selected].text : "")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
