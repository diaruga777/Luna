# Streaming test audio

`streaming.mp4` is a generated three-minute sine wave, with no external music.
It is deliberately larger than the playback startup buffer. Regenerate with:

```sh
ffmpeg -f lavfi -i sine=frequency=220:duration=180:sample_rate=44100 -c:a aac -b:a 128k -metadata title="Streaming Test" streaming.mp4
```

The long-podcast latency test uses an optional generated two-hour MP3 instead of
checking a large binary into the repository:

```sh
ffmpeg -f lavfi -i sine=frequency=220:duration=7200:sample_rate=22050 -c:a libmp3lame -q:a 5 -write_xing 0 -y /tmp/luna-two-hour-podcast.mp3
TEST_RUNNER_LUNA_PODCAST_LONG_MP3_FIXTURE=/tmp/luna-two-hour-podcast.mp3 xcodebuild test -scheme LunaMusic -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:LunaMusicTests/PodcastLocalResumeTests
```

It prepares an indexed container once, restores the saved manifest with an
unreachable publisher, asserts that launch opens no audio, and measures Play from
cold file open until the media clock advances one hour into the episode. No preroll
or launch-time audio preparation is allowed. Normal local restore/cancellation/
seek/EOF tests use the bundled MP4 and need no network fixture.

To exercise the real download/atomic-install pipeline and storage-cap fallback,
start the RSS fixture server with the same optional file and pass both variables
to the Music tests:

```sh
LUNA_PODCAST_LONG_MP3_FIXTURE=/tmp/luna-two-hour-podcast.mp3 python3 tools/podcast-tests/fixture_server.py
TEST_RUNNER_LUNA_PODCAST_DOWNLOAD_FIXTURE_URL=http://127.0.0.1:19265 TEST_RUNNER_LUNA_PODCAST_LONG_MP3_FIXTURE=/tmp/luna-two-hour-podcast.mp3 xcodebuild test -scheme LunaMusic -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:LunaMusicTests/PodcastQueueDownloadTests
```
