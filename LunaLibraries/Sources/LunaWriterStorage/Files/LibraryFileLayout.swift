import Foundation

/// One file that has to move because a sheet was renamed or regrouped.
public struct FileMove: Equatable, Sendable {
    public let documentID: DocumentID
    public let from: String
    public let to: String

    public init(documentID: DocumentID, from: String, to: String) {
        self.documentID = documentID
        self.from = from
        self.to = to
    }
}

/// Where a sheet's `.md` file sits under the library root, as arithmetic over
/// names. Nothing here touches the file system, so the answer can be checked
/// before anything is moved.
///
/// The path mirrors the group tree, because the folder IS the group: a writer
/// who makes a folder in Files gets a group, and one who renames a sheet gets
/// a renamed file.
public enum LibraryFileLayout {
    public static let fileExtension = "md"
    /// Longest a single path component may be, in characters.
    public static let maximumNameLength = 80
    /// Names a file system will not take, whatever the writer typed.
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")

    public static func sanitize(_ name: String) -> String {
        let collapsed = name
            .components(separatedBy: illegal).joined(separator: "-")
            .components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let capped = String(collapsed.prefix(maximumNameLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return capped.isEmpty ? L10nWriterStorage.untitledDocumentTitle : capped
    }

    /// The folder components for a group, outermost first.
    public static func folderPath(for group: GroupID, groups: [WriterGroup]) -> [String] {
        var byID: [GroupID: WriterGroup] = [:]
        for entry in groups { byID[entry.id] = entry }
        var components: [String] = []
        var current: GroupID? = group
        var guardCount = 0
        while let id = current, let entry = byID[id], guardCount < 64 {
            components.append(sanitize(entry.name))
            current = entry.parentID
            guardCount += 1
        }
        return components.reversed()
    }

    /// The relative path a sheet should have. `taken` holds relative paths
    /// already claimed by other sheets; a clash takes " 2", " 3", …
    public static func path(
        for document: WriterDocument, groups: [WriterGroup], taken: Set<String> = []
    ) -> String {
        let folder = folderPath(for: document.groupID, groups: groups)
        let base = sanitize(document.title)
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = join(folder, base)
        var suffix = 2
        while lowered.contains(candidate.lowercased()), suffix < 1_000 {
            candidate = join(folder, "\(base) \(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Every sheet whose file is not where this layout puts it. Paths are
    /// claimed in the order given, so the plan never sends two sheets to one
    /// file.
    public static func movePlan(for documents: [WriterDocument], groups: [WriterGroup]) -> [FileMove] {
        var taken = Set<String>()
        var moves: [FileMove] = []
        for document in documents {
            let target = path(for: document, groups: groups, taken: taken)
            taken.insert(target)
            if document.fileRelativePath != target {
                moves.append(FileMove(
                    documentID: document.id, from: document.fileRelativePath, to: target))
            }
        }
        return moves
    }

    /// The group a folder maps to, or nil when no group has that path. Used
    /// when a file appears in a folder Luna did not make.
    public static func group(forFolderPath components: [String], groups: [WriterGroup]) -> GroupID? {
        groups.first { folderPath(for: $0.id, groups: groups) == components }?.id
    }

    private static func join(_ folder: [String], _ name: String) -> String {
        (folder + ["\(name).\(fileExtension)"]).joined(separator: "/")
    }
}
