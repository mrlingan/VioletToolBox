# Source and algorithm acknowledgements

The macOS port follows the GPL-3.0-or-later license of
[Smart-Paocai/VioletToolBox](https://github.com/Smart-Paocai/VioletToolBox).
OFP key tables, package layout handling and OPS/Super behavior were ported from
that project's `OppoOfpExtractor.cs`, `OnePlusOpsExtractor.cs` and
`OfpSegmentedSuperMerger.cs`. The upstream icon and attribution are preserved.

The OPS cipher algorithm was checked against B. Kerler's original
[opscrypto.py](https://github.com/bkerler/oppo_decrypt/blob/master/opscrypto.py).
That source identifies itself as “Oneplus Decrypter (c) V 1.4 B.Kerler
2019-2022” and is licensed under the MIT License. Independent synthetic test
vectors record the reference source's SHA-256 in `firmware_manifest.json`.
The Python CLI is not bundled with or executed by the application.

## MIT notice for the OPS reference algorithm

Copyright (c) 2019-2022 B. Kerler

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Format references and system libraries

- Payload ZSTD uses the decoder subset of
  [facebook/zstd 1.5.7](https://github.com/facebook/zstd/tree/f8745da6ff1ad1e7bab384bd1f9d742439278e99),
  under the upstream BSD-3-Clause option. Original license notices and source
  hashes are preserved in `Sources/CZstdDecoder`; the build recipe includes its
  license in the app. This newly added dependency has not been built or tested.

- The EDL development backend links the BSD-3-Clause
  [linux-msm/qdl](https://github.com/linux-msm/qdl/tree/d66c6efd72759be5dbb6c7199cd8bd1d9f2674ec)
  and a shared LGPL-2.1 [libusb](https://github.com/libusb/libusb/releases/tag/v1.0.29).
  The build recipe preserves their licenses and corresponding source archives
  in EDLLicenses / EDLSources. The helper is GPL-3.0-or-later. This stage has
  not been built or tested; see EDL_NATIVE.md for the exact scope and pins.

- Android Sparse follows the public AOSP
  [sparse format](https://android.googlesource.com/platform/system/core/+/refs/heads/main/libsparse/sparse_format.h).
- Payload follows the public AOSP
  [update metadata format](https://android.googlesource.com/platform/system/update_engine/+/refs/heads/main/update_metadata.proto).
- CommonCrypto, libz, libarchive, libbz2 and liblzma are dynamically linked
  system libraries supplied by macOS; their implementations are not vendored.
- Optional Google Platform Tools retain their original `NOTICE.txt` in the
  bundle. scrcpy is an independently installed program under its own license.
