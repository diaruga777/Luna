//
//  PluginAPISurfaceTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// `tools/plugin-sim/luna-plugin.d.ts` against the bridges that actually
/// install the surface.
///
/// The `.d.ts` is what a plugin author's editor autocompletes from and what
/// `docs/plugins/api.md` calls authoritative, so a member installed with no
/// typing is a member nobody can discover. A cross-artifact pin, which is the
/// exempt category: the expected list is built from the bridges' own
/// `installedMembers`, never restated here.
final class PluginAPISurfaceTests: XCTestCase {

    private func typings(file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/plugin-sim/luna-plugin.d.ts")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The body of one `export interface <name> { … }` block.
    private func interfaceBody(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "export interface \(name) {") else { return nil }
        guard let end = source.range(of: "\n}", range: start.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// Every capability a manifest may declare has to be a property of `Luna`,
    /// and so does every companion namespace a bridge installs beside one.
    func testTheTypingsDeclareEveryNamespaceAPluginCanSee() throws {
        let source = try typings()
        let body = try XCTUnwrap(
            interfaceBody("Luna", in: source), "the Luna interface is gone from the .d.ts")
        let expected = PluginCapabilityName.allCases.map(\.rawValue)
            + PluginCapabilityName.allCompanionNamespaces.sorted()
        for name in expected {
            XCTAssertTrue(
                body.contains("\n  \(name)?:") || body.contains("\n  \(name)?("),
                "luna-plugin.d.ts declares no `\(name)` on the luna object")
        }
    }

    /// `luna.text` is not a capability, so the check above has to be reading
    /// the companion list rather than the capability list alone.
    func testTheCompanionNamespaceIsPartOfThatList() {
        XCTAssertEqual(
            PluginCapabilityName.allCompanionNamespaces, [PluginTextBridge.namespaceName])
        XCTAssertFalse(
            PluginCapabilityName.allCases.map(\.rawValue)
                .contains(PluginTextBridge.namespaceName))
    }

    func testEveryHTMLMemberTheBridgeInstallsIsTyped() throws {
        try assertMembers(PluginHTMLBridge.installedMembers, declaredIn: "LunaHTML")
    }

    func testEveryFetchMemberTheBridgeInstallsIsTyped() throws {
        try assertMembers(PluginFetchBridge.installedMembers, declaredIn: "LunaFetch")
    }

    func testEveryTextMemberTheBridgeInstallsIsTyped() throws {
        try assertMembers(PluginTextBridge.installedMembers, declaredIn: "LunaText")
    }

    /// `luna.fetch` is a function that also carries members, so its typing has
    /// to keep the call signature as well as the three helpers.
    func testTheFetchTypingStaysCallable() throws {
        let body = try XCTUnwrap(interfaceBody("LunaFetch", in: try typings()))
        XCTAssertTrue(
            body.contains("(request: string | FetchRequest): Promise<FetchResponse>;"),
            "luna.fetch is no longer typed as callable")
    }

    private func assertMembers(
        _ members: [String], declaredIn name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let body = try XCTUnwrap(
            interfaceBody(name, in: try typings()),
            "the \(name) interface is gone from the .d.ts", file: file, line: line)
        XCTAssertFalse(members.isEmpty, file: file, line: line)
        for member in members {
            XCTAssertTrue(
                body.contains("\n  \(member)(") || body.contains("\n  \(member):"),
                "luna-plugin.d.ts declares no `\(member)` on \(name)",
                file: file, line: line)
        }
    }
}
