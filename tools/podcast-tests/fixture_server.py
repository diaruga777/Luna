"""Local RSS + ranged audio fixture for simulator integration tests. No external I/O."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io, wave, struct, math, time, os, zlib
from pathlib import Path
from urllib.parse import urlsplit
from email.utils import formatdate
port = 19265
buffer = io.BytesIO()
with wave.open(buffer, 'wb') as sound:
    sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(8000)
    sound.writeframes(b''.join(struct.pack('<h', int(300 * math.sin(i * 2 * math.pi * 220 / 8000))) for i in range(8000 * 30)))
audio = buffer.getvalue()
notification_audio = (Path(__file__).resolve().parents[2] / 'LunaMusicTests/Fixtures/streaming.mp4').read_bytes()
published_notification_feeds = set()

def notification_item(number, title):
    return f'<item><guid>notification-{number}</guid><title>{title}</title><pubDate>{formatdate(1780000000 + number * 86400, usegmt=True)}</pubDate><itunes:duration>180</itunes:duration><enclosure url="http://127.0.0.1:{port}/notification.mp4" type="audio/mp4" length="{len(notification_audio)}"/></item>'

feed = f'''<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Luna Podcast Test Feed</title><itunes:author>Local Integration Fixture</itunes:author><description>Simulator test only.</description><item><guid>fixture-2</guid><title>Fixture Episode Two</title><pubDate>Wed, 07 Oct 2026 10:00:00 +0000</pubDate><itunes:duration>30</itunes:duration><description>Second fixture episode.</description><enclosure url="http://127.0.0.1:{port}/two.wav" type="audio/wav" length="{len(audio)}"/></item><item><guid>fixture-1</guid><title>Fixture Episode One</title><pubDate>Tue, 06 Oct 2026 10:00:00 +0000</pubDate><itunes:duration>30</itunes:duration><description>First fixture episode.</description><enclosure url="http://127.0.0.1:{port}/one.wav" type="audio/wav" length="{len(audio)}"/></item></channel></rss>'''.encode()
# A publisher-sized archive exercises import, row layout, filtering and scrolling.
notes = '<p>Long publisher notes with links &amp; details.</p>' * 100
show_notes = 'A large archive with long publisher descriptions. ' * 12
large_feed = (f'<rss version="2.0"><channel><title>Luna Large Archive</title><description>{show_notes}</description>' + ''.join(
    f'<item><guid>large-{index}</guid><title>Archive Episode {index:04d}</title><pubDate>{formatdate(1700000000 + index * 86400, usegmt=True)}</pubDate><description><![CDATA[{notes}]]></description><enclosure url="http://127.0.0.1:{port}/one.wav" type="audio/wav" length="{len(audio)}"/></item>'
    for index in range(2000)) + '</channel></rss>').encode()
# A small real image exercises notification attachment download and conversion.
def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
artwork = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0))
           + png_chunk(b'IDAT', zlib.compress((b'\x00' + bytes([140, 70, 220]) * 64) * 64)) + png_chunk(b'IEND', b''))
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        route = urlsplit(self.path)
        if route.path == '/publish-notification-fixture':
            published_notification_feeds.add(route.query)
            self.send_response(204); self.end_headers()
        elif route.path == '/notification-feed.xml':
            items = notification_item(2, "Playing Now") + notification_item(1, "Queued " + route.query[:8])
            if route.query in published_notification_feeds:
                items += notification_item(3, "New Episode " + route.query[:8])
            data = f'<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Queue Fixture</title>{items}</channel></rss>'.encode()
            self.send_response(200); self.send_header('Content-Type', 'application/rss+xml')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        elif route.path == '/artwork.png':
            self.send_response(200); self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(artwork))); self.end_headers(); self.wfile.write(artwork)
        elif route.path == '/feed.xml':
            if 'loading-test=' in route.query: time.sleep(4)
            if self.headers.get('If-None-Match') == '"fixture-v1"':
                self.send_response(304); self.end_headers(); return
            self.send_response(200); self.send_header('Content-Type','application/rss+xml'); self.send_header('ETag','"fixture-v1"'); self.send_header('Content-Length',str(len(feed))); self.end_headers(); self.wfile.write(feed)
        elif route.path == '/large-feed.xml':
            self.send_response(200); self.send_header('Content-Type', 'application/rss+xml')
            self.send_header('Content-Length', str(len(large_feed))); self.end_headers(); self.wfile.write(large_feed)
        elif route.path == '/long.mp3' and os.environ.get('LUNA_PODCAST_LONG_MP3_FIXTURE'):
            path = os.environ['LUNA_PODCAST_LONG_MP3_FIXTURE']
            size = os.path.getsize(path)
            start, end = 0, size - 1
            if self.headers.get('Range', '').startswith('bytes='):
                bounds = self.headers['Range'][6:].split('-')
                start = int(bounds[0] or 0); end = min(int(bounds[1] or end), end)
                self.send_response(206); self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            else: self.send_response(200)
            self.send_header('Accept-Ranges', 'bytes'); self.send_header('Content-Type', 'audio/mpeg')
            self.send_header('Content-Length', str(end-start+1)); self.end_headers()
            with open(path, 'rb') as sound:
                sound.seek(start); remaining = end-start+1
                while remaining:
                    chunk = sound.read(min(65536, remaining)); self.wfile.write(chunk); remaining -= len(chunk)
        elif self.path in ('/one.wav', '/two.wav', '/notification.mp4'):
            payload = notification_audio if self.path == '/notification.mp4' else audio
            start, end = 0, len(payload)-1
            if self.headers.get('Range','').startswith('bytes='):
                bounds=self.headers['Range'][6:].split('-'); start=int(bounds[0] or 0); end=min(int(bounds[1] or end),end)
                self.send_response(206); self.send_header('Content-Range',f'bytes {start}-{end}/{len(payload)}')
            else: self.send_response(200)
            self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Type', 'audio/mp4' if self.path.endswith('.mp4') else 'audio/wav'); self.send_header('Content-Length',str(end-start+1)); self.end_headers(); self.wfile.write(payload[start:end+1])
        else: self.send_error(404)
ThreadingHTTPServer(('127.0.0.1',port),Handler).serve_forever()
