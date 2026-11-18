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
//! The repository is a folder on the Mac, or a public repository on GitHub
//! (owner/repo, or its address, with /tree/<branch> for a branch). GitHub:
//! the app reads the commit and the list of files through api.github.com,
//! and the files through raw.githubusercontent.com (a file in Git LFS from
//! media.githubusercontent.com), with no token, as web/app/project.js
//! does. The app reads only the files that the plates need: the files of
//! the parts on the plates, and the files of profiles/<folder>/ of the
//! profile of each plate.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation

/// Where the files of a project are.
@MainActor
protocol ProjectSource: AnyObject {
    var label: String { get }
    func read(_ path: String) async throws -> Data
    /// The paths of the files under a folder of the repository.
    func list(_ folder: String) -> [String]
}

/// A folder on the Mac.
@MainActor
final class FolderSource: ProjectSource {
    let folder: URL
    init(_ folder: URL) { self.folder = folder }
    var label: String { folder.lastPathComponent }

    func read(_ path: String) async throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(path))
    }

    func list(_ dir: String) -> [String] {
        let root = folder.appendingPathComponent(dir)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return dir + "/" + url.path.dropFirst(root.path.count + 1)
        }
    }
}

/// A public repository on GitHub, at one commit.
@MainActor
final class GitHubSource: ProjectSource {
    let owner: String, repo: String, sha: String
    private let paths: [String]
    private var cache: [String: Data] = [:]

    var label: String { "\(owner)/\(repo) @ \(sha.prefix(7))" }

    private init(owner: String, repo: String, sha: String, paths: [String]) {
        self.owner = owner
        self.repo = repo
        self.sha = sha
        self.paths = paths
    }

    /// "owner/repo", "https://github.com/owner/repo", or ".../tree/branch".
    static func open(_ text: String) async throws -> GitHubSource {
        var t = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www."] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        if t.hasPrefix("github.com/") { t.removeFirst("github.com/".count) }
        let parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw Project.Failure(message: "Type owner/repo, or the address of a repository on github.com.") }
        let owner = parts[0]
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let ref = parts.count >= 4 && parts[2] == "tree" ? parts[3...].joined(separator: "/") : nil
        let api = "https://api.github.com/repos/\(owner)/\(repo)"
        func get(_ url: String) async throws -> [String: Any] {
            guard let u = URL(string: url) else { throw Project.Failure(message: "A bad address.") }
            var r = URLRequest(url: u)
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw Project.Failure(message: "GitHub has no public repository \(owner)/\(repo)\(ref.map { " with \($0)" } ?? "").") }
            if code == 403 || code == 429 {
                throw Project.Failure(message: "GitHub refused the request (the limit of requests with no login is 60 an hour). Try again later.")
            }
            guard (200 ..< 300).contains(code), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                throw Project.Failure(message: "GitHub answered \(code).")
            }
            return j
        }
        let branch: String
        if let ref {
            branch = ref
        } else {
            branch = try await get(api)["default_branch"] as? String ?? "main"
        }
        let commit = try await get("\(api)/commits/\(branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)")
        guard let sha = commit["sha"] as? String else { throw Project.Failure(message: "GitHub gave no commit.") }
        let tree = try await get("\(api)/git/trees/\(sha)?recursive=1")
        let paths = (tree["tree"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "blob" ? $0["path"] as? String : nil }
        return GitHubSource(owner: owner, repo: repo, sha: sha, paths: paths)
    }

    func list(_ folder: String) -> [String] { paths.filter { $0.hasPrefix(folder + "/") } }

    func read(_ path: String) async throws -> Data {
        if let d = cache[path] { return d }
        let enc = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        func fetch(_ host: String) async throws -> Data {
            guard let u = URL(string: "\(host)/\(owner)/\(repo)/\(sha)/\(enc)") else { throw Project.Failure(message: "A bad path: \(path).") }
            let (d, r) = try await URLSession.shared.data(from: u)
            guard ((r as? HTTPURLResponse)?.statusCode ?? 0) == 200 else { throw Project.Failure(message: "GitHub has no file \(path).") }
            return d
        }
        var d = try await fetch("https://raw.githubusercontent.com")
        // A Git LFS pointer: the file is in the LFS storage.
        if d.count < 400, String(decoding: d.prefix(40), as: UTF8.self).hasPrefix("version https://git-lfs") {
            d = try await fetch("https://media.githubusercontent.com/media")
        }
        cache[path] = d
        return d
    }
}

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
        /// The count of the part on the plates of the plan (0: off).
        var count: Int
        var printer: String
        var rowID: String { "part-\(id)" }
    }

    @MainActor
    private static func plan(_ yml: String, _ counts: String?) throws -> [String: Any] {
        guard let text = coreString({ zs_project_plan(yml, counts, $0, $1, $2) }),
              let plan = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw Failure(message: "The printdeck.yml does not read.")
        }
        if let error = plan["error"] as? String {
            throw Failure(message: "printdeck.yml, line \(plan["line"] as? Int ?? 0): \(error)")
        }
        return plan
    }

    /// The parts of the plan of a printdeck.yml, with their counts on the
    /// plates of the plan.
    @MainActor
    static func parts(yml: String) -> [Part] {
        guard let plan = try? plan(yml, nil) else { return [] }
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

    /// Loads the plates of a project into a set. counts: "n,n,..." with an
    /// entry for each part ("-": the count of the plan, 0: not on a plate),
    /// or nil. Returns the name of the project and its printdeck.yml.
    @MainActor
    static func load(_ source: ProjectSource, into set: OpaquePointer, counts: String? = nil) async throws -> (name: String, yml: String) {
        guard let ymlData = try? await source.read("printdeck.yml") else {
            throw Failure(message: "The repository has no printdeck.yml at its root.")
        }
        let yml = String(decoding: ymlData, as: UTF8.self)
        let plan = try plan(yml, counts)
        let parts = plan["parts"] as? [[String: Any]] ?? []
        // The files of the parts on the plates, and the profile folders.
        var paths = Set<String>()
        var folders = Set<String>()
        for plate in plan["plates"] as? [[String: Any]] ?? [] {
            if let profile = plate["profile"] as? String, let f = profile.split(separator: "/").first { folders.insert(String(f)) }
            for item in plate["items"] as? [[String: Any]] ?? [] {
                guard let i = item["part"] as? Int, i < parts.count else { continue }
                for f in parts[i]["files"] as? [String] ?? [] { paths.insert(f) }
            }
        }
        for f in folders { paths.formUnion(source.list("profiles/\(f)")) }
        guard let files = zs_files_new() else { throw Failure(message: "No memory.") }
        defer { zs_files_free(files) }
        for p in paths.sorted() {
            guard let data = try? await source.read(p) else { continue }
            _ = data.withUnsafeBytes { zs_files_add(files, p, $0.baseAddress, $0.count) }
        }
        var message = [CChar](repeating: 0, count: 512)
        let rc = zs_set_project_load(set, files, yml, counts, 0, &message, message.count)
        guard rc == 0 else {
            let why = message.withUnsafeBufferPointer { coreText($0.baseAddress) }
            throw Failure(message: why.isEmpty ? statusText(rc) : why)
        }
        return (plan["name"] as? String ?? source.label, yml)
    }
}

extension SliceModel {
    /// Opens a project in place of the plates of the window. counts: the
    /// counts of the parts (nil: the counts of the plan).
    func openProject(_ source: ProjectSource, counts: [Int?]? = nil) async throws {
        history.commit()
        let text = counts.map { $0.map { $0.map(String.init) ?? "-" }.joined(separator: ",") }
        let loaded = try await Project.load(source, into: set, counts: text)
        readPlatesAfterLoad()
        name = loaded.name
        project = ProjectState(source: source, parts: Project.parts(yml: loaded.yml), counts: counts ?? [])
    }
}

/// The open project of a window: its source, its parts, and the counts that
/// the user set (nil: the count of the plan).
struct ProjectState {
    var source: ProjectSource
    var parts: [Project.Part]
    var counts: [Int?]

    func count(_ i: Int) -> Int {
        (i < counts.count ? counts[i] : nil) ?? parts[i].count
    }
}
