import CoreBluetooth

/// A restored connected peripheral will not send a new didConnect callback.
/// Resume GATT work directly once its central manager is powered on.
public enum BluetoothRestorationAction: Equatable {
    case resume, connect, wait

    public init(state: CBPeripheralState) {
        switch state {
        case .connected: self = .resume
        case .disconnected: self = .connect
        case .connecting, .disconnecting: self = .wait
        @unknown default: self = .wait
        }
    }
}
