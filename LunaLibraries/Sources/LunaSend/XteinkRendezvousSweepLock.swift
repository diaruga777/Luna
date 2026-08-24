//
//  XteinkRendezvousSweepLock.swift
//  Luna
//

import Foundation
import LunaAppConfig

/// Cross-process mutual exclusion for one rendezvous window.
///
/// The central Luna app and the Reader both run a live `XteinkBLECentral`
/// against the one shared store, and iOS shares the one physical BLE link —
/// so BOTH processes can see the same rendezvous become ready. Two sweeps on
/// one GATT session interleave duplicate control ops and data frames, which
/// the reader rejects (`resume_mismatch`/`sequence`) and the transfer dies.
/// Only the process that wins this `flock` sweeps; the loser stays silent —
/// it must not even answer `no_work`, since the owner concludes the window.
///
/// `flock` is per open-file-description, so the lock also excludes a second
/// acquire inside one process, and the kernel releases it if the holder dies.
public final class XteinkRendezvousSweepLock: @unchecked Sendable {
    public static let shared = XteinkRendezvousSweepLock()

    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var held = false
    private let fileURL: URL?

    public init(
        fileURL: URL? = AppConfig.sharedContainerURL()?
            .appendingPathComponent("xteink-rendezvous-sweep.lock")
    ) {
        self.fileURL = fileURL
    }

    /// Attempts the lock without blocking. When no shared container exists
    /// (nothing to arbitrate through), it degrades to a per-process flag so a
    /// sweep still runs exactly once.
    public func acquire() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !held else { return false }
        if let path = fileURL?.path {
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            if fd >= 0 {
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    close(fd)
                    return false
                }
                descriptor = fd
            }
        }
        held = true
        return true
    }

    public func release() {
        stateLock.lock(); defer { stateLock.unlock() }
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
        held = false
    }
}
