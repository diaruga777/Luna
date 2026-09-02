//
//  PluginVersion.swift
//  LunaPluginKit
//

import Foundation

/// The plugin API this build speaks. A manifest declaring a higher number is
/// refused at import: the bridge it expects does not exist here.
public enum PluginAPIVersion {
    public static let current = 1
}

/// A plugin's `M.m.p` version. It is also a DIRECTORY name in the shared
/// container, so it is re-rendered from its numbers rather than kept as text.
public struct PluginVersion: Equatable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part),
                  value >= 0, part.count <= 9
            else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: PluginVersion, rhs: PluginVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = PluginVersion(text) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "\"\(text)\" is not M.m.p"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
