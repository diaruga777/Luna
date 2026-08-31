//
//  MembershipExceptionsExistTests.swift
//  LunaTests
//

import XCTest

/// Guards `Luna.xcodeproj/project.pbxproj` against the dangling-exception trap
/// CLAUDE.md documents: a synchronized group picks up files on disk by itself,
/// but each per-target `membershipExceptions` entry names a file by hand, and
/// nothing checks that name against disk when it is edited or deleted. A
/// dangling name compiles fine incrementally and only fails a CLEAN build
/// ("Build input files cannot be found") — which this test catches without
/// needing one.
///
/// Parsing approach shared with `StageRegistryTests.membershipExceptionsByTarget()`:
/// scan for the `isa = PBXFileSystemSynchronizedBuildFileExceptionSet;` marker
/// and read forward to the block's closing `};`. That test only needed the
/// block's target name and full text; this one also needs the block's own
/// object id (to match it against a `PBXFileSystemSynchronizedRootGroup`'s
/// `exceptions` list) and its parsed file list.
final class MembershipExceptionsExistTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    private struct SynchronizedGroup {
        let path: String
        let exceptionSetIDs: [String]
    }

    /// Xcode writes each root group either on one line or as an indented
    /// block (its current form), so this scans block-wise from the isa marker
    /// to the closing `};` at object indentation, the same way
    /// `parseExceptionSets` below does.
    private func parseSynchronizedGroups(_ project: String) -> [SynchronizedGroup] {
        var groups: [SynchronizedGroup] = []
        var remainder = Substring(project)
        while let isa = remainder.range(of: "isa = PBXFileSystemSynchronizedRootGroup;") {
            let block: Substring
            let after = remainder[isa.upperBound...]
            if let blockEnd = after.range(of: "\n\t\t};") {
                block = after[..<blockEnd.lowerBound]
                remainder = after[blockEnd.upperBound...]
            } else if let lineEnd = after.range(of: "\n") {
                // One-line form: the whole object shares the isa's line.
                block = after[..<lineEnd.lowerBound]
                remainder = after[lineEnd.upperBound...]
            } else {
                block = after
                remainder = after[after.endIndex...]
            }

            guard let pathStart = block.range(of: "path = ") else { continue }
            let afterPath = block[pathStart.upperBound...]
            guard let semi = afterPath.range(of: ";") else { continue }
            var path = String(afterPath[..<semi.lowerBound])
            if path.hasPrefix("\""), path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }

            var ids: [String] = []
            if let excStart = block.range(of: "exceptions = ("),
               let excEnd = block.range(of: ");", range: excStart.upperBound..<block.endIndex) {
                let body = block[excStart.upperBound..<excEnd.lowerBound]
                for token in body.split(separator: ",") {
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let space = trimmed.range(of: " ") {
                        ids.append(String(trimmed[..<space.lowerBound]))
                    } else {
                        ids.append(trimmed)
                    }
                }
            }
            groups.append(SynchronizedGroup(path: path, exceptionSetIDs: ids))
        }
        return groups
    }

    /// Every `PBXFileSystemSynchronizedBuildFileExceptionSet`, keyed by its own
    /// object id — a group's `exceptions` list references sets by id, not by
    /// target, and several sets can share one target.
    private func parseExceptionSets(_ project: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var remainder = Substring(project)
        while let isa = remainder.range(
            of: "isa = PBXFileSystemSynchronizedBuildFileExceptionSet;") {
            // The object id lives on the line before this one, e.g.:
            // "\t\t0F6359E5F1947F76D1DC13EC /* PBXFileSystemSynchronizedBuildFileExceptionSet */ = {\n\t\t\tisa = …"
            let before = remainder[..<isa.lowerBound]
            let beforeLines = before.split(separator: "\n", omittingEmptySubsequences: false)
            guard beforeLines.count >= 2 else { break }
            let idLine = beforeLines[beforeLines.count - 2].trimmingCharacters(in: .whitespaces)
            guard let idEnd = idLine.range(of: " ") else { break }
            let id = String(idLine[..<idEnd.lowerBound])

            let block = remainder[isa.upperBound...]
            guard let blockEnd = block.range(of: "\n\t\t};") else { break }
            let body = block[..<blockEnd.lowerBound]

            var files: [String] = []
            if let membStart = body.range(of: "membershipExceptions = ("),
               let membEnd = body.range(of: ");", range: membStart.upperBound..<body.endIndex) {
                let list = body[membStart.upperBound..<membEnd.lowerBound]
                for rawLine in list.split(separator: "\n") {
                    var entry = rawLine.trimmingCharacters(in: .whitespaces)
                    if entry.hasSuffix(",") { entry.removeLast() }
                    if entry.hasPrefix("\""), entry.hasSuffix("\"") {
                        entry = String(entry.dropFirst().dropLast())
                    }
                    guard !entry.isEmpty else { continue }
                    files.append(entry)
                }
            }
            result[id] = files
            remainder = block[blockEnd.upperBound...]
        }
        return result
    }

    func testEveryMembershipExceptionNamesAFileThatExistsOnDisk() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Luna.xcodeproj/project.pbxproj"),
            encoding: .utf8)
        let groups = parseSynchronizedGroups(project)
        let exceptionSets = parseExceptionSets(project)
        XCTAssertFalse(
            groups.isEmpty, "no synchronized root groups parsed — parser drifted from the project format")
        XCTAssertFalse(
            exceptionSets.isEmpty, "no exception sets parsed — parser drifted from the project format")

        var checked = 0
        for group in groups {
            for setID in group.exceptionSetIDs {
                guard let files = exceptionSets[setID] else {
                    XCTFail("\(group.path) references exception set \(setID), which was never parsed")
                    continue
                }
                for file in files {
                    let url = repositoryRoot
                        .appendingPathComponent(group.path)
                        .appendingPathComponent(file)
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: url.path),
                        """
                        \(group.path)/\(file) is named in a membership exception but does \
                        not exist on disk. A CLEAN build of the target that owns this \
                        exception set will fail with "Build input files cannot be found" \
                        — either the file was deleted without editing project.pbxproj, or \
                        it moved.
                        """)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "no membership-exception files were checked — parser drifted")
    }
}
