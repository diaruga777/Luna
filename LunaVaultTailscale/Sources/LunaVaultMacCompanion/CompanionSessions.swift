import Foundation
import LunaVaultBEP
import LunaVaultMacPeer

/// Accessed under CompanionController's lock. Keep the newest authenticated
/// sessions so abandoned TCP streams cannot lock every app out until a restart.
struct CompanionSessions {
    typealias Session = (BEPConnection, CompanionBEPDelegate)
    private var sessions: [UUID: Session] = [:]
    private var order: [UUID] = []
    var values: Dictionary<UUID, Session>.Values { sessions.values }
    var isEmpty: Bool { sessions.isEmpty }
    subscript(id: UUID) -> Session? { sessions[id] }

    mutating func insert(_ session: Session, for id: UUID) -> Session? {
        let retired = order.count >= 8 ? removeValue(forKey: order[0]) : nil
        sessions[id] = session
        order.append(id)
        return retired
    }
    @discardableResult
    mutating func removeValue(forKey id: UUID) -> Session? {
        order.removeAll { $0 == id }
        return sessions.removeValue(forKey: id)
    }
    mutating func removeAll() { sessions.removeAll(); order.removeAll() }
}
