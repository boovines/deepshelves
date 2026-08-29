# LM-042 runtime evidence deferred to H9

LM-042 remains technically blocked because LM-041 is H9-deferred and the production card
presentation still requires visual/accessibility inspection in the running application. Its
safe evidence proves the source mapping and absence of synthesized claims, but does not
waive that runtime boundary.

On the isolated validation Mac, use the exact committed revision in both search surfaces:

1. Display deterministic results for Accessibility, OCR, application, title, URL,
   transcript, and visual evidence; confirm each card cites the correct source and only the
   exact source text supplied by its contract.
2. Hover/focus every source indicator and inspect the VoiceOver label. Confirm the source is
   available without permanent debug chrome and no unsupported summary appears.
3. Run once without diagnostics and confirm no rank/score overlay exists. Run once with the
   explicit local diagnostics flag and confirm only text rank, visual rank, and fused score
   appear, with no captured content added to diagnostics.
4. Preserve screenshots, the accessibility transcript, exact revision, host declaration,
   and encoder-service tripwire output in the H9 ledger.

Unit, model, static, compile-only, and deterministic snapshot evidence in this directory is
supporting implementation evidence only and is not runtime evidence.
