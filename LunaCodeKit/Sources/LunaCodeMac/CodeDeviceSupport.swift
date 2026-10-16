import Foundation
import LunaCodeCore

/// Xcode/CoreDevice commands only. No UI automation agent is installed on phones.
enum CodeDeviceSupport {
    static func json(_ executable: String, _ arguments: [String], directory: String, root: URL,
                     process: CodeProcess = CodeProcess(), timeout: TimeInterval = 120) async throws -> Any {
        let log = root.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try await process.run(executable, arguments, directory: directory, log: log, timeout: timeout)
        let data = try Data(contentsOf: log)
        guard status == 0 else { throw CodeFailure("Xcode could not read project details. Open the project on the Mac to resolve packages and signing.\n" + String(decoding: data.suffix(2000), as: UTF8.self)) }
        return try parseJSONOutput(data)
    }
    static func parseJSONOutput(_ data: Data) throws -> Any {
        // Xcode can prepend timestamped warnings containing [MT] or package
        // progress. Find the complete JSON document rather than its first bracket.
        for start in data.indices where data[start] == 123 || data[start] == 91 {
            if let object = try? JSONSerialization.jsonObject(with: data.suffix(from: start)) { return object }
        }
        throw CodeFailure("Xcode returned no readable project details.\n" + String(decoding: data.suffix(2000), as: UTF8.self))
    }
    static func schemes(path: String, root: URL) async throws -> [String] {
        let object = try await json("/usr/bin/xcodebuild", [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path, "-list", "-json"], directory: (path as NSString).deletingLastPathComponent, root: root) as? [String: Any]
        let project = object?["workspace"] as? [String: Any] ?? object?["project"] as? [String: Any]
        return project?["schemes"] as? [String] ?? []
    }
    static func settings(_ project: CodeProject, root: URL, process: CodeProcess = CodeProcess(), destination: String? = nil) async throws -> [[String: String]] {
        let rows = try await json("/usr/bin/xcodebuild", project.xcodeArguments + ["-configuration", "Debug"] + (destination.map { ["-destination", $0] } ?? []) + ["-showBuildSettings", "-json"], directory: project.root, root: root, process: process) as? [[String: Any]] ?? []
        return rows.compactMap { $0["buildSettings"] as? [String: String] }
    }
    static func isApp(_ settings: [String: String]) -> Bool {
        settings["PRODUCT_TYPE"] == "com.apple.product-type.application" &&
        (settings["SUPPORTED_PLATFORMS"] ?? settings["PLATFORM_NAME"] ?? "").components(separatedBy: " ").contains("iphoneos")
    }
    static func apps(path: String, scheme selectedScheme: String? = nil, root: URL) async throws -> [CodeBuildApp] {
        var apps: [CodeBuildApp] = []
        let available: [String]
        if let selectedScheme { available = [selectedScheme] }
        else { available = try await schemes(path: path, root: root) }
        for scheme in available where !scheme.lowercased().contains("webdriveragent") {
            let project = CodeProject(path: path, scheme: scheme)
            let settings = try await settings(project, root: root)
            // A scheme can build dependencies too. Its primary target is first.
            if let app = settings.first, isApp(app), let bundle = app["PRODUCT_BUNDLE_IDENTIFIER"], !bundle.lowercased().contains("webdriveragent") {
                apps.append(CodeBuildApp(project: project, name: app["PRODUCT_NAME"] ?? scheme, bundleID: bundle))
            }
        }
        // Alias schemes for the same application (e.g. Luna and LunaReader) share one row.
        var bundles = Set<String>()
        return apps.filter { bundles.insert($0.bundleID).inserted }
    }
    static func devices(root: URL) async throws -> [CodeDevice] {
        let output = root.appendingPathComponent(UUID().uuidString + ".json")
        let log = root.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: log) }
        let status = try await CodeProcess().run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", output.path], directory: root.path, log: log, timeout: 30)
        guard status == 0 else { throw CodeFailure("Could not list phones. Check Xcode and the device connection on the Mac.") }
        return try parseDevices(Data(contentsOf: output))
    }
    static func parseDevices(_ data: Data) throws -> [CodeDevice] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        return (result?["devices"] as? [[String: Any]] ?? []).compactMap { device in
            let properties = device["properties"] as? [String: Any]
            let hardware = properties?["hardware"] as? [String: Any] ?? device["hardwareProperties"] as? [String: Any] ?? [:]
            let state = properties?["state"] as? [String: Any] ?? device["deviceProperties"] as? [String: Any] ?? [:]
            let connection = properties?["connection"] as? [String: Any] ?? device["connectionProperties"] as? [String: Any] ?? [:]
            let connected = connection["state"] as? String ?? connection["tunnelState"] as? String
            guard hardware["reality"] as? String == "physical", hardware["platform"] as? String == "iOS",
                  (connected == "connected" || (connected == "disconnected" && connection["pairingState"] as? String == "paired")), let id = hardware["udid"] as? String, let name = state["name"] as? String else { return nil }
            return CodeDevice(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func git(_ arguments: [String], directory: String, root: URL, process: CodeProcess = CodeProcess()) async throws -> String {
        let log = root.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try await process.run("/usr/bin/git", arguments, directory: directory, log: log, timeout: 60)
        let output = String(decoding: try Data(contentsOf: log), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { throw CodeFailure("Git: " + output) }
        return output
    }
    static func branches(path: String, root: URL) async throws -> [String] {
        let output = try await git(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], directory: (path as NSString).deletingLastPathComponent, root: root)
        return output.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
    }
}
