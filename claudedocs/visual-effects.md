# Visual effects

Luna uses ordinary UIKit presentation, navigation, and content-change animations. The
shared custom effects are the loading indicator, onboarding progress dots, moon-horizon
download progress, and the Reader-only Lunar Eclipse navigation treatment.

## Loading spinner (`DotMatrixSpinnerView`)

`LunaLibraries/Sources/LunaDesignSystem/DotMatrixSpinnerView.swift` is the shared loading
indicator: a configurable grid of rounded dots whose opacity and scale ripple diagonally.
It is a plain UIKit/Core Animation view with the familiar `startAnimating()`,
`stopAnimating()`, and `hidesWhenStopped` API. The email login cover can resolve its grid
into a checkmark after successful verification.

## Onboarding progress (`OnboardingDotMatrixProgressView`)

`LunaLibraries/Sources/LunaSocialUI/OnboardingDotMatrixProgressView.swift` renders the
current onboarding position as a compact row of dots. Completed/current dots use the
reading accent and upcoming dots are dimmed. The current dot pulses unless Reduce Motion
is enabled. Step illustrations are implemented separately by `OnboardingAnimationView`.

## Moon-horizon progress (`MoonHorizonProgressBar` / `MoonHorizonProgressView`)

`LunaLibraries/Sources/LunaDesignSystem/MoonHorizonProgress.swift` is the shared
determinate download-progress treatment. A bright point leads a thin illuminated line
along a curved horizon, with an optional activity pulse while progress is in flight.
`MoonHorizonProgressBar` is the UIKit renderer and `MoonHorizonProgressView` is the
SwiftUI/WidgetKit renderer. Both honor Reduce Motion.

The effect is used by Downloader progress surfaces including the Live Activity, action
extension saved-media screen, reading-list status pill, and Downloader App Clip.

## Lunar Eclipse navigation

Luna Reader exposes an off-by-default **Lunar Eclipse Transition** toggle under Settings
→ Appearance. When enabled and Reduce Motion is off, a native reader opened from a real
Reader list row uses `LunarEclipseTransition`; its corresponding pop uses the reverse
treatment. Search, deep links, Downloader, Price Tracker, modals, and reader-internal
navigation retain their standard animations.

`LunarEclipseNavigationDelegate` installs the navigation delegate and
`LunarEclipseTransitionCenter` carries the source-row context into the animator. The
animation silhouettes the source while a scene-wide veil darkens, moves the eclipse to
zenith under a corona, swaps the screen beneath the opaque frame, and uncovers the reader.
The reverse crosses the screen back to the originating row. Simulator builds use a longer
duration for visual tuning; device builds use production timing.

## Dynamic Island eclipse corona

While Luna Reader is foregrounded on a Dynamic-Island iPhone,
`DynamicIslandCoronaView` adds a non-interactive procedural corona behind the
system-owned black capsule. Layered cool/warm rim glows and irregular polar streamers
create the lunar-eclipse edge; a slow opacity shimmer stops when the scene resigns active
and is disabled for Reduce Motion. The effect is Reader-only and uses the portrait top
safe-area geometry as UIKit's public cutout signal, so it stays absent on notch,
home-button, iPad, and landscape layouts.

## Testing notes

- Top navigation-bar items can be flaky to tap through simulator automation; content-area
  taps are more reliable.
- Archive/TestFlight with stable Xcode 26.2. Check the latest App Store Connect build
  number before uploading a new archive.
