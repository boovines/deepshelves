# LM-028 HEIC soak and fault report

Status: **safe suite passed; real production soak technically blocked**

## Safety outcome

No hardware HEVC test, VideoToolbox encoder test, application launch, or Apple ImageIO
runtime test is part of the canonical gate. During an exploratory metadata-only `sips`
probe of a pinned HEIC fixture, `VTEncoderXPCService` appeared unexpectedly. The process
tripwire detected it and the service was terminated immediately. No panic was observed,
no Xcode/test process remained, and Apple ImageIO was not executed again.

The accidental reachability found by that probe is fixed fail-closed:

- `HEICKeyframeWriter` has no default encoder.
- Every media writer caller must inject an encoder explicitly.
- The legacy live capture harness defaults to `QuarantinedHEICFrameEncoder`.
- The legacy ImageIO decode benchmark throws `runtimeQuarantined` before opening a file.

An attempted five-second headless ScreenCaptureKit smoke on 2026-08-29 also left a
`VTEncoderXPCService` process after the harness had exited, despite the software-only HEIC
writer and absence of direct VideoToolbox/ImageIO linkage. The service was terminated, the
runnable experiment was removed, and no repeat was attempted. Live ScreenCaptureKit runtime
is therefore quarantined alongside app/XCUITest runtime on this Mac. This does not change the
software HEIC codec contract or any privacy/publication/deletion invariant; it only proves
that the complete live source cannot supply the required soak evidence here.

## Safe test suite

- 62 focused Release unit tests and 5 fake-media integration tests passed.
- Focus/filter/resize/URL races reject stale epochs and retain a four-frame queue bound.
- All 40 denied/uncertain privacy corpus cases project zero canonical/derived artifacts.
- Resolver, lifecycle, archive transaction, manifest/asset integrity, startup recovery, and
  fake HEIC publication tests passed.
- Contract fixtures, privacy smoke, dependency closure, strict Swift format, and universal
  Release compile passed.
- Hardware encoder tests: 0. App launches: 0. Apple ImageIO runtime tests: 0.

## Decode-only HEIC corpus

The three unmodified, hash-pinned libheif fixtures are licensed and attributed in
`Fixtures/LM028/README.md`. FFmpeg 8.0 decoded each primary HEVC image 30 times using the
software `hevc` decoder, `-hwaccel none`, and one thread. Pixel hashes were deterministic.

| Fixture | Bytes | Dimensions | p50 | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| high-entropy example | 718,114 | 1280×854 | 82.935 ms | 85.664 ms | 95.127 ms |
| UI alpha | 8,284 | 512×512 | 54.129 ms | 57.309 ms | 57.395 ms |
| UI rainbow | 7,080 | 452×462 coded | 53.333 ms | 57.413 ms | 61.216 ms |

Peak child RSS was 32,473,088 bytes, below the 750 MB application budget. The weighted
corpus (10% high-entropy, 90% UI) projects to 197,487 bytes per accepted 1920×1080 frame.
This validates software exact-frame decoding and a conservative mixed-content storage
model; it does not validate the quarantined application codec.

## Eight-hour office model

The deterministic model advances exactly 28,800 seconds at two incoming frames per second,
with a retained change/heartbeat every ten seconds, focus transition every five minutes,
recovery fault every 47 minutes, and excluded interval every 13 minutes.

| Metric | Result | Gate |
|---|---:|---:|
| Candidates | 57,600 | exact |
| Persisted frames | 3,108 | measured model |
| Stale rejections | 95 | >0 |
| Excluded rejections | 36 | >0 |
| Recoveries | 10 | >0 |
| Backpressure drops | 176 | bounded/newest retained |
| Queue peak/final | 4 / 0 | ≤4 / 0 |
| Prohibited sentinel persisted | 0 | 0 |
| Corrupt/orphan publication | 0 / 0 | 0 / 0 |
| Projected 30-day bytes | 18,413,687,880 | <20,000,000,000 |

## Accelerated fault model

The 72-hour model advances 259,200 seconds and processes 518,400 candidates, including
2,879 stale rejections, 617 exclusions, 392 recoveries, and 5,348 bounded backpressure
drops. It persists 33,325 frames, peaks at four queued frames, finishes with zero queued
frames, and reports zero prohibited sentinel, corrupt publication, or orphan publication.
Its deliberately elevated transition/fault rate is a stress profile, not the normal-office
retention projection.

## Remaining gate

The acceptance criterion says “eight-hour office soak,” meaning a real wall-clock
production capture/resource run. That run was not executed and is not represented as
synthetic evidence. It remains blocked until either:

1. an in-process software HEIC codec boundary is implemented and proven never to start
   `VTEncoderXPCService`, or
2. a later ADR authorizes an isolated expendable validation host after an OS/firmware
   change.

Foreground-window isolation, local-only operation, identity, atomic publication, integrity,
search evidence, retention, and forensic deletion remain satisfiable and unchanged.
