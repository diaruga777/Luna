#!/usr/bin/env python3
"""Install the native Xcode product without changing the existing Mac identity."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def metadata(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())


def certificate(app):
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    with tempfile.TemporaryDirectory() as folder:
        prefix = str(Path(folder) / 'cert')
        run('/usr/bin/codesign', '-d', '--extract-certificates=' + prefix, str(app))
        leaf = Path(prefix + '0')
        if not leaf.exists():
            raise ValueError('Luna Mac needs its existing Apple Development certificate. Ad-hoc signing is not supported.')
        return hashlib.sha1(leaf.read_bytes()).hexdigest().upper()


def identity(destination):
    pinned = certificate(destination) if destination.exists() else None
    matches = [sha.upper() for sha, name in re.findall(r'\b([A-Fa-f0-9]{40}) "([^"]+)"', run('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'))
               if name.startswith('Apple Development: ') and (not pinned or sha.upper() == pinned)]
    if len(matches) != 1:
        raise ValueError('The installed Luna Mac certificate is unavailable or ambiguous. Set its signing identity in Xcode from Keychain.')
    return matches[0]


def install(source, destination):
    if destination.is_symlink():
        raise ValueError('Use the existing app bundle directly, without a destination symlink.')
    if source.resolve() == destination.resolve():
        raise ValueError('Build the app separately before installing it.')
    new = metadata(source)
    if new.get('CFBundlePackageType') != 'APPL' or new.get('CFBundleExecutable') != 'LunaVaultMacCompanion':
        raise ValueError('Choose the LunaVaultMac application product.')
    new_cert = certificate(source)
    if destination.exists():
        if new.get('CFBundleIdentifier') != metadata(destination).get('CFBundleIdentifier'):
            raise ValueError('Keep the installed Luna Mac bundle ID. The existing app was left intact.')
        if new_cert != certificate(destination):
            raise ValueError('Keep the installed Luna Mac signing certificate. The existing app was left intact.')
        requirement = subprocess.run(['/usr/bin/codesign', '-dr-', str(destination)], capture_output=True, text=True, check=True)
        match = re.search(r'^designated => (.+)$', requirement.stdout + requirement.stderr, re.M)
        if not match:
            raise ValueError('Could not verify the existing Luna Mac signing requirement.')
        run('/usr/bin/codesign', '--verify', '--test-requirement', '=' + match[1], str(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.luna-mac-install-', dir=destination.parent) as folder:
        staged, backup = Path(folder) / 'New.app', Path(folder) / 'Previous.app'
        run('/usr/bin/ditto', str(source), str(staged))
        certificate(staged)
        # Stop only this installed copy, after the replacement passed validation.
        executable = str(destination / 'Contents/MacOS' / new['CFBundleExecutable'])
        pids = [line.split(None, 1)[0] for line in run('/bin/ps', '-axo', 'pid=,comm=').splitlines()
                if len(line.split(None, 1)) == 2 and line.split(None, 1)[1] == executable]
        for pid in pids:
            run('/bin/kill', '-TERM', pid)
        deadline = time.monotonic() + 15
        while pids and any(subprocess.run(['/bin/kill', '-0', pid], capture_output=True).returncode == 0 for pid in pids):
            if time.monotonic() > deadline:
                raise ValueError('Luna Mac is still closing. Finish its current work and try again.')
            time.sleep(0.1)
        if destination.exists():
            destination.rename(backup)
        try:
            staged.rename(destination)
            certificate(destination)
        except BaseException:
            if destination.exists():
                shutil.rmtree(destination)
            if backup.exists():
                backup.rename(destination)
            raise
    # Refresh Launch Services so Finder, the Dock and Orbit see the bundled icon.
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(destination)], check=False, capture_output=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path, nargs='?', default=Path('/Applications/Luna Vault.app'))
    parser.add_argument('--identity', action='store_true')
    args = parser.parse_args()
    try:
        if args.identity:
            print(identity(args.source))
        else:
            install(args.source, args.destination)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')
