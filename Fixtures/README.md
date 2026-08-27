# Fixture corpus

The deterministic privacy, retrieval, timeline, media, and compatibility fixtures specified in `Docs/Plan/10-contracts-and-fixtures.md` are added alongside their owning stories. Fixture labels are immutable once frozen.

`Contracts/v1/` contains the canonical synthetic JSON compatibility corpus for `MemoryContracts`. Regenerate it with `scripts/generate-contract-fixtures.sh`; every file is canonical JSON with RFC 3339 fractional UTC timestamps and lowercase UUIDs. `manifest.json` pins the generator version, source, license, semantic labels, and SHA-256 of each fixture.

Once a fixture is committed, changing its bytes or labels requires an explicit contract-version or fixture-defect story. Implementations under evaluation must not rewrite their own golden expectations.
