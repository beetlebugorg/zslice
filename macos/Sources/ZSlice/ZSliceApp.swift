//! The macOS app of zslice: a SwiftUI shell over the Zig core.
//!
//! Each window is one document: an STL or 3MF file. The document holds the
//! bytes of the file. The window makes a SliceModel (one zs_app of the
//! core) and loads the bytes into it, and the core slices. The shell only
//! draws, reads files, and moves the events of the core to the main
//! thread. The app logic is in the core (see docs/app/README.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let stl = UTType(importedAs: "public.standard-tesselated-geometry-format", conformingTo: .threeDContent)
    static let threeMF = UTType(importedAs: "org.3mf.3mf", conformingTo: .threeDContent)
}

/// A model file. The bytes go to the core when the window opens.
struct ModelDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.stl, .threeMF]
    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@main
struct ZSliceApp: App {
    var body: some Scene {
        DocumentGroup(viewing: ModelDocument.self) { file in
            DocumentWindow(document: file.document, name: file.fileURL?.lastPathComponent ?? "model.stl")
        }
    }
}
