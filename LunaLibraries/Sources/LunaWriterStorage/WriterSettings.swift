import Foundation
import LunaWriterModels

/// How much of the sheet stays lit while the caret moves.
public enum FocusMode: String, Codable, CaseIterable, Sendable {
    case off, sentence, paragraph
}

/// What opens the command palette while typing.
public enum PaletteTrigger: String, Codable, CaseIterable, Sendable {
    /// Two spaces typed within `CommandPaletteController.doubleSpaceInterval`.
    case doubleSpace
    /// An "@" typed at a word boundary.
    case atSign
}

/// The column width presets the editor offers.
public enum EditorLineWidth: String, Codable, CaseIterable, Sendable {
    case narrow, medium, wide
}

/// The writer's editor preferences, in the standard defaults suite.
///
/// Every setter posts `WriterSettings.didChange` after the value is stored, so
/// a view that redraws on the notification reads the new value.
public final class WriterSettings {

    public static let didChange = Notification.Name("com.hsanabria.luna.writerSettingsDidChange")

    private enum Key {
        static let focusMode = "luna.writer.focusMode"
        static let syntaxColouring = "luna.writer.syntaxColouring"
        static let typewriterScrolling = "luna.writer.typewriterScrolling"
        static let font = "luna.writer.font"
        static let fontSize = "luna.writer.fontSize"
        static let lineWidth = "luna.writer.lineWidth"
        static let showAuthorship = "luna.writer.showAuthorship"
        static let gazeEnabled = "luna.writer.gazeEnabled"
        static let voiceEnabled = "luna.writer.voiceEnabled"
        static let lastCalibrationGrade = "luna.writer.lastCalibrationGrade"
        static let paletteTrigger = "luna.writer.paletteTrigger"
    }

    public static let defaultFontSize = 18.0

    private let defaults: UserDefaults
    private let center: NotificationCenter

    public init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    public var focusMode: FocusMode {
        get { FocusMode(rawValue: defaults.string(forKey: Key.focusMode) ?? "") ?? .off }
        set { write(newValue.rawValue, Key.focusMode) }
    }

    public var syntaxColouring: Bool {
        get { defaults.object(forKey: Key.syntaxColouring) as? Bool ?? false }
        set { write(newValue, Key.syntaxColouring) }
    }

    public var typewriterScrolling: Bool {
        get { defaults.object(forKey: Key.typewriterScrolling) as? Bool ?? false }
        set { write(newValue, Key.typewriterScrolling) }
    }

    /// A `ReaderFont` raw value. Kept as a string because this tier is
    /// Foundation-only and the font itself is resolved in the editor.
    public var fontIdentifier: String? {
        get { defaults.string(forKey: Key.font) }
        set { write(newValue, Key.font) }
    }

    public var fontSize: Double {
        get { (defaults.object(forKey: Key.fontSize) as? Double) ?? Self.defaultFontSize }
        set { write(newValue, Key.fontSize) }
    }

    public var lineWidth: EditorLineWidth {
        get { EditorLineWidth(rawValue: defaults.string(forKey: Key.lineWidth) ?? "") ?? .medium }
        set { write(newValue.rawValue, Key.lineWidth) }
    }

    public var showAuthorship: Bool {
        get { defaults.object(forKey: Key.showAuthorship) as? Bool ?? true }
        set { write(newValue, Key.showAuthorship) }
    }

    public var gazeEnabled: Bool {
        get { defaults.object(forKey: Key.gazeEnabled) as? Bool ?? false }
        set { write(newValue, Key.gazeEnabled) }
    }

    public var voiceEnabled: Bool {
        get { defaults.object(forKey: Key.voiceEnabled) as? Bool ?? false }
        set { write(newValue, Key.voiceEnabled) }
    }

    public var paletteTrigger: PaletteTrigger {
        get { PaletteTrigger(rawValue: defaults.string(forKey: Key.paletteTrigger) ?? "") ?? .doubleSpace }
        set { write(newValue.rawValue, Key.paletteTrigger) }
    }

    public var lastCalibrationGrade: String? {
        get { defaults.string(forKey: Key.lastCalibrationGrade) }
        set { write(newValue, Key.lastCalibrationGrade) }
    }

    private func write(_ value: Any?, _ key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        // A setter reached from a background queue (calibration grading
        // runs off-main) must not post there: an observer redrawing UI
        // expects the notification on main.
        if Thread.isMainThread {
            center.post(name: WriterSettings.didChange, object: self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.center.post(name: WriterSettings.didChange, object: self)
            }
        }
    }
}
