"""Local RSS + ranged audio fixture for simulator integration tests. No external I/O."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io, wave, struct, math, time, os
from urllib.parse import urlsplit
port = 19265
buffer = io.BytesIO()
with wave.open(buffer, 'wb') as sound:
    sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(8000)
    sound.writeframes(b''.join(struct.pack('<h', int(300 * math.sin(i * 2 * math.pi * 220 / 8000))) for i in range(8000 * 30)))
audio = buffer.getvalue()
feed = f'''<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Luna Podcast Test Feed</title><itunes:author>Local Integration Fixture</itunes:author><description>Simulator test only.</description><item><guid>fixture-2</guid><title>Fixture Episode Two</title><pubDate>Wed, 07 Oct 2026 10:00:00 +0000</pubDate><itunes:duration>30</itunes:duration><description>Second fixture episode.</description><enclosure url="http://127.0.0.1:{port}/two.wav" type="audio/wav" length="{len(audio)}"/></item><item><guid>fixture-1</guid><title>Fixture Episode One</title><pubDate>Tue, 06 Oct 2026 10:00:00 +0000</pubDate><itunes:duration>30</itunes:duration><description>First fixture episode.</description><enclosure url="http://127.0.0.1:{port}/one.wav" type="audio/wav" length="{len(audio)}"/></item></channel></rss>'''.encode()
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        route = urlsplit(self.path)
        if route.path == '/feed.xml':
            if 'loading-test=' in route.query: time.sleep(4)
            if self.headers.get('If-None-Match') == '"fixture-v1"':
                self.send_response(304); self.end_headers(); return
            self.send_response(200); self.send_header('Content-Type','application/rss+xml'); self.send_header('ETag','"fixture-v1"'); self.send_header('Content-Length',str(len(feed))); self.end_headers(); self.wfile.write(feed)
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
        elif self.path in ('/one.wav','/two.wav'):
            start, end = 0, len(audio)-1
            if self.headers.get('Range','').startswith('bytes='):
                bounds=self.headers['Range'][6:].split('-'); start=int(bounds[0] or 0); end=min(int(bounds[1] or end),end)
                self.send_response(206); self.send_header('Content-Range',f'bytes {start}-{end}/{len(audio)}')
            else: self.send_response(200)
            self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Type','audio/wav'); self.send_header('Content-Length',str(end-start+1)); self.end_headers(); self.wfile.write(audio[start:end+1])
        else: self.send_error(404)
ThreadingHTTPServer(('127.0.0.1',port),Handler).serve_forever()
