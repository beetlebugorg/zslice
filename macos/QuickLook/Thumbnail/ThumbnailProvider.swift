//! The thumbnail of an STL, 3MF, or G-code file in Finder (a Quick Look
//! thumbnail extension): the picture of Render.swift.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let size = request.maximumSize
        let px = Int(max(size.width, size.height) * request.scale)
        let r = Render.render(request.fileURL, px: px)
        guard let img = r.image else {
            handler(nil, nil)
            return
        }
        handler(QLThumbnailReply(contextSize: size, drawing: { ctx in
            let s = min(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.draw(img, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            return true
        }), nil)
    }
}
