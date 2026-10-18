import LunaModels
import LunaPremium
import UIKit

/// Every plugin-creation entry point uses the gate inside the creation screen.
/// Import, export and installed plugins remain available without premium.
final class PremiumUnlockViewController: UIViewController {
    private let access: PremiumAccess
    private let completion: (Bool) -> Void
    private let purchaseButton = UIButton(type: .system)
    private let freeButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private let status = UILabel()
    private var busy = false
    private var finished = false

    init(access: PremiumAccess? = nil, completion: @escaping (Bool) -> Void) {
        self.access = access ?? .shared
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("Premium_title")
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.finish(false) })
        let title = UILabel()
        title.text = L10n.string("Premium_createPlugins")
        title.font = .preferredFont(forTextStyle: .title2)
        title.numberOfLines = 0
        let detail = UILabel()
        detail.text = L10n.string("Premium_supportDescription")
        detail.font = .preferredFont(forTextStyle: .body)
        detail.numberOfLines = 0
        purchaseButton.configuration = .filled()
        purchaseButton.setTitle(L10n.string("Premium_loadingPrice"), for: .normal)
        purchaseButton.isEnabled = false
        purchaseButton.addAction(UIAction { [weak self] _ in self?.purchase() }, for: .touchUpInside)
        freeButton.setTitle(L10n.string("Premium_unlockWithoutPaying"), for: .normal)
        freeButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        freeButton.addAction(UIAction { [weak self] _ in self?.confirmFree() }, for: .touchUpInside)
        restoreButton.setTitle(L10n.string("Premium_restorePurchases"), for: .normal)
        restoreButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        restoreButton.addAction(UIAction { [weak self] _ in self?.restore() }, for: .touchUpInside)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView(arrangedSubviews: [title, detail, purchaseButton, freeButton, restoreButton, status])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            purchaseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            freeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            restoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        Task { [weak self] in
            guard let self else { return }
            await access.prepare()
            guard !finished else { return }
            if access.state.hasAccess { finish(true); return }
            updatePrice()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { finished = true }
    }

    private func updatePrice() {
        purchaseButton.setTitle(access.product.map { L10n.string("Premium_unlockPrice", $0.displayPrice) } ?? L10n.string("Premium_retryPurchase"), for: .normal)
        purchaseButton.isEnabled = !busy
        if access.product == nil { status.text = L10n.string("Premium_priceUnavailable") }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        purchaseButton.isEnabled = !value
        freeButton.isEnabled = !value
        restoreButton.isEnabled = !value
        navigationItem.leftBarButtonItem?.isEnabled = !value
    }

    private func purchase() {
        guard !busy else { return }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            defer { setBusy(false) }
            do { if try await access.purchase() { finish(true) } }
            catch { status.text = error.localizedDescription }
            updatePrice()
        }
    }

    private func restore() {
        guard !busy else { return }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            defer { setBusy(false) }
            do {
                if try await access.restore() { finish(true) }
                else { status.text = L10n.string("Premium_noPurchase") }
            } catch { status.text = error.localizedDescription }
        }
    }

    private func confirmFree() {
        let alert = UIAlertController(
            title: L10n.string("Premium_title"),
            message: L10n.string("Premium_freeMessage"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Premium_continueForFree"), style: .default) { [weak self] _ in
            self?.access.state.continueForFree()
            self?.finish(true)
        })
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func finish(_ allowed: Bool) {
        guard !finished else { return }
        finished = true
        dismiss(animated: true) { [completion] in completion(allowed) }
    }
}
