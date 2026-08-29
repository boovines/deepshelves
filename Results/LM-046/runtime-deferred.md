# LM-046 runtime evidence deferred to H9

LM-046 remains technically blocked. Its date model, persisted state, timeline projection,
transition presentation, selected context, and fail-closed Revisit plan are implementation-ready,
but the original acceptance still requires application and NSWorkspace action runtime evidence.

On the physically distinct isolated validation Mac, run the exact committed revision under the
encoder-service tripwire and deny-all network policy:

1. Open Timeline with no saved date and prove it selects today. Navigate with the date picker,
   buttons, Command-left/right, close the app, and reopen; prove the exact local day restores.
2. Repeat across the 2026 spring-forward and fall-back boundaries under at least English and
   French locales. Prove 23/25-hour filmstrips, repeated/missing-hour timezone labels, correct day
   transitions, and no off-by-one restoration.
3. Exercise all four zooms, Option-left/right application-transition movement, detailed labels,
   summarized labels, gap text/patterns, selection, and selected-result context with pointer,
   keyboard, and VoiceOver. Preserve content-free transcripts and screenshots.
4. For app-only and browser moments, invoke Revisit and prove the current approved application is
   opened, only the approved HTTP(S) origin/path is supplied, and query, fragment, credentials,
   form values, scroll position, tab identity, or captured UI state are never supplied.
5. After selection but before Revisit, separately suppress/delete the frame, remove the app or
   host from current approved scope, substitute a private context, and alter the URL scheme. Every
   case must fail closed without opening any application or address.
6. Preserve exact revision, host declaration, interaction/accessibility transcript, launch audit,
   screenshots, and tripwire output in the H9 ledger.

Unit, model, static, compile-only, and deterministic snapshot evidence in this directory is
supporting implementation evidence only. It does not satisfy these runtime checks.
