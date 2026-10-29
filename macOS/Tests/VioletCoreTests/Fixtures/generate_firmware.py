"""Generate synthetic, unflashable fixtures using independent reference code.

Usage: python3 generate_firmware.py path/to/bkerler/opscrypto.py
No downloads, third-party Python packages, or production decryption code are used.
The OPS reference's pure arithmetic functions are selected with ast, so its CLI,
docopt dependency, filesystem helpers and main function are never executed.
"""
import ast
import base64
import hashlib
import json
import pathlib
import re
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
REPO = ROOT.parents[3]
reference = pathlib.Path(sys.argv[1]).read_text()
tree = ast.parse(reference)
wanted = {"key", "mbox4", "mbox5", "mbox6", "sbox"}
nodes = [node for node in tree.body if
         (isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in wanted for t in node.targets)) or
         (isinstance(node, ast.FunctionDef) and node.name in {"gsbox", "key_update", "key_custom"})]
namespace = {"unpack": struct.unpack}
exec(compile(ast.Module(body=nodes, type_ignores=[]), "opscrypto-reference", "exec"), namespace)
manifest = {"reference": "https://github.com/bkerler/oppo_decrypt/blob/master/opscrypto.py",
            "referenceSHA256": hashlib.sha256(reference.encode()).hexdigest(), "packages": {}, "vectors": []}


def ops_encrypt(data, version):
    namespace["mbox"] = namespace[f"mbox{version}"]
    return bytes(namespace["key_custom"](data, namespace["key"], encrypt=True))[:len(data)]


def pattern(length):
    return bytes((i * 37 + 11) & 255 for i in range(length))


def align(data, block=512):
    return data + bytes((-len(data)) % block)


def record(name, data, files):
    (ROOT / name).write_bytes(data)
    manifest["packages"][name] = {key: {"size": len(value), "sha256": hashlib.sha256(value).hexdigest()} for key, value in files.items()}


def make_ops(version, bad=None):
    image = bytearray(bytes(512))
    length = 1024 * 1024 + 17 if version == 5 and bad is None else 4097
    files = [("images/boot.img", b"B" * 4096, "Program0"), ("prog_firehose.bin", pattern(length), "SAHARA"),
             ("tiny.bin", pattern(7), "SAHARA"), ("rawprogram0.xml", b"<data>TEST ONLY</data>", "UFS_PROVISION")]
    sections = {}
    expected = {}
    for index, (name, plain, section) in enumerate(files):
        if bad == "traversal" and index == 0:
            name = "../escape.img"
        if bad == "duplicate" and index == 1:
            name = "images/boot.img"
        offset = len(image) // 512
        encoded = ops_encrypt(plain, version) if section == "SAHARA" else plain
        image.extend(align(encoded))
        if bad == "range" and index == 0:
            offset = 0x7FFFFFFF
        sections.setdefault(section, []).append(f'<File Path="{name}" FileOffsetInSrc="{offset}" SizeInByteInSrc="{len(plain)}"/>')
        expected[name] = plain
    xml = '<?xml version="1.0" encoding="UTF-8"?><settings>' + ''.join(f'<{key}>' + ''.join(value) + f'</{key}>' for key, value in sections.items()) + '</settings>'
    if bad == "entity":
        xml = xml.replace('<settings>', '<!DOCTYPE settings [<!ENTITY boom SYSTEM "file:///etc/hosts">]><settings>')
    plain_xml = xml.encode()
    padded = plain_xml + bytes(512 - len(plain_xml) % 512)
    image.extend(ops_encrypt(padded, version))
    footer = bytearray(512)
    struct.pack_into('<I', footer, 0x18, len(plain_xml))
    image.extend(footer)
    if bad:
        (ROOT / f'TEST_BAD_{bad}.ops').write_bytes(image)
    else:
        expected['settings.xml'] = plain_xml
        record(f'TEST_ONLY_MBOX{version}.ops', image, expected)


for version in [4, 5, 6]:
    make_ops(version)
    for length in [7, 16, 17, 32, 4096]:
        manifest['vectors'].append({'version': version, 'length': length, 'ciphertext': base64.b64encode(ops_encrypt(pattern(length), version)).decode()})
for bad in ['traversal', 'duplicate', 'range', 'entity']:
    make_ops(5, bad)

key_source = (REPO / 'VioletToolBox/OppoOfpExtractor.cs').read_text()


def tables(name):
    body = key_source.split('string[][] ' + name + ' =', 1)[1].split('\n    ];', 1)[0]
    return [re.findall(r'"([a-fA-F0-9]+)"', row) for row in re.findall(r'\[([^\[\]]+)\]', body)]


def derive(table):
    if len(table) == 2:
        return table[0].encode(), table[1].encode()
    mask = bytes.fromhex(table[0])
    def one(value):
        mixed = bytes(v ^ mask[i % len(mask)] for i, v in enumerate(bytes.fromhex(value)))
        shuffled = bytes(((v << 4) | (v >> 4)) & 255 for v in mixed)
        return hashlib.md5(shuffled).hexdigest()[:16].encode()
    return one(table[1]), one(table[2])


def aes(data, key, iv):
    return subprocess.run(['/usr/bin/openssl', 'enc', '-aes-128-cfb', '-K', key.hex(), '-iv', iv.hex(), '-nopad'],
                          input=data, check=True, capture_output=True).stdout


def encode_shuffle(data):
    key = b'geyixue'
    return bytes((((v ^ key[i % 7]) << 4) | ((v ^ key[i % 7]) >> 4)) & 255 for i, v in enumerate(data))


for key_index in [0, 8]:
    key, iv = derive(tables('MtkKeyTables')[key_index])
    image = bytearray(align(aes(b'MMM TEST ONLY!!!\0', key, iv)))
    table = bytearray()
    expected = {}
    for name, plain, encrypted in [('images/boot.img', pattern(5000), 37), ('config.xml', b'<data>TEST ONLY MTK</data>', 0)]:
        entry = bytearray(96)
        struct.pack_into('<QQQ', entry, 32, len(image), len(plain), encrypted)
        entry[56:56 + len(name)] = name.encode()
        table.extend(entry)
        image.extend(align(aes(plain[:encrypted], key, iv) + plain[encrypted:]))
        expected[name] = plain
    footer = bytearray(108)
    struct.pack_into('<H', footer, 72, 2)
    image.extend(encode_shuffle(table)); image.extend(encode_shuffle(footer))
    record(f'TEST_ONLY_MTK{key_index}.ofp', image, expected)

for page, key_index in [(512, 0), (4096, 5)]:
    key, iv = derive(tables('QcKeyTables')[key_index])
    image = bytearray(page)
    expected = {}
    sections = {}
    for name, plain, category in [('boot.img', pattern(4097), 'Program'), ('config.xml', b'<data>TEST ONLY QC</data>', 'Config'),
                                   ('prog_firehose.bin', pattern(513), 'Sahara'), ('firmware.bin', pattern(128), 'Firmware')]:
        offset = len(image) // page
        raw_length = len(plain)
        read_size = raw_length if category in ['Config', 'Firmware'] else len(align(plain, page))
        plain = plain + bytes(read_size - raw_length)
        crypt_length = 0 if category == 'Firmware' else (raw_length if category == 'Sahara' else min(0x40000, raw_length))
        encoded = aes(plain[:crypt_length], key, iv) + plain[crypt_length:]
        image.extend(align(encoded, page))
        sections[category] = f'<File Path="{name}" FileOffsetInSrc="{offset}" SizeInByteInSrc="{raw_length}" SizeInSectorInSrc="{len(align(plain, page)) // page}"/>'
        expected[name] = plain
    xml = ('<?xml version="1.0" encoding="UTF-8"?><firmware>' + ''.join(f'<{k}>' + v + f'</{k}>' for k, v in sections.items()) + '</firmware>').encode()
    xml_offset = len(image) // page
    image.extend(align(aes(xml, key, iv), page))
    footer = bytearray(page)
    struct.pack_into('<III', footer, 16, 0x7cef, xml_offset, len(xml))
    image.extend(footer)
    expected['ProFile.xml'] = xml
    record(f'TEST_ONLY_QC{page}.ofp', image, expected)

(ROOT / 'firmware_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Generated synthetic fixtures:', len(manifest['packages']), 'packages and', len(manifest['vectors']), 'OPS reference vectors.')
