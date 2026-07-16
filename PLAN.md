# LibSimpleDBProfiles Plan

## Status

Planning only. No implementation or release exists yet.

`LibSimpleDB-2.0` is still under review and unreleased. Do not release this
companion until the required core API has a reviewed `2.0.0` tag.

## Goal

Build a reusable scoped profile manager on top of `LibSimpleDB-2.0` without
adding profile or scope prefixes to hot-path database reads.

The companion will own scoped storage, profile selection, profile lifecycle,
copying, renaming, deletion, and migration policy. LibSimpleDB will continue
to own nested defaults, reads, writes, resets, validation, and path callbacks.

## Library Identity

- Repository and folder: `LibSimpleDBProfiles`
- LibStub family: `LibSimpleDBProfiles-1.0`
- Initial LibStub minor: `1`
- Initial Git tag: `1.0.0`
- Required dependency: `LibSimpleDB-2.0`, minimum minor `1`
- First release dependency pin: reviewed `LibSimpleDB` tag `2.0.0`
- No standalone addon TOC unless an in-game development harness later requires
  one

The profile companion is a separate API family and release stream. A compatible
companion update increments its LibStub minor and uses SemVer Git tags without a
`v` prefix.

## Why This Is A Companion Library

Profiles add storage and selection policy that does not belong in the core
database abstraction:

- Profile names and character-to-profile mappings
- Global versus profile scope ownership
- Realm, character, class, specialization, and faction scope ownership
- Create, copy, rename, reset, and delete behavior
- Profile lifecycle events
- Storage schema migrations

Keeping these concerns separate preserves LibSimpleDB as a small general-purpose
database library. Addons that do not need profiles do not embed unused policy.

## Storage Schema

The proposed account-wide SavedVariables container is:

```lua
MyAddonDB = {
    global = {},
    realms = {
        ["Area 52"] = {},
    },
    characters = {
        ["Character - Area 52"] = {},
    },
    classes = {
        MAGE = {},
    },
    specs = {
        ["MAGE:62"] = {},
    },
    factions = {
        Horde = {},
    },
    profiles = {
        Default = {},
    },
    profileKeys = {
        ["Character - Realm"] = "Default",
    },
}
```

The addon supplies the required `selectionKey` and the keys for every keyed
scope. The companion must not derive character, realm, class, specialization,
or faction identity from game APIs. This keeps player identity and gameplay
policy out of the library.

The `selectionKey` identifies whose profile choice is being remembered. It is
independent of the character scope key and can represent a character, a
character-specialization pair, a loadout, or another consumer-defined
selection context:

```lua
storage.profileKeys[selectionKey] = profileName
```

Defaults are separated by scope:

```lua
local defaults = {
    global = {
        minimap = { hide = false },
    },
    realm = {},
    character = {},
    class = {},
    spec = {},
    faction = {},
    profile = {
        display = { scale = 1 },
    },
}
```

Defaults are not copied into every stored profile. Empty profile tables fall
back through the one profile database instance's defaults.

## Active-Root Architecture

The companion creates one stable LibSimpleDB instance for every supported
scope:

```lua
local globalDB = LibSimpleDB:New(storage.global, defaults.global)
local realmDB = LibSimpleDB:New(
    storage.realms[scopeKeys.realm],
    defaults.realm
)
local characterDB = LibSimpleDB:New(
    storage.characters[scopeKeys.character],
    defaults.character
)
local classDB = LibSimpleDB:New(
    storage.classes[scopeKeys.class],
    defaults.class
)
local specDB = LibSimpleDB:New(
    storage.specs[scopeKeys.spec],
    defaults.spec
)
local factionDB = LibSimpleDB:New(
    storage.factions[scopeKeys.faction],
    defaults.faction
)
local profileDB = LibSimpleDB:New(
    storage.profiles[currentProfile],
    defaults.profile
)
```

Consumers read directly from the selected scope:

```lua
profileDB:Get("display", "scale")
globalDB:Get("minimap", "hide")
specDB:Get("layout", "enabled")
```

Do not expose a facade that prepends scope or profile keys:

```lua
-- Rejected design
manager:Get("profiles", currentProfile, "display", "scale")
manager:Get("global", "minimap", "hide")
```

Profile switching rebinds the existing profile database:

```lua
profileDB:SetData(storage.profiles[newProfile])
```

The profile lookup happens once during initialization or switching. Ordinary
`Get()` calls retain their original path depth and performance.

`SetScopeKey(scope, key)` rebinds the existing database object for `realm`,
`character`, `class`, `spec`, or `faction`. This supports context changes such
as a specialization switch without invalidating a database object retained by
a consumer.

## Read-Path Invariants

- The companion must not run on the hot path of `profileDB:Get()` or
  any scoped database `Get()`.
- Scope and active-profile resolution happen only during initialization or an
  explicit selection or scope-key change.
- Maintain one stable profile LibSimpleDB instance, not one instance per stored
  profile.
- Maintain one stable LibSimpleDB instance for every supported scope.
- Do not copy defaults per profile.
- Do not add transparent value caches. The retained SavedVariables tables are
  mutable references and cannot be invalidated reliably after external changes.
- Consumers with per-frame settings reads should cache applied values and
  refresh them through profile/data lifecycle notifications.
- Profile and scope changes are cold paths. Correctness and clear lifecycle
  notifications take priority over optimizing those operations.

## Proposed Constructor And Accessors

```lua
local Profiles = LibStub("LibSimpleDBProfiles-1.0")

local manager = Profiles:New(storage, defaults, {
    selectionKey = "Character - Realm",
    scopeKeys = {
        realm = "Realm",
        character = "Character - Realm",
        class = "MAGE",
        spec = "MAGE:62",
        faction = "Horde",
    },
    defaultProfile = "Default",
})

local globalDB = manager:GetGlobalDB()
local realmDB = manager:GetRealmDB()
local characterDB = manager:GetCharacterDB()
local classDB = manager:GetClassDB()
local specDB = manager:GetSpecDB()
local factionDB = manager:GetFactionDB()
local profileDB = manager:GetProfileDB()
```

Proposed core methods:

```lua
manager:GetGlobalDB()
manager:GetRealmDB()
manager:GetCharacterDB()
manager:GetClassDB()
manager:GetSpecDB()
manager:GetFactionDB()
manager:GetProfileDB()
manager:GetSelectionKey()
manager:SetSelectionKey(key)
manager:GetScopeKey(scope)
manager:SetScopeKey(scope, key)
manager:GetCurrentProfile()
manager:GetProfileNames()
manager:SetProfile(name)
manager:CreateProfile(name)
manager:CopyProfile(sourceName, destinationName, options)
manager:RenameProfile(oldName, newName)
manager:DeleteProfile(name)
manager:ResetProfile()
```

The returned database objects must remain stable for the manager's lifetime.

`selectionKey` and every entry in `scopeKeys` are required non-empty strings.
They can change only through their explicit setter methods; mutating the
constructor options table has no effect.

## Profile Operation Semantics

### Select

`SetProfile(name)` should:

1. Normalize and validate the profile name.
2. Create an empty target profile when it does not exist.
3. Update `storage.profileKeys[selectionKey]`.
4. Update the manager's active profile name.
5. Call `profileDB:SetData(targetTable)`.
6. Dispatch the manager profile-change lifecycle notification.

Selecting the active profile is a no-op.

When selection creates a profile, `OnProfileCreated` fires before the database
is rebound and `OnProfileChanged` fires.

### Selection Key

`SetSelectionKey(key)` changes the context whose selected profile is active. It
resolves the new key's mapped profile or `defaultProfile`, creates that profile
when needed, and rebinds the stable profile database only when the resolved
profile differs from the current profile.

Changing to a selection key that resolves to the already active profile does
not fire `OnProfileChanged`.

### Scope Keys

`SetScopeKey(scope, key)` accepts only `realm`, `character`, `class`, `spec`, or
`faction`. It validates the key, creates an empty raw scope table when the key
has not been seen before, and rebinds that scope's stable database with
`SetData()`.

Setting the current key is a no-op. A successful rebind relies on that scoped
LibSimpleDB instance's `OnDataChanged`; it does not fire a profile lifecycle
event.

### Create

Creating a profile adds an empty raw table. Defaults remain owned by the stable
profile database instance and are not materialized into storage.

### Copy

Copy only raw overrides from the source profile. The destination must receive a
detached deep copy so profiles never share mutable nested tables. The companion
owns the profile container and can perform this copy without accessing private
LibSimpleDB instance fields.

Copying to an existing destination is rejected unless the caller passes
`{ overwrite = true }`. The explicit option records destructive intent after a
UI or other caller has confirmed the operation.

### Reset

Reset the active profile through `profileDB:Reset()` so its data table identity
is preserved and normal LibSimpleDB lifecycle behavior applies.

### Rename

Move the stored profile table without copying it, update every matching
`profileKeys` entry, and preserve the active data table when renaming the active
profile. Renaming to an existing destination is always rejected.

### Delete

Deleting the active profile is rejected. Deleting an inactive profile removes
every matching `profileKeys` entry so those selection contexts resolve to
`defaultProfile` the next time they are used. Deletion must never leave a
selection pointing at a missing profile.

## Profile Name Contract

Every method that accepts a profile name applies the same normalization before
lookup or mutation:

1. Require a string.
2. Trim leading and trailing whitespace.
3. Collapse internal whitespace runs to one ASCII space.
4. Reject an empty result, remaining control characters, and invalid UTF-8 byte
   sequences.
5. Preserve case and valid non-ASCII characters.

Names are case-sensitive. The library imposes no length limit; a consumer UI
may impose a display-oriented limit. Unicode normalization and case folding are
not attempted because WoW's Lua 5.1 environment has no portable canonical
normalization primitive.

## Lifecycle And Callback Contract

Profile switching is a bulk data change:

- `profileDB:SetData()` fires LibSimpleDB `OnDataChanged`.
- It does not synthesize per-path callbacks.
- Cached consumers must perform a full settings refresh after a profile switch.

The companion provides explicit lifecycle callbacks with stable snapshot
dispatch and error isolation:

```text
OnProfileChanged(manager, newName, oldName)
OnProfileCreated(manager, name)
OnProfileCopied(manager, sourceName, destinationName, overwritten)
OnProfileRenamed(manager, oldName, newName)
OnProfileDeleted(manager, name)
OnProfileReset(manager, name)
```

`OnProfileChanged` fires after `profileDB:SetData()` and the resulting
LibSimpleDB `OnDataChanged`. It is the documented source of truth for
profile-aware UI and other consumers that care which profile is active.

Consumers that only care that the database root changed, and do not care about
profile semantics, should listen to LibSimpleDB's `OnDataChanged`. Consumers
should not listen to both events for the same refresh path, which would refresh
twice for one switch.

## Ownership And Validation

- Retain the outer storage table by reference for SavedVariables persistence.
- Validate and normalize `global`, every keyed scope container, `profiles`, and
  `profileKeys` before exposing database instances.
- Selection and scope keys must be supplied by the consumer and must be
  non-empty strings.
- Stored profile values must follow LibSimpleDB's SavedVariables-compatible
  data model.
- Never create references between profiles or cycles involving the outer
  storage container.

## Migration

An existing flat database cannot become its own nested profile because that
would create a SavedVariables cycle:

```lua
-- Invalid
oldData.profiles.Default = oldData
```

Migration requires a new outer container:

```lua
local oldData = MyAddonDB

MyAddonDB = {
    global = {},
    realms = {},
    characters = {},
    classes = {},
    specs = {},
    factions = {},
    profiles = {
        Default = oldData,
    },
    profileKeys = {
        [selectionKey] = "Default",
    },
}
```

Migration must run before the companion exposes either scope DB. Each consumer
addon owns its schema version and migration from addon-specific legacy data.

## Dependency And Packaging

Load order in a consumer package:

```text
Libs\LibStub\LibStub.lua
Libs\LibSimpleDB-2.0\embed.xml
Libs\LibSimpleDBProfiles-1.0\embed.xml
```

The companion source must fail clearly when `LibSimpleDB-2.0` or its required
minor is unavailable. Consumer packages should pin reviewed Git tags for both
libraries rather than copying working-tree source manually.

## Planned Repository Layout

```text
LibSimpleDBProfiles/
  .editorconfig
  .gitattributes
  LibSimpleDBProfiles-1.0.lua
  embed.xml
  README.md
  API.md
  CHANGELOG.md
  LICENSE
  PLAN.md
  tests/
    run.lua
    libstub.lua
```

The scaffold phase will add `.editorconfig` and `.gitattributes` with UTF-8,
LF, final-newline, spaces-only policy before source files are created.

## Test Plan

- Constructor validation and first-load storage normalization
- Default profile creation and selection-key mapping
- Stable DB object identities for all seven scopes across profile and scope-key
  changes
- Realm, character, class, spec, and faction key isolation and rebinding
- Required selection/scope-key validation and explicit setter behavior
- Isolation of raw overrides between profiles
- Shared instance defaults without materializing them into each profile
- Same-profile selection no-op behavior
- Selection-key changes that resolve to the same or a different profile
- Profile creation, copy without aliasing, reset, rename, and deletion
- Explicit copy overwrite and rename conflict behavior
- Profile-name normalization, case sensitivity, and unrestricted length
- Active-profile rename and deletion behavior
- Every `profileKeys` mapping updated by rename/delete operations
- `OnDataChanged` and companion lifecycle ordering and arguments
- No path callbacks synthesized during switching or bulk operations
- Existing path callback registrations remain active after switching
- Callback mutation snapshots and error isolation
- Reload persistence using the documented storage schema
- Flat-database migration without cycles or shared profile tables
- Actual `LibSimpleDB-2.0` dependency with both embedded load orders where valid
- Same-family companion minor upgrades before and after manager creation
- Multiple embedded copies and lower/newer companion minors
- Lua 5.1 syntax and unsupported-value/error contracts

## Performance Scope

No standalone benchmark suite is required. Profile and scope changes are
infrequent operations that consumers perform outside combat-sensitive hot
paths. The direct scoped LibSimpleDB objects keep ordinary reads outside the
companion library.

## Implementation Sequence

1. Keep the resolved contracts below synchronized with API documentation and
   tests.
2. Scaffold the repository text policy, license, metadata, LibStub declaration,
   and dependency check.
3. Write API documentation and storage/lifecycle tests before implementation.
4. Implement storage normalization and stable scope database construction.
5. Implement profile selection and lifecycle dispatch.
6. Implement create, copy, reset, rename, and delete operations.
7. Add migrations and real tagged-dependency integration tests.
8. Smoke-test at least one existing LibSimpleDB consumer migrated to profiles.
9. Review, tag `1.0.0`, then pin the companion from migrated consumers.

## Resolved Contract Decisions

- `SetProfile(name)` creates a missing profile.
- `selectionKey` is required and changes only through `SetSelectionKey(key)`.
- Profile names use the documented normalization, remain case-sensitive, and
  have no library-level length limit.
- `CopyProfile()` requires explicit overwrite intent for an existing
  destination.
- `RenameProfile()` never overwrites an existing destination.
- Deleting the active profile is rejected.
- `OnProfileChanged` is authoritative for profile-aware refreshes;
  LibSimpleDB `OnDataChanged` is authoritative for profile-agnostic data-root
  refreshes.
- Version 1.0 supports global, realm, character, class, spec, faction, and
  profile scopes.
- Benchmarks are not a release requirement because profile and scope changes
  are infrequent cold-path operations.
