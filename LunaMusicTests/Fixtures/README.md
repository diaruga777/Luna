# Streaming test audio

`streaming.mp4` is a generated three-minute sine wave, with no external music.
It is deliberately larger than the playback startup buffer. Regenerate with:

```sh
ffmpeg -f lavfi -i sine=frequency=220:duration=180:sample_rate=44100 -c:a aac -b:a 128k -metadata title="Streaming Test" streaming.mp4
```

The long-podcast latency test uses an optional generated two-hour MP3 instead of
checking a large binary into the repository:

```sh
ffmpeg -f lavfi -i sine=frequency=220:duration=7200:sample_rate=22050 -c:a libmp3lame -b:a 32k -y /tmp/luna-two-hour-podcast.mp3
TEST_RUNNER_LUNA_PODCAST_LONG_MP3_FIXTURE=/tmp/luna-two-hour-podcast.mp3 xcodebuild test -scheme LunaMusic -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:LunaMusicTests/PodcastLocalResumeTests
```

It restores the saved manifest with an unreachable publisher, prepares a paused
seek to one hour, and measures Play until the media clock advances. Normal local
restore/cancellation/seek/EOF tests use the bundled MP4 and need no network fixture.
