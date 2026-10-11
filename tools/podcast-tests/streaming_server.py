"""Throttled ranged podcast fixture. Run before the opt-in hosted streaming test.

TEST_RUNNER_LUNA_PODCAST_STREAM_FIXTURE_URL=http://127.0.0.1:19266/slow.mp4 xcodebuild test ...
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import threading
import time
from urllib.parse import urlsplit, parse_qs

AUDIO = (Path(__file__).resolve().parents[2] / 'LunaMusicTests/Fixtures/streaming.mp4').read_bytes()
lock = threading.Lock()
sent = {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        route = urlsplit(self.path)
        token = parse_qs(route.query).get('session', ['default'])[0]
        if route.path == '/slow-art.png':
            time.sleep(3)
            self.send_error(404)
            return
        if route.path in ('/transcript.vtt', '/chapters.json'):
            data = b'WEBVTT\n\n00:00:00.000 --> 00:00:10.000\nReady before artwork.\n' if route.path.endswith('vtt') else b'{"chapters":[{"startTime":0,"title":"Introduction"}]}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if route.path == '/stats':
            with lock:
                data = json.dumps({'bytes': sent.get(token, 0), 'total': len(AUDIO)}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if route.path not in ('/slow.mp4', '/delayed.mp4'):
            self.send_error(404)
            return
        if route.path == '/delayed.mp4':
            time.sleep(2)
        start, end = 0, len(AUDIO) - 1
        if self.headers.get('Range', '').startswith('bytes='):
            bounds = self.headers['Range'][6:].split('-')
            start = int(bounds[0] or 0)
            end = min(int(bounds[1] or end), end)
            if start > end:
                self.send_error(416)
                return
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(AUDIO)}')
        else:
            self.send_response(200)
        self.send_header('Content-Type', 'audio/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end-start+1))
        self.end_headers()
        try:
            for offset in range(start, end + 1, 8192):
                chunk = AUDIO[offset:min(offset + 8192, end + 1)]
                self.wfile.write(chunk)
                self.wfile.flush()
                with lock:
                    sent[token] = sent.get(token, 0) + len(chunk)
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(('127.0.0.1', 19266), Handler).serve_forever()
