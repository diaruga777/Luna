import LunaModels
import LunaPremium
import UIKit

/// Every plugin-creation entry point uses the gate inside the creation screen.
/// Import, export and installed plugins remain available without premium.
public final class PremiumUnlockViewController: UIViewController {
    private let access: PremiumAccess
    private let completion: (Bool) -> Void
    private let purchaseButton = UIButton(type: .system)
    private let freeButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private let status = UILabel()
    private let happyHourTag = UILabel()
    private let happyHourDetail = UILabel()
    private let reminderButton = UIButton(type: .system)
    private let reminderStatus = UILabel()
    private var remindersEnabled = false
    private var displayedProductID: String?
    private var clockTask: Task<Void, Never>?
    private var ready = false
    private var busy = false
    private var finished = false

    public init(access: PremiumAccess? = nil, completion: @escaping (Bool) -> Void) {
        self.access = access ?? .shared
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("Premium_title")
        isModalInPresentation = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.finish(false) })
        let title = UILabel()
        title.text = L10n.string("Premium_unlockTitle")
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
        happyHourTag.font = .preferredFont(forTextStyle: .caption1)
        happyHourTag.adjustsFontForContentSizeCategory = true
        happyHourTag.textColor = .systemOrange
        happyHourTag.numberOfLines = 0
        happyHourDetail.font = .preferredFont(forTextStyle: .footnote)
        happyHourDetail.textColor = .secondaryLabel
        happyHourDetail.numberOfLines = 0
        happyHourDetail.text = L10n.string("Premium_happyHourSchedule")
        happyHourTag.text = L10n.string("Premium_happyHourTag")
        reminderButton.setTitle(L10n.string("Premium_remindMe"), for: .normal)
        reminderButton.configuration = .plain()
        reminderButton.configuration?.image = UIImage(systemName: "bell")
        reminderButton.configuration?.imagePadding = 6
        reminderButton.addAction(UIAction { [weak self] _ in self?.toggleReminders() }, for: .touchUpInside)
        reminderStatus.font = .preferredFont(forTextStyle: .footnote)
        reminderStatus.textColor = .secondaryLabel
        reminderStatus.numberOfLines = 0
        let tagIcon = UIImageView(image: UIImage(systemName: "tag.fill"))
        tagIcon.tintColor = .systemOrange
        tagIcon.setContentHuggingPriority(.required, for: .horizontal)
        let tag = UIStackView(arrangedSubviews: [tagIcon, happyHourTag])
        tag.spacing = 6
        tag.alignment = .center
        tag.isLayoutMarginsRelativeArrangement = true
        tag.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        tag.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        tag.layer.cornerRadius = 10
        let tagRow = UIStackView(arrangedSubviews: [tag, UIView()])
        let happyHour = UIStackView(arrangedSubviews: [happyHourDetail, reminderButton, reminderStatus])
        happyHour.axis = .vertical
        happyHour.spacing = 8
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView(arrangedSubviews: [title, detail, tagRow, purchaseButton, freeButton, happyHour, restoreButton, status])
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
        NotificationCenter.default.addObserver(self, selector: #selector(refreshOnForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        Task { [weak self] in
            guard let self else { return }
            await access.prepare()
            ready = true
            guard !finished else { return }
            if access.state.isPaid { finish(true); return }
            updatePrice()
            if access.purchaseProduct == nil { status.text = L10n.string("Premium_priceUnavailable") }
            await updateReminderState()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !finished else { return }
                if ready { updatePrice() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clockTask?.cancel()
        clockTask = nil
        if isBeingDismissed || navigationController?.isBeingDismissed == true { finished = true }
    }

    @objc private func refreshOnForeground() {
        Task { [weak self] in
            guard let self, !finished else { return }
            await access.reloadProducts()
            await updateReminderState()
            if ready { updatePrice() }
        }
    }

    private func updatePrice() {
        let product = access.purchaseProduct
        displayedProductID = product?.id
        purchaseButton.setTitle(product.map { L10n.string("Premium_unlockPrice", $0.displayPrice) }
            ?? L10n.string("Premium_retryPurchase"), for: .normal)
        purchaseButton.isEnabled = !busy
        happyHourTag.text = L10n.string(access.isHappyHour ? "Premium_happyHourActive" : "Premium_happyHourTag")
        if access.isHappyHour, access.hasHappyHourPrice, let regular = access.product, let sale = access.happyHourProduct {
            happyHourDetail.text = L10n.string("Premium_happyHourPrices", sale.displayPrice, regular.displayPrice)
        } else {
            happyHourDetail.text = L10n.string("Premium_happyHourSchedule")
        }
        if product != nil, status.text == L10n.string("Premium_priceUnavailable") { status.text = nil }
        reminderStatus.isHidden = reminderStatus.text?.isEmpty ?? true
    }

    private func updateReminderState() async {
        remindersEnabled = await PremiumHappyHourReminders.shared.isEnabled
        reminderButton.setTitle(L10n.string(remindersEnabled ? "Premium_stopReminders" : "Premium_remindMe"), for: .normal)
        reminderButton.configuration?.image = UIImage(systemName: remindersEnabled ? "bell.badge.fill" : "bell")
    }

    private func toggleReminders() {
        guard !busy else { return }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            defer { setBusy(false) }
            if remindersEnabled {
                PremiumHappyHourReminders.shared.cancel()
                reminderStatus.text = nil
            } else {
                do {
                    if try await PremiumHappyHourReminders.shared.enable() {
                        reminderStatus.text = L10n.string("Premium_remindersEnabled")
                    } else {
                        let alert = UIAlertController(title: L10n.string("Premium_notificationsOff"),
                            message: L10n.string("Premium_notificationsSettings"), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
                        alert.addAction(UIAlertAction(title: L10n.string("Premium_openSettings"), style: .default) { _ in
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        })
                        present(alert, animated: true)
                    }
                } catch { reminderStatus.text = L10n.string("Premium_reminderFailed") }
            }
            await updateReminderState()
            updatePrice()
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        purchaseButton.isEnabled = !value
        freeButton.isEnabled = !value
        restoreButton.isEnabled = !value
        reminderButton.isEnabled = !value
        navigationItem.leftBarButtonItem?.isEnabled = !value
    }

    private func purchase() {
        guard !busy else { return }
        let expectedProductID = displayedProductID
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            defer { setBusy(false) }
            if expectedProductID == nil {
                await access.reloadProducts()
                updatePrice()
                status.text = access.purchaseProduct == nil ? L10n.string("Premium_priceUnavailable") : nil
                return // A retry loads a price; a separate tap consents to that price.
            }
            do { if try await access.purchase(expectedProductID: expectedProductID) { finish(true) } }
            catch {
                if access.state.isPaid { finish(true) }
                else { status.text = error.localizedDescription }
            }
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
