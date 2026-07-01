//
//  ProviderInferenceTests.swift
//  LunaMailAccountTests
//

import XCTest
@testable import LunaMailAccount

final class ProviderInferenceTests: XCTestCase {

    func testDomainExtraction() {
        XCTAssertEqual(ProviderInference.domain(of: "Alice@Example.COM"), "example.com")
        XCTAssertNil(ProviderInference.domain(of: "not-an-email"))
    }

    func testKnownDomainsInfer() {
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@gmail.com"), .gmail)
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@googlemail.com"), .gmail)
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@icloud.com"), .icloud)
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@me.com"), .icloud)
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@hotmail.com"), .outlook)
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@outlook.com"), .outlook)
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@yahoo.com"), .yahoo)
    }

    func testUnknownDomainIsGeneric() {
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@fastmail.com"), .generic)
        XCTAssertEqual(ProviderInference.inferProviderID(for: "a@my-company.co"), .generic)
    }

    func testISPDBParse() {
        let xml = """
        <?xml version="1.0"?>
        <clientConfig version="1.1">
          <emailProvider id="example.com">
            <incomingServer type="pop3">
              <hostname>pop.example.com</hostname><port>995</port><socketType>SSL</socketType>
            </incomingServer>
            <incomingServer type="imap">
              <hostname>imap.example.com</hostname><port>993</port><socketType>SSL</socketType>
            </incomingServer>
            <outgoingServer type="smtp">
              <hostname>smtp.example.com</hostname><port>587</port><socketType>STARTTLS</socketType>
            </outgoingServer>
          </emailProvider>
        </clientConfig>
        """
        let config = ProviderInference.parseISPDB(xml)
        XCTAssertEqual(config?.server.imapHost, "imap.example.com")
        XCTAssertEqual(config?.server.imapPort, 993)
        XCTAssertEqual(config?.server.smtpHost, "smtp.example.com")
        XCTAssertEqual(config?.server.smtpPort, 587)
        XCTAssertEqual(config?.server.smtpUsesSTARTTLS, true)
    }

    func testISPDBParseMissingReturnsNil() {
        XCTAssertNil(ProviderInference.parseISPDB("<clientConfig></clientConfig>"))
    }
}
