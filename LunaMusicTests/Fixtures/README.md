# Streaming test audio

`streaming.mp4` is a generated three-minute sine wave, with no external music.
It is deliberately larger than the playback startup buffer. Regenerate with:

```sh
ffmpeg -f lavfi -i sine=frequency=220:duration=180:sample_rate=44100 -c:a aac -b:a 128k -metadata title="Streaming Test" streaming.mp4
```
