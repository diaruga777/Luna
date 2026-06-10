//
//  Log.swift
//  Clip
//
//  Minimal print-based logger — this is a prototype and stdout is enough.
//

import Foundation

/// Trivial logger: forwards messages to `print`. Empty value type, so `Sendable`.
struct Logger: Sendable {
    func debug(_ message: String) { print("[debug] \(message)") }
    func info(_ message: String) { print("[info] \(message)") }
    func warn(_ message: String) { print("[warn] \(message)") }
    func error(_ message: String) { print("[error] \(message)") }
}
