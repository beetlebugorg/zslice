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

    /// A part of the plan, for the Project page.
    struct Part: Identifiable {
        var id: Int
        var name: String
        var group: String
        var description: String
        /// The count of the file (the default when the user sets none).
        var count: Int
        var printer: String
        var rowID: String { "part-\(id)" }
    }

    /// The parts of the plan of a printdeck.yml (all parts: counts nil).
    @MainActor
    static func parts(yml: String) -> [Part] {
        guard let text = coreString({ zs_project_plan(yml, nil, $0, $1, $2) }),
              let plan = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return [] }
        // The count of a part on the plates of the plan: 0 for a part that
        // the plan leaves off (another variant of a part).
        var onPlates: [Int: Int] = [:]
        for plate in plan["plates"] as? [[String: Any]] ?? [] {
            for item in plate["items"] as? [[String: Any]] ?? [] {
                if let i = item["part"] as? Int { onPlates[i, default: 0] += item["count"] as? Int ?? 1 }
            }
        }
        return (plan["parts"] as? [[String: Any]] ?? []).enumerated().map { i, p in
            Part(id: i, name: p["name"] as? String ?? "", group: p["group"] as? String ?? "",
                 description: p["description"] as? String ?? "", count: onPlates[i] ?? 0,
                 printer: p["printer"] as? String ?? "")
        }
    }

    /// Loads the plates of the project in a folder into a set. counts: "n,n,..."
    /// with an entry for each part ("-": the count of the file, 0: not on a
    /// plate), or nil for all parts.
    @MainActor
    static func load(folder: URL, into set: OpaquePointer, counts: String? = nil) throws -> String {
        let ymlURL = folder.appendingPathComponent("printdeck.yml")
        guard let yml = try? String(contentsOf: ymlURL, encoding: .utf8) else {
            throw Failure(message: "The folder has no printdeck.yml.")
        }
        guard let planText = coreString({ zs_project_plan(yml, counts, $0, $1, $2) }),
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
        let rc = zs_set_project_load(set, files, yml, counts, 0, &message, message.count)
        guard rc == 0 else {
            let why = message.withUnsafeBufferPointer { coreText($0.baseAddress) }
            throw Failure(message: why.isEmpty ? statusText(rc) : why)
        }
        return plan["name"] as? String ?? folder.lastPathComponent
    }
}

extension SliceModel {
    /// Opens the project of a folder in place of the plates of the window.
    /// counts: the counts of the parts (nil: the counts of the file).
    func openProject(_ folder: URL, counts: [Int?]? = nil) throws {
        history.commit()
        let text = counts.map { $0.map { $0.map(String.init) ?? "-" }.joined(separator: ",") }
        let name = try Project.load(folder: folder, into: set, counts: text)
        readPlatesAfterLoad()
        self.name = name
        project = ProjectState(folder: folder, parts: Project.parts(yml: (try? String(contentsOf: folder.appendingPathComponent("printdeck.yml"), encoding: .utf8)) ?? ""),
                               counts: counts ?? [])
    }
}

/// The open project of a window: its folder, its parts, and the counts that
/// the user set (nil: the count of the file).
struct ProjectState {
    var folder: URL
    var parts: [Project.Part]
    var counts: [Int?]

    func count(_ i: Int) -> Int {
        (i < counts.count ? counts[i] : nil) ?? parts[i].count
    }
}
