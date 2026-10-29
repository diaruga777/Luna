#!/usr/bin/env python3
"""Generate a phone-sized PDF of Luna's automation definitions."""
from collections import Counter
from html import escape
from pathlib import Path
import re

from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, Spacer, PageBreak, KeepTogether

from build_automation_overview import ROOT, extract, contracts

OUT = ROOT / 'output/pdf/luna-automation.pdf'
OUT.parent.mkdir(parents=True, exist_ok=True)
records = extract()
hooks = contracts()
styles = {
    'title': ParagraphStyle('title', fontName='Helvetica-Bold', fontSize=18, leading=22, spaceAfter=8),
    'head': ParagraphStyle('head', fontName='Helvetica-Bold', fontSize=11.5, leading=15, spaceBefore=9, spaceAfter=5),
    'body': ParagraphStyle('body', fontName='Helvetica', fontSize=10.5, leading=14, spaceAfter=5),
    'cell': ParagraphStyle('cell', fontName='Helvetica', fontSize=10, leading=13),
    'small': ParagraphStyle('small', fontName='Helvetica', fontSize=9, leading=12, textColor=colors.HexColor('#444444'), spaceAfter=5),
    'code': ParagraphStyle('code', fontName='Courier', fontSize=8.3, leading=12, spaceAfter=3, splitLongWords=True),
}


def plain(value):
    return value.replace('\u2019', "'").replace('\u2018', "'").replace('\u201c', '"').replace('\u201d', '"').replace('\u2013', '-').replace('\u2014', '-').replace('\u2192', ' > ').replace('\u00b7', ',')


def p(text, style='body'):
    return Paragraph(escape(plain(text)), styles[style])


def h(text):
    story.append(p(text, 'head'))


def short_type(value):
    if value == 'No value':
        return '-'
    plural = value.startswith('[')
    value = value.strip('[]').replace('Entity', '')
    aliases = {'SavedItem': 'Saved item', 'ProvideContextResult': 'Context result', 'SaveResult': 'Save result',
               'IntentFile': 'File', 'LibraryMusic': 'Library music', 'PodcastEpisode': 'Episode',
               'PodcastShow': 'Show / audio list', 'PodcastStation': 'Station', 'VaultFile': 'Vault item',
               'KeyboardShortcut': 'Shortcut', 'KeyboardWord': 'Word', 'KeyboardPreference': 'Preference',
               'WriterDocument': 'Sheet', 'WriterNote': 'Note', 'WriterGroup': 'Folder',
               'DataChangePage': 'Change page', 'String': 'Text'}
    return aliases.get(value, value) + ('[]' if plural else '')


def actions(values):
    rows = [[p('Action', 'cell'), p('Returns', 'cell')]]
    for r in values:
        name = r['name'] + (' (private)' if r['hidden'] else '')
        rows.append([p(name, 'cell'), p(short_type(r['returns']), 'cell')])
    table = Table(rows, colWidths=[211, 105], repeatRows=1, hAlign='LEFT')
    table.setStyle(TableStyle([
        ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#ededed')),
        ('LINEBELOW', (0, 0), (-1, -1), .3, colors.HexColor('#d8d8d8')),
        ('LEFTPADDING', (0, 0), (-1, -1), 5), ('RIGHTPADDING', (0, 0), (-1, -1), 5),
        ('TOPPADDING', (0, 0), (-1, -1), 4), ('BOTTOMPADDING', (0, 0), (-1, -1), 4),
    ]))
    story.append(table)


def entities(values):
    h('Entities')
    for r in values:
        # Names and field identifiers are enough for a compact developer index.
        fields = ', '.join(v['name'] for v in r['properties'])
        label = r['symbol'].replace('Entity', '') + (' (transient)' if r['transient'] else '')
        story.append(KeepTogether([p(label, 'body'), p(fields, 'small')]))


def choices(values):
    if not values:
        return
    h('Enums')
    for r in values:
        story.append(p(r['symbol'] + ': ' + r['description'], 'small'))


def page(title, note=None):
    if story:
        story.append(PageBreak())
    story.append(p(title, 'title'))
    if note:
        story.append(p(note, 'small'))


def app_records(app, kind):
    return [r for r in records if r['app'] == app and r['kind'] == kind]


story = []
page('Luna Reader', 'App Intents and hooks - 30 Oct 2026. [] means a list; - means no returned value. Shared actions are on page 7.')
actions(app_records('Reader', 'Intent'))
h('Safari URL')
story.append(p('Get Current Safari URL returns a URL without saving or opening Reader. It reads the last page reported by the Safari extension, with the same 72-hour freshness window used by Reader. Enable the extension for the site.'))
entities(app_records('Reader', 'Entity'))
choices(app_records('Reader', 'Choice'))

music = app_records('Music', 'Intent')
podcast = [r for r in music if r['source'].endswith('PodcastAppIntents.swift') or r['symbol'] == 'ResumeLastPodcastIntent']
page('Luna Music', 'Music actions. Podcast actions are on the next page.')
actions([r for r in music if r not in podcast])
entities([r for r in app_records('Music', 'Entity') if r['symbol'] == 'LibraryMusicEntity'])
choices([r for r in app_records('Music', 'Choice') if r['symbol'] != 'PodcastEpisodeAction'])

page('Luna Music - podcasts')
actions(podcast)
entities([r for r in app_records('Music', 'Entity') if r['symbol'] != 'LibraryMusicEntity'])
choices([r for r in app_records('Music', 'Choice') if r['symbol'] == 'PodcastEpisodeAction'])

for app in ['Vault', 'Keyboard', 'Writer']:
    page('Luna ' + app)
    actions(app_records(app, 'Intent'))
    entities(app_records(app, 'Entity'))
    choices(app_records(app, 'Choice'))
    if app == 'Vault':
        story.append(p('Export, import and delete require authentication. Delete asks for confirmation.', 'small'))

page('Shared change hooks', 'These actions and entities exist in all five apps.')
actions(app_records('All apps', 'Intent'))
entities(app_records('All apps', 'Entity'))
h('Notification titles')
story.append(p('Luna.<app>.<kind>.<operation>', 'code'))
for app in ['Reader', 'Music', 'Vault', 'Keyboard', 'Writer']:
    contract = next(r for r in hooks if r['kind'] == 'Change hook' and r['app'] == app)
    kinds = re.search(r'Kinds: (.*?)\.', contract['description'])[1]
    story.append(p(app.lower() + ': ' + kinds))
story.append(p('Operations: created, updated, deleted, where supported. Payload: eventID, itemID, kind, operation. Vault itemID is a relative path.'))
h('Consumption')
story.append(p('Get Data Changes with your saved token; process Changes; dismiss notifications; persist Next Token after success. Repeat while Has More is true.'))
story.append(p('Change notifications are opt-in per app and passive. History keeps 10,000 events per app; pages hold up to 500. Dismissal does not consume history.', 'small'))

page('User notification hooks')
notification_notes = {
    'Friend share received': 'shareReceived-<UUID>; lunaNotificationType=shareReceived. Opens Reader.',
    'Price drop': 'Random UUID; no custom payload or product tap route.',
    'Weekly proposal': 'weeklyProposal-<UUID>; lunaNotificationType=weeklyProposal.',
    'Plugin notification': 'plugin.<pluginID>.<identifier>; optional lunaPluginDeepLink routes the tap.',
    'Xteink Wi-Fi transfer': 'xteink-wifi-transfer. Opens Reader to continue the transfer.',
    'Premium happy-hour reminder': 'luna.premium.happyhour.saturday / .sunday. Opt-in weekend alerts at 14:00 local time.',
    'New podcast episode': 'podcast.<showID>.<episodeID>; podcastEpisodeID payload. Tap opens the episode.',
}
for r in hooks:
    if r['kind'] == 'Notification':
        h(r['app'] + ': ' + r['name'])
        story.append(p(notification_notes[r['name']]))
h('Podcast notification actions')
story.append(p('podcast.add-to-queue\npodcast.play-next', 'code'))
story.append(p('Both queue the episode without starting playback. Category: podcast.new-episode.', 'small'))
h('Background task families')
for app in ['Reader', 'Music', 'Vault']:
    story.append(p(app + ': ' + ', '.join(r['name'] for r in hooks if r['kind'] == 'Background hook' and r['app'] == app) + '.', 'small'))

page('Internal notification names', 'NotificationCenter signals inside app processes; not user alerts or Shortcuts triggers.')
for app in ['Reader', 'Music', 'Writer', 'All apps']:
    values = app_records(app, 'Internal event')
    if values:
        h(app)
        for r in values:
            story.append(p(r['name'], 'code'))


def footer(canvas, doc):
    canvas.setStrokeColor(colors.HexColor('#cccccc'))
    canvas.line(22, 26, 338, 26)
    canvas.setFont('Helvetica', 8)
    canvas.setFillColor(colors.HexColor('#555555'))
    canvas.drawString(22, 14, 'Luna automation - developer reference')
    canvas.drawRightString(338, 14, str(doc.page))


doc = SimpleDocTemplate(str(OUT), pagesize=(360, 720), leftMargin=22, rightMargin=22,
                        topMargin=23, bottomMargin=37, title='Luna automation', author='')
doc.build(story, onFirstPage=footer, onLaterPages=footer)
print(OUT)
print(dict(Counter(r['kind'] for r in records)))
