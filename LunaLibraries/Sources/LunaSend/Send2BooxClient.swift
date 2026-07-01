//
//  Send2BooxClient.swift
//  Luna
//

import LunaModels
import Foundation

/// Uploads an article EPUB to a Boox device via Onyx's (unofficial) Send2Boox
/// service. Ported from the `hrw/onyx-send2boox` reference: get STS creds →
/// signed OSS PUT → register the object so the device pulls it over WiFi.
public protocol Send2BooxUploading {
    /// Uploads + registers the EPUB. Throws if not logged in or any step fails.
    func upload(epubData: Data, fileName: String, title: String) async throws
}

/// Production Send2Boox uploader.
///
/// IMPORTANT: this drives an UNOFFICIAL Onyx API and reproduces Alibaba OSS V1
/// header signing by hand (the reference used the `oss2` SDK). It can't be
/// validated without a real Onyx account + device, so it's gated behind explicit
/// user setup with an in-app disclosure. The OSS PUT signs the `Date` header; if
/// a future iOS strips/overwrites that reserved header the upload would fail and
/// we'd switch to a presigned-URL scheme.
public final class Send2BooxClient: Send2BooxUploading {

    public struct NotConfiguredError: Error {}

    private let credentials: SendCredentialsStoring
    private let api: BooxAPIClient
    private let session: URLSession

    public init(host: String,
         credentials: SendCredentialsStoring = KeychainSendCredentialsStore.shared,
         session: URLSession = .shared) {
        self.credentials = credentials
        self.api = BooxAPIClient(host: host, session: session)
        self.session = session
    }

    public func upload(epubData: Data, fileName: String, title: String) async throws {
        guard let token = credentials.booxToken(), !token.isEmpty else {
            throw NotConfiguredError()
        }

        // 1. Account id + cloud bucket/endpoint + temporary OSS credentials.
        let user = try await api.value(path: "users/me", token: token, as: BooxUserData.self)
        // The reference client also pings these before pushing (likely session/
        // device activation). Best-effort — mirror it, ignore the bodies.
        try? await api.send(path: "users/getDevice", method: "GET", token: token, body: nil)
        try? await api.send(path: "im/getSig?user=\(user.uid)", method: "GET", token: token, body: nil)
        let buckets = try await api.value(path: "config/buckets", token: token, as: BooxBucketsData.self)
        let sts = try await api.value(path: "config/stss", token: token, as: BooxSTSData.self)

        // 2. Signed OSS PUT of the EPUB to the user's push area.
        let objectKey = "\(user.uid)/push/\(UUID().uuidString).epub"
        let signer = OSSRequestSigner(
            accessKeyId: sts.accessKeyId,
            accessKeySecret: sts.accessKeySecret,
            securityToken: sts.securityToken)
        guard let signed = signer.signPut(
            bucket: buckets.onyxCloud.bucket,
            endpointHost: buckets.onyxCloud.aliEndpoint,
            objectKey: objectKey,
            contentType: "application/epub+zip",
            date: Date())
        else { throw BooxAPIError(path: "oss-sign", detail: "couldn't build signed request") }

        var put = URLRequest(url: signed.url)
        put.httpMethod = "PUT"
        for (header, value) in signed.headers {
            put.setValue(value, forHTTPHeaderField: header)
        }
        let (_, putResponse) = try await session.upload(for: put, from: epubData)
        guard let http = putResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (putResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw BooxAPIError(path: "oss-put", detail: "HTTP \(code)")
        }

        // 3. Register the uploaded object so the device pulls it.
        try await api.send(path: "push/saveAndPush", token: token, body: [
            "data": [
                "bucket": buckets.onyxCloud.bucket,
                "name": fileName,
                "parent": NSNull(),
                "resourceDisplayName": fileName,
                "resourceKey": objectKey,
                // The reference hardcodes "txt" regardless of the real extension
                // (which lives in resourceKey) — it's the only proven value, so
                // match it rather than guess "epub".
                "resourceType": "txt",
                "title": title,
            ],
        ])
    }
}

/// The Boox destination: Send2Boox upload.
public final class BooxDestination: ArticleDestination {
    public let id = ArticleDestinationID.boox
    public let displayName = "Boox"

    private let credentials: SendCredentialsStoring
    private let uploaderOverride: Send2BooxUploading?

    public init(credentials: SendCredentialsStoring = KeychainSendCredentialsStore.shared,
         uploader: Send2BooxUploading? = nil) {
        self.credentials = credentials
        self.uploaderOverride = uploader
    }

    public var isConfigured: Bool { BooxSendSettings.isConfigured(credentials: credentials) }

    public func sendMode(for item: ReadingListItem) -> ArticleSendMode {
        SourceSendSettings.sendMode(
            forDestination: id, source: item.effectiveCaptureSource,
            friendUsername: item.sharedByUsername)
    }

    public var appIntentsSendMode: ArticleSendMode { SourceSendSettings.appIntentsMode(forDestination: id) }

    public func send(epubData: Data, fileName: String, title: String) async throws {
        // Built with the current region's host so a region change takes effect.
        let uploader = uploaderOverride
            ?? Send2BooxClient(host: BooxSendSettings.host, credentials: credentials)
        try await uploader.upload(epubData: epubData, fileName: fileName, title: title)
    }
}
