# Local Enrichment Pipeline

## Outcome

Turn accepted keyframes into useful searchable records without cloud inference: structured Accessibility text first, OCR where needed, browser/app context, required visual embeddings, and optional audio transcription.

## Ordering principle

Use the cheapest and most reliable signal first:

1. Application and window metadata
2. Accessibility tree
3. Browser URL and document metadata
4. OCR
5. Visual embedding
6. Optional local caption or summary after V1

Do not run every expensive model on every frame. Enrichment is asynchronous, resumable, and priority-aware.

## Accessibility extraction

Capture a bounded representation of the focused window:

- Role, subrole, title, value, description, help text, enabled/focused state
- Bounding box when available
- Hierarchy path and stable-enough element signature
- Focused element and selected text
- Browser address/document URL when exposed

Apply limits:

- Maximum node count
- Maximum depth
- Maximum string length per node
- Time budget per traversal
- Redaction before persistence

Flatten the tree into searchable text while retaining structured elements for future highlighting. Store source and confidence so retrieval can favor Accessibility text over OCR duplicates.

## OCR

Use Apple Vision text recognition. It runs on-device and provides text, confidence, and bounding boxes.

Policy:

- Skip OCR when Accessibility coverage is high and the visual frame is text-light.
- Run fast recognition initially.
- Schedule accurate recognition when the frame is likely valuable or search later misses it.
- Normalize Unicode, whitespace, and line ordering.
- Preserve bounding boxes for result highlighting.
- Deduplicate OCR spans that substantially overlap Accessibility text.

## Browser and site context

Prefer accessibility/document APIs over reading browser databases.

Store:

- Browser bundle ID
- Normalized origin and host
- Normalized scheme, lowercase host, and optional non-sensitive path after policy approval
- Page title
- Private-window classification

Discard credentials, query strings, and fragments before persistence. Do not persist a URL when reliable browser context is unavailable.

Never make network requests for favicons. Resolve application icons locally and generate deterministic site initials or use locally cached icons derived from page resources only if no request is required.

## Visual-semantic embeddings

Use an image/text-aligned model so “lamp” can retrieve a furniture screenshot even when OCR does not contain that word.

Use Apple MobileCLIP-S0 with Apple’s published Core ML image and text encoders. Bundle the pinned compiled model and tokenizer resources with the application so first use requires no download. MobileCLIP-S0 is the fixed V1 choice because it is designed for efficient on-device image-text retrieval; larger MobileCLIP variants and SigLIP 2 are benchmark challengers, not implementation branches.

For each accepted visual frame:

- Resize and normalize once.
- Produce a unit-normalized image embedding.
- Version the model and preprocessing parameters.
- Convert the unit vector to Float16 and append it to the versioned flat vector file.
- Store the byte offset, dimension, model version, and capture ID in SQLite.
- Reindex asynchronously after a model upgrade.

For each semantic query:

- Produce the corresponding text embedding with the exact paired text encoder.
- Retrieve nearest image vectors after applying hard metadata/time filters.

Do not use OCR-text embeddings as a substitute for image embeddings; retain separate vector spaces and fuse their ranked results later.

## Optional local summarization

Daily or activity-block summaries are useful but not required for retrieval parity.

If added after the primary product is complete:

- Use an explicitly selected local model adapter; do not add a cloud-provider interface.
- Summarize only extracted text and metadata by default, not pixels.
- Store provenance: source capture IDs, model, prompt version, and generation time.
- Make summaries deletable and regenerate them after source deletion.
- Never let generated summaries outrank exact source evidence without a visible label.

## Optional audio transcription

Audio is a separate phase and off by default.

- Require explicit microphone/system-audio opt-in.
- Use pinned WhisperKit Core ML `small.en`. A different model requires its own measured ADR rather than an in-product model picker in V1.
- Store compressed local audio chunks and word/segment timestamps.
- Treat speaker diarization as optional.
- Correlate audio chunks to the screen timeline by monotonic timestamp.
- Include independent retention and exclusion controls.

Package audio model assets in the audio-enabled build or install them through an explicit, separate developer-run installer. The application itself never downloads a model.

## Enrichment jobs

| Job | Priority | Trigger |
|---|---|---|
| Metadata normalization | Immediate | Every accepted capture |
| Accessibility extraction | Immediate | Every meaningful event |
| OCR fast | High | Accessibility insufficient |
| Thumbnail generation | High | Every accepted capture |
| Visual embedding | Medium | Every indexed searchable frame |
| OCR accurate | Low | Valuable/failed frame or idle time |
| Activity aggregation | Low | Periodic |
| Summary generation | User/idle | Explicitly enabled |

Every job is idempotent and keyed by capture ID plus algorithm version.

## Quality evaluation

Create a 500-frame private fixture covering:

- Browsers, terminals, editors, mail, chat, media, PDFs, and native apps
- Light/dark modes
- Dense/sparse text
- High-DPI and scaled displays
- Multiple languages relevant to the user
- Password and private-window exclusions

Measure:

- Accessibility text coverage
- OCR character/word error rate
- Duplicate-text rate
- Visual retrieval Recall@10
- Enrichment latency and energy use
- Failure rate by application

## Implementation phases

### E1: Metadata and Accessibility

Gate: searchable structured text from at least 80% of common-workflow frames.

### E2: Vision OCR fallback

Gate: combined source improves fixture text recall without duplicating result snippets excessively.

### E3: MobileCLIP-S0 embeddings

Gate: at least 0.80 Recall@10 on a hand-labeled set of visual-description queries, model bundle integrity verified offline, and p95 frame embedding below the spike threshold.

### E4: Optional transcription and summaries

Gate: all inference verified offline and derived data linked to source provenance.

## Risks and trade-offs

- Accessibility traversal can hang or return huge trees. Enforce deadlines and node budgets.
- OCR every frame is wasteful. Use Accessibility coverage and visual-change heuristics.
- Model upgrades can invalidate vectors. Version every derived artifact.
- Captioning screenshots may introduce hallucinations. Retrieval should always return original evidence.

## Sources

- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Apple Core ML](https://developer.apple.com/documentation/CoreML)
- [Apple MobileCLIP](https://github.com/apple/ml-mobileclip)
- [Apple Core ML MobileCLIP models](https://huggingface.co/apple/coreml-mobileclip)
- [Argmax WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
- [Screenpipe accessibility-first architecture](https://github.com/screenpipe/screenpipe)
