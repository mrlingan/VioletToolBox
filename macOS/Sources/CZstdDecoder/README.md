# Pinned Zstandard decoder

The unchanged decoder subset under `vendor/` comes from facebook/zstd 1.5.7,
commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99` (the peeled v1.5.7 tag).
`UPSTREAM.json` records the source archive SHA-256 and each copied file's hash.
The source archive is `https://codeload.github.com/facebook/zstd/tar.gz/f8745da6ff1ad1e7bab384bd1f9d742439278e99`.

The upstream dual license is retained; this application selects BSD-3-Clause.
See `vendor/LICENSE` and the preserved alternative `vendor/COPYING`.

SwiftPM compiles the common/decompression C units. Thread-pool units, legacy
decoders and architecture-specific assembly are disabled or excluded. There is
no compressor, executable, Homebrew dependency or system-private ZSTD binding.
`VioletZstd.c` bounds input/output/window size and rejects external dictionaries.

This target was added while the user had paused compilation and tests. Neither
architecture has been built or run with this target yet. Downloading and copying
the pinned source is dependency preparation, not a successful decoder test.
