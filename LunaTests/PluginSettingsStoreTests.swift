import LunaPluginKit
import XCTest

final class PluginSettingsStoreTests: XCTestCase {
    private var root: URL!
    private var id: String!
    private var kv: PluginKVStore!
    private var settings: PluginSettingsStore!
    private let secrets = PluginSecretsStore()
    private let fields = [PluginSettingField(
        key: "apiKey", type: .password, label: "API Key", isRequired: true, isSecret: true)]

    override func setUp() {
        super.setUp()
        id = "user.settings-test.\(UUID().uuidString.lowercased())"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        kv = PluginKVStore(fileURL: root.appendingPathComponent("test.sqlite"))
        settings = PluginSettingsStore(values: kv, secrets: secrets) { [fields] _ in fields }
    }

    override func tearDown() {
        secrets.removeAll(pluginID: id)
        settings = nil
        kv = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testASettingsTokenIsReadableFromTheSecretsStoreAndNeverStoredAsPlaintext() throws {
        try settings.setValueJSON("\"test-token\"", pluginID: id, key: "apiKey")
        XCTAssertEqual(secrets.secret(pluginID: id, key: "apiKey"), "test-token")
        XCTAssertEqual(kv.valueJSON(pluginID: id, key: "apiKey"), "\"\"")
        XCTAssertEqual(settings.allValuesJSON(pluginID: id)["apiKey"], "\"\"")
        XCTAssertTrue(settings.isConfigured(pluginID: id, fields: fields))
        try settings.setValueJSON(nil, pluginID: id, key: "apiKey")
        XCTAssertNil(secrets.secret(pluginID: id, key: "apiKey"))
        XCTAssertFalse(settings.isConfigured(pluginID: id, fields: fields))
    }

    func testLegacyPlaintextMigratesBeforeSettingsAreReturned() throws {
        try kv.setValueJSON("\"legacy-token\"", pluginID: id, key: "apiKey")
        XCTAssertEqual(settings.allValuesJSON(pluginID: id)["apiKey"], "\"\"")
        XCTAssertEqual(secrets.secret(pluginID: id, key: "apiKey"), "legacy-token")
        XCTAssertEqual(kv.valueJSON(pluginID: id, key: "apiKey"), "\"\"")
    }

    func testOrdinarySettingsStillUseTheDatabase() throws {
        try settings.setValueJSON("\"live\"", pluginID: id, key: "_status")
        XCTAssertEqual(settings.valueJSON(pluginID: id, key: "_status"), "\"live\"")
        XCTAssertNil(secrets.secret(pluginID: id, key: "_status"))
    }
}
