#!/usr/bin/env python3
"""Build pinned macOS qdl + VioletEDL and a bundled shared libusb.

Source preparation only has been implemented in the current porting stage.
This script is deliberately not invoked while the user has paused builds/tests.
Requires Xcode/CLT, make, Git, Python and access to the pinned public sources.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
QDL_COMMIT = 'd66c6efd72759be5dbb6c7199cd8bd1d9f2674ec'
USB_URL = 'https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2'
USB_SHA256 = '5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85'


def run(args, cwd=None, env=None):
    subprocess.run([str(value) for value in args], cwd=cwd, env=env, check=True)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def prepare_sources(cache):
    qdl = cache / 'qdl'
    if not qdl.exists():
        run(['git', 'init', qdl])
        run(['git', 'remote', 'add', 'origin', 'https://github.com/linux-msm/qdl.git'], qdl)
        run(['git', 'fetch', '--depth', '1', 'origin', QDL_COMMIT], qdl)
        run(['git', 'checkout', '--detach', 'FETCH_HEAD'], qdl)
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=qdl, text=True).strip() != QDL_COMMIT:
        raise RuntimeError('Cached qdl commit differs from the source lock')
    run(['git', 'diff', '--exit-code', 'HEAD', '--'], qdl)
    archive = cache / 'libusb-1.0.29.tar.bz2'
    if not archive.exists():
        partial = archive.with_suffix('.part')
        urllib.request.urlretrieve(USB_URL, partial)
        if digest(partial) != USB_SHA256:
            raise RuntimeError('libusb source SHA-256 mismatch')
        partial.rename(archive)
    if digest(archive) != USB_SHA256:
        raise RuntimeError('libusb source SHA-256 mismatch')
    usb = cache / 'libusb-1.0.29'
    if not usb.exists():
        staging = Path(tempfile.mkdtemp(prefix='edl-source-', dir=cache))
        try:
            with tarfile.open(archive) as source:
                for member in source.getmembers():
                    path = PurePosixPath(member.name)
                    if path.is_absolute() or '..' in path.parts or path.parts[0] != 'libusb-1.0.29' or not (member.isfile() or member.isdir()):
                        raise RuntimeError('Unexpected member in pinned libusb archive')
                source.extractall(staging)
            (staging / 'libusb-1.0.29').rename(usb)
        finally:
            shutil.rmtree(staging)
    return qdl, usb, archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default=platform.machine())
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise RuntimeError('This build recipe targets macOS')
    cache = PROJECT / '.cache/native-tools'; cache.mkdir(parents=True, exist_ok=True)
    qdl, usb, archive = prepare_sources(cache)
    work = cache / 'edl-build' / args.arch; work.mkdir(parents=True, exist_ok=True)
    # Preserve the pristine pinned checkout. Apply our status-propagation patch
    # only in a dedicated derived tree, and ship that exact source plus patch.
    derived = work / 'qdl-source'
    if derived.exists():
        shutil.rmtree(derived)
    derived.mkdir()
    source_tar = work / 'qdl-source.tar'
    with source_tar.open('wb') as target:
        subprocess.run(['git', 'archive', '--format=tar', QDL_COMMIT], cwd=qdl, stdout=target, check=True)
    with tarfile.open(source_tar) as source:
        source.extractall(derived)
    patches = [PROJECT / 'NativeTools/patches' / name for name in ['qdl-bootable-status.patch', 'qdl-unsigned-sector-count.patch']]
    for patch in patches:
        run(['/usr/bin/patch', '-f', '-p1', '-i', patch], derived)
    qdl = derived
    prefix = work / 'prefix'
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
    flags = ['-O2', '-arch', args.arch, '-mmacosx-version-min=13.0', '-isysroot', sdk]
    env = dict(os.environ)
    env['CC'] = clang
    env['CFLAGS'] = shlex.join(flags)
    env['LDFLAGS'] = shlex.join(flags)
    env['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    usb_build = work / 'libusb'; usb_build.mkdir(exist_ok=True)
    host = 'aarch64-apple-darwin' if args.arch == 'arm64' else 'x86_64-apple-darwin'
    run([usb / 'configure', '--host=' + host, '--prefix=' + str(prefix), '--enable-shared', '--disable-static', '--disable-tests-build', '--disable-examples-build'], usb_build, env)
    run(['make', '-j', str(os.cpu_count() or 4)], usb_build, env)
    run(['make', 'install'], usb_build, env)
    output = PROJECT / '.cache/packaged-edl' / args.arch
    tools = output / 'edl-tools'; tools.mkdir(parents=True, exist_ok=True)
    licenses = output / 'EDLLicenses'; licenses.mkdir(exist_ok=True)
    sources = output / 'EDLSources'; sources.mkdir(exist_ok=True)
    dylib = prefix / 'lib/libusb-1.0.0.dylib'
    shutil.copy2(dylib.resolve(), tools / dylib.name)
    run(['install_name_tool', '-id', '@loader_path/' + dylib.name, tools / dylib.name])
    (work / 'version.h').write_text('#define VERSION "violet-' + QDL_COMMIT[:12] + '"\n')
    names = ['sahara', 'util', 'ux', 'oscompat', 'file', 'file_nozip', 'auto', 'cli', 'qud', 'firehose', 'input_type', 'io', 'patch', 'program', 'programmer', 'read', 'sahara_config', 'sha2', 'sim', 'ufs', 'usb', 'vip', 'sparse', 'gpt', 'flashmap', 'json', 'contents', 'pathbuf']
    includes = ['-I' + str(qdl / 'include'), '-I' + str(qdl / 'src'), '-I' + str(work), '-I' + sdk + '/usr/include/libxml2', '-I' + str(prefix / 'include/libusb-1.0')]
    objects = []
    for name in names:
        target = work / (name + '.o')
        run([clang, *flags, '-std=gnu11', '-D_FILE_OFFSET_BITS=64', *includes, '-c', qdl / 'src' / (name + '.c'), '-o', target])
        objects.append(target)
    link = ['-L' + str(prefix / 'lib'), '-lusb-1.0', '-lxml2', '-lz', '-liconv', '-framework', 'IOKit', '-framework', 'CoreFoundation', '-framework', 'Security', '-lobjc', '-Wl,-headerpad_max_install_names']
    for name, entry in [('qdl', qdl / 'src/qdl.c'), ('violet-edl', PROJECT / 'NativeTools/VioletEDL.c')]:
        binary = tools / name
        run([clang, *flags, '-std=gnu11', '-D_FILE_OFFSET_BITS=64', *includes, entry, *objects, *link, '-o', binary])
        run(['install_name_tool', '-change', str(dylib), '@executable_path/' + dylib.name, binary])
        run(['codesign', '--force', '--sign', '-', binary])
    run(['codesign', '--force', '--sign', '-', tools / dylib.name])
    shutil.copy2(qdl / 'LICENSE', licenses / 'qdl-BSD-3-Clause.txt')
    shutil.copy2(usb / 'COPYING', licenses / 'libusb-LGPL-2.1.txt')
    shutil.copy2(PROJECT.parent / 'LICENSE', licenses / 'VioletEDL-GPL-3.0.txt')
    shutil.copy2(archive, sources / archive.name)
    shutil.copy2(PROJECT / 'NativeTools/VioletEDL.c', sources / 'VioletEDL.c')
    shutil.copy2(Path(__file__), sources / 'build-edl-tools.py')
    for patch in patches:
        shutil.copy2(patch, sources / patch.name)
    with tarfile.open(sources / 'qdl-source.tar.gz', 'w:gz') as target:
        target.add(qdl, arcname='qdl')
    manifest = {'qdl': {'repository': 'https://github.com/linux-msm/qdl', 'commit': QDL_COMMIT, 'patches': [{'name': patch.name, 'sha256': digest(patch)} for patch in patches]}, 'libusb': {'url': USB_URL, 'sha256': USB_SHA256}, 'architecture': args.arch, 'deployment_target': '13.0', 'zip_container': False, 'libxml2': 'Apple SDK / system dylib', 'sha256': {str(file.relative_to(output)): digest(file) for folder in [tools, licenses, sources] for file in folder.rglob('*') if file.is_file()}}
    (output / 'EDL_NATIVE_TOOLS.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
