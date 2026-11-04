# Reader launch scaling, 4 November 2026

The reported library is approximately 50–100 saves, including 30 videos. A small
metadata-only launch is insufficient to represent that workload. This follow-up
tests total row count, local media, article size/images, saved reading positions,
and an established search-vector cache separately from a first-time backfill.

## Measurements

iPhone 17 Pro simulator, iOS 26.2, Release, arm64, same build settings on both
sides. Each result is the mean of ten cold-process launches measured with
`XCTApplicationLaunchMetric(waitUntilResponsive: true)`; the warm-up is discarded.
These measure when the app answers accessibility, not video-first-frame latency.

| Fixture | Before (ms) | After (ms) |
| --- | ---: | ---: |
| Empty | 1,009 | — |
| 100 articles, about 1.9k words each | 1,113 | — |
| 100 saves: 70 articles + 30 local videos | 1,163 | 1,101 |
| Same count; articles have about 18.6k words, 20 images and saved reading positions | 1,345 | 1,283 |
| Long/resumed case plus 34.41 MB of search vectors | — | 1,303 |
| 5,000 articles | 2,168 | — |
| 5,000 saves: 2,500 articles + 2,500 local videos | 4,939 | 2,296 |

Before is `09d29cdc1`; after is `be534eef0`. The raw samples, medians and relative
standard deviations are in [the measurement JSON](launch-scaling-2026-11-04.json).
The 5,000-save change is large relative to its 0.8% / 1.7% relative standard
deviations. At 100 saves the gains are modest and the runs vary by 3–5%; these
single before/after pairs do not establish a reliable percentage improvement
on a physical phone. The vector-cache case is within the long-case variation.

The no-resume long-article run completed, but XCTest returned no performance
samples. It is excluded rather than treated as a measurement. Consequently the
long-case comparison combines article length, images and restoration; it does
not quantify their individual contributions.

## Findings and changes

`KindDeckProvider.deckPreparedSnapshot` reads and orders the whole save list,
including archived metadata. It does **not** load every article body or create
every video player. The portrait carousel mounts the current card and its two
neighbors. Mounted articles still decode their complete JSON before rendering.

The media presenter used separate SQL reads for archived state, fingerprints,
content checks and archive cells, plus repeated complete media-library reads.
It now reads media once per synchronous reload, indexes that snapshot by save
ID and source URL, and reuses it for unbacked rows and Photos reconciliation.
The snapshot is discarded when the reload settles, including an unchanged
reload. Interactive actions still read fresh data. A regression test grows the
library from one to 100 videos and verifies read-statement count stays bounded;
it also checks a later reload sees another connection's archive mutation.

`SavedMediaStore.recoverInterruptedTransitionsUnlocked` used to resolve
`mediaDirectory` for every local video. That getter creates directories and
applies backup policy. It now resolves the directory once per sweep.
`ArticleImageDownloader.resolveLocalImages` had the same pattern for each inline
image; it now resolves the article directory once, and avoids it entirely for
content with no named images. Missing-file and animated-image repair behavior is
unchanged.

There is still content-dependent work on main: restored positions below the
preview make `ScrollReaderViewController` render the whole article and build its
word map before it can restore that position. Its initial layout also forces
TextKit layout. Ordinary top-of-article opening uses a progressive prefix, while
restoration can bypass that shortcut. The sampled long/resumed launch contains
main-thread renderer, word-map and media-file reconciliation stacks. This is a
more relevant remaining path for a 100-save library than extrapolating from the
5,000-row stress case.

Metadata hydration, sorting, media existence checks and archive presentation
models remain proportional to library size. This change removes repeated
queries/passes; it does not turn the store into a paged metadata source.

## Fixture scope and limitations

Fixtures run only in a new, dedicated simulator named `Luna Launch Scale`.
No phone or pre-existing simulator library was changed. Eighty percent of rows
are archived; the newest article is centered with a local video beside it.
The supplied video is a genuine one-second 320×180 H.264 MP4. Posters/inline
images are 1600×900 JPEGs. Distinct file paths are hard links to common synthetic
payloads, so count and decoder work are exercised without duplicating gigabytes
of test data. The first fixture generator produced 1,859 / 18,577 body words;
the reusable generator accepts exact word counts.

This does not reproduce long 4K/HDR clips, iCloud downloads, device storage
pressure or a real Photos library. Photos-backed rows also run per-asset
PhotoKit existence checks during reconciliation; that path was inspected in
code, not measured with this local-file fixture. A physical iPhone was not
available. The optional question about video storage had no answer during this
run, so no storage location is assumed for the user's actual videos.

The fixture uses the default keep-forever retention policy. With age-based
retention enabled, `prepareSnapshotSideEffects` still calls `purgeExpired`
synchronously; expired local media can add SQL updates and file reaping before
the deck finishes construction. Likewise, Photos reconciliation performs its
per-asset checks only with full read authorization. These conditional costs are
source findings, not measured explanations of the user's particular pause.

Historical search backfill and embedding generation are marked complete in the
fixtures to isolate established-library behavior. Their full-text body indexes
are not populated. The vector stress case has 11,200 normalized synthetic
768-dimensional vectors (160 chunks per article); it exercises cache loading,
not the quality or cost of generating embeddings. The simulator's embedding
model is unavailable, and the cache uses the matching `nl-en-unavailable` key.

## Reproduction and validation

Create and boot a fresh iOS 26.2 iPhone simulator named `Luna Launch Scale`,
install the Release Reader app and launch it once to create an empty store.
Generate reusable assets with `ffmpeg`:

```sh
ffmpeg -f lavfi -i color=c=blue:s=320x180:d=1 -an -c:v libx264 \
  -pix_fmt yuv420p video.mp4
ffmpeg -f lavfi -i testsrc=size=1600x900 -frames:v 1 poster.jpg
```

With `DEVELOPER_DIR` set to the desired Xcode, seed the established long case:

```sh
python3 scripts/seed_launch_scale_fixture.py --simulator <UDID> \
  --assets <folder-with-video-and-poster> --count 100 --mode mixed --videos 30 \
  --words 18577 --images 20 --resume
```

Add `--vector-chunks 160` for the vector-cache case. For the short case use
`--words 1859` and omit `--images` / `--resume`. The script refuses physical
devices, simulators with another name, and an existing nonempty library unless
it already carries the synthetic-fixture marker. It directly seeds fixture SQL
and files; it is not an ingest or ownership-integrity test.

Run the `LaunchPerf` plan's `testLaunchToResponsivePerformance` in Release with
`ONLY_ACTIVE_ARCH=YES`, using the same derived data and simulator across cases.
Use `xcodebuild test-without-building` after building once so compilation cannot
compete with measured launches. Keep the app terminated while replacing fixtures.

Validation: 49 focused tests pass across bulk media reads, cross-connection
refresh, deck identity/archive behavior, media persistence, animated article
images and progressive reader rendering/reuse. Six unrelated media URL-identity
tests previously reproduced on unchanged main were excluded; they still expect
the Swift recognizer that `pluginsOnly` disables. The fixture script's syntax
and refusal of a pre-existing ordinary simulator were checked, and its vector
fixture was used for the recorded run.
