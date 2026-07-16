# Email login flow

`Luna/Mail/` implements the email-account sign-in flow shared by all three apps
(the app target, filesystem-synchronized, so no project-file edits are needed when
files are added here). Entry point: `EmailLoginFlow.present(from:accountStore:
completion:)`, called from `AppDelegate` (first-launch prompt), the "Replay
Onboarding" flow (`OnboardingFlow`, with an ephemeral `accountStore` — see
`claudedocs/onboarding.md`), `EmailAndKindleSettingsScreen`, and `CatchUpViewController`
(inline nudge). It builds a `UINavigationController` with
`installDotMatrixTransitions()` and presents it via `DotMatrixModal.present`.
During first-launch onboarding, `OnboardingFlow` instead embeds the same
`EmailEntryViewController` directly as its root. That mode replaces modal Cancel
with a top-right **Skip for now** action and advances to the Safari onboarding
step after a successful credential/OAuth check; all address-entry, provider
inference, AutoFill, autodiscovery, loading-cover, and success behaviors are shared.

## Screens

1. **`EmailEntryViewController`** (`EmailLoginFlow.swift`) — address entry. A
   hero (accent rounded icon tile + 28pt bold title + secondary-label body,
   `OnboardingStepViewController`'s visual language, see below) sits above a
   rounded field card, with a filled "Continue" button pinned above the keyboard.
   In onboarding this is the first onboarding screen itself, not a second sheet
   launched from an opt-in screen, and the field still autofocuses from
   `viewDidAppear`.
2. **`CredentialViewController`** (`CredentialViewController.swift`, its own
   file) — app-specific password entry, pushed for every provider except
   Outlook. Same hero/card/button treatment; the hero symbol is `key.fill` and
   the title is the provider's display name.
3. **Outlook** skips step 2 entirely — `ASWebAuthenticationSession` runs OAuth
   instead (see below).

Both screens use `view.keyboardLayoutGuide` for the button: one required
constraint (`button.bottomAnchor == view.keyboardLayoutGuide.topAnchor -16`)
is enough, because `keyboardLayoutGuide.topAnchor` already rests at the
safe-area bottom when no keyboard is shown — no separate "floor" constraint is
needed (a second required constraint pinned to the safe area would in fact
conflict with the keyboard-tracking one at rest).

## Shared visual language (`EmailLoginShared.swift`)

`EmailLoginUI` — static builders for the hero tile, title label, body label,
field card, and leading glyph — mirrors `OnboardingStepViewController`'s
`iconTile`/title/body/button treatment (`LunaLibraries/Sources/LunaSocialUI/
OnboardingStepViewController.swift`) so the login flow reads as a continuation
of onboarding rather than a bolted-on system form. `GlassStyle.lunaBrandAccent`
(the indigo/periwinkle app-icon accent) is the fill throughout, not the user's
reading accent, for the same reason onboarding uses it.

- **`EmailLoginActionButton`** — the filled 52pt/cornerRadius-14 Continue/Sign
  In button. `isEnabled` dims to 50% alpha (a stock disabled state barely dims
  a solid fill). `setLoading(true)` swaps the title for a small embedded white
  `DotMatrixSpinnerView` and blocks taps — used only by `EmailEntryViewController`
  during `resolveServer` autodiscovery (the address-entry step's only network
  wait; the credential step instead shows the full-screen loading cover, since
  its wait is longer and worth taking over the whole screen for). Restoring the
  correct `isEnabled` afterward is the caller's job — `setLoading` only undoes
  the title swap.
- **`ProviderBadgeView`** / **`ProviderBadgeText`** — the small capsule chip
  ("Gmail", "iCloud", …) inside the email field card. `ProviderBadgeText.text(for:)`
  is a pure function (`.generic` → `nil`) driven from the existing
  `addressEdited` `.editingChanged`/`.editingDidEnd` control action — no
  delegate. The badge view's constraints never change; only `alpha` is
  animated, so there's no layout jump when it appears or disappears. Because
  an empty field has no `@`, `ProviderInference.inferProviderID` returns
  `.generic` for it too, so "hidden when empty" falls out of the same check as
  "hidden for unknown domains" — no separate empty-string special case.
- **`AuthPresentationContext`** — anchors the OAuth `ASWebAuthenticationSession`
  to the presenting window.
- **`UIView.shake()`** — the invalid-input shake, shared by both fields.

## Provider inference & autodiscovery

`LunaLibraries/Sources/LunaMailAccount/ProviderInference.swift` infers a
`MailProvider.ID` from the address's domain (`gmail.com` → `.gmail`, etc.;
anything unrecognized → `.generic`). For `.generic`, `EmailEntryViewController
.resolveServer` first tries Thunderbird's ISPDB
(`autoconfig.thunderbird.net`) for the custom domain's IMAP/SMTP settings, and
falls back to a `imap.<host>`/`smtp.<host>` implicit-TLS guess if that also
comes back empty. This resolve is the address-entry step's only network wait —
see the button-embedded spinner above.

## OAuth vs. app-password paths

- **Outlook** (`.outlook`) is OAuth-only (Microsoft Graph, not IMAP/SMTP) —
  `EmailEntryViewController.startOutlookOAuth` runs PKCE via
  `MicrosoftOAuth` + `ASWebAuthenticationSession`, skipping
  `CredentialViewController` entirely.
  - **User cancellation** (`ASWebAuthenticationSessionError.canceledLogin`)
    is silent: the entry screen stays exactly as it was, no cover, no alert.
  - Any **other session error**, or a **callback that arrives without a
    `code` query item** (a real failure, not a cancellation — e.g. Microsoft
    denied the request), shows "Outlook sign-in failed." This used to return
    silently in both cases; only the cancellation case is silent now.
  - On a successful callback, the token exchange (`exchangeOutlookCode`) shows
    the loading cover, requests notification authorization (see below), swaps
    the access/refresh tokens into `EmailAccountStore`, best-effort installs
    the inbox filter, then resolves the cover to a checkmark before dismissing.
- **Everyone else** (Gmail/iCloud/Yahoo/generic IMAP) authenticates with an
  app-specific password via `IMAPSMTPTransport` (`LunaMailTransport`), entered
  in `CredentialViewController`.
  - **App-password whitespace bug fix**: pasting a password from Gmail/iCloud/
    Yahoo's app-password page commonly carries the provider's own display
    grouping ("xxxx xxxx xxxx xxxx"). `CredentialViewController
    .normalizedPassword(_:providerID:)` (pure, static, unit-tested) strips
    *all* whitespace for every provider except `.generic`, which only
    edge-trims — a custom IMAP server's password is unconstrained free text
    that could legitimately contain an internal space.
  - No `textContentType` on the password field (unlike the email field):
    setting one would let AutoFill offer the account's real sign-in password
    for that domain, which is the wrong secret for an app-specific password.
  - A trailing eye button toggles `isSecureTextEntry`; toggling it re-sets
    `text` (clear then restore) to avoid stale glyphs/caret jumps that a bare
    `isSecureTextEntry` flip can leave behind on a live field.

## The full-screen loading cover (`EmailLoginLoadingCover.swift`)

Both verification paths — `CredentialViewController.signIn`'s IMAP/SMTP
`verifyCredentials()`, and the OAuth token exchange — install one
`EmailLoginLoadingCover` over `navigationController?.view` (not just the
screen's own view, so the Cancel/back bar buttons are covered too): an opaque
`.systemBackground` view with a centered `DotMatrixSpinnerView(dimension: 7,
side: 40)`. Nothing under it is tappable. `dimension: 7` (vs. the default 4)
is specifically so the checkmark shape in `resolveToCheckmark` (below) reads
as a recognizable "✓" rather than a handful of scattered dots. On failure the
cover is torn down (`hide()`) and the screen's own UI (button, field
interaction) is explicitly re-enabled before the error alert is shown — never
left disabled with no cover and no way to retry.

### Notification permission during the network wait

Right after each cover is shown and verification/exchange has started,
`NotificationManager.requestAuthorization()` (`LunaSocial`) is called. This
used to fire from `EmailEntryViewController.continueTapped`, interrupting the
user with the system permission dialog mid-typing, before anything they'd
asked for had actually started. Now it fires only once the network round trip
is already underway and the screen is covered and unusable anyway — the
system dialog appears over the dot-matrix cover, and the user answers it
during otherwise-dead waiting time instead of at an arbitrary earlier moment.
Neither success nor failure handling is gated on the dialog's outcome in any
way; it's fire-and-forget, same as every other call site
(`AppDelegate`, `OnboardingFlow`'s `existingAccountStep`, both untouched by
this change).

### Success beat: checkmark resolve

`DotMatrixSpinnerView.resolveToCheckmark(holdDuration:completion:)`
(`LunaLibraries/Sources/LunaDesignSystem/DotMatrixSpinnerView.swift`) stops the
ripple and animates the matrix into a "✓": dots whose cell-center lies within
half a cell of a fixed 3-point checkmark polyline (unit-square coordinates
`(0.18,0.55) → (0.42,0.78) → (0.82,0.28)`, top-down to match `layoutDots`'
row-major y-axis) animate to full opacity/1.05x scale with a small stagger
ordered by position along the stroke (`checkmarkStrokePosition`); every other
dot fades to ~0.08 opacity/0.6x scale. After the last dot settles, it holds for
`holdDuration` (default 0.35s; total beat ≈0.5s) and calls `completion`. Both
verification paths call this on success, then `DotMatrixModal.dismiss` from the
completion — so the user sees the spinner resolve into a checkmark before the
sheet closes, instead of an abrupt cut. The classification
(`isCheckmarkDot(dimension:index:)`) and stroke-position
(`checkmarkStrokePosition(dimension:index:)`) functions are pure/static/public
so the shape can be sanity-checked without a live view (`LunaTests/
DotMatrixSpinnerViewTests.swift`); `isCheckmarkDot` degrades gracefully (returns
`false`, never crashes) for coarse or degenerate dimensions.

## Error copy

`CredentialViewController.isConnectivityFailure(_:)` distinguishes two failure
shapes from the IMAP/SMTP transport (`StreamIMAPClient`/`StreamSMTPClient`,
backed by `URLSessionStreamTask`, in `LunaMailTransport`):

- A **connectivity failure** (host unreachable, timeout) surfaces as an
  `NSError` in `NSURLErrorDomain`, `NSPOSIXErrorDomain`, or
  `"kCFErrorDomainCFNetwork"` — "Couldn't reach the mail servers. Check your
  connection and try again."
- A **protocol-level failure** (`IMAPError`/`SMTPError` — the server replied,
  but the login was rejected) is in neither domain — "Check the address and
  app password and try again," same message as before this change.

This is a pragmatic domain check, not exhaustive: a `MailStream.StreamError`
(e.g. the connection drops mid-exchange, "connection closed") isn't in either
domain and currently reads as a credential failure. Left as a known,
acceptable simplification rather than trying to enumerate every internal
error type from outside `LunaMailTransport`.

## AutoFill invariants (do not regress)

Both text fields:

- **No delegate.** The system owns the native AutoFill/credential-suggestion
  insertion path directly; a delegate would interpose on iOS 26's input-
  suggestion/replacement path used by system and third-party credential
  providers.
- **`becomeFirstResponder()` only in `viewDidAppear`**, never `viewDidLoad` —
  starting the input session before the view is attached to the presented
  window can leave the suggestion bar showing a choice from a provisional
  session that never delivers its tap to the field.
- **Return key via a control action** (`.editingDidEndOnExit`), not a
  delegate method.
- The email field additionally mirrors its text into `enteredAddress` via
  `.editingChanged`/`.editingDidEnd` (AutoFill and password-manager fills can
  arrive through editing-change and drop the field's own `text` if the
  extension UI backgrounds the app mid-fill) and sets `textContentType =
  .emailAddress` to prefer the fast personal-email suggestion over the
  password-manager UI.
- The password field deliberately sets **no** `textContentType` (see above).

`LunaTests/EmailEntryAutoFillTests.swift` pins these; since the field now sits
inside a rounded field card (several levels deep — scroll view → content →
stack → card → field, not a direct subview of the root view), its lookup uses
a small recursive `findTextField(in:)` search rather than a flat
`view.subviews` scan.
