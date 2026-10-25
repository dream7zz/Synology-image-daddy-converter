# Changelog

All notable changes are recorded here, and every release is published at
<https://github.com/dream7zz/Synology-image-daddy-converter/releases>.

## [0.3.0] — 2026-10-25

### Changed
- Thumbnail loading now uses a real async network path (`URLSession.data(for:)`)
  instead of blocking a cooperative-pool thread on a semaphore. Concurrency is
  bounded by an `AsyncGate` actor, and disk reads/writes run off the pool. This
  removes the thread-pool starvation that showed up as ~18 blocked threads while
  scrolling the grid.
- Batch runs (`Engine.run`) execute on a dedicated queue rather than inline in a
  `Task`, so a long scan no longer occupies a cooperative thread for its whole
  duration. `Engine` internals stay synchronous; only the launch site moved.

### Fixed
- `EngineOptions.autoUpload` defaulted to `true`, contradicting its own
  documentation and the test that guards it. The app sets it explicitly for its
  upload action, but a bare `siactl run` would have written to the NAS without
  `--upload`. Default is now `false`.

## [0.2.1] — 2026-10-25

### Fixed
- **Crash when browsing thumbnails** (`EXC_BAD_ACCESS` in
  `_NativeDictionary._copyOrMoveAndResize`). Concurrent thumbnail loads on the
  cooperative thread pool mutated the in-memory cache dictionary without
  synchronization, so a resize could free storage another thread was reading.
  All cache access now goes through a single locked mutator.
- Thumbnail memory cache is now bounded to 400 entries; previously every image
  ever displayed stayed resident, which could grow to gigabytes during long
  browsing sessions.

### Added
- `siarace`: a ThreadSanitizer harness for the thumbnail cache. The unguarded
  variant reports `Swift access race`; the fixed implementation completes
  38,400 concurrent calls with no report.

## [0.2.0] — 2026-10-20

### Added
- Multi-account support with per-account caches and ledgers.
- Per-stage progress (download / extract / upload) and per-item failure reasons.
- Folder-scoped scanning: ticked folders define the grid, counts and queue.
- "Invalid data" category for 0-byte and truncated files, excluded from the queue.
- Three decode paths: AVFoundation resource loader, tail-index reassembly, and
  prefix decoding for stream-oriented containers.
