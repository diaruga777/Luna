//
//  PhotosPermissionAlert.swift
//  Luna
//

import LunaModels
import UIKit

/// The alert shown wherever a denied Photos permission blocks a download from
/// reaching the library: only the app's own page in system Settings can grant
/// it back, so the alert's one live action goes straight there.
enum PhotosPermissionAlert {
    static func present(
        from viewController: UIViewController,
        openSettings: @escaping () -> Void = {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    ) {
        let alert = UIAlertController(
            title: L10n.string("Onboarding_Util_storagePermissionAlertTitle"),
            message: L10n.string("Onboarding_Util_storagePermissionAlertMessage"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: L10n.string("Common_openSettings"), style: .default
        ) { _ in
            openSettings()
        })
        viewController.present(alert, animated: true)
    }
}
