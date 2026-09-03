//
//  KeyboardFrameObserverTests.swift
//  LunaTests
//

import XCTest
@testable import LunaWriterEditor

final class KeyboardFrameObserverTests: XCTestCase {

    private var center: NotificationCenter!
    private var observer: KeyboardFrameObserver!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        observer = KeyboardFrameObserver(center: center)
    }

    override func tearDown() {
        observer = nil
        center = nil
        super.tearDown()
    }

    private func post(_ name: Notification.Name, frame: CGRect, isLocal: Bool?) {
        var userInfo: [AnyHashable: Any] = [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)]
        if let isLocal {
            userInfo[UIResponder.keyboardIsLocalUserInfoKey] = isLocal
        }
        center.post(name: name, object: nil, userInfo: userInfo)
    }

    // MARK: - Frame tracking

    func testFrameUpdatesFromALocalKeyboardChangeNotification() {
        let frame = CGRect(x: 0, y: 400, width: 320, height: 300)
        post(UIResponder.keyboardWillChangeFrameNotification, frame: frame, isLocal: true)
        XCTAssertTrue(observer.isVisible)
        XCTAssertEqual(observer.frame, frame)
    }

    func testANonLocalNotificationIsIgnored() {
        post(UIResponder.keyboardWillChangeFrameNotification,
             frame: CGRect(x: 0, y: 400, width: 320, height: 300), isLocal: false)
        XCTAssertFalse(observer.isVisible)
        XCTAssertEqual(observer.frame, .zero)
    }

    func testANotificationWithNoLocalKeyIsTreatedAsLocal() {
        post(UIResponder.keyboardWillChangeFrameNotification,
             frame: CGRect(x: 0, y: 400, width: 320, height: 300), isLocal: nil)
        XCTAssertTrue(observer.isVisible)
    }

    func testHideNotificationClearsTheFrame() {
        post(UIResponder.keyboardWillChangeFrameNotification,
             frame: CGRect(x: 0, y: 400, width: 320, height: 300), isLocal: true)
        post(UIResponder.keyboardWillHideNotification, frame: .zero, isLocal: true)
        XCTAssertFalse(observer.isVisible)
    }

    func testObserverIsToldOfTheFrameChange() {
        final class Recorder: KeyboardFrameObserving {
            var seen: [CGRect] = []
            func keyboardFrameDidChange(_ frame: CGRect) { seen.append(frame) }
        }
        let recorder = Recorder()
        observer.observer = recorder
        let frame = CGRect(x: 0, y: 400, width: 320, height: 300)
        post(UIResponder.keyboardWillChangeFrameNotification, frame: frame, isLocal: true)
        XCTAssertEqual(recorder.seen, [frame])
    }

    // MARK: - keyboardOverlap(in:) — the coordinate-space conversion itself

    private func makeHostedView(size: CGSize = CGSize(width: 320, height: 700)) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        window.addSubview(view)
        window.makeKeyAndVisible()
        addTeardownBlock { window.isHidden = true }
        return (window, view)
    }

    func testKeyboardOverlapIsZeroWithNoKeyboard() {
        let (_, view) = makeHostedView()
        XCTAssertEqual(observer.keyboardOverlap(in: view), 0)
    }

    func testKeyboardOverlapIsZeroForAViewWithNoWindow() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        post(UIResponder.keyboardWillChangeFrameNotification,
             frame: CGRect(x: 0, y: 400, width: 320, height: 300), isLocal: true)
        XCTAssertEqual(observer.keyboardOverlap(in: view), 0)
    }

    /// A live `UIWindow` in a plain XCTest process has no real window-server
    /// connection, so `UIScreen.coordinateSpace.convert` degrades to a zero
    /// rect there (measured: it does, on this SDK) — there is no way to pin
    /// the screen-vs-window conversion itself against a genuine geometric
    /// answer without a hosted UI test. What IS pinned, precisely: the
    /// arithmetic `keyboardOverlap(in:)` reduces to once the keyboard's
    /// frame is already in the view's own coordinate space — this is the
    /// half of the P1 fix that a plain unit test can hold accountable.
    func testOverlapArithmeticOnceTheKeyboardFrameIsInViewCoordinates() {
        let viewBounds = CGRect(x: 0, y: 0, width: 320, height: 700)

        // The keyboard's top edge sits 300pt above the view's own bottom.
        let keyboardTopWithin = CGRect(x: 0, y: 400, width: 320, height: 300)
        XCTAssertEqual(
            KeyboardFrameObserver.overlap(convertedKeyboardFrame: keyboardTopWithin, viewBounds: viewBounds), 300)

        // The keyboard is entirely below the view: no overlap.
        let keyboardBelow = CGRect(x: 0, y: 900, width: 320, height: 300)
        XCTAssertEqual(
            KeyboardFrameObserver.overlap(convertedKeyboardFrame: keyboardBelow, viewBounds: viewBounds), 0)

        // The keyboard covers more than the whole view: capped at the
        // view's own height, never negative and never more than that.
        let keyboardOverTheTop = CGRect(x: 0, y: -400, width: 320, height: 2000)
        XCTAssertEqual(
            KeyboardFrameObserver.overlap(convertedKeyboardFrame: keyboardOverTheTop, viewBounds: viewBounds), 700)
    }
}
