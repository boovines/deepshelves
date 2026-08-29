# LM-041 runtime evidence deferred to H9

LM-041 remains technically blocked. ADR 0006 permits its implementation to feed later safe
work, but does not waive the original 10,000-card S6 performance, selection, accessibility,
or stale-thumbnail runtime acceptance.

The isolated validation Mac must run the exact committed revision and production result-grid
implementation in both the main Search section and global panel:

1. Load the deterministic 10,000-card S6 archive through the production paging/grid path;
   record frame pacing, input latency, resident memory, visible-item count, reuse behavior,
   and every threshold required by S6.
2. Resize through the one-, two-, and three-column breakpoints; scroll repeatedly to the end,
   verify stable ordering/no duplicates, and exercise pagination success, cancellation, and
   retry without losing the settled page.
3. Rapidly alternate selections and locators while thumbnails are delayed; confirm that no
   card ever displays pixels from a different frame or locator and that corrupt/tampered
   thumbnail identity fails closed.
4. Use keyboard navigation and VoiceOver in both surfaces; verify selection, Return
   activation, stable card labels/positions, loading/no-result/indexing/error states, and the
   actual result-count/load-more announcements.
5. Preserve the S6 report, content-free accessibility transcript, screenshots, exact
   revision, host declaration, and encoder-service tripwire output in the H9 ledger.

Unit, model, static, compile-only, and deterministic snapshot evidence in this directory is
supporting implementation evidence only. The 10,000-card model check deliberately contains no
timing claim and is not a substitute for any runtime S6 or accessibility check.
