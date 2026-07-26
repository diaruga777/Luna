//
//  EmailRecipientPrompt.swift
//  LunaSocialUI
//

import ContactsUI
import UIKit
import LunaModels

/// The two ways a screen collects an email recipient — a typed-address alert and
/// the system contact picker — shared by the Friends screen and the recipient
/// picker so the prompts can't drift.
enum EmailRecipientPrompt {

    /// Presents the "type an email" alert; `onSubmit` receives the raw text.
    static func presentEmailAlert(
        from presenter: UIViewController, title: String,
        onSubmit: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = L10n.string("name@example.com")
            $0.keyboardType = .emailAddress
            $0.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Add"), style: .default) { [weak alert] _ in
            guard let raw = alert?.textFields?.first?.text else { return }
            onSubmit(raw)
        })
        presenter.present(alert, animated: true)
    }

    /// The email-bearing contact picker. No Contacts permission needed — the
    /// picker runs out-of-process. The caller stays the delegate.
    static func makeContactPicker(delegate: CNContactPickerDelegate) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0")
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey]
        picker.delegate = delegate
        return picker
    }
}
