//! The picture of a printer camera (Core/Camera.swift), for a card of the
//! Printers page and its large view. The feed plays while the view shows:
//! a card that scrolls out of the lazy grid, or a closed page, stops it.
//! The turn of the printer (rotation, flip) applies to the picture.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct CameraView: View {
    let source: CameraSource
    var large = false
    @State private var feed: CameraFeed?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let img = feed?.image {
                let turned = source.rotation == 90 || source.rotation == 270
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: source.flipH ? -1 : 1, y: source.flipV ? -1 : 1)
                    .rotationEffect(.degrees(Double(source.rotation)))
                    .scaleEffect(turned ? CGFloat(img.height) / CGFloat(max(img.width, 1)) : 1)
            }
            if let m = feed?.message, !m.isEmpty {
                Text(m)
                    .font(large ? .callout : .caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.black.opacity(feed?.image == nil ? 0 : 0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
        .clipped()
        .onAppear {
            let f = CameraFeed(source: source, large: large)
            feed = f
            f.start()
        }
        .onDisappear {
            feed?.stop()
            feed = nil
        }
        .onChange(of: source) {
            feed?.stop()
            let f = CameraFeed(source: source, large: large)
            feed = f
            f.start()
        }
    }
}

/// The camera of one printer, large, in a sheet.
struct LargeCamera: View {
    let printer: Printer
    let source: CameraSource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(printer.name).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            CameraView(source: source, large: true)
                .aspectRatio(4 / 3, contentMode: .fit)
        }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 520)
    }
}
