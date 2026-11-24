import AppKit
import Foundation

struct SchoolAccount: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    var createdAt: Date
}

/// Local accounts. Every account keeps its own session, tasks, grades, reports and attachments
/// under `Users/<id>/`, so two school accounts on one Mac never share data.
enum Accounts {
    static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/作业速览", isDirectory: true)
    static let manifestURL = base.appendingPathComponent("accounts.json")
    static let users = base.appendingPathComponent("Users", isDirectory: true)
    static let activeKey = "activeAccountID"
    static let defaultID = "default"
    static let keychainPrefix = "cn.schoolis.naisstu.SP_Assignments"

    struct Manifest: Codable {
        var active: String
        var accounts: [SchoolAccount]
    }

    static func root(for id: String) -> URL {
        users.appendingPathComponent(id, isDirectory: true)
    }

    /// `accounts.json` is the only source of truth, so the app and the widgets always agree.
    static var activeID: String { load().active }

    static var activeRoot: URL { root(for: activeID) }

    static func keychainService(for id: String) -> String { "\(keychainPrefix).\(id)" }

    static func load() -> Manifest {
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? decoder().decode(Manifest.self, from: data),
           !decoded.accounts.isEmpty {
            return decoded
        }
        let found = discovered()
        return Manifest(active: found.first?.id ?? defaultID, accounts: found)
    }

    static func save(_ manifest: Manifest) {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
        UserDefaults.standard.set(manifest.active, forKey: activeKey)
    }

    /// Moves the pre-account layout into `Users/default/` once, then keeps `accounts.json` current.
    @discardableResult
    static func prepare() -> Manifest {
        let files = FileManager.default
        try? files.createDirectory(at: users, withIntermediateDirectories: true)
        let legacy = [".private", "data", "reports"].map { base.appendingPathComponent($0) }
        let target = root(for: defaultID)
        if legacy.contains(where: { files.fileExists(atPath: $0.path) }) {
            try? files.createDirectory(at: target, withIntermediateDirectories: true)
            for item in legacy where files.fileExists(atPath: item.path) {
                let destination = target.appendingPathComponent(item.lastPathComponent)
                if files.fileExists(atPath: destination.path) { continue }
                try? files.moveItem(at: item, to: destination)
            }
        }
        var manifest = load()
        if manifest.accounts.isEmpty {
            manifest.accounts = discovered()
        }
        if !manifest.accounts.contains(where: { $0.id == manifest.active }) {
            manifest.active = manifest.accounts.first?.id ?? defaultID
        }
        save(manifest)
        return manifest
    }

    @discardableResult
    static func create(label: String) -> SchoolAccount {
        var manifest = load()
        var index = manifest.accounts.count + 1
        var id = "account-\(index)"
        while manifest.accounts.contains(where: { $0.id == id }) {
            index += 1
            id = "account-\(index)"
        }
        let account = SchoolAccount(id: id, label: label, createdAt: Date())
        try? FileManager.default.createDirectory(at: root(for: id), withIntermediateDirectories: true)
        manifest.accounts.append(account)
        save(manifest)
        return account
    }

    static func rename(_ id: String, label: String) {
        var manifest = load()
        guard let index = manifest.accounts.firstIndex(where: { $0.id == id }) else { return }
        manifest.accounts[index].label = label
        save(manifest)
    }

    static func activate(_ id: String) {
        var manifest = load()
        guard manifest.accounts.contains(where: { $0.id == id }) else { return }
        manifest.active = id
        save(manifest)
    }

    static func remove(_ id: String) throws {
        var manifest = load()
        guard manifest.accounts.count > 1 else { throw AccountError.lastAccount }
        guard id != manifest.active else { throw AccountError.activeAccount }
        manifest.accounts.removeAll { $0.id == id }
        if manifest.active == id { manifest.active = manifest.accounts.first?.id ?? defaultID }
        save(manifest)
        try? FileManager.default.removeItem(at: root(for: id))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", keychainService(for: id)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Restarts the app so the new account reloads every cached value from its own folder.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 0.8; /usr/bin/open -n \"\(path)\""]
        try? script.run()
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    enum AccountError: LocalizedError {
        case lastAccount, activeAccount

        var errorDescription: String? {
            switch self {
            case .lastAccount: return "Keep at least one account."
            case .activeAccount: return "Switch to another account before deleting this one."
            }
        }
    }

    private static func discovered() -> [SchoolAccount] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        let found = ids.filter { !$0.hasPrefix(".") }.sorted().map {
            SchoolAccount(id: $0, label: $0 == defaultID ? "Default" : $0, createdAt: Date())
        }
        return found.isEmpty ? [SchoolAccount(id: defaultID, label: "Default", createdAt: Date())] : found
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Root a widget should read: the active account folder, falling back to the legacy layout.
    static func widgetRoot() -> URL { WidgetSnapshot.activeRoot() }
}
