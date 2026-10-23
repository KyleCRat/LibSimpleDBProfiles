# Engineering Guide

## Product Boundary

LibSimpleDBProfiles is an embedded LibStub library. It owns profile identity,
selection, private storage containers, administration, and profile-wide payload
migration. LibSimpleDB owns active payload reads, writes, defaults, path
callbacks, reset, and data-root switching.

Do not add a standalone addon TOC or UI to this repository. A future
SimpleDBAdmin addon consumes the public discovery and administration APIs.

## Load Order

`embed.xml` is authoritative. The bootstrap must load first and `Library.lua`
must load last. Every intermediate file must keep the
`_loadInProgressMinor` guard. The bootstrap validates LibSimpleDB before
reserving the LibStub minor.

Compatible upgrades update the persistent manager, admin, and Migration
prototypes in place. Do not copy methods onto instances.

## Lua Layout

Use StyLua 2.5.2 and Selene 0.31.0 with the checked-in configuration. Keep
nonempty functions, callbacks, loops and multi-branch conditionals multiline.
Simple single-branch conditionals may collapse within the 80-column guide,
including indentation; empty functions may stay inline. Use four spaces,
UTF-8, LF and final newlines. Keep unrelated statements on separate lines.

Keep related declarations, table fields, and other short one-line statements
grouped. Separate control-flow blocks and function definitions from surrounding
statements with a blank line before and after the block. Do not add blank lines
immediately inside a block solely because its first or last statement is
another block.

Review naming, logical grouping and complexity even when both tools pass.
Verify new `wow.yml` globals against the runtime or the fixture providing them;
never add names merely to silence findings. Prefix intentionally unused
parameters with `_`. Keep lint exceptions narrow and explain their contract.
Do not install tools, add package managers or change global shell settings
without explicit permission. Do not build a permanent custom style parser or
linter. Narrow, read-only, one-off structural checks, such as XML include
resolution, are allowed.

## Module Ownership

- `LibSimpleDBProfiles-1.0.lua`: LibStub bootstrap, persistent prototypes, weak
  registries, and load gating.
- `Internal/Util.lua`: value copying, UTF-8/name validation, equality, and safe
  callback dispatch.
- `Internal/Identity.lua`: WoW identity capture, `profileRef`, `profileID`, and
  localized display names.
- `Internal/Storage.lua`: private schema normalization, canonical containers,
  character metadata, and payload enumeration.
- `Migration.lua`: consumer Migration construction and staged version steps.
- `Internal/Descriptors.lua`: detached profile, usage, and character views.
- `Manager.lua`: construction, active binding, selection, and lifecycle
  registration.
- `Operations.lua`: ordinary create, copy, reset, rename, and delete behavior.
- `Admin.lua`: exact-ID and offline-character administration.
- `Events.lua`: specialization lifecycle handling.
- `Library.lua`: public library methods, compatible upgrades, and event-frame
  finalization.

## Invariants

- `profileRef` is relative and selectable; `profileID` is exact and
  manager-local.
- The active LibSimpleDB object remains stable for the manager's lifetime.
- Expected conflicts return `nil, stableCode` without side effects. Programming
  misuse and corrupt required storage throw.
- Permanent profiles are resettable but not renamable or deletable.
- Consumer payload migrations never interpret defaults and commit atomically per
  version step.
- Profile and character descriptors are detached snapshots.
- No profile operation runs in a combat-sensitive hot path; clarity and
  correctness take priority over micro-optimization.

## Verification

Run all checks from the repository root:

```powershell
stylua --check .
selene .
lua.exe tests/run.lua
luac.exe -p LibSimpleDBProfiles-1.0.lua
git diff --check
```

Compile every Lua module, not only the bootstrap. Keep tests synchronized with
`API.md` and `PLAN.md`, including mixed embedded-copy load orders.

Require zero formatting or lint findings, including warnings. Apply formatting
with `stylua --verify .`; add `--respect-ignores` when passing individual files.
Do not commit, tag or push unless requested.
