//
//  PriceUIAlerts.swift
//  LunaPriceUI
//

import UIKit
import LunaModels

extension UIViewController {
    /// The price screens' shared OK-only message alert.
    func presentPriceMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
        present(alert, animated: true)
    }
}
