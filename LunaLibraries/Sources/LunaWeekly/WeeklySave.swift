//
//  WeeklySave.swift
//  LunaWeekly
//

import CryptoKit
import Foundation
import LunaModels

/// The three save types a "of the week" entry can carry. One entry per kind
/// exists at any time; the central Luna app cycles all three, each faceted app
/// shows only its own.
public enum WeeklySaveKind: String, Codable, CaseIterable, Sendable {
    case article
    case media
    case product

    /// The kinds an app is allowed to fetch and display. The runtime mirror of
    /// the same three-way split `LunaApp.handlesArticles/Media/Products` draws.
    public static func kinds(for app: LunaApp) -> [WeeklySaveKind] {
        switch app {
        case .luna:
            // Central Luna's fetch order is the same Reader → Downloader →
            // Price Tracker ranking used by its onboarding examples.
            return LunaApp.onboardingRankedSiblings.compactMap {
                switch $0 {
                case .reader: return .article
                case .downloader: return .media
                case .priceTracker: return .product
                case .luna: return nil
                }
            }
        case .reader: return [.article]
        case .downloader: return [.media]
        case .priceTracker: return [.product]
        }
    }

    /// The fixed CloudKit record name for this kind's single record. Fixed
    /// names are what let reads be `fetch(withRecordID:)` instead of a query —
    /// no queryable index required in the dashboard.
    public var recordName: String { "weekly-" + rawValue }
}

/// One signed "of the week" entry. Only the holder of the private key can
/// produce a `signature` the bundled public key accepts, so an unsigned or
/// tampered record is indistinguishable from no record at all.
public struct WeeklySave: Codable, Equatable, Sendable {
    public let kind: WeeklySaveKind
    public let urlString: String
    /// When it became "of the week" — the age both display tiers key off.
    public let date: Date
    /// Ed25519 signature over `canonicalMessage`.
    public let signature: Data

    public init(kind: WeeklySaveKind, urlString: String, date: Date, signature: Data) {
        self.kind = kind
        self.urlString = urlString
        self.date = date
        self.signature = signature
    }

    /// After this long an entry stops existing entirely.
    static let expiryInterval: TimeInterval = 30 * 24 * 60 * 60
    /// After this long the label stops saying "week" and starts saying "month".
    static let monthTierInterval: TimeInterval = 9 * 24 * 60 * 60

    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(date) > Self.expiryInterval
    }

    public func isMonthTier(now: Date = Date()) -> Bool {
        now.timeIntervalSince(date) >= Self.monthTierInterval
    }

    /// The exact bytes that get signed and verified. ONE formatter for both
    /// directions: a signature made over a differently-formatted date would
    /// verify nowhere.
    public var canonicalMessage: Data {
        Data(Self.canonicalMessageString(
            kind: kind, urlString: urlString, date: date).utf8)
    }

    public static func canonicalMessageString(
        kind: WeeklySaveKind, urlString: String, date: Date
    ) -> String {
        "\(kind.rawValue)\n\(urlString)\n\(canonicalDateFormatter.string(from: date))"
    }

    /// ISO8601, seconds precision, UTC — deliberately WITHOUT fractional
    /// seconds, so a date that survives a CloudKit round trip still formats
    /// identically on the reader's side.
    static let canonicalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

/// A public "this should be the save of the week" submission. Anyone signed
/// into iCloud can write one; only the key-holder reads them.
public struct WeeklyProposal: Codable, Equatable, Sendable {
    /// The CloudKit record name — `proposal-<hash of the url>`, which IS the
    /// per-URL dedup.
    public let recordName: String
    public let kind: WeeklySaveKind
    public let urlString: String
    public let date: Date

    public init(recordName: String, kind: WeeklySaveKind, urlString: String, date: Date) {
        self.recordName = recordName
        self.kind = kind
        self.urlString = urlString
        self.date = date
    }

    /// Builds a proposal whose record name derives from the URL, so a second
    /// proposal of the same link lands on the same record instead of piling up.
    public init(kind: WeeklySaveKind, urlString: String, date: Date) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recordName = "proposal-" + WeeklyProposal.hash(trimmed)
        self.kind = kind
        self.urlString = trimmed
        self.date = date
    }

    /// First 32 hex characters of SHA-256 over the trimmed URL.
    public static func hash(_ urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
