#!/usr/bin/env python3
"""Synthetic established-library rendering fixtures; never run against real user data.

See claudedocs/launch-scaling.md for setup, metrics and fixture limitations.
"""
import argparse, json, os, pathlib, shutil, sqlite3, subprocess, time, uuid
from array import array


p = argparse.ArgumentParser(description="Replace a disposable Luna Launch Scale simulator library with synthetic saves.")
p.add_argument("--simulator", required=True)
p.add_argument("--assets", type=pathlib.Path, required=True, help="Folder containing video.mp4 and poster.jpg (generated with ffmpeg)")
p.add_argument('--count', type=int, required=True)
p.add_argument('--words', type=int, default=2000)
p.add_argument('--mode', choices=['articles', 'mixed', 'video_front'], default='articles')
p.add_argument('--images', type=int, default=0)
p.add_argument('--model', default='nl-en-unavailable')
p.add_argument('--resume', action='store_true')
p.add_argument('--videos', type=int)
p.add_argument('--vector-chunks', type=int, default=0)
a = p.parse_args()
if a.count < 0 or a.words < 1 or a.images < 0 or a.vector_chunks < 0 or (a.videos is not None and not 0 <= a.videos <= a.count):
    p.error('Counts must be nonnegative, article words positive, and videos <= saves.')
if not all((a.assets / name).is_file() for name in ['video.mp4', 'poster.jpg']):
    p.error('The assets folder must contain video.mp4 and poster.jpg.')
SIM = a.simulator
SIMCTL = subprocess.check_output(['xcrun', '--find', 'simctl'], text=True).strip()
devices = json.loads(subprocess.check_output([SIMCTL, 'list', 'devices', '--json'], text=True))
device = next((d for group in devices['devices'].values() for d in group if d['udid'] == SIM), None)
if not device or not device['name'].startswith('Luna Launch Scale') or device['state'] != 'Booted':
    p.error('Use a booted disposable simulator named Luna Launch Scale. Physical devices and other simulators are refused.')
groups = subprocess.check_output([SIMCTL, 'get_app_container', SIM, 'com.hsanabria.luna', 'groups'], text=True)
ROOT = pathlib.Path(next(line.split('\t', 1)[1] for line in groups.splitlines() if line.startswith('group.com.hsanabria.luna\t')))
ASSETS = a.assets
marker = ROOT / '.luna-scale-fixture'
if not marker.exists():
    check = sqlite3.connect('file:' + str(ROOT / 'saves.sqlite') + '?mode=ro', uri=True)
    count = check.execute('SELECT COUNT(*) FROM saves').fetchone()[0]
    check.close()
    if count:
        p.error('The simulator already has saves. Use a fresh empty disposable simulator.')
    marker.write_text('Synthetic launch fixtures only.\n')
subprocess.run([SIMCTL, 'terminate', SIM, 'com.hsanabria.luna'], capture_output=True)
for name in ['Articles', 'SavedMedia']:
    shutil.rmtree(ROOT / name, ignore_errors=True)
articles = ROOT / 'Articles'
files = ROOT / 'SavedMedia/Files'
thumbs = ROOT / 'SavedMedia/Thumbnails'
for directory in [articles, files, thumbs]: directory.mkdir(parents=True, exist_ok=True)
shutil.copyfile(ASSETS / 'poster.jpg', articles / 'scale-poster.jpg')
sentence = 'A saved story about reading science culture design people places and daily life.'.split()
words = (sentence * ((a.words + len(sentence) - 1) // len(sentence)))[:a.words]
blocks = [{'kind': 'paragraph', 'text': ' '.join(words[i:i+100]), 'links': []} for i in range(0, len(words), 100)]
for i in range(a.images):
    blocks.insert(min(len(blocks), i * 4), {'kind':'image', 'text':'', 'links':[], 'imageFileName':'scale-poster.jpg', 'imageSize':{'width':1600,'height':900}})
payload = json.dumps({'title':'A long saved article', 'author':'Scale Fixture', 'blocks':blocks}).encode()
template = ASSETS / ('article-' + str(uuid.uuid4()) + '.json')
template.write_bytes(payload)
c = sqlite3.connect(ROOT / 'saves.sqlite')
c.execute('PRAGMA foreign_keys=ON')
c.execute('DELETE FROM saves')
vector = array('f', [1.0] + [0.0] * 767).tobytes()
now = time.time() - 978307200
videos = 0
video_count = a.videos if a.videos is not None else a.count // 2
video_indices = {min(a.count-1, int(k*a.count/max(1,video_count)) + (0 if a.mode == 'video_front' else 1)) for k in range(video_count)}
if video_count == a.count:
    video_indices = set(range(a.count))
for i in range(a.count):
    save_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'luna-scale-' + str(i))).upper()
    video = a.mode != 'articles' and i in video_indices
    archived = now - i - 1000 if i >= max(10, a.count // 5) else None
    title = ('Video' if video else 'Article') + f' {i}: reading science culture design people places and daily life'
    url = f'https://www.tiktok.com/@luna/video/{1000000000000000000+i}' if video else f'https://scale.invalid/articles/{i}'
    content_name = None if video else save_id + '.json'
    c.execute('INSERT INTO saves(id,seq,url_string,title,date_added,archived_at,state,read_state,content_file_name,word_count,platform,platform_item_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
        (save_id,a.count-i,url,title,now-i,archived,'ready','opened',content_name,None if video else a.words,'tiktok' if video else None,str(1000000000000000000+i) if video else None))
    if video:
        videos += 1
        file_name = save_id + '.mp4'
        thumbnail = save_id + '.jpg'
        os.link(ASSETS / 'video.mp4', files / file_name)
        os.link(ASSETS / 'poster.jpg', thumbs / thumbnail)
        c.execute('INSERT INTO media_saves(save_id,source_url_string,title,date_saved,archived_at,kind,storage_state,file_name,thumbnail_file_name,platform,platform_item_id) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
            (save_id,url,title,now-i,archived,'video','localFile',file_name,thumbnail,'tiktok',str(1000000000000000000+i)))
    else:
        os.link(template, articles / content_name)
    # Isolate established-library rendering from a first-ever embedding backfill.
    c.execute('UPDATE library_documents SET needs_backfill=0, embedded_generation=generation, model=? WHERE save_id=?',(a.model,save_id))
    if a.resume and not video:
        c.execute('UPDATE saves SET last_scroll_offset=5000, last_word_index=500 WHERE id=?',(save_id,))
    if a.vector_chunks and not video:
        c.executemany('INSERT INTO library_vectors(save_id,ordinal,dimensions,vector) VALUES(?,?,?,?)',
            ((save_id, chunk, 768, vector) for chunk in range(a.vector_chunks)))
c.execute('DELETE FROM pending_deletes')
c.commit()
c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
c.close()
print(json.dumps({'count':a.count,'videos':videos,'article_words':a.words,'article_images':a.images,'article_bytes':len(payload),'model':a.model,'simulator':SIM}),flush=True)

template.unlink(missing_ok=True)
