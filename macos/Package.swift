// swift-tools-version: 6.0
// The macOS app of zslice: a SwiftUI shell over the Zig core.
// Build the core first with build-core.sh. It writes lib/libzslice.a.
// SPDX-License-Identifier: AGPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "ZSlice",
    platforms: [.macOS(.v14)],
    targets: [
        // The C API of the core (include/zslice-app.h).
        .systemLibrary(name: "CZslice", path: "Sources/CZslice"),
        .executableTarget(
            name: "ZSlice",
            dependencies: ["CZslice"],
            path: "Sources/ZSlice",
            // The icon: Xcode compiles the catalog, and make-app.sh makes
            // the .icns of the set.
            exclude: ["Assets.xcassets"],
            linkerSettings: [
                .unsafeFlags(["-L", "lib"]),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
