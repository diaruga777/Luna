Synthetic ten-minute, silent H.264 video used for AVFoundation streaming tests.
The MP4 moov atom is intentionally at the end. No network or licensed media.

Regenerate with:

```sh
ffmpeg -f lavfi -i 'testsrc=size=320x180:rate=1' -t 600 \
  -c:v libx264 -pix_fmt yuv420p -g 5 -preset fast -an vault-episodes.mp4
```
