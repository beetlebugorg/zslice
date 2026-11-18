//! The window of one document: the 3D view of the plate, with the print
//! card over it (docs/internals/one-view.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct DocumentWindow: View {
    let document: ModelDocument
    let name: String
    @State private var model = SliceModel()
    @State private var loadError: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SliceView(model: model)
                .ignoresSafeArea()
            PrintCard(model: model)
                .padding(16)
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            do {
                try model.load(name: name, data: document.data)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .alert("The file did not open", isPresented: .constant(loadError != nil)) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }
}

/// The floating card with the facts of the print.
struct PrintCard: View {
    let model: SliceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.state {
            case .slicing:
                ProgressView(value: model.progress) { Text("Slicing") }
                    .frame(width: 180)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle")
            case .done:
                if let s = model.stats {
                    Text(duration(s.print_time_s)).font(.title2.weight(.semibold))
                    Text(String(format: "%.1f g · %.2f m · %d layers", s.filament_g, s.filament_mm / 1000, s.layer_count))
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .opacity(model.state == .empty || model.state == .ready ? 0 : 1)
    }

    private func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }
}
