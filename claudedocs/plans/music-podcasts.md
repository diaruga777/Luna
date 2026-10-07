# Luna Music: Podcasts implementation plan

Requested: a complete Apple Podcasts-style client alongside Music, not a reduced
v1, plus a back → forward gesture within two seconds that switches preserved
queues and a strictly deterministic Resume Last Podcast audio intent.

## Implementation sequence

1. Foundation-only podcast models, RSS parsing (iTunes/Podcasting 2.0), directory
   search/discovery, durable library, per-show settings, saved/listened/progress,
   stations, OPML and tested continuation policy.
2. Conditional feed polling, background refresh and download sessions, automatic
   download limits/removal, download recovery, notifications, stream/offline
   AVPlayer playback, interruption/route handling, speed/sleep timer, chapters,
   timed transcript parsing/search and video playback.
3. UIKit Podcasts home/discovery/library/search, show/episode pages, contextual
   actions, queue editing, per-show/global settings, native compact/full player,
   accessibility and navigation alongside existing Music.
4. One media coordinator; independent persistent music/podcast queues; back then
   forward within <=2 monotonic seconds toggles media, consuming both skips.
   Standalone back is deferred until the chord expires so switching doesn't
   damage the queue or position being left. A missing destination leaves the
   original queue intact and executes the ordinary skips.
5. AudioPlaybackIntent resumes the exact last podcast regardless of selected
   surface. Only natural completion of the final queued item permits fallback.
   Per followed show, select the oldest unplayed episode strictly after that
   show's most recently played episode; then choose the oldest candidate across
   shows (stable ID ties). A never-played show starts at its oldest unplayed
   episode. No history/eligible candidate is a no-op. Manual marking, a playback
   failure, queue removal or a seek to the end never grants fallback permission.
   CarPlay browsing, Now Playing, hardware transport and widget status use the
   same coordinator.
6. Fixture/unit/integration/UI verification, documentation of actual evidence and
   API boundaries, logical commits, merge to main and delete branch/worktree.

## Parity acceptance inventory

- Search shows/episodes, discover charts/categories, direct RSS URL subscriptions.
- Follow/unfollow, pull to refresh, foreground/background polling, new episodes.
- Library shows/latest/saved/downloaded/played, episode search/order/hide played.
- Stream/download/cancel/remove/retry, background recovery, cellular preferences,
  per-show auto-download limits, played-download retention, storage management.
- Play next/later, reorder/remove/clear, show continuation, independent media queues.
- Progress/resume, manual listened/unlistened, save/share, episode descriptions.
- Skip back/forward defaults 15/30 seconds and configurable intervals; seek/speed,
  sleep timer/end of episode, AirPlay/volume, background/interruption/headphones.
- Feed/embedded chapters, publisher timed transcripts with search/seek, video.
- Stations, notifications, export/import follows; cross-device library/progress.
- Siri/Shortcuts deterministic resume, CarPlay browse/Now Playing/queue switching.
- Dynamic Type/VoiceOver, loading/error/offline/empty states.

## Public platform boundaries (not scope reductions)

Apple Podcasts editorial/personalized recommendations, Apple account follows,
ratings/reviews, Apple-paid subscriptions, Apple-generated transcripts/chapters,
and proprietary enhanced dialogue are not available as public RSS client APIs.
Use public publisher metadata where supplied, and disclose unsupported services.
No private API, fake transcript, or fabricated catalog content.

The existing MPMusicPlayerController applicationQueuePlayer handles external
commands inside MediaPlayer, per Apple's documentation. App-owned AVPlayer
sessions can interpret hardware events; protected Apple Music remote interception
must not be claimed without evidence. Do not approximate the gesture by guessing
from track changes (normal queue navigation and natural endings are ambiguous).
CarPlay also needs Apple's already documented managed signing entitlement.
iOS schedules background polling opportunistically, not on a guaranteed interval.

## Reference behavior

- https://support.apple.com/guide/iphone/iph3a22707a5/ios
- https://support.apple.com/en-gb/guide/iphone/iph4003ecb12/ios
- https://podcasters.apple.com/support/900-availability-rights-and-release-date
- https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller
- https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter

## Verification and remaining work

Record completed checks and unresolved acceptance items here as implementation
progresses. The original checkout contains unrelated uncommitted project changes;
preserve them during merge.

## Execution result (2026-10-08)

Implemented steps 1–5 and simulator verification. Core policy/feed/store/merge tests,
34 hosted Music tests, the five existing Music UI checks and both new podcast UI
checks have passing runs. The RSS UI fixture caught and verified fixes for an
asynchronous alert-address lifetime bug and the navigation run caught UIKit
renaming the Music tab. Download retention has a dedicated regression check.

The deliverable is the implemented public-feed client, **not a verified wholesale
Apple Podcasts clone**. Remaining gaps are explicit: protected Apple Music remote
interception is not public; Apple services listed above cannot be reproduced from
RSS; active queues/device settings do not sync between devices; generated
transcripts/chapters/Enhance Dialogue are not implemented. Physical CarPlay,
headphone gesture delivery, HLS background recovery and live CloudKit account/schema
behavior are not proven by simulator tests. See `claudedocs/music.md` for the exact
implementation and validation contract.
