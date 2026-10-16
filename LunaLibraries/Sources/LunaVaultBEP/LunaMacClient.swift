import Foundation

/// An app that has completed Luna Mac setup. This travels only inside the
/// authenticated BEP stream; it is never inferred from discovery or a name.
public enum LunaMacClient: String, Codable, CaseIterable, Sendable {
    case vault, music, code
    public var title: String { "Luna " + rawValue.capitalized }
    public var introduction: String {
        switch self {
        case .vault: return "Browse your Mac and keep your files with you."
        case .music: return "Browse and play the music stored on your Mac."
        case .code: return "Edit your Mac’s source files and run builds."
        }
    }
}

public struct LunaMacClientStartup: Codable, Equatable, Sendable {
    public static let folder = "luna-client-v1"
    public let version: Int
    public let client: LunaMacClient
    public init(client: LunaMacClient) { version = 1; self.client = client }
}
