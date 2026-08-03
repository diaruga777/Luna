# Permanent util card

Every Luna card deck has one permanent utility card at carousel index zero. It
replaces the former left tray, standalone onboarding root, synthetic pasteboard
card, and card-carousel empty state.

The shared implementation is
`Luna/UtilCard/UtilCardContentViewController.swift`. Each surface host constructs
it through `CardCarouselHostViewController.makeUtilCardContentController` and
keeps saved content at `cardOffset == 1`.

## Deck position and launch selection

- The util card is always the first/leftmost card and always appears in the mini
  carousel.
- Its mini-card artwork is the running app's action-extension icon. The main app
  icon is only a bundle fallback if the extension artwork cannot be loaded.
- An empty store launches centered on index zero. There is no separate empty
  view or empty-card carousel.
- A non-empty store launches centered on its first save at index one. Reaching
  the util card therefore means paging left.
- New saves still take the center through the ordinary new-ID detection in
  `CardCarouselHostViewController`.

## Content shared by both states

The bottom paste row is always present. It is the real `UIPasteControl`-backed
`OnboardingPasteRow`, so Luna receives clipboard data only after the system paste
control authorizes it. A valid URL runs the surface host's normal ingest path;
invalid input resolves in the row.

The Save of the Week row is also permanent. For now its canonical URL is:

`https://www.lewissociety.org/innerring/`

It starts with a bundled title/host fallback, then uses
`RecentURLMatcher.evaluate` to fetch the title and thumbnail/favicon. The row is
black with a Liquid Glass rim tinted from the current app palette and formats its
subtitle as `host • Save of the week`.

Selecting the weekly row or a recent row calls the same full ingest path as any
other in-app save. `UtilCardSaveTransition` owns the shared handoff: the source
shell expands to the destination card while thumbnail and
labels travel independently, then the mounted destination crossfades in and the
deck centers it.

## First-run state

`AppOnboardingStore.isCompleted == false` selects this state when the carousel
host is constructed. The card shows:

1. the surface-specific two-beat animated intro headline;
2. Save of the Week;
3. Safari setup;
4. Shortcut/Action Button setup on capable surfaces, or share setup on the
   fallback surfaces;
5. the permanent paste row at the bottom.

The headline is moved toward the top of the card, leaving room for the weekly
row and both setup actions. The setup actions launch the existing native Safari
and Messages/setup lessons with `AppOnboardingViewController.presentSetupReplay`.
Completing or skipping a lesson marks that setup leg handled and checks/disables
its button for the remainder of the process.

The card captures its state once per process/root construction. Finishing both
legs does not rearrange the visible card in that session. On the next app launch,
the host observes completion and constructs the completed variant.

## Completed state and recent URLs

Once setup is complete, the headline and setup buttons are absent. Save of the
Week moves to the top of the card. Beneath it the card adds as many matching,
unsaved recent Safari URLs as fit above the paste row; the card never scrolls.

Recent rows use the same black layout as Save of the Week but a neutral Liquid
Glass rim and only the URL host as the subtitle. They come from
`RecentURLMatcher.shared.matches`, so source, classification, cache, newest-first
ordering, and unsaved filtering are exactly the former recent-URL behavior:

- each Safari extension records the newest 20 raw HTTP(S) URLs in the shared App
  Group;
- evaluation runs the real ingest pipeline for the current surface;
- positive and negative verdicts are version-stamped and cached;
- saved URLs disappear on `.readingListChanged`, while deleting that save can
  reveal the cached recent again;
- if Safari is not configured and has produced no usable history, no recent rows
  appear.

## Completion and inheritance

Completion remains per app, with setup evidence shared where appropriate.
`AppOnboardingStore.isCompleted` is true when any of the following holds:

- that app has an explicit completion marker;
- central Luna's Safari and save integrations already cover a newly installed
  faceted app;
- both this app's Safari and save-setup legs have either real run evidence or a
  handled/skipped marker.

The Safari and save handled markers are separate. This permits the buttons to
show their checked state during the launch in which setup finishes while keeping
the layout stable until relaunch. Debug `-resetOnboarding` clears completion,
handled markers, and setup run evidence.

## Validation

`UtilCardTests` pins both launch variants, the permanent paste/weekly controls,
the exact weekly URL, and the weekly row's save callback. Carousel-host and price
screen tests pin the permanent index-zero offset.
