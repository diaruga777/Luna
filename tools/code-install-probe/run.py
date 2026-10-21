#!/usr/bin/env python3
"""Reproducible feasibility fixture. Install never implies launch or verification."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def run(arguments, *, output=None, timeout=180):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if output:
        output.write_bytes(result.stdout)
        output.chmod(0o600)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} failed ({result.returncode}); see the private output directory")
    return result.stdout


def query(device, arguments, output, stage):
    document = output / (stage + '.json')
    run(['xcrun', 'devicectl', 'device', *arguments, '--device', device,
         '--timeout', '120', '--json-output', str(document)], output=output / (stage + '.log'))
    document.chmod(0o600)
    result = json.loads(document.read_bytes())
    if result.get('info', {}).get('outcome') != 'success':
        raise RuntimeError(f'{stage}: CoreDevice did not confirm command success')
    return result


def identity(details, device):
    value = details.get('result', {})
    properties = value.get('properties', {})
    hardware = properties.get('hardware', value.get('hardwareProperties', {}))
    if hardware.get('udid') != device or hardware.get('reality') != 'physical':
        raise RuntimeError('The Apple connection does not match the selected physical phone')
    return properties.get('connection', value.get('connectionProperties', {}))


def matches(document, product):
    return any(app.get('bundleIdentifier') == product['CFBundleIdentifier']
               and app.get('version') == product['CFBundleShortVersionString']
               and app.get('bundleVersion', app.get('buildVersion')) == product['CFBundleVersion']
               for app in document.get('result', {}).get('apps', []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['doctor', 'build', 'install', 'probe', 'collect'])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--device', help='Explicit physical Apple UDID; never a device name')
    parser.add_argument('--team', help='Explicit development team for a device build')
    parser.add_argument('--bundle-id', default='dev.luna.install-probe')
    parser.add_argument('--build-number', default=str(int(time.time())))
    parser.add_argument('--simulator', action='store_true', help='Build only; cannot prove device feasibility')
    parser.add_argument('--port', type=int, help='Optional port observed from Apple discovery on this phone')
    args = parser.parse_args()
    if args.command == 'doctor':
        print(json.dumps({'xcode': run(['xcodebuild', '-version']).decode().strip(),
                          'macOS': run(['sw_vers', '-productVersion']).decode().strip(),
                          'physicalChecks': 'pending', 'usesWebDriverAgent': False}, indent=2))
        return 0
    if not args.output:
        parser.error('--output is required')
    output = args.output.resolve()
    if output == REPO or REPO in output.parents:
        parser.error('--output must be outside the repository (logs contain private device metadata)')
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.chmod(0o700)
    app = output / 'DerivedData/Build/Products' / ('Debug-iphonesimulator' if args.simulator else 'Debug-iphoneos') / 'InstallProbe.app'
    if args.command == 'build':
        if not args.simulator and not args.team:
            parser.error('--team is required for a device build')
        if not re.fullmatch(r'[A-Za-z0-9.-]+', args.bundle_id) or 'webdriveragent' in args.bundle_id.lower():
            parser.error('invalid fixture bundle ID')
        if not re.fullmatch(r'\d+(\.\d+){0,2}', args.build_number):
            parser.error('invalid fixture build number')
        run(['ruby', str(HERE / 'generate.rb'), str(output), args.bundle_id, args.build_number])
        arguments = ['xcodebuild', 'build', '-project', str(output / 'InstallProbe.xcodeproj'),
                     '-scheme', 'InstallProbe', '-destination', 'generic/platform=iOS Simulator' if args.simulator else 'generic/platform=iOS',
                     '-derivedDataPath', str(output / 'DerivedData')]
        if args.team:
            arguments += ['-allowProvisioningUpdates', 'DEVELOPMENT_TEAM=' + args.team]
        run(arguments, output=output / 'build.log', timeout=900)
        print(json.dumps({'state': 'built', 'app': str(app), 'installed': False, 'launched': False}))
        return 0
    if not args.device or not re.fullmatch(r'(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})', args.device):
        parser.error('--device must be the explicit physical Apple UDID')
    if args.simulator:
        parser.error('device checks require a physical phone')
    details = query(args.device, ['info', 'details'], output, 'device')
    connection = identity(details, args.device)
    if args.command == 'install':
        product = plistlib.loads((app / 'Info.plist').read_bytes())
        if product.get('CFBundleIdentifier') != args.bundle_id:
            parser.error('built fixture identity does not match --bundle-id')
        run(['codesign', '--verify', '--deep', '--strict', str(app)], output=output / 'signature.log')
        query(args.device, ['install', 'app', str(app)], output, 'install')
        installed = query(args.device, ['info', 'apps', '--bundle-id', args.bundle_id], output, 'readback')
        verified = matches(installed, product)
        # Automatic CoreDevice routing is recorded as returned, never guessed
        # to be local/Tailscale based on a successful command or an IP prefix.
        summary = {'state': 'succeeded' if verified else 'unknownCompletion', 'launched': False,
                   'revisionVerified': verified, 'transportType': connection.get('transportType', 'unknown'),
                   'tunnelTransportProtocol': connection.get('tunnelTransportProtocol', 'unknown'),
                   'underlay': 'unverified', 'build': product['CFBundleVersion']}
        (output / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary))
        return 0 if verified else 3
    if args.command == 'probe':
        # Explicit foreground test command; it is not part of install or scheduling.
        if args.port is not None:
            if not 1 <= args.port <= 65535:
                parser.error('--port must be an observed Apple service port')
        # Launch's app arguments must follow all devicectl options.
        run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
             '--timeout', '30', '--json-output', str(output / 'probe-launch.json'),
             '--terminate-existing', args.bundle_id, '--', '--probe',
             *(['--port', str(args.port)] if args.port else [])], output=output / 'probe-launch.log')
        print(json.dumps({'state': 'probeLaunched', 'installationVerifiedByProbe': False}))
    elif args.command == 'collect':
        query(args.device, ['copy', 'from', '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle_id,
                           '--source', 'Documents/probe.jsonl', '--destination', str(output / 'probe.jsonl')], output, 'collect')
        print(json.dumps({'state': 'collected', 'physicalAcceptance': 'requires manual review'}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
