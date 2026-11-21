//! Spatial cards (web/app/spatial.js): each kind of card remembers where
//! the user put it, and its size.
//!
//! The user asked for it: "remember where I put it, leave it there, and
//! pop it up there the next time I need it". Each kind of card (the line
//! card, the range card, the part card, the history card) has one place
//! and one size for the user, in the preferences of the app (`prefs`, so a
//! test run keeps its own).
//!
//! - A drag of the head of a card moves it, and keeps its place.
//! - The grip at the lower right corner resizes it, and keeps its size.
//!   A card is at least as tall as its content: a taller size adds room at
//!   its foot.
//! - A card that opens takes its size, and goes to its place unless there
//!   it covers the thing that the user clicked (the line, the parts, the
//!   layers, the bubble): then it goes to the automatic place for this
//!   time. The place moves inside the free area of the view.
//! - A double click on the head forgets the place and the size.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import Observation
import SwiftUI

@MainActor
@Observable
final class SpatialStore {
    static let shared = SpatialStore()

    /// The place (the top left corner, points of the view) and the size of
    /// a kind; each part can be missing.
    struct Entry: Codable, Equatable {
        var x: Double?, y: Double?
        var w: Double?, h: Double?
    }

    private static let key = "spatial.v1"
    private(set) var entries: [String: Entry] = [:]
    /// The size during a drag of the grip, before it is kept.
    var live: [String: CGSize] = [:]

    private init() {
        if let d = prefs.data(forKey: Self.key), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { prefs.set(d, forKey: Self.key) }
    }

    /// The size of a kind: the live size of a resize, else the kept one.
    func size(_ kind: String) -> CGSize? {
        if let l = live[kind] { return l }
        guard let e = entries[kind], let w = e.w else { return nil }
        return CGSize(width: w, height: e.h ?? 0)
    }

    /// The kept place of a kind as the center of a card of `size`, moved
    /// inside the free area of the view (the tool strip, the toolbar, the
    /// layer slider, and the bottom bar left out): whole when it fits. nil: no place, or there
    /// the card covers `box`.
    func center(_ kind: String, size: CGSize, area: CGSize, bottom: CGFloat, avoiding box: CGRect?) -> CGPoint? {
        guard let e = entries[kind], let x0 = e.x, let y0 = e.y else { return nil }
        let left: CGFloat = 64, top: CGFloat = 60, right = area.width - 84, foot = area.height - max(bottom, 8)
        let x = max(left, min(CGFloat(x0), right - size.width))
        // A card that fits stays whole in the view; a taller one keeps its
        // head in it.
        let y = max(top, min(CGFloat(y0), foot - (size.height <= foot - top ? size.height : 80)))
        let r = CGRect(x: x, y: y, width: size.width, height: size.height)
        if let box, r.intersects(box) { return nil }
        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }

    /// A drag of the head put the card with its center at `center`.
    func moved(_ kind: String, center: CGPoint, size: CGSize) {
        var e = entries[kind] ?? Entry()
        e.x = Double(center.x - size.width / 2)
        e.y = Double(center.y - size.height / 2)
        entries[kind] = e
        save()
    }

    /// The end of a resize.
    func resized(_ kind: String, to size: CGSize) {
        live[kind] = nil
        var e = entries[kind] ?? Entry()
        e.w = Double(size.width)
        e.h = Double(size.height)
        entries[kind] = e
        save()
    }

    /// A double click on the head: the place and the size go.
    func forget(_ kind: String) {
        live[kind] = nil
        entries[kind] = nil
        save()
    }
}

extension View {
    /// The width of a card of `kind` (its kept size, else `width`), and its
    /// kept height as a least height.
    func spatialSize(_ kind: String, width: CGFloat) -> some View {
        let s = SpatialStore.shared.size(kind)
        return frame(width: s.map { max($0.width, 220) } ?? width)
            .frame(minHeight: s.map { $0.height } ?? 0, alignment: .top)
    }

    /// The grip of a card of `kind` at its lower right corner. `size` is the
    /// size of the card now.
    func spatialGrip(_ kind: String, size: CGSize) -> some View {
        overlay(alignment: .bottomTrailing) { SpatialGrip(kind: kind, size: size) }
    }
}

/// The grip at the lower right corner of a card: a drag resizes the card.
struct SpatialGrip: View {
    let kind: String
    let size: CGSize
    @State private var start: CGSize?

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .padding(2)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let s0 = start ?? size
                    start = s0
                    SpatialStore.shared.live[kind] = CGSize(width: max(220, s0.width + g.translation.width), height: max(80, s0.height + g.translation.height))
                }
                .onEnded { _ in
                    if let s = SpatialStore.shared.live[kind] { SpatialStore.shared.resized(kind, to: s) }
                    start = nil
                })
            .help("Drag to resize the card. A double click on its head puts it back.")
            .accessibilityLabel("Resize")
    }
}

/// The close button of a card, as in the web and Linux apps: a flat ×
/// at the size of the title, in a hit area of 24 points. Put it in the
/// head of the card, in an HStack aligned on the first text baseline, so
/// it stays on the first line of a title that wraps.
struct CloseMark: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}
