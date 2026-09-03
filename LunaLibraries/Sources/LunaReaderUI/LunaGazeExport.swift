// LunaReaderUI's RSVP eye tracking is built on the gaze types that moved to
// `LunaGaze` so Luna Writer's read-along can share them. Re-exporting keeps
// every Reader call site and test importing only LunaReaderUI.
@_exported import LunaGaze
