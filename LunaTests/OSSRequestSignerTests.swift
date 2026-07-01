//
//  OSSRequestSignerTests.swift
//  LunaTests
//

import LunaSend
import XCTest
@testable import Luna

final class OSSRequestSignerTests: XCTestCase {

    func testStringToSignCanonicalization() {
        let stringToSign = OSSRequestSigner.stringToSign(
            method: "PUT",
            contentMD5: "",
            contentType: "application/epub+zip",
            date: "Wed, 28 May 2025 12:00:00 GMT",
            canonicalizedOSSHeaders: "x-oss-security-token:TOKEN\n",
            canonicalizedResource: "/my-bucket/uid/push/abc.epub")
        XCTAssertEqual(
            stringToSign,
            "PUT\n\napplication/epub+zip\nWed, 28 May 2025 12:00:00 GMT\n"
            + "x-oss-security-token:TOKEN\n/my-bucket/uid/push/abc.epub")
    }

    func testHMACSHA1IsDeterministicAndCorrectLength() {
        let a = OSSRequestSigner.hmacSHA1Base64(key: "secret", message: "data")
        let b = OSSRequestSigner.hmacSHA1Base64(key: "secret", message: "data")
        XCTAssertEqual(a, b)
        // SHA-1 produces 20 bytes; base64 of 20 bytes is 28 chars (with padding).
        XCTAssertEqual(Data(base64Encoded: a)?.count, 20)
        XCTAssertNotEqual(a, OSSRequestSigner.hmacSHA1Base64(key: "secret", message: "data2"))
    }

    func testSignPutBuildsVirtualHostedURLAndHeaders() throws {
        let signer = OSSRequestSigner(
            accessKeyId: "AKID", accessKeySecret: "SECRET", securityToken: "STSTOKEN")
        let signed = try XCTUnwrap(signer.signPut(
            bucket: "my-bucket",
            endpointHost: "https://oss-eu-central-1.aliyuncs.com",
            objectKey: "uid/push/abc.epub",
            contentType: "application/epub+zip",
            date: Date(timeIntervalSince1970: 1_700_000_000)))

        XCTAssertEqual(
            signed.url.absoluteString,
            "https://my-bucket.oss-eu-central-1.aliyuncs.com/uid/push/abc.epub")
        XCTAssertEqual(signed.headers["x-oss-security-token"], "STSTOKEN")
        XCTAssertEqual(signed.headers["Content-Type"], "application/epub+zip")
        XCTAssertNotNil(signed.headers["Date"])
        XCTAssertTrue(signed.headers["Authorization"]?.hasPrefix("OSS AKID:") ?? false)
    }
}
