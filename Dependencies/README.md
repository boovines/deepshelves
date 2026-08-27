# Audited dependency closure

`dependencies.json` is the canonical LM-004 software/model bill of materials. It records exact revisions, licenses, expected sizes, SHA-256 digests, linkage scope, and update procedures. The generated Xcode project intentionally continues to reference only local packages until the owning implementation story integrates an audited dependency.

The full upstream MCP package and Argmax OSS package are explicitly `forbiddenShipping`: their source distributions include network transports or model-download paths. Later stories may create narrow local targets from the pinned official source only after proving that stdio-only MCP and local-model-only audio binaries contain none of those transports. `EventSource` and `swift-nio` record the upstream MCP resolver closure but may never link into a DeepShelves shipping target.

Apple's pinned MobileCLIP weights use the Apple Machine Learning Research Model License, which limits them to research use and excludes commercial product use. They may be evaluated in this private personal research build. They must not be redistributed or used for a commercial release without a different license grant or an explicitly approved model decision.

## Create the cache while online

Run this only as an explicit build/bootstrap action:

```bash
./scripts/bootstrap-dependencies.sh --fetch /Volumes/DeepShelvesDependencyCache
```

The command downloads each artifact to a partial file, verifies size and SHA-256, and only then atomically publishes it into the cache. It never runs code or post-install scripts from a dependency or model repository. Existing mismatched files cause a hard failure and are not overwritten.

Copy the completed cache to the offline build machine by trusted local media. Xcode 26.5 (build 17F42) is Apple-licensed software and must be installed separately; it is not redistributable through this cache.

## Verify and use the cache offline

Disconnect networking or apply the deny-all network policy, then run:

```bash
./scripts/bootstrap-dependencies.sh --offline /Volumes/DeepShelvesDependencyCache
./scripts/check-dependencies.sh --static
```

`--offline` contains no network command and verifies every cached byte against the committed manifest. Extract only the source archive or model subtree needed by the active LM story into a local, ignored build directory. Keep SwiftPM automatic resolution disabled and point the story's XcodeGen/local package entry at that verified local checkout.

No runtime code invokes this bootstrap. The app, CLI, and MCP helper must never read dependency URLs, download packages/models, run an updater, or contact a cache. Normal release journeys run under a deny-all network policy in S7 and LM-063.

## Updating a pin

Use the component-specific `updateProcedure` in `dependencies.json`. Every update requires a story-scoped review that:

1. resolves tags to exact commits and regenerates source/binary/model hashes;
2. re-audits license and transitive dependency changes;
3. starts from an empty cache and passes both online fetch and offline verification;
4. reruns the affected spike, privacy, release, and linked-binary gates; and
5. commits the updated manifest/evidence with no downloaded cache contents.
