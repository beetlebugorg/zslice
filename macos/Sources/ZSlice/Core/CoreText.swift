//! The texts of the core: a C string, and the words for a status code.
//! The app and the Quick Look preview share this file.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation

/// The text of a C string of the core ("" for NULL).
func coreText(_ p: UnsafePointer<CChar>?) -> String {
    guard let p else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: p, count: strlen(p)), as: UTF8.self)
}

/// A status in plain words, with what to do (zs_status_message), the same
/// in each app: for the user.
func statusText(_ rc: Int32) -> String {
    coreText(zs_status_message(rc))
}

/// The name of a status (zs_status_string): for the logs.
func statusName(_ rc: Int32) -> String {
    coreText(zs_status_string(rc))
}
