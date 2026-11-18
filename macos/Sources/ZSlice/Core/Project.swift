//! printdeck.yml projects (docs/user/projects.md, src/project.zig).
//!
//! A project is a repository with a printdeck.yml at its root: its parts,
//! each with its files, count, printer, Cura profile, material, and Cura
//! settings. The core plans the plates (zs_project_plan) and loads them
//! (zs_set_project_load): one plate of the set for each plate of the plan,
//! each with the profiles of its Cura stack and its parts, arranged. A
//! plate with no Cura stack (a resin plate) comes in with its parts, for
//! their footprints, and does not slice.
//!
//! The app reads only the files that the plates need: the files of the
//! parts on the plates, and the files of profiles/<folder>/ of the profile
//! of each plate.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation

enum Project {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Loads the plates of the project in a folder into a set.
    @MainActor
    static func load(folder: URL, into set: OpaquePointer) throws -> String {
        let ymlURL = folder.appendingPathComponent("printdeck.yml")
        guard let yml = try? String(contentsOf: ymlURL, encoding: .utf8) else {
            throw Failure(message: "The folder has no printdeck.yml.")
        }
        guard let planText = coreString({ zs_project_plan(yml, nil, $0, $1, $2) }),
              let plan = (try? JSONSerialization.jsonObject(with: Data(planText.utf8))) as? [String: Any] else {
            throw Failure(message: "The printdeck.yml does not read.")
        }
        if let error = plan["error"] as? String {
            throw Failure(message: "printdeck.yml, line \(plan["line"] as? Int ?? 0): \(error)")
        }
        let parts = plan["parts"] as? [[String: Any]] ?? []
        let plates = plan["plates"] as? [[String: Any]] ?? []
        // The files of the parts on the plates, and the profile folders.
        var paths = Set<String>()
        var folders = Set<String>()
        for plate in plates {
            if let profile = plate["profile"] as? String, let f = profile.split(separator: "/").first { folders.insert(String(f)) }
            for item in plate["items"] as? [[String: Any]] ?? [] {
                guard let i = item["part"] as? Int, i < parts.count else { continue }
                for f in parts[i]["files"] as? [String] ?? [] { paths.insert(f) }
            }
        }
        for f in folders {
            let dir = folder.appendingPathComponent("profiles").appendingPathComponent(f)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                paths.insert("profiles/\(f)/" + url.path.dropFirst(dir.path.count + 1))
            }
        }
        guard let files = zs_files_new() else { throw Failure(message: "No memory.") }
        defer { zs_files_free(files) }
        for p in paths {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(p)) else { continue }
            _ = data.withUnsafeBytes { zs_files_add(files, p, $0.baseAddress, $0.count) }
        }
        var message = [CChar](repeating: 0, count: 512)
        let rc = zs_set_project_load(set, files, yml, nil, 0, &message, message.count)
        guard rc == 0 else {
            let why = message.withUnsafeBufferPointer { coreText($0.baseAddress) }
            throw Failure(message: why.isEmpty ? statusText(rc) : why)
        }
        return plan["name"] as? String ?? folder.lastPathComponent
    }
}

extension SliceModel {
    /// Opens the project of a folder in place of the plates of the window.
    func openProject(_ folder: URL) throws {
        history.commit()
        let name = try Project.load(folder: folder, into: set)
        readPlatesAfterLoad()
        self.name = name
    }
}
