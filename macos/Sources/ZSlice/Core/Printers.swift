//! The printers: the library of printer models of the core, and the
//! printers of the user (docs/user/getting-started.md, "Add your printer"
//! and "Printers").
//!
//! The library (zs_printers_builtin, src/printers/library.txt) has the
//! brands, the models, the machine profile of each model, and the files of
//! its bed model. The app bundle has the bed files (Contents/Resources/
//! beds); a build from the source tree reads them from src/printers/beds.
//!
//! A printer of the user has a name, the id of its model, the machine
//! settings (a profile text of the core), and a connection: none (export a
//! file), printdeck, OctoPrint, or Moonraker, with its address. A printdeck
//! with a certificate has an https address too. The app keeps the list in
//! ~/Library/Application Support/zslice/printers.json, and the API key of
//! each printer in the Keychain of macOS, never in a file.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation
import Observation
import Security

/// The library of printer models of the core.
@MainActor
final class PrinterLibrary {
    static let shared = PrinterLibrary()
    let lib: OpaquePointer?

    private init() {
        var p: OpaquePointer?
        lib = zs_printers_builtin(&p) == 0 ? p : nil
    }

    var brands: [(name: String, range: Range<Int>)] {
        guard let lib else { return [] }
        return (0 ..< zs_printers_brand_count(lib)).compactMap { i in
            var name: UnsafePointer<CChar>?
            var first = 0, end = 0
            guard zs_printers_brand_get(lib, i, &name, &first, &end) == 0 else { return nil }
            return (coreText(name), first ..< end)
        }
    }

    func model(_ i: Int) -> zs_printer_model? {
        guard let lib else { return nil }
        var m = zs_printer_model()
        return zs_printers_model_get(lib, i, &m) == 0 ? m : nil
    }

    /// The printers that most people have (zs_printers_popular).
    var popular: [Int] {
        guard let lib else { return [] }
        var out = [UInt32](repeating: 0, count: 64)
        let n = zs_printers_popular(lib, &out, out.count)
        return out.prefix(min(n, out.count)).map(Int.init)
    }

    /// The models that match a query, best first (brand -1: all).
    func search(_ query: String, brand: Int = -1, max: Int = 400) -> [Int] {
        guard let lib else { return [] }
        var out = [UInt32](repeating: 0, count: max)
        let n = zs_printers_search(lib, query, brand, &out, max)
        return out.prefix(min(n, max)).map(Int.init)
    }

    func facts(_ i: Int) -> String {
        guard let lib else { return "" }
        return coreString { zs_printers_facts(lib, i, $0, $1, $2) } ?? ""
    }

    func sources(_ i: Int) -> String {
        guard let lib else { return "" }
        return coreString { zs_printers_sources(lib, i, $0, $1, $2) } ?? ""
    }

    /// The machine profile of a model, with a nozzle (0: its default).
    func profile(_ i: Int, nozzle: Double = 0) -> String? {
        guard let lib else { return nil }
        return coreString { zs_printers_profile(lib, i, nozzle, $0, $1, $2) }
    }

    /// The model that fits a printer on the network: a name hint, its bed,
    /// and its nozzle (0 when not known: the stock tool head of a family).
    func match(hint: String, bedX: Double, bedY: Double, height: Double, nozzle: Double = 0) -> Int? {
        guard let lib else { return nil }
        let i = zs_printers_match_nozzle(lib, hint, bedX, bedY, height, nozzle)
        return i >= 0 ? i : nil
    }

    /// The model of a product name ("Bambu Lab X2D", web/app/printers.js
    /// findModel): the first of the 8 best of the search whose brand, name,
    /// and title have all the words of the product name. nil if none.
    func findModel(product: String) -> Int? {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !(("a" ... "z").contains($0) || ("0" ... "9").contains($0)) }).map(String.init)
        }
        let want = words(product)
        guard !want.isEmpty else { return nil }
        for i in search(product, brand: -1, max: 8) {
            guard let m = model(i) else { continue }
            let have = Set(words("\(coreText(m.brand)) \(coreText(m.name)) \(coreText(m.title))"))
            if want.allSatisfy(have.contains) { return i }
        }
        return nil
    }

    func find(id: String) -> Int? {
        guard let lib else { return nil }
        let i = zs_printers_find(lib, id)
        return i >= 0 ? i : nil
    }

    /// The model of the machine settings of an app (machine.model, else a
    /// machine.name that is the title of a model).
    func model(of core: OpaquePointer) -> Int? {
        guard let lib else { return nil }
        let id = coreString { zs_app_setting_get(core, "machine.model", $0, $1, $2) } ?? ""
        let name = coreString { zs_app_setting_get(core, "machine.name", $0, $1, $2) } ?? ""
        let i = zs_printers_find_machine(lib, id, name)
        return i >= 0 ? i : nil
    }

    /// The folder of the bed files.
    static let bedsFolder: URL? = {
        if let env = ProcessInfo.processInfo.environment["ZSLICE_BEDS_DIR"] { return URL(fileURLWithPath: env) }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("beds"), FileManager.default.fileExists(atPath: r.path) { return r }
        // A build from the source tree: macos/.build/<config>/ZSlice.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let beds = dir.appendingPathComponent("src/printers/beds")
            if FileManager.default.fileExists(atPath: beds.path) { return beds }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    /// Shows the bed model of the printer of an app in a view, or the grid
    /// alone if it has none.
    func showBed(of core: OpaquePointer, in view: OpaquePointer) {
        guard let lib, let i = model(of: core) else {
            zs_view_clear_bed(view)
            return
        }
        var bed = zs_printer_bed()
        guard zs_printers_bed(lib, i, &bed) == 0, let dir = Self.bedsFolder else {
            zs_view_clear_bed(view)
            return
        }
        func bytes(_ name: UnsafePointer<CChar>?) -> Data? {
            let n = coreText(name)
            return n.isEmpty ? nil : try? Data(contentsOf: dir.appendingPathComponent(n))
        }
        let mesh = bytes(bed.mesh), tex = bytes(bed.texture)
        let rc = (mesh ?? Data()).withUnsafeBytes { m in
            (tex ?? Data()).withUnsafeBytes { t in
                zs_view_set_bed(view, lib, i, m.bindMemory(to: UInt8.self).baseAddress, mesh?.count ?? 0,
                                t.bindMemory(to: UInt8.self).baseAddress, tex?.count ?? 0)
            }
        }
        if rc != 0 { zs_view_clear_bed(view) }
    }
}

/// A printer of the user.
struct Printer: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case none, printdeck, octoprint, moonraker, bambu

        var title: String {
            switch self {
            case .none: "None (export a file)"
            case .printdeck: "printdeck"
            case .octoprint: "OctoPrint"
            case .moonraker: "Moonraker (Klipper)"
            case .bambu: "Bambu Lab (LAN mode, untested)"
            }
        }
    }

    var id = UUID()
    var name: String
    /// The id of its model in the library, or "".
    var model: String = ""
    /// The machine settings: a profile text of the core.
    var machine: String = ""
    var kind = Kind.none
    var url = ""
    /// The https address of a printdeck with a certificate, or "".
    var https = ""
    /// Bambu Lab: the serial number (for the MQTT topics), else "".
    var serial = ""

    /// A printer added from the list of a deck: its name in that list
    /// (/slicer/printer.json), so a send can check that the address still
    /// leads to it. "" for other printers.
    var deckName = ""

    /// A Bambu Lab printer behind a printdeck: a printdeck printer of a
    /// Bambu Lab model. The deck takes a .gcode.3mf in place of G-code, and
    /// sends it to the printer itself.
    var bambuDeck: Bool { kind == .printdeck && model.hasPrefix("bambu-lab-") }

    init(name: String, model: String = "", machine: String = "", kind: Kind = .none, url: String = "") {
        self.name = name
        self.model = model
        self.machine = machine
        self.kind = kind
        self.url = url
    }

    /// A file of an older app may lack a field, and a newer one may have
    /// a kind that this app does not know: each field has its default then.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Printer"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        machine = try c.decodeIfPresent(String.self, forKey: .machine) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? Kind.none
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        https = try c.decodeIfPresent(String.self, forKey: .https) ?? ""
        serial = try c.decodeIfPresent(String.self, forKey: .serial) ?? ""
        deckName = try c.decodeIfPresent(String.self, forKey: .deckName) ?? ""
    }

    /// The API key, in the Keychain (for a Bambu printer: its access code).
    var apiKey: String {
        get { Keychain.read(account: id.uuidString) ?? "" }
        nonmutating set { Keychain.write(newValue, account: id.uuidString) }
    }
}

/// The API keys of the printers in the Keychain of macOS.
enum Keychain {
    static let service = "org.beetlebug.zslice.printer"
    /// A test run (ZSLICE_FRESH) keeps its keys in memory: its printers
    /// go at its end, so their keys must not stay in the Keychain.
    private static let fresh = ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil
    nonisolated(unsafe) private static var memory: [String: String] = [:]
    private static let lock = NSLock()

    static func read(account: String) -> String? {
        if fresh { return lock.withLock { memory[account] } }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String, account: String, label: String = "zslice printer API key") {
        if fresh {
            lock.withLock { memory[account] = value.isEmpty ? nil : value }
            return
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = label
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// The printers of the user, and the current printer.
@MainActor
@Observable
final class PrinterStore {
    static let shared = PrinterStore()

    private(set) var printers: [Printer] = []
    var currentID: UUID? {
        didSet { save() }
    }

    var current: Printer? { printers.first { $0.id == currentID } }

    private var file: URL { SavedSettings.folder.appendingPathComponent("printers.json") }
    private let fresh = ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil

    private struct Saved: Codable {
        var printers: [Printer]
        var current: UUID?
    }

    private init() {
        guard !fresh, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        printers = s.printers
        currentID = s.current
    }

    private func save() {
        guard !fresh else { return }
        try? FileManager.default.createDirectory(at: SavedSettings.folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Saved(printers: printers, current: currentID)) {
            try? d.write(to: file, options: .atomic)
        }
    }

    func add(_ p: Printer) {
        printers.append(p)
        currentID = p.id
    }

    func update(_ p: Printer) {
        guard let i = printers.firstIndex(where: { $0.id == p.id }) else { return }
        printers[i] = p
        save()
    }

    func remove(_ id: UUID) {
        printers.first { $0.id == id }?.apiKey = ""
        printers.removeAll { $0.id == id }
        if currentID == id { currentID = printers.first?.id }
        save()
    }
}
