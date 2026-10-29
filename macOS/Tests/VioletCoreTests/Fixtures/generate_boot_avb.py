"""Generate TEST_ONLY samples with official AOSP mkbootimg.py and avbtool.py.
Usage: python3 generate_boot_avb.py /path/to/cached/aosp-v4
The tools are not shipped in the application. Keys here are public test fixtures.
"""
import gzip, hashlib, json, pathlib, subprocess, sys, tempfile, zipfile
root = pathlib.Path(__file__).parent
reference = pathlib.Path(sys.argv[1]).resolve()
def run(*args):
    subprocess.run([str(a) for a in args], check=True, stdout=subprocess.DEVNULL)
def avb(*args):
    run(sys.executable, reference/'avbtool.py', *args)
with tempfile.TemporaryDirectory() as work:
    work = pathlib.Path(work)
    for name, size in [('kernel', 5217), ('ramdisk', 1031), ('second', 511), ('dtbo', 127), ('dtb', 37)]:
        (work/name).write_bytes((('TEST_ONLY_'+name+'|').encode()*size)[:size])
    for v in range(5):
        args = ['--header_version',v,'--kernel',work/'kernel','--ramdisk',work/'ramdisk','--cmdline','test_only=1 console=null','--output',root/f'TEST_ONLY_boot_v{v}.img']
        if v < 3: args += ['--pagesize',2048,'--second',work/'second']
        if v in (1,2): args += ['--recovery_dtbo',work/'dtbo']
        if v == 2: args += ['--dtb',work/'dtb']
        run(sys.executable,reference/'mkbootimg.py',*args)
    run(sys.executable,reference/'mkbootimg.py','--header_version',4,'--ramdisk',work/'ramdisk','--output',root/'TEST_ONLY_init_boot.img')
    archive = bytearray()
    for inode, (name, data, mode) in enumerate([('init',b'TEST_ONLY_STOCK_INIT\n',0o100750),('init.rc',b'# TEST ONLY\non early-init\n',0o100644),('TRAILER!!!',b'',0)],1):
        encoded = name.encode() + b'\0'
        fields = [inode,mode,0,0,1,0,len(data),0,0,0,0,len(encoded),0]
        archive += b'070701' + ''.join(f'{v:08x}' for v in fields).encode() + encoded
        archive += b'\0' * (-len(archive) % 4)
        archive += data; archive += b'\0' * (-len(archive) % 4)
    (work/'stock.cpio.gz').write_bytes(gzip.compress(bytes(archive),mtime=0))
    run(sys.executable,reference/'mkbootimg.py','--header_version',4,'--kernel',work/'kernel','--ramdisk',work/'stock.cpio.gz','--output',root/'TEST_ONLY_patch_boot.img')
    for bits, alg in [(2048,'SHA256_RSA2048'),(4096,'SHA512_RSA4096')]:
        key = root/f'TEST_ONLY_RSA{bits}.pem'
        run('openssl','genrsa','-out',key,bits)
        image = root/f'TEST_ONLY_avb_{bits}.img'
        image.write_bytes((work/'kernel').read_bytes())
        avb('add_hash_footer','--image',image,'--partition_name','boot','--partition_size',131072,'--algorithm',alg,'--key',key,'--salt','0102030405060708090a0b0c0d0e0f10','--rollback_index',42)
    run('openssl','pkcs8','-topk8','-nocrypt','-in',root/'TEST_ONLY_RSA2048.pem','-out',root/'TEST_ONLY_RSA2048_PKCS8.pem')
    avb('make_vbmeta_image','--output',root/'TEST_ONLY_vbmeta.img','--algorithm','SHA256_RSA2048','--key',root/'TEST_ONLY_RSA2048.pem','--include_descriptors_from_image',root/'TEST_ONLY_avb_2048.img')
    avb('make_vbmeta_image','--output',root/'TEST_ONLY_vbmeta_unsigned.img')
    for name, content in [('module_one.zip',b'id=test.one\nname=Test One\nversion=1.0\nauthor=Fixture\n'),('module_two.zip',b'id=test.two\r\nname=Test Two\r\nversion=2\r\n'),('module_bad.zip',b'id=../../bad\n')]:
        with zipfile.ZipFile(root/('TEST_ONLY_'+name),'w',zipfile.ZIP_DEFLATED) as z:
            z.writestr('module.prop',content)
            z.writestr('customize.sh','#!/system/bin/sh\n# TEST ONLY, never execute\n')
    with zipfile.ZipFile(root/'TEST_ONLY_module_duplicate.zip','w') as z:
        z.writestr('module.prop','id=test.one\n'); z.writestr('module.prop','id=test.two\n')
manifest = {
    'notice':'All keys and images are TEST ONLY; do not flash or use these keys for production.',
    'sources':['https://android.googlesource.com/platform/external/avb/+/refs/heads/main/avbtool.py','https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/main/mkbootimg.py'],
    'reference_sha256':{name:hashlib.sha256((reference/name).read_bytes()).hexdigest() for name in ['avbtool.py','mkbootimg.py']},
    'sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.glob('TEST_ONLY_*')) if p.suffix in ['.img','.pem','.zip']}
}
(root/'boot_avb_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Generated official AOSP fixtures')
