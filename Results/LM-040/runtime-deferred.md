# LM-040 runtime evidence deferred to H9

LM-040 remains technically blocked. ADR 0006 permits its implementation to feed later safe
work, but does not waive the acceptance requirement that filter controls pass real keyboard
and VoiceOver interaction.

The isolated validation Mac must run the exact committed revision and verify both the main
Search section and global panel:

1. Type lexical text plus `app:`, `site:`, relative-day, and explicit interval syntax; confirm
   every applied filter is announced as a visible removable token and reaches the result set.
2. Use keyboard navigation alone to open the app, site, and date menus, accept approved
   autocomplete suggestions, remove every token, and restore focus predictably.
3. Use VoiceOver to confirm labels, hints, ordering, selected/removable state, result-change
   announcements, and the absence of inaccessible duplicate controls.
4. Confirm ambiguous app display names remain explicit picker choices but never resolve from
   ambiguous parser text, and confirm suppressed/unready archive metadata is never suggested.
5. Preserve the interaction transcript, content-free accessibility audit, screenshots, exact
   revision, host declaration, and encoder-service tripwire output in the H9 ledger.

Unit, model, static, compile-only, and filter-state snapshot evidence in this directory is
supporting implementation evidence only. None of it is a substitute for these runtime checks.
