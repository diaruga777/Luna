#!/usr/bin/env python3
"""Build the offline automation catalogue from the shipping Swift definitions.

Run from any directory. Uses only Python's standard library. The annotated
notification contracts below supplement extracted intent/entity metadata.
"""
import html
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APPS = ['Reader', 'Music', 'Vault', 'Keyboard', 'Writer']
FOLDERS = {'Luna': 'Reader', 'LunaMusic': 'Music', 'LunaMusicShared': 'Music',
           'LunaVault': 'Vault', 'LunaKeyboard': 'Keyboard', 'LunaWriter': 'Writer',
           'LunaLiveActivity': 'Reader', 'SharedAutomation': 'All apps'}
STRINGS = dict(re.findall(r'^"(.*?)"\s*=\s*"(.*?)";',
    (ROOT / 'LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings').read_text(), re.M))


def localized(value):
    return STRINGS.get(value, value).replace(r'\n', ' ').replace(r'\"', '"')


def field(body, name):
    match = re.search(r'\b' + name + r'\s*(?::[^=\n]+)?\s*=\s*(?:IntentDescription\(\s*)?"([^"\n]*)"', body)
    return localized(match[1]) if match else ''


def properties(body, wrapper):
    # A wrapper can contain nested calls, such as optionsProvider: Foo().
    pattern = r'@' + wrapper + r'\((.*?)\)\s*(?:public\s+)?var\s+(\w+)\s*:\s*([\w.\[\]?]+)'
    result = []
    for match in re.finditer(pattern, body, re.S):
        arguments, name, value_type = match.groups()
        label = re.search(r'title:\s*"([^"\n]+)"', arguments)
        default = re.search(r'default:\s*([^,\n)]+)', arguments)
        result.append({'name': name, 'label': localized(label[1]) if label else name,
                       'type': value_type, 'default': default[1].strip() if default else None})
    return result


def owner(path):
    if path.parts[0] in FOLDERS:
        return FOLDERS[path.parts[0]]
    module = path.parts[2] if len(path.parts) > 2 else ''
    if 'Music' in module or 'Podcast' in module:
        return 'Music'
    if 'Writer' in module:
        return 'Writer'
    if 'Vault' in module:
        return 'Vault'
    if module in ['LunaAppConfig', 'LunaPremium']:
        return 'All apps'
    return 'Reader'


def item(kind, app, name, description, source, **extra):
    return dict(kind=kind, app=app, name=name, description=description, source=source, **extra)


def extract():
    records, providers = [], {}
    swift_files = sorted(p for folder in [*FOLDERS, 'LunaLibraries/Sources']
                         for p in (ROOT / folder).rglob('*.swift'))
    for path in swift_files:
        relative = path.relative_to(ROOT)
        source = path.read_text()
        # All exposed types are top-level. Stop at the next top-level declaration,
        # allowing nested error enums and conditional conformance extensions.
        declarations = list(re.finditer(r'^(?:(?:public|private|internal|final)\s+)*(struct|enum|class|extension)\s+(\w+)([^\n{]*)\{', source, re.M))
        for index, match in enumerate(declarations):
            declaration, symbol, conformances = match.groups()
            body = source[match.end():declarations[index + 1].start() if index + 1 < len(declarations) else len(source)]
            location = dict(source=str(relative), line=source[:match.start()].count('\n') + 1)
            if declaration == 'extension':
                continue
            if 'AppShortcutsProvider' in conformances:
                for intent in re.findall(r'AppShortcut\(\s*intent:\s*(\w+)\(', body):
                    providers[intent] = symbol
                continue
            if re.search(r'\b(AppIntent|AudioPlaybackIntent|LiveActivityIntent|WidgetConfigurationIntent)\b', conformances):
                returned = re.search(r'ReturnsValue<([\w.\[\]?]+)>', body)
                records.append(item('Intent', owner(relative), field(body, 'title') or symbol,
                    field(body, 'description'), symbol=symbol, parameters=properties(body, 'Parameter'),
                    returns=returned[1] if returned else 'No value',
                    opens=bool(re.search(r'openAppWhenRun[^=]*=\s*true', body)),
                    foreground='ForegroundContinuableIntent' in conformances,
                    hidden=bool(re.search(r'isDiscoverable[^=]*=\s*false', body)),
                    confirmation='requestConfirmation(' in body,
                    authenticated='requiresAuthentication' in body,
                    audio='AudioPlaybackIntent' in conformances,
                    longRunning=symbol in ['SaveIntent', 'GetArticleAudioIntent'], **location))
            elif re.search(r'\b(AppEntity|IndexedEntity|TransientAppEntity)\b', conformances):
                query = re.search(r'defaultQuery\s*=\s*(\w+)\(', body)
                records.append(item('Entity', owner(relative), field(body, 'typeDisplayRepresentation') or symbol,
                    '', symbol=symbol, properties=properties(body, 'Property'),
                    transient='TransientAppEntity' in conformances,
                    indexed='IndexedEntity' in conformances, query=query[1] if query else None, **location))
            elif 'AppEnum' in conformances:
                cases = []
                for line in re.findall(r'^\s*case\s+([^\n]+)', body, re.M):
                    cases.extend(value.strip().split('=')[0].strip() for value in line.split(','))
                records.append(item('Choice', owner(relative), field(body, 'typeDisplayRepresentation') or symbol,
                    ', '.join(cases), symbol=symbol, **location))
        # Internal notification definitions only; system lifecycle observers are
        # not custom hooks. Include definitions split over several source lines.
        for match in re.finditer(r'(?:static\s+)?let\s+(\w+)\s*=\s*Notification\.Name\(\s*"([^"\n]+)"', source):
            symbol, value = match.groups()
            if value.startswith(('UIApplication', 'NSMetadata')):
                continue
            records.append(item('Internal event', owner(relative), value,
                'In-process NotificationCenter event. Not a user notification or a Shortcuts trigger.',
                str(relative), symbol=symbol, line=source[:match.start()].count('\n') + 1))
    for record in records:
        if record['kind'] == 'Intent':
            record['provider'] = providers.get(record['symbol'])
    return records


def contracts():
    records = []
    changes = [
        ('Reader', 'article, media, product, link', 'Saved-item UUID. Readable documents use article; created is emitted when content becomes usable.', 'LunaLibraries/Sources/LunaStorage/SavesStore.swift'),
        ('Music', 'song, playlist, show, episode, station, queue', 'Library and podcast IDs. Podcast queue uses item ID podcasts. Resume-position ticks are excluded.', 'LunaLibraries/Sources/LunaMusicCore/PodcastAutomation.swift'),
        ('Vault', 'file, folder', 'Relative path, resolved through Find Vault Items → Path. Includes incoming Mac index changes and removals.', 'LunaLibraries/Sources/LunaVaultStore/VaultFolderStore.swift'),
        ('Keyboard', 'shortcut, word, preference', 'Shortcut ID; language:word; or preference key. Preferences emit updated; words emit created/deleted.', 'LunaLibraries/Sources/LunaStorage/KeyboardStore.swift'),
        ('Writer', 'document, note, group', 'Sheet, note or folder UUID. Committed SQL changes are coalesced; note attachments update the note.', 'LunaLibraries/Sources/LunaWriterStorage/Database/WriterDatabase.swift'),
    ]
    for app, kinds, note, source in changes:
        records.append(item('Change hook', app, f'Luna.{app.lower()}.<kind>.<operation>',
            f'Kinds: {kinds}. Operations: created, updated, deleted (where supported). {note}', source,
            payload='eventID · itemID · kind · operation',
            delivery='Opt in per app in Settings → Automations. Passive; no sound, badge or body. Identifier: luna.change.<event UUID>.',
            consumption='Get Data Changes → process Changes → Dismiss Change Notifications → persist Next Token.'))
    notices = [
        ('Reader', 'Scheduled trigger notification', 'Schedule Trigger Notification schedules one notification after a delay in seconds (0 sends immediately).', 'LunaLibraries/Sources/LunaIntents/TriggerNotificationScheduler.swift', 'luna.trigger.<supplied ID or UUID>', 'Configurable title, subtitle, body and JSON userInfo; use Body for Shortcuts data.', 'Quiet/silent by default; configurable delivery, sound, badge, thread and existing category. Requires notification permission; requests provisional permission if undetermined. Reusing an ID replaces the pending trigger.'),
        ('Reader', 'Friend share received', 'An accepted friend’s share has been imported.', 'LunaLibraries/Sources/LunaSocial/NotificationManager.swift', 'shareReceived-<UUID>', 'lunaNotificationType = shareReceived', 'Opens the app; cleared when the saves list is reached. No dedicated item deep link.'),
        ('Reader', 'Price drop', 'A background price refresh crosses the configured alert threshold.', 'LunaLibraries/Sources/LunaSocial/NotificationManager.swift', '<random UUID>', 'No custom payload', 'Alert and sound. No product-specific notification-tap route.'),
        ('Reader', 'Weekly proposal', 'A new proposed weekly pick is available to the key holder.', 'LunaLibraries/Sources/LunaWeekly/WeeklySaveRefresher.swift', 'weeklyProposal-<UUID>', 'lunaNotificationType = weeklyProposal', 'Alert and sound; no dedicated proposal-tap handler in AppDelegate.'),
        ('Reader', 'Plugin notification', 'A consented plugin calls luna.notifications.post; clear removes that plugin’s own notifications.', 'LunaLibraries/Sources/LunaPluginExport/Bridges/PluginNotificationsBridge.swift', 'plugin.<pluginID>.<identifier>', 'Optional lunaPluginDeepLink', 'App-process only; requires existing notification permission. Tapping a deep link routes through Reader’s URL handler.'),
        ('Reader', 'Xteink Wi-Fi transfer', 'The reader is ready for a Wi-Fi transfer; foreground Luna to continue.', 'LunaLibraries/Sources/LunaSend/XteinkCrossPointTransfer.swift', 'xteink-wifi-transfer', 'No custom payload', 'Alert and sound; opens the app.'),
        ('All apps', 'Premium happy-hour reminder', 'Explicitly enabled weekend reminders, local time Saturday and Sunday at 14:00. Shared premium UI schedules under the calling app’s identity.', 'LunaLibraries/Sources/LunaPremium/PremiumHappyHourReminders.swift', 'luna.premium.happyhour.saturday / .sunday', 'No custom payload', 'Repeating calendar alerts. Reader’s tap handler opens its premium screen; no equivalent special route was found in companion delegates.'),
        ('Music', 'New podcast episode', 'A followed show has notifications enabled and a new episode arrives during refresh.', 'LunaLibraries/Sources/LunaMusicCore/PodcastEpisodeNotifications.swift', 'podcast.<showID>.<episodeID>', 'podcastEpisodeID; category podcast.new-episode', 'Tap opens episode. Actions: podcast.add-to-queue and podcast.play-next enqueue without starting playback. Declined/disabled alerts are discarded.'),
    ]
    for app, title, description, source, identifier, payload, handling in notices:
        records.append(item('Notification', app, title, description, source,
                            identifier=identifier, payload=payload, handling=handling))
    backgrounds = [
        ('Reader', 'Mail fetch', 'com.hsanabria.luna.mailFetch', 'Luna/AppDelegate.swift'),
        ('Reader', 'Price refresh', 'com.hsanabria.luna.priceRefresh', 'Luna/AppDelegate.swift'),
        ('Reader', 'Weekly proposal check', 'com.hsanabria.luna.weeklyProposalCheck', 'Luna/UtilCard/WeeklyProposalBackgroundCheck.swift'),
        ('Reader', 'Nightly article audio', 'com.hsanabria.luna.nightlyArticleAudio', 'Luna/NightlyArticleAudioBackgroundTask.swift'),
        ('Music', 'Podcast refresh', '<music bundle ID>.podcast-refresh', 'LunaMusic/MusicAppDelegate.swift'),
        ('Vault', 'Sync and transfer', '<vault bundle ID>.sync; .share.transfer; dynamically registered transfer IDs', 'LunaVault/VaultAppDelegate.swift'),
        ('Vault', 'Maintenance', '<vault bundle ID>.<importRepair / index / thumbnailMaintenance raw value>', 'LunaVault/VaultAppDelegate.swift'),
    ]
    for app, title, identifier, source in backgrounds:
        records.append(item('Background hook', app, title,
            'System-scheduled work; timing is controlled by iOS. This is not a Shortcuts action or a notification trigger.', source, identifier=identifier))
    return records


def render_card(record):
    esc = html.escape
    def code(value):
        return '<code>' + esc(str(value)) + '</code>'
    chips = [record['app'], record['kind']]
    for key, label in [('provider', 'Automatic shortcut'), ('hidden', 'Private control'),
                       ('audio', 'Audio playback'), ('opens', 'Opens app'),
                       ('foreground', 'May continue in app'), ('confirmation', 'Confirms deletion'),
                       ('authenticated', 'Requires authentication'), ('transient', 'Transient result'),
                       ('indexed', 'Spotlight indexed')]:
        if record.get(key):
            chips.append(label)
    content = '<div class="chips">' + ''.join('<span>' + esc(c) + '</span>' for c in chips) + '</div>'
    content += '<h3>' + esc(record['name']) + '</h3>'
    if record.get('description'):
        content += '<p>' + esc(record['description']) + '</p>'
    if record['kind'] == 'Intent':
        content += '<p class="output">Returns ' + code(record['returns']) + '</p>'
        if record.get('longRunning'):
            content += '<p class="small">Long-running conformance on iOS 27 builds with the supported beta compiler; ordinary intent runtime on iOS 26.</p>'
    for name, label in [('parameters', 'Inputs'), ('properties', 'Properties')]:
        if name not in record:
            continue
        values = record[name]
        if not values:
            content += '<p class="small">No ' + label.lower() + '.</p>'
            continue
        content += '<details><summary>' + label + ' · ' + str(len(values)) + '</summary><table><thead><tr><th>Name</th><th>Type</th><th>Default</th></tr></thead><tbody>'
        for value in values:
            content += '<tr><td>' + esc(value['label']) + '</td><td>' + code(value['type']) + '</td><td>' + esc(value.get('default') or ('Optional' if value['type'].endswith('?') else '—')) + '</td></tr>'
        content += '</tbody></table></details>'
    for key in ['query', 'identifier', 'payload', 'delivery', 'consumption', 'handling']:
        if record.get(key):
            content += '<p class="small"><strong>' + key.title() + '</strong> ' + esc(record[key]) + '</p>'
    href = '../' + record['source']
    content += '<details class="source"><summary>Source' + (' · ' + esc(record['symbol']) if record.get('symbol') else '') + '</summary><a href="' + esc(href, quote=True) + '">' + esc(record['source']) + '</a>'
    if record.get('line'):
        content += '<span class="small"> · line ' + str(record['line']) + '</span>'
    content += '</details>'
    search = json.dumps(record, ensure_ascii=False).lower()
    return '<article class="card" data-app="' + esc(record['app'], quote=True) + '" data-kind="' + record['kind'] + '" data-search="' + esc(search, quote=True) + '">' + content + '</article>'


def main():
    records = extract() + contracts()
    order = {kind: index for index, kind in enumerate(['Intent', 'Entity', 'Choice', 'Change hook', 'Notification', 'Internal event', 'Background hook'])}
    records.sort(key=lambda r: (order[r['kind']], [*APPS, 'All apps'].index(r['app']), r['name']))
    counts = {kind: sum(r['kind'] == kind for r in records) for kind in order}
    revision = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, text=True).strip()
    template = (ROOT / 'scripts/automation-overview.template.html').read_text()
    output = template.replace('<!-- CARDS -->', '\n'.join(map(render_card, records)))
    labels = {'Intent': 'Intent definitions', 'Entity': 'Entities', 'Choice': 'Choices', 'Change hook': 'Change hooks', 'Notification': 'Notification families', 'Internal event': 'Internal events', 'Background hook': 'Background families'}
    output = output.replace('<!-- COUNTS -->', ''.join(f'<div><b>{count}</b><span>{labels[kind]}</span></div>' for kind, count in counts.items()))
    rows = []
    for app in APPS:
        intents = [r for r in records if r['kind'] == 'Intent' and r['app'] in [app, 'All apps']]
        entities = [r for r in records if r['kind'] == 'Entity' and r['app'] in [app, 'All apps']]
        rows.append(f'<tr><td>{app}</td><td>{sum(not r["hidden"] for r in intents)}</td><td>{len(entities)}</td><td>{sum(bool(r.get("provider")) for r in intents)}</td></tr>')
    output = output.replace('<!-- APP ROWS -->', ''.join(rows))
    output = output.replace('<!-- REVISION -->', revision)
    output = output.replace('<!-- DATA -->', json.dumps(records, ensure_ascii=False).replace('</', '<\\/'))
    (ROOT / 'docs/automation-overview.html').write_text(output)
    print(json.dumps({'counts': counts, 'intentsByApp': {app: sum(r['kind'] == 'Intent' and r['app'] == app for r in records) for app in [*APPS, 'All apps']}}, indent=2))


if __name__ == '__main__':
    main()
