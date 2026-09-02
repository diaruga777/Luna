//
//  PluginBluetoothSession.swift
//  LunaPluginTransport
//

import Foundation

/// One live GATT link, as `luna.bluetooth`'s `BluetoothSession` (§10.2).
///
/// Every call serializes on this session's own queue: one X3-shaped peripheral
/// accepts one control operation or data stream at a time, and a plugin that
/// interleaved two would have its transfer rejected by the device rather than
/// by Luna. Notifications are buffered from `subscribe` on, so a status the
/// device published before the plugin asked for it is still delivered by
/// `next`.
///
/// A disconnect rejects every queued and in-flight call with `disconnected`
/// rather than leaving a plugin's promise pending for the rest of the process.
public final class PluginBluetoothSession: @unchecked Sendable {

    public let device: PluginBluetoothDevice
    /// `maximumWriteValueLength(for: .withoutResponse)`, read once at open.
    public let mtu: Int

    private let transport: any PluginBluetoothTransporting
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var pending: [(id: UInt64, start: () -> Void, fail: (PluginTransportError) -> Void)] = []
    private var isRunning = false
    private var isClosed = false
    private var nextOperationID: UInt64 = 0
    /// The failure handler of the operation currently in flight.
    private var inFlightFailure: ((PluginTransportError) -> Void)?
    /// Notification values received since `subscribe`, oldest first.
    private var buffers: [String: [String]] = [:]
    private var notificationWaiters: [String: (String) -> Void] = [:]
    /// One writer waiting for controller room (`canWriteWithoutResponse`).
    private var readyToWriteWaiter: (() -> Void)?

    init(
        device: PluginBluetoothDevice, transport: any PluginBluetoothTransporting,
        queue: DispatchQueue
    ) {
        self.device = device
        self.transport = transport
        self.queue = queue
        mtu = max(1, transport.maximumWriteLength(deviceID: device.id))
    }

    public var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed
    }

    // MARK: - Operations

    public func discover(
        serviceUUID: String,
        completion: @escaping (Result<[String], PluginTransportError>) -> Void
    ) {
        enqueue(completion) { [self] settle in
            transport.discover(serviceUUID: serviceUUID, deviceID: device.id) { settle($0) }
        }
    }

    public func read(
        characteristicUUID: String,
        completion: @escaping (Result<String, PluginTransportError>) -> Void
    ) {
        enqueue(completion) { [self] settle in
            transport.read(characteristicUUID: characteristicUUID, deviceID: device.id) {
                settle($0)
            }
        }
    }

    public func write(
        base64: String, characteristicUUID: String, withResponse: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        enqueue(completion) { [self] settle in
            guard !withResponse else {
                transport.write(
                    base64: base64, characteristicUUID: characteristicUUID,
                    deviceID: device.id, withResponse: true) { settle($0) }
                return
            }
            // Local backpressure only: the controller has room. Application
            // pacing against the device's own durable receipts is the
            // plugin's, through `next`.
            whenReadyToWrite { [self] in
                transport.write(
                    base64: base64, characteristicUUID: characteristicUUID,
                    deviceID: device.id, withResponse: false) { settle($0) }
            }
        }
    }

    public func subscribe(
        characteristicUUID: String,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        enqueue(completion) { [self] settle in
            lock.lock()
            if buffers[characteristicUUID] == nil { buffers[characteristicUUID] = [] }
            lock.unlock()
            transport.subscribe(characteristicUUID: characteristicUUID, deviceID: device.id) {
                settle($0)
            }
        }
    }

    /// The next notification value on `characteristicUUID`, from the buffer
    /// when one already arrived.
    public func next(
        characteristicUUID: String, timeout: TimeInterval,
        completion: @escaping (Result<String, PluginTransportError>) -> Void
    ) {
        enqueue(completion) { [self] settle in
            lock.lock()
            if var buffered = buffers[characteristicUUID], !buffered.isEmpty {
                let value = buffered.removeFirst()
                buffers[characteristicUUID] = buffered
                lock.unlock()
                settle(.success(value))
                return
            }
            notificationWaiters[characteristicUUID] = { value in settle(.success(value)) }
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let waiter = notificationWaiters[characteristicUUID]
                notificationWaiters[characteristicUUID] = nil
                lock.unlock()
                guard waiter != nil else { return }
                settle(.failure(.timedOut(
                    "no notification arrived on \(characteristicUUID) within \(Int(timeout))s")))
            }
        }
    }

    public func disconnect(completion: @escaping (Result<Void, PluginTransportError>) -> Void) {
        transport.cancelConnection(deviceID: device.id)
        close(reason: .disconnected)
        completion(.success(()))
    }

    // MARK: - Events from the center

    func deliver(notification base64: String, characteristicUUID: String) {
        lock.lock()
        let waiter = notificationWaiters[characteristicUUID]
        if waiter != nil {
            notificationWaiters[characteristicUUID] = nil
        } else if buffers[characteristicUUID] != nil {
            buffers[characteristicUUID]?.append(base64)
        }
        lock.unlock()
        waiter?(base64)
    }

    func deliverReadyToWrite() {
        lock.lock()
        let waiter = readyToWriteWaiter
        readyToWriteWaiter = nil
        lock.unlock()
        waiter?()
    }

    /// Ends the session. Every queued and in-flight call fails with `reason`.
    func close(reason: PluginTransportError) {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let queued = pending
        pending = []
        let inFlight = inFlightFailure
        inFlightFailure = nil
        // A waiter belongs to an operation this same call fails, so dropping
        // it delivers nothing late.
        notificationWaiters = [:]
        readyToWriteWaiter = nil
        lock.unlock()
        inFlight?(reason)
        for entry in queued { entry.fail(reason) }
    }

    // MARK: - Serialization

    private func whenReadyToWrite(_ work: @escaping () -> Void) {
        guard !transport.canWriteWithoutResponse(deviceID: device.id) else { return work() }
        lock.lock()
        readyToWriteWaiter = work
        lock.unlock()
    }

    /// Adds one operation to the queue. `body` receives the settle function it
    /// must call exactly once; the pump runs the next operation after it does.
    private func enqueue<T>(
        _ completion: @escaping (Result<T, PluginTransportError>) -> Void,
        _ body: @escaping (@escaping (Result<T, PluginTransportError>) -> Void) -> Void
    ) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            completion(.failure(.disconnected))
            return
        }
        nextOperationID &+= 1
        let id = nextOperationID
        lock.unlock()

        let settled = OperationLatch()
        let settle: (Result<T, PluginTransportError>) -> Void = { [weak self] result in
            guard settled.take() else { return }
            guard let self else { return completion(result) }
            self.lock.lock()
            self.inFlightFailure = nil
            self.lock.unlock()
            completion(result)
            self.pump()
        }
        let fail: (PluginTransportError) -> Void = { error in
            guard settled.take() else { return }
            completion(.failure(error))
        }
        let start = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.inFlightFailure = fail
            self.lock.unlock()
            body(settle)
        }
        lock.lock()
        pending.append((id: id, start: start, fail: fail))
        lock.unlock()
        pump()
    }

    /// Runs the head of the queue when nothing else is in flight. Always hops
    /// to the session queue, so a synchronously-settling operation cannot grow
    /// the stack one frame per queued call.
    private func pump() {
        queue.async { [self] in
            lock.lock()
            guard !isClosed, !isRunning, !pending.isEmpty else { lock.unlock(); return }
            isRunning = true
            let entry = pending.removeFirst()
            lock.unlock()
            entry.start()
            lock.lock()
            isRunning = false
            let more = !pending.isEmpty && inFlightFailure == nil
            lock.unlock()
            if more { pump() }
        }
    }
}

/// One-shot guard so an operation settles exactly once, whichever of the
/// transport's answer, the disconnect and the timeout arrives first.
final class OperationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
