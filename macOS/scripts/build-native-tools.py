#!/usr/bin/env python3
"""Build pinned GPL host tools into .cache/packaged-tools/<arch>.

Does not change the system Rust installation or Android devices. Requires Xcode,
Git, and network access for public sources / Rust packages on the first run.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import urllib.request

PROJECT = pathlib.Path(__file__).resolve().parents[1]
REPO = PROJECT.parent
CACHE = PROJECT / '.cache/native-tools'
LOCK = {
    'Magisk': ('topjohnwu/Magisk', '0972f67d97f9b6302b67c5171283330c74114b4a'),
    'KernelPatch': ('bmax121/KernelPatch', '406c85ce79a5e1c19b53be34c04baadc1ec68bc5'),
    'KernelSU': ('tiann/KernelSU', '75e179d378d7aaa0de8946358a3384444c3e36b0'),
}
RUST_TOOLCHAIN = 'nightly-2026-10-27'
INIT_URL = 'https://github.com/tiann/KernelSU/releases/download/v3.3.1/ksuinit-aarch64'
INIT_SHA256 = '365c66e5435a9ecdb3dbb23ceda2d9253568defeee3682af95220087094eff5d'


def run(args, cwd=None, env=None):
    subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True)


def source(name):
    repo, commit = LOCK[name]
    directory = CACHE / name
    if not directory.exists():
        run(['git', 'init', directory])
        run(['git', 'remote', 'add', 'origin', 'https://github.com/' + repo + '.git'], directory)
        run(['git', 'fetch', '--depth', '1', 'origin', commit], directory)
        run(['git', 'checkout', '--detach', 'FETCH_HEAD'], directory)
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=directory, text=True).strip()
    if actual != commit:
        raise RuntimeError(f'{name}: cached commit differs from lock; preserve it and use a separate cache')
    return directory


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        for data in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(data)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default=platform.machine())
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    output = PROJECT / '.cache/packaged-tools' / args.arch
    tools = output / 'native-tools'; tools.mkdir(parents=True, exist_ok=True)
    payloads = output / 'RootPayloads'; payloads.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env['RUSTUP_HOME'] = str(CACHE / 'rustup')
    env['CARGO_HOME'] = str(CACHE / 'cargo')
    env['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    env['LIBCLANG_PATH'] = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib'
    rustup = CACHE / 'cargo/bin/rustup'
    if not rustup.exists():
        host = 'aarch64-apple-darwin' if platform.machine() == 'arm64' else 'x86_64-apple-darwin'
        installer = CACHE / 'rustup-init'
        url = f'https://static.rust-lang.org/rustup/archive/1.29.2/{host}/rustup-init'
        urllib.request.urlretrieve(url, installer)
        expected = urllib.request.urlopen(url + '.sha256', timeout=30).read().decode().split()[0]
        if sha256(installer) != expected:
            raise RuntimeError('rustup installer SHA-256 mismatch')
        installer.chmod(0o755)
        run([installer, '-y', '--no-modify-path', '--profile', 'minimal', '--default-toolchain', 'none'], env=env)
    target = 'aarch64-apple-darwin' if args.arch == 'arm64' else 'x86_64-apple-darwin'
    run([rustup, 'toolchain', 'install', RUST_TOOLCHAIN, '--profile', 'minimal', '--component', 'rust-src', '--target', target], env=env)
    cargo = CACHE / 'cargo/bin/cargo'

    magisk = source('Magisk')
    run(['git', 'submodule', 'update', '--init', '--depth', '1', 'native/src/external/cxx-rs', 'native/src/external/lz4'], magisk)
    generated = magisk / 'native/out/generated'; generated.mkdir(parents=True, exist_ok=True)
    (generated / 'flags.h').write_text('#pragma once\n#define MAGISK_VERSION "31.1"\n#define MAGISK_VER_CODE 31100\n#define MAGISK_DEBUG 0\n')
    env['CARGO_TARGET_DIR'] = str(CACHE / 'build/Magisk' / args.arch)
    run([cargo, '+' + RUST_TOOLCHAIN, 'build', '-p', 'magiskboot', '--release', '--target', target], magisk / 'native/src', env)
    shutil.copy2(pathlib.Path(env['CARGO_TARGET_DIR']) / target / 'release/magiskboot', tools / 'magiskboot')

    kernelpatch = source('KernelPatch')
    work = kernelpatch / 'tools'
    shutil.copy2(kernelpatch / 'kernel/include/preset.h', work / 'preset.h')
    files = [work / (name + '.c') for name in ['image', 'kallsym', 'kptools', 'order', 'insn', 'patch', 'symbol', 'kpm', 'common', 'bootimg', 'x86_64']]
    files += sorted((work / 'lib').rglob('*.c'))
    run(['xcrun', 'clang', '-O2', '-arch', args.arch, '-mmacosx-version-min=13.0', '-std=c11', '-Wno-unused',
         '-I' + str(work), '-I' + str(work / 'lib'), '-DBZ_NO_STDIO', '-DXZ_DEC_ANY_CHECK',
         *files, '-lz', '-o', tools / 'kptools'])

    kernelsu = source('KernelSU')
    env['CARGO_TARGET_DIR'] = str(CACHE / 'build/KernelSU' / args.arch)
    run([cargo, '+' + RUST_TOOLCHAIN, 'build', '-p', 'ksud', '--release', '--target', target], kernelsu / 'userspace', env)
    shutil.copy2(pathlib.Path(env['CARGO_TARGET_DIR']) / target / 'release/ksud', tools / 'ksud')
    init = CACHE / 'ksuinit-aarch64'
    if not init.exists():
        urllib.request.urlretrieve(INIT_URL, init)
    if sha256(init) != INIT_SHA256:
        raise RuntimeError('ksuinit SHA-256 mismatch')
    shutil.copy2(init, payloads / init.name)
    for name in ['akpimg', 'fkpimg']:
        directory = payloads / 'KernelPatch'; directory.mkdir(exist_ok=True)
        shutil.copy2(REPO / 'VioletToolBox/KernelPatch' / name, directory / name)
    for module in (REPO / 'VioletToolBox/LKM_Patch').rglob('*.ko'):
        relative = module.relative_to(REPO / 'VioletToolBox')
        destination = payloads / relative; destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(module, destination)
    for binary in tools.iterdir():
        binary.chmod(0o755)
        run(['codesign', '--force', '--sign', '-', binary])
    licenses = output / 'NativeToolLicenses'; licenses.mkdir(exist_ok=True)
    for name in LOCK:
        shutil.copy2(CACHE / name / 'LICENSE', licenses / (name + '-LICENSE'))
    manifest = {'sources': {name: {'repository': 'https://github.com/' + repo, 'commit': commit} for name, (repo, commit) in LOCK.items()},
                'rust': RUST_TOOLCHAIN, 'deployment_target': '13.0', 'architecture': args.arch,
                'ksuinit_url': INIT_URL, 'ksuinit_sha256': INIT_SHA256,
                'sha256': {str(file.relative_to(output)): sha256(file) for file in sorted(output.rglob('*')) if file.is_file() and file.name != 'NATIVE_TOOLS.json'}}
    (output / 'NATIVE_TOOLS.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Built native tools:', output)


if __name__ == '__main__':
    main()
