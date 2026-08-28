# Retrieval and Search

## Outcome

Deliver fast and trustworthy recall across exact text, partial text, application/site metadata, time expressions, and visual descriptions. Search must remain useful before any semantic model is available.

## Query model

Represent each search as a structured query:

| Field | Examples |
|---|---|
| free_text | lamp, invoice number, project deadline |
| apps | Chrome, Mail, Claude |
| sites | github.com, linear.app |
| time_range | today, yesterday, last week, explicit dates |
| content_types | Accessibility, OCR, transcript |
| has_media | screenshot, audio |
| activity_state | active, idle |
| sort | relevance, newest, oldest |

The command palette should parse natural time phrases and recognized operator forms such as app:, site:, before:, and after: into visible removable tokens. Hard filters are applied before vector search whenever possible.

## Indexes

### Lexical

Use SQLite FTS5 with `merged_text_records` as its external-content table. Maintenance is
explicit and transactional; there are no FTS synchronization triggers. Integrity checks
compare the FTS docsize row inventory with ready merged records rather than counting
external-content query rows.

Indexed fields with different weights:

- Focused Accessibility text
- Window title and page title
- OCR text
- Application name
- Website host
- Transcript

The concrete column order is approved merged screen text, window title, application name,
host, path, and transcript text. Transcript remains a separate reserved column until the
optional audio phase so evidence labeling and source weighting stay truthful.

Use BM25 and weight structured/focused text above OCR and transcripts. Use FTS snippets and highlights in result cards.

The lexical engine treats user text as literals, never as FTS5 operator syntax. Quoted
phrases remain phrases; every other normalized term is quoted and combined with `AND`.
Its fixed BM25 column weights are `6, 4, 2, 2, 1.5, 1` for approved screen text, title,
application, host, path, and transcript. Deterministic exact/contains boosts are title
`4/1.5`, application `3`, host `2.5`, and path `1.5`. Final lexical order is score
descending, capture time descending, then lowercase frame UUID ascending.

The user-created `AccessPolicy` interval, application allowlist, and browser-host allowlist
are hard SQL predicates on ready canonical records. Empty application allowlists return
no agent results; browser records also require their canonical host to be allowed. Request
filters must already be policy subsets and further narrow those predicates. Expiry is
checked before every page, and `maxResults` caps the complete signed cursor chain rather
than each page independently.

Evidence is projected only from matching durable non-suppressed spans or exact canonical
title/application/URL/transcript fields. Search does not synthesize a claim or summary.
Cancellation is checked before archive access, after the bounded SQL page, and before
returning the contract page.

### Visual semantic

Use paired MobileCLIP-S0 image and text embeddings. Store unit-normalized Float16 image vectors in a contiguous, model-versioned flat file. SQLite maps capture IDs to byte offsets and dimensions.

V1 uses exact cosine search:

- Memory-map the active vector file read-only.
- Apply hard app/site/time filters to produce allowed capture IDs.
- Scan vectors in bounded chunks with Accelerate/vDSP.
- Maintain a top-k heap without allocating one score per capture.
- Compare results with a scalar reference implementation in tests.

Do not ship sqlite-vec or HNSW initially. Add an approximate index only if exact search exceeds 750 ms p95 on the million-frame benchmark or requires more than 500 MB resident vector memory on the target Mac.

### Text semantic

Out of scope for V1. FTS5 handles extracted text; MobileCLIP handles visual concepts. Add a text-semantic model only through an ADR backed by query-set improvement.

## Ranking pipeline

    Parse query
        |
        +-- Apply application/site/time filters
        |
        +-- FTS5 BM25 candidates
        +-- image-vector candidates
        |
        +-- Reciprocal-rank fusion
        |
        +-- metadata and recency features
        |
        +-- duplicate/session collapse
        |
        +-- final results with evidence

Use reciprocal-rank fusion with a fixed k of 60 because component scores are not directly comparable. Avoid an opaque learned ranker until labeled query data is large enough to evaluate one.

Suggested ranking features:

- FTS rank by source field
- Image similarity
- Exact title/app/site match
- Focused-window match
- Temporal proximity to requested range
- Duplicate-frame penalty

Do not add a general recency boost to queries with a specific historical time range.

## Result grouping

Continuous captures often produce many near-identical results. Collapse captures into activity sessions using:

- Same application/window/site
- Small timestamp gap
- Similar perceptual hash
- Similar extracted text

Return the strongest capture as the group representative and expose the full sequence in the detail timeline.

## Search API

The internal contract should support both UI and agent access:

    SearchRequest
      query
      interval
      bundleIDs
      hosts
      mode
      pageSize
      cursor
      accessPolicy

    SearchResponse
      results[]
      next_cursor
      local diagnostics timing/index versions when diagnostics are enabled

Each result includes:

- Frame ID
- Timestamp
- Application, window, and site
- Thumbnail reference
- Evidence snippet with source type
- Matched terms
- Rank contributions for local debugging
- Media and thumbnail locators authorized for the caller

Use the opaque query-fingerprinted keyset cursor defined in plan 10 for every sort mode. Do not depend on an expiring result cache for pagination correctness. Lexical cursors carry the exact score bit pattern, capture timestamp, frame UUID, and cumulative policy result count; changing any query or policy scope rejects the cursor.

## Query understanding

Phase 1 uses deterministic parsing with Foundation date parsing plus explicit grammar rules:

- Date/time grammar
- Known app names
- URL/host recognition
- Explicit operators

Do not require an LLM and do not add query rewriting in V1. Preserve unrecognized terms as free text; parsed filters remain visible and editable.

## Evaluation set

Build and maintain a private benchmark:

- 500 or more captures across common applications
- 100 or more queries
- One or more relevant capture IDs per query
- Query classes: exact text, paraphrase, visual object, app/site, temporal, combined, negative

Report:

- Recall@1, Recall@5, Recall@10
- Mean reciprocal rank
- nDCG@10 for multiple-relevance queries
- Query latency p50/p95
- Indexing throughput
- Result duplicate rate
- No-result precision for negative queries

Keep Coast’s demonstrated “lamp + today” query as one acceptance fixture.

## Implementation phases

### R1: Structured filters and FTS5

Gate: Recall@5 at least 0.90 on exact and metadata queries; p95 below 300 ms on a 30-day fixture.

### R2: Session grouping and timeline context

Gate: duplicate result rate below 15% without lowering Recall@10.

### R3: MobileCLIP-S0 and exact Accelerate search

Gate: Recall@10 at least 0.80 on visual-description queries and p95 below 750 ms on the million-frame fixture.

### R4: Hybrid fusion and feedback

Gate: hybrid nDCG@10 improves over both lexical-only and vector-only baselines.

### R5: Scale checkpoint

Run the million-frame benchmark. An approximate vector index becomes a new ADR only if the fixed exact-scan thresholds fail.

## Failure behavior

- If vector index is missing, search remains fully functional with FTS.
- If parsing is uncertain, preserve text rather than applying a risky filter.
- If indexes are rebuilding, search old compatible indexes or clearly show partial status.
- Every result links back to captured evidence rather than presenting generated assertions as fact.

## Sources

- [SQLite FTS5 and BM25](https://www.sqlite.org/fts5.html)
- [Apple Accelerate](https://developer.apple.com/documentation/accelerate)
- [USearch Swift, contingency only](https://github.com/unum-cloud/usearch/blob/main/swift/README.md)
- [Apple MobileCLIP](https://github.com/apple/ml-mobileclip)
- [SigLIP 2 paper](https://arxiv.org/abs/2502.14786)
- [Screenpipe local search](https://github.com/screenpipe/screenpipe)
