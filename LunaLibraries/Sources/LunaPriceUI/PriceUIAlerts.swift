//
//  PriceUIAlerts.swift
//  LunaPriceUI
//

import LunaTransitions
import UIKit

extension UIViewController {
    /// The price screens' shared OK-only message alert.
    func presentPriceMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DotMatrixModal.present(alert, from: self)
    }
}
