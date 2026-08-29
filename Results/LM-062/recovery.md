# LM-062 recovery-flow evidence

- Canonical runbook: `Docs/Operations/archive-recovery.md`
- Existing typed rollback-safe whole-archive reset: `ArchiveResetCoordinator`
- New explicit selected-evidence export, integrity, quarantine, and repair entry point:
  `ArchiveMaintenanceCoordinator`
- Runtime proof class: unit/static/compile only on the owner's laptop.
- Deferred unchanged to H9: native application confirmation, export destination interaction,
  real source-media presentation, repair/relaunch, key-loss, and whole-archive reset journey.
