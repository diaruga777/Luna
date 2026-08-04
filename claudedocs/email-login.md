# Email login flow

`Luna/Mail/` implements email-account sign-in for the two apps that do email
(`Luna` and `LunaReader` — `LunaApp.sharesByEmail`; the app target is
filesystem-synchronized, so no project-file edits are needed when files are added
here).

There is **one** entry point and no modal sheet: the Sharing Account section of
**Settings → Email** (`EmailAndKindleSettingsScreen`) IS the sign-in
form until an account exists. Anything that needs an account and doesn't have one
redirects there rather than asking first —
`SendToFriendSheet.accountSetupLauncher` and
`UtilCardContentViewController.emailSetupLauncher` (the util card's
"Read your newsletters in Luna" button, `claudedocs/util-card.md`), both
installed by the `KindWiring` variants of those two apps, call
`EmailAndKindleSettingsScreen.pushForAccountSetup(from:)`, which pushes the screen
with the address field already focused (`focusesAddressField`, honored in
`viewDidAppear`). An app extension, which can't navigate the app's settings,
explains in an alert instead.

An account whose saved credential is later rejected stays present for recovery
rather than being silently deleted. `EmailAccountStore.authenticationIssue`
persists either `.credentialsRejected` (IMAP/SMTP) or
`.authorizationExpired` (Outlook OAuth) in the shared App Group. In that state
`isConfigured` remains true (metadata + Keychain secret still exist) while
`isReady` becomes false, so sending/importing pauses and prerequisite redirects
lead back here. Settings shows the affected address, an orange provider-specific
error row, **Reconnect Email**, and Sign Out. Reconnect reuses the address and
stored provider/server configuration (it does not re-infer or rediscover a
custom domain): Outlook launches OAuth again; app-password providers push the
normal credential controller. Saving the replacement credential clears the
issue.

## Steps

1. **The inline address row** (`EmailAndKindleSettingsScreen`) — the same rounded
   envelope field card retained from the former tray setup, with a left-aligned address
   field carrying the AutoFill invariants below and a provider chip that fades in
   once the domain is recognized; beneath it a
   **Connect** row, tinted and selectable only while the typed address could
   plausibly be one, and showing a small eclipse-horizon spinner during autodiscovery.
   The field and chip are long-lived views re-hosted into each freshly built cell:
   the screen reloads its table on `viewWillAppear`, and rebuilding the field
   would drop both the half-typed address and the keyboard session.
2. **`EmailAccountSetup`** (`EmailAccountSetup.swift`) — everything between the
   address and a saved account: provider inference, IMAP/SMTP resolution
   (registry or ISPDB autodiscovery), then either pushing step 3 or running
   Outlook OAuth to completion. It is owned by the screen that holds the field, so
   another entry point could reuse it unchanged. `onBusyChange` brackets the one
   network wait so the Connect row can show it; `completion(true)` means an
   account was saved.
3. **`CredentialViewController`** (`CredentialViewController.swift`) —
   app-specific password entry, pushed for every provider except Outlook. A hero
   (accent rounded icon tile + 28pt bold title + secondary-label body) sits above
   a rounded field card with a filled "Sign In" button pinned above the keyboard;
   the hero symbol is `key.fill` and the title is the provider's display name.
   Pushed onto the settings stack, it always stays put through its success
   checkmark and hands control to `completion` (the settings screen pops back to
   itself and reloads) — it has no dismissal mode of its own.
4. **Outlook** skips step 3 entirely — `ASWebAuthenticationSession` runs OAuth
   instead (see below).

`CredentialViewController` uses `view.keyboardLayoutGuide` for its button: one
required
constraint (`button.bottomAnchor == view.keyboardLayoutGuide.topAnchor -16`)
is enough, because `keyboardLayoutGuide.topAnchor` already rests at the
safe-area bottom when no keyboard is shown — no separate "floor" constraint is
needed (a second required constraint pinned to the safe area would in fact
conflict with the keyboard-tracking one at rest).

## Shared visual language (`EmailLoginShared.swift`)

`EmailLoginUI` — static builders for the hero tile, title label, body label,
field card, and leading glyph — gives the credential screen a composed look
rather than a bolted-on system form. `GlassStyle.lunaBrandAccent`
(the indigo/periwinkle app-icon accent) is the fill throughout, not the user's
reading accent, so the screen reads as "Luna" whatever the reading accent is.

- **`EmailLoginActionButton`** — the filled 52pt/cornerRadius-14 Sign In button.
  `isEnabled` dims to 50% alpha (a stock disabled state barely dims
  a solid fill). `setLoading(true)` swaps the title for a small embedded white
  `HorizonSpinnerView` and blocks taps. Restoring the
  correct `isEnabled` afterward is the caller's job — `setLoading` only undoes
  the title swap.
- **`ProviderBadgeView`** / **`ProviderBadgeText`** — the small capsule chip
  ("Gmail", "iCloud", …) inside the email field card. `ProviderBadgeText.text(for:)`
  is a pure function (`.generic` → `nil`) driven from the settings screen's
  `addressEdited` `.editingChanged` control action — no
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
anything unrecognized → `.generic`). For `.generic`, `EmailAccountSetup
.resolveServer` first tries Thunderbird's ISPDB
(`autoconfig.thunderbird.net`) for the custom domain's IMAP/SMTP settings, and
falls back to a `imap.<host>`/`smtp.<host>` implicit-TLS guess if that also
comes back empty. This resolve is the address-entry step's only network wait —
see the button-embedded spinner above.

## OAuth vs. app-password paths

- **Outlook** (`.outlook`) is OAuth-only (Microsoft Graph, not IMAP/SMTP) —
  `EmailAccountSetup.startOutlookOAuth` runs PKCE via
  `MicrosoftOAuth` + `ASWebAuthenticationSession`, skipping
  `CredentialViewController` entirely.
  - **User cancellation** (`ASWebAuthenticationSessionError.canceledLogin`)
    is silent: the settings screen stays exactly as it was, no cover, no alert.
  - Any **other session error**, or a **callback that arrives without a
    `code` query item** (a real failure, not a cancellation — e.g. Microsoft
    denied the request), shows "Outlook sign-in failed." This used to return
    silently in both cases; only the cancellation case is silent now.
  - On a successful callback, the token exchange (`exchangeOutlookCode`) shows
    the loading cover, swaps
    the access/refresh tokens into `EmailAccountStore`, best-effort installs
    the inbox filter, then resolves the cover to a checkmark before handing back
    to the settings screen.
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
.systemBackground` view with a centered `HorizonSpinnerView(side: 40)`.
Nothing under it is tappable. On failure the cover is torn down (`hide()`) and the screen's own UI (button, field
interaction) is explicitly re-enabled before the error alert is shown — never
left disabled with no cover and no way to retry.

### Notification permission

`NotificationManager.requestAuthorization()` (`LunaSocial`) is **not** requested at
launch. Connecting an account is one of exactly three moments Luna asks (the others
are pasting the Save of the Week key and committing a price alert threshold), because
until an account exists there is no incoming share to announce. The app-password path
asks in `signIn()` — once the cover is up and verification is underway, so the network
round trip and the system dialog share the same dead time — and the Outlook OAuth path
asks in `exchangeOutlookCode` right after the account is saved. Fire-and-forget both
ways: no success or failure handling is gated on the outcome, and the call is a no-op
once the choice has been made, so a re-sign-in never re-asks.

### Success beat: checkmark resolve

`HorizonSpinnerView.resolveToCheckmark(completion:)`
(`LunaLibraries/Sources/LunaDesignSystem/HorizonSpinnerView.swift`) stops
the orbit, fades the ring and its lights, and draws a centered white-hot "✓" before
calling `completion`. Both verification paths call this on success and hand back
from the completion, so the user sees a compact success beat before the screen
changes. Its basic activity-view contract is covered by
`LunaTests/HorizonSpinnerViewTests.swift`.

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

## Detecting a login that stopped working

Runtime mail calls come from `MailTransportFactory`, which wraps the concrete
transport in `AuthenticationStateTrackingTransport`. The concrete transports
emit the typed `EmailAuthenticationError` only for definite provider rejection:

- an IMAP tagged failure at `LOGIN`, or SMTP rejection during `AUTH`, records
  `.credentialsRejected`;
- a Microsoft token refresh rejected as `invalid_grant` /
  `interaction_required`, Graph `401`, or a Graph authorization error records
  `.authorizationExpired`.

The wrapper persists that issue and posts
`EmailAccountStore.accountChanged`. DNS, timeout, offline, rate-limit, generic
400, and 5xx failures keep their original errors and never trigger recovery UI.
After an issue is recorded `MailTransportFactory` stops background sends/imports
until recovery succeeds; saving new credentials clears it. A successful
authenticated wrapper call also clears a stale issue defensively.

The top-level Settings Email row shows “Sign-in required.” The Email screen
observes `accountChanged`, so it updates even if a foreground mail operation
discovers the rejection while Settings is already visible.

## AutoFill invariants (do not regress)

Both the inline address field and the password field:

- **No delegate.** The system owns the native AutoFill/credential-suggestion
  insertion path directly; a delegate would interpose on iOS 26's input-
  suggestion/replacement path used by system and third-party credential
  providers.
- **`becomeFirstResponder()` only in `viewDidAppear`**, never `viewDidLoad` —
  starting the input session before the view is attached to the window can leave
  the suggestion bar showing a choice from a provisional session that never
  delivers its tap to the field. The address field additionally takes the keyboard
  only when a redirect asked for it (`focusesAddressField`); a plain visit to the
  settings screen leaves the keyboard down.
- **Return key via a control action** (`.editingDidEndOnExit`), not a
  delegate method.
- The address field sets `textContentType = .emailAddress` (and the email
  keyboard) to prefer the fast personal-email suggestion over the
  password-manager UI.
- The password field deliberately sets **no** `textContentType` (see above).

`LunaTests/EmailEntryAutoFillTests.swift` pins these. It hosts the settings
screen in a window so the table realizes real cells, then looks inside the
sign-in row for its field (the Kindle section has a field of its own, so a
first-match search of the whole view would be ambiguous). Both it and
`EmailLoginTests` build the screen with an injected scratch `EmailAccountStore`,
so the form's behavior doesn't depend on whatever the App Group Keychain holds.
