//
//  WeakScriptMessageHandler.swift
//  Luna
//

import WebKit

/// Weak trampoline for `WKUserContentController.add(_:name:)`, which retains
/// its handler strongly. Registering a view controller directly creates a
/// cycle (controller → web view → configuration → userContentController →
/// controller), so the controller's deinit — and its
/// `removeScriptMessageHandler` call — can never run. Register this instead;
/// only the trampoline is retained, and the edge back to the target is weak.
public final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {

    private weak var target: WKScriptMessageHandler?

    public init(target: WKScriptMessageHandler) {
        self.target = target
    }

    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
