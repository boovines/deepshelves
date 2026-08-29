# LM-043 runtime evidence deferred to H9

LM-043 remains technically blocked. Its source/cache/detail implementation is ready for
downstream safe work, but the original acceptance explicitly requires real production
software-HEIC decode and application recovery behavior that is prohibited on this laptop.

On the isolated validation Mac, run the exact committed revision under the encoder-service
tripwire and deny-all network policy:

1. Decode the canonical exact-source corpus through the production detail repository and
   verify random-frame p95 below 150 ms and p99 below 300 ms, including cold and cached paths.
2. Rapidly select nonadjacent results while decode is delayed; confirm the canvas never shows
   a frame, epoch, window, locator, or pixels other than the latest requested identity.
3. After a cached success, separately tamper the media bytes, media hash/size projection,
   manifest bytes/hash, manifest epoch/window, entry path/hash/size, and current suppression
   state. Every case must replace the canvas with its honest recovery UI and never return
   cached pixels.
4. Exercise fit/zoom/pan/reset, previous/next boundary stepping, keyboard and VoiceOver
   output, retry, and explicit export. Confirm export contains the exact revalidated original
   HEIC, cancellation writes nothing, and failure never mutates the archive.
5. Preserve latency samples, content-free interaction/accessibility transcript, screenshots,
   exact revision, host declaration, and tripwire output in the H9 ledger.

Unit, model, static, compile-only, and deterministic snapshot evidence in this directory is
supporting implementation evidence only. It does not satisfy these runtime checks.
