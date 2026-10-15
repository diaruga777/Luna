import CoreBluetooth
import XCTest
import LunaSend

final class BluetoothRestorationActionTests: XCTestCase {
    func testConnectedRestorationResumesWithoutAnotherConnectCallback() {
        XCTAssertEqual(BluetoothRestorationAction(state: .connected), .resume)
    }

    func testDisconnectedRestorationRequestsAConnection() {
        XCTAssertEqual(BluetoothRestorationAction(state: .disconnected), .connect)
    }

    func testAnInFlightConnectionOrDisconnectionKeepsItsCallback() {
        XCTAssertEqual(BluetoothRestorationAction(state: .connecting), .wait)
        XCTAssertEqual(BluetoothRestorationAction(state: .disconnecting), .wait)
    }
}
