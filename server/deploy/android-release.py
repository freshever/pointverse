#!/usr/bin/env python3
"""VPS-side publication: immutable APKs, atomic catalog, explicit latest selection."""
import argparse, fcntl, hashlib, json, os, pathlib, re, shutil, tempfile


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix='.catalog-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o644)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def publish(root, incoming=None, activate=None):
    root.mkdir(parents=True, exist_ok=True)
    with (root / '.publish.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        catalog_path = root / 'releases.json'
        catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {'schemaVersion': 1, 'latest': None, 'releases': []}
        if activate:
            release = next((r for r in catalog['releases'] if r['file'] == activate), None)
            if not release: raise ValueError('Unknown release')
            if hashlib.sha256((root / 'files' / activate).read_bytes()).hexdigest() != release['sha256']:
                raise ValueError('APK checksum mismatch')
            catalog['latest'] = activate
        else:
            release = json.loads((incoming / 'release.json').read_text())
            filename = release['file']
            if not re.fullmatch(r'[A-Za-z0-9._-]+\.apk', filename): raise ValueError('Invalid filename')
            if release['package'] != 'com.pointverse.app': raise ValueError('Unexpected Android application')
            if not re.fullmatch(r'[a-f0-9]{64}', release['sha256']): raise ValueError('Invalid checksum')
            if not re.fullmatch(r'[a-f0-9]{64}', release['signerSha256']): raise ValueError('Invalid signer')
            payload = incoming / 'app.apk'
            if hashlib.sha256(payload.read_bytes()).hexdigest() != release['sha256'] or payload.stat().st_size != release['size']:
                raise ValueError('APK checksum/size mismatch')
            if any(r['signerSha256'] != release['signerSha256'] for r in catalog['releases']):
                raise ValueError('Signing certificate changed; existing users could not upgrade')
            (root / 'files').mkdir(exist_ok=True)
            destination = root / 'files' / filename
            if destination.exists():
                if hashlib.sha256(destination.read_bytes()).hexdigest() != release['sha256']: raise ValueError('Immutable APK collision')
            else:
                shutil.copyfile(payload, root / 'files' / (filename + '.incoming'))
                os.chmod(root / 'files' / (filename + '.incoming'), 0o644)
                os.replace(root / 'files' / (filename + '.incoming'), destination)
            if not any(r['file'] == filename for r in catalog['releases']): catalog['releases'].insert(0, release)
            catalog['latest'] = filename
            for asset in ('index.html', 'downloads.js', 'downloads.css'):
                shutil.copyfile(incoming / asset, root / (asset + '.incoming'))
                os.chmod(root / (asset + '.incoming'), 0o644)
                os.replace(root / (asset + '.incoming'), root / asset)
        atomic_json(catalog_path, catalog)
        print('Activated Android release:', catalog['latest'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=pathlib.Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--incoming', type=pathlib.Path)
    source.add_argument('--activate')
    args = parser.parse_args()
    publish(args.root, args.incoming, args.activate)
