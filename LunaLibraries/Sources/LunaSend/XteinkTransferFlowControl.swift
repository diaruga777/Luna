//
//  XteinkTransferFlowControl.swift
//  Luna
//

import Foundation

/// Application-level pacing for the BLE data stream.
///
/// iOS's `canSendWriteWithoutResponse` is local backpressure only: it says the
/// phone's controller can queue another packet, not that the reader has
/// durably consumed the earlier ones. An unpaced stream outruns the reader's
/// SD writes without bound, overflows its fixed frame pool, and starves its
/// allocator. The reader confirms durable receipt (`resume_offset`) at every
/// checkpoint boundary, so the sender stays within one unconfirmed checkpoint
/// interval (rounded up to a whole frame). A 1 KiB lead over that boundary
/// exceeded the reader's 16-slot pool at a 185-byte ATT MTU. The frame crossing
/// the boundary triggers the acknowledgement, so no extra lead is necessary.
public enum XteinkTransferFlowControl {
    /// The reader's confirmation stride. A current reader advertises its own
    /// as `"ckpt"` in every transfer status (2048 on the current firmware,
    /// sized so the paced in-flight window fits its 16-slot frame pool); this
    /// default matches the one firmware build that predates the field.
    public static let defaultCheckpointIntervalBytes = 8192
    public static let inFlightMarginBytes = 0

    /// Whether the sender must wait for the next confirmation before writing
    /// another frame. Never pauses at or past the final byte — the `commit`
    /// exchange confirms the tail. A pause always has a checkpoint boundary
    /// at or below it
    /// that a healthy reader is still going to confirm.
    public static func shouldPause(
        sentBytes: Int, confirmedBytes: Int, totalBytes: Int,
        checkpointIntervalBytes: Int = defaultCheckpointIntervalBytes
    ) -> Bool {
        guard sentBytes < totalBytes else { return false }
        return sentBytes - confirmedBytes >= checkpointIntervalBytes + inFlightMarginBytes
    }
}
