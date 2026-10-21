import Foundation
import LunaCodeCore

public struct CodeMacTarget: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var project: CodeProject
    public var deviceID: String
    public var branch: String
    public var repository: String?
    public var intervalHours: Int
    public var enabled: Bool
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var pendingRequest: CodeRequest?
    public var jobKind: String?
    public var lastJobID: String?
    public var jobID: String?
    public var failure: String?
    public init(id: String = UUID().uuidString, name: String, project: CodeProject, deviceID: String, branch: String = "main", intervalHours: Int = 144, enabled: Bool = false) {
        self.id = id; self.name = name; self.project = project; self.deviceID = deviceID; self.branch = branch
        self.intervalHours = intervalHours; self.enabled = enabled
    }
    public func isDue(at date: Date) -> Bool {
        enabled && jobID == nil && (lastSuccess.map { date.timeIntervalSince($0) >= Double(intervalHours) * 3600 } ?? true)
            && (lastAttempt.map { date.timeIntervalSince($0) >= 1800 } ?? true)
    }
}
public enum CodeMacPaths {
    public static var root: URL {
        if let path = ProcessInfo.processInfo.environment["LUNA_CODE_HOME"], path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Luna Vault/Code/Catalog", isDirectory: true)
    }
}
