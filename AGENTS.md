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

Keep related declarations, table fields, and other short one-line statements
grouped. Separate control-flow blocks and function definitions from surrounding
statements with a blank line before and after the block. Do not add blank lines
immediately inside a block solely because its first or last statement is
another block.

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
lua.exe tests/run.lua
luac.exe -p LibSimpleDBProfiles-1.0.lua
git diff --check
```

Compile every Lua module, not only the bootstrap. Keep tests synchronized with
`API.md` and `PLAN.md`, including mixed embedded-copy load orders.
