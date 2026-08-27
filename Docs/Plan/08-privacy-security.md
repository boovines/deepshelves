# Privacy, Security, and Trust Boundary

## Outcome

Make “local-first” technically enforceable rather than a marketing claim. The finished application must operate after installation with no outbound network traffic and must minimize the consequences of local compromise.

## Threat model

Protect against:

- Accidental capture of password managers, banking, healthcare, private browsing, and authentication flows
- A local agent requesting broader history than intended
- Another local user reading the archive
- Malware or a malicious process querying an unauthenticated local API
- Sensitive content in diagnostics
- Incomplete deletion
- Unintended runtime network access or dependency/model fetching
- A future implementation accidentally adding telemetry

Not fully protected against:

- A root/admin attacker on an unlocked Mac
- Screen content already visible to other privileged software
- Copies made through user-configured backups or exports
- A compromised operating system

## Network policy

- No analytics, crash upload, update checks, remote favicon lookup, cloud model, or account system.
- Do not link URLSession-based networking or a generic HTTP client into shipping application/helper targets.
- Bundle pinned MobileCLIP-S0 and required tokenizer assets.
- Optional audio models are installed only through a separate user-invoked model installer build step; normal runtime never downloads them.
- Add a CI/static check for unexpected networking dependencies.
- Add a runtime test that exercises capture, search, timeline, and agent queries while blocking all network interfaces.

If automatic updates are later added, they are a separate build flavor and opt-in.

## Capture minimization

- Capture exactly one uniquely resolved foreground `SCWindow` through `SCContentFilter(desktopIndependentWindow:)`; never capture the composited display in V1.
- Tie every buffer to a revocable window-capture epoch and reject stale buffers after focus, URL, filter, or dimension changes.
- Missing, ambiguous, minimized, protected, secondary-display-only, or policy-uncertain windows produce metadata-only gaps and no pixels.
- The app's own bundle, login/lock-screen processes, and system permission surfaces are always excluded.
- Detected password managers begin in a versioned editable exclusion set; removing one requires a warning that pixels cannot be reliably redacted.
- Private browser windows are excluded by default.
- Exclusions apply before persistence.
- Secure-input state suppresses capture.
- Raw keystrokes and clipboard content are never stored.
- Password fields are excluded from Accessibility extraction.
- OCR redaction detects common credentials, tokens, payment cards, SSNs, and private keys before text persistence.
- Because OCR redaction cannot reliably sanitize the pixels, application/site exclusion remains the primary control.
- Provide a global pause shortcut and visible menu-bar state.
- Provide one-click “forget recent history.”

## Local access control

- Data directory mode 0700; files 0600.
- Database keys and helper capabilities in macOS Keychain only.
- No loopback HTTP API exists.
- MCP policies enforced server-side.
- Full-resolution media access is more restricted than metadata/text.
- Bulk export and complete archive deletion require a native confirmation that states scope and destination; destructive confirmation defaults to Cancel.

The personal build uses Hardened Runtime but not App Sandbox: reliable Accessibility inspection and global activity monitoring are core functions and are poor fits for a sandboxed App Store target. Keep entitlements minimal, rely on macOS TCC for Screen Recording/Accessibility, and require a shared signed-helper Keychain access group. This is a local developer-signed build, not a Mac App Store package.

## Encryption

Required:

- FileVault setup warning/status
- Keychain for secrets
- No sensitive logs

Required before dogfood:

- SQLCipher for database, FTS, settings, and audit rows
- Random 256-bit key in macOS Keychain
- Cipher activation verification on every open

HEVC media, thumbnails, flat vectors, audio, and temporary files rely on FileVault and filesystem permissions in V1. The UI must describe this boundary accurately. Do not claim full archive encryption.

## Diagnostics

Logs may contain:

- State transitions
- Error codes
- Queue depths
- Durations
- Capture IDs
- Application bundle IDs only when diagnostics are explicitly enabled

Logs must not contain:

- Screenshot pixels
- OCR or Accessibility text
- Window titles or URLs by default
- Search queries
- Agent-returned content
- Audio/transcripts

Support bundle generation is explicit, previewable, and local.

## Dependency and model trust

- Pin every dependency and model revision.
- Record license, source, checksum, and expected size.
- Generate a software/model bill of materials.
- Verify bundled or explicitly installed model checksums before loading.
- Do not execute post-install scripts from model repositories.
- Review application entitlements and linked frameworks; only required capabilities ship.
- Treat captured Accessibility/OCR text and MCP clients as untrusted input.

## Privacy tests

Create automated scenarios:

- Excluded password-manager and private-browser sentinels visible behind/beside an allowed target never appear in any pixel or derivative.
- Notification, menu bar, Dock, desktop, and split-screen-adjacent sentinels never appear.
- Rapid focus/filter changes never persist a stale prior-window buffer.
- Excluded app remains foreground through heartbeat.
- Window changes into and out of private mode.
- URL changes between allowed and denied domains.
- Screen changes during capture race.
- Password field visible beside ordinary text.
- Forget-last-15-minutes while indexing is in progress.
- Agent queries overlap denied and allowed captures.
- Application runs offline for eight hours.
- Search and crash paths produce no content logs.

Gate: no excluded canonical or derived artifact exists after each scenario.

## User-facing guarantees

The settings UI should be able to truthfully state:

- Capture and enrichment occur on this Mac.
- No normal feature requires an account.
- No data leaves the Mac unless the user explicitly exports it or gives a local third-party agent access.
- The archive is not a backup or compliance record.
- Local administrators or malware may still access data on an unlocked Mac.

Avoid absolute statements such as “no one can ever access your data.”

## Implementation phases

### P1: Threat model and default exclusions

Gate: privacy fixture suite exists before ambient recording ships.

### P2: Network-free build and local authentication

Gate: packet/process inspection shows zero outbound requests during the full test journey.

### P3: Deletion proof and agent scoping

Gate: forensic fixture scan finds no deleted or denied content in media, DB, indexes, logs, or temporary files.

### P4: SQLCipher and Keychain

Gate: database ciphertext, helper access, recovery, performance, and key-loss behavior are documented and tested.

## Sources

- [Apple Platform Security](https://support.apple.com/guide/security/welcome/web)
- [SQLCipher for Apple](https://www.zetetic.net/sqlcipher/sqlcipher-apple/)
- [Coast privacy controls and disclosed network exceptions](https://coast.app/privacy)
- [Screenpipe privacy data flow](https://docs.screenpipe.com/privacy-data-flow)
