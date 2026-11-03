import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).parents[1] / 'install_vault_mac.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.source, self.destination = [Path(self.folder.name) / name for name in ['Built.app', 'Installed.app']]
        for app in [self.source, self.destination]:
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='test.vault.mac', CFBundlePackageType='APPL', CFBundleExecutable='LunaVaultMacCompanion')))
        (self.destination / 'old-marker').touch()

    def testChangedCertificateLeavesInstalledBundleIntact(self):
        with patch.object(installer, 'certificate', side_effect=['new', 'old']):
            with self.assertRaisesRegex(ValueError, 'signing certificate'):
                installer.install(self.source, self.destination)
        self.assertTrue((self.destination / 'old-marker').exists())

    def testChangedBundleIDLeavesInstalledBundleIntact(self):
        meta = installer.metadata(self.source); meta['CFBundleIdentifier'] = 'wrong.app'
        (self.source / 'Contents/Info.plist').write_bytes(plistlib.dumps(meta))
        with patch.object(installer, 'certificate', return_value='same'):
            with self.assertRaisesRegex(ValueError, 'bundle ID'):
                installer.install(self.source, self.destination)
        self.assertTrue((self.destination / 'old-marker').exists())

    def testValidationFailureAfterReplacementRestoresOriginal(self):
        def command(*args):
            if args[0] == '/usr/bin/ditto':
                shutil.copytree(args[1], args[2])
            return ''
        with patch.object(installer, 'certificate', side_effect=['same', 'same', 'same', ValueError('bad replacement')]), patch.object(installer, 'run', side_effect=command), patch.object(installer.subprocess, 'run') as process:
            process.return_value.stdout = 'designated => fixture'; process.return_value.stderr = ''
            with self.assertRaisesRegex(ValueError, 'bad replacement'):
                installer.install(self.source, self.destination)
        self.assertTrue((self.destination / 'old-marker').exists())


if __name__ == '__main__':
    unittest.main()
