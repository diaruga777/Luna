# Modal and navigation exit audit — 2 November 2026

Reviewed presentation call sites, full-screen controllers, hidden navigation bars,
and custom close-control layouts in Reader, Vault, Music, Keyboard, and Writer.

## Fixed

- Vault's connected file/image previews presented Quick Look directly. They now
  use Quick Look as the root of a system navigation controller with Done. UIKit
  owns the safe-area chrome and image interactions. Both Mac Files and Vault
  Folder use this path, and dismissing it releases temporary preview files.
- The legacy Vault protected-object preview host now supplies native navigation
  and Done for image, PDF, text, media, and Quick Look previews. Unavailable/error
  preview states also have Done. Repository lease renewal/release stays intact.
- `NavHeaderTableController` left the shared navigation bar hidden for subsequent
  standard screens. It now restores the system bar when leaving and reasserts
  its own hidden-bar state on return. This fixes Reader's Show Source and Create
  Plugin screens, and Writer's Automations page, through their shared owner.
- Plugin creation also opens from failed saves and recovery handoffs. It now
  explicitly shows the system bar when pushed from the card deck and supplies
  Cancel when presented as a modal navigation root.
- Reader's attachment lightbox positioned Close relative to the fitted image,
  which could place it under the status bar for tall images. Close now has a
  fixed 44-point target within the live safe area, with image space reserved
  below it and image layout updated on rotation. Its background tap recognizer
  ignores the button and its descendant views.
- Music and podcast full-screen players exposed only an invisible dismiss
  button over a grabber, partly above the safe-area top. Both now show a down
  chevron with a 44-point target wholly below the safe-area top.

## Other reviewed paths

Reader's archived-image and platform-video viewers, Vault's dedicated video
player, Writer's editor and read-along presentations, and Keyboard's settings,
pickers, and import alerts already provide safe-area controls, native navigation,
or system dismissal. Plugin import/review/consent flows provide explicit cancel
or decline actions. Custom settings headers keep their existing scroll hit-test
and interactive-back coverage.

## Verification

Targeted simulator tests cover the plugin-source round trip, custom-header round
trips, scrolling-header hit testing, lightbox close geometry/hit testing in
portrait and landscape, Quick Look Done hit testing and dismissal cleanup, and
the two players' visible close-button geometry/hit testing. Vault and Music
layout tests attach rendered screenshots for visual inspection.

All 45 targeted tests passed on the iPhone 17 Pro simulator with iOS 26.2:
7 Reader navigation/lightbox tests, 10 plugin-creation tests, 9 Music layout
tests, 18 Vault visual-flow tests, and 1 Vault preview lease-release test.
Reader, Vault, and Music built successfully as part of those runs. This pass
does not claim a manual walkthrough of every screen or physical-device testing.
