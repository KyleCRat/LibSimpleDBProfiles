# LibSimpleDBProfiles Plan

## Status

Planning only. No implementation or release exists yet.

`LibSimpleDB-2.0` is still under review and unreleased. Do not release this
companion until the required core API has a reviewed `2.0.0` tag.

## Goal

Build a reusable profile manager on top of `LibSimpleDB-2.0` without adding
profile identity or selection work to hot-path database reads.

The library presents one public profile model:

- Permanent profiles backed by canonical character, specialization, class,
  realm, faction, and global storage
- User profiles with normalized user-supplied names
- A virtual Automatic profile that selects the most specific non-empty
  permanent profile

Consumers use the same profile-selection, active-database, reset, copy, and
lifecycle APIs for permanent and user profiles. Internal canonical storage
remains separated because each permanent profile has different identity and
automatic-selection semantics, but the term `scope` is not part of the
consumer-facing model or UI contract.

LibSimpleDB continues to own nested defaults, reads, writes, resets,
validation, and path callbacks.

## Library Identity

- Repository and folder: `LibSimpleDBProfiles`
- LibStub family: `LibSimpleDBProfiles-1.0`
- Initial LibStub minor: `1`
- Initial Git tag: `1.0.0`
- Required dependency: `LibSimpleDB-2.0`, minimum minor `1`
- First release dependency pin: reviewed `LibSimpleDB` tag `2.0.0`
- No standalone addon TOC unless an in-game development harness later requires
  one

The companion has its own API family and release stream. A compatible update
increments its LibStub minor and uses a SemVer Git tag without a `v` prefix.

## Consumer Storage

Every consumer passes an addon-owned account-wide SavedVariables table by
reference:

```toc
## SavedVariables: MyAddonDB
```

```lua
local manager = Profiles:New(MyAddonDB, defaults)
```

Do not use character-specific SavedVariables for manager storage:

```toc
## SavedVariablesPerCharacter: MyAddonDB
```

A per-character table would isolate every permanent and user profile to one
character and prevent cross-character sharing. The constructor receives only a
table reference and cannot reliably determine which TOC field declared it, so
account-wide ownership is a documented consumer requirement.

The outer table is the consumer namespace. Profile data must never be stored on
the shared LibStub library table.

Two addons using the library remain independent:

```lua
local managerA = Profiles:New(AddonADB, defaultsA)
local managerB = Profiles:New(AddonBDB, defaultsB)
```

A permanent Elemental profile in `AddonADB` is invisible to `AddonBDB`.
Consumers do not add another addon-name key inside their storage because their
outer SavedVariables table already supplies that namespace. Each addon must use
a unique TOC SavedVariables global name.

An addon needing multiple logical databases supplies separate child tables,
such as `MyAddonDB.settings` and `MyAddonDB.layout`. Passing the same storage
table to multiple managers intentionally shares one profile namespace and is
not the normal consumer pattern.

## Storage Schema

Permanent profiles retain canonical internal containers. User profiles retain
their normalized name as their exact storage key:

```lua
MyAddonDB = {
    global = {},
    realms = {
        ["3676"] = {},
    },
    characters = {
        ["Player-3676-01234567"] = {},
    },
    classes = {
        SHAMAN = {},
    },
    specs = {
        ["262"] = {},
    },
    factions = {
        Horde = {},
    },
    profiles = {
        ["团队配置"] = {},
    },
    selections = {
        ["Player-3676-01234567"] = {
            kind = "user",
            name = "团队配置",
        },
    },
}
```

A forced permanent-profile selection stores the permanent profile type rather
than its current derived identity key:

```lua
storage.selections[playerGUID] = {
    kind = "permanent",
    profile = "class",
}
```

No stored selection means the virtual Automatic profile is selected:

```lua
storage.selections[playerGUID] = nil
```

All permanent and user profiles store the same data schema and use the same
defaults:

```lua
local defaults = {
    display = {
        scale = 1,
    },
    minimap = {
        hide = false,
    },
}
```

Defaults belong to the stable active LibSimpleDB instance and are not
materialized into profile storage.

## Permanent Profiles

The library derives permanent-profile identities from nonlocalized game values.
Consumers do not supply or rename these keys.

| Permanent profile | Canonical storage key |
|---|---|
| Global | No key; `storage.global` |
| Realm | `tostring(GetRealmID())` |
| Character | `UnitGUID("player")` |
| Class | Class filename from `UnitClassBase("player")`, such as `SHAMAN` |
| Specialization | `tostring(specID)`, such as `262` |
| Faction | Tag from `UnitFactionGroup("player")`, such as `Horde` |

The current canonical table for every permanent profile is normalized during
construction and is never deleted. A table may be empty, but its permanent
profile remains selectable and resettable.

`New()` must run after the consumer's SavedVariables are loaded and player
identity APIs are available. It fails clearly when required identity cannot be
resolved. A temporarily unavailable or zero specialization is not a valid
specialization identity; Automatic skips Specialization until a valid ID is
known.

The library listens for `ACTIVE_PLAYER_SPECIALIZATION_CHANGED`:

- Automatic re-evaluates its permanent-profile priority.
- A forced Specialization profile follows the new active specialization and
  stays explicitly selected even when the new profile is empty.
- A forced user or other permanent profile remains unchanged.

Tests mock identity APIs. The public API does not expose arbitrary identity
overrides solely for tests.

## Profile References

Profile selection uses typed references, never visible names alone. This keeps
permanent and user profiles unambiguous even when their display names match.

```lua
local automaticRef = {
    kind = "automatic",
}

local permanentRef = {
    kind = "permanent",
    profile = "spec",
}

local userRef = {
    kind = "user",
    name = "Raid",
}
```

Accepted permanent profile identifiers are `character`, `spec`, `class`,
`realm`, `faction`, and `global`. References returned by the library are
detached snapshots and may be passed back to profile methods.

The virtual Automatic reference does not own a data table. It resolves to a
permanent profile and exposes that table through the active database.

## Profile Descriptors

`GetProfiles()` returns descriptors for Automatic, every current permanent
profile, and every user profile. Consumers can build one selector without
knowing separate selection APIs.

```lua
{
    ref = {
        kind = "permanent",
        profile = "spec",
    },
    displayName = "Elemental",
    permanent = true,
    selected = false,
    active = true,
    hasData = true,
    canReset = true,
    canRename = false,
    canDelete = false,
}
```

```lua
{
    ref = {
        kind = "user",
        name = "Raid",
    },
    displayName = "Raid",
    permanent = false,
    selected = false,
    active = false,
    hasData = true,
    canReset = true,
    canRename = true,
    canDelete = true,
}
```

The Automatic descriptor is permanent and reports the permanent profile it
currently activates. It has no independent raw data table.

`selected` identifies the entry chosen by the current character. `active`
identifies the entry supplying `activeDB` data. When Automatic is selected, its
descriptor has `selected = true` and the matching permanent profile has
`active = true`; the permanent profile is not also reported as selected. A
forced permanent or user profile is both selected and active.

Descriptors expose capabilities so a consumer UI can disable unsupported
commands without hard-coding profile kinds. Library methods still enforce the
same rules when called directly.

The default descriptor order is:

```text
Automatic
Character
Specialization
Class
Realm
Faction
Global
User profiles
```

The library supplies localized permanent-profile display names from current
player information. The UI may show one flat list, lock permanent entries, or
optionally group permanent and user-created profiles. It never needs to expose
the implementation term `scope`.

## User Profile Names

The normalized user name is the exact key in `storage.profiles` and the exact
name stored in a user-profile reference:

```lua
local ref = manager:CreateProfile("团队配置")

storage.profiles["团队配置"] = {}
```

Every method accepting a user profile name applies the same normalization:

1. Require a string containing valid UTF-8.
2. Trim leading and trailing ASCII whitespace.
3. Collapse internal ASCII whitespace runs to one ASCII space.
4. Reject an empty result and ASCII control characters.
5. Preserve case and every valid non-ASCII character.

Names are case-sensitive and have no library-level length limit. Validation
must not use ASCII-only allowlists such as `%w` or `[A-Za-z]`. Chinese,
Japanese, Korean, Cyrillic, Arabic, accented Latin, and other valid UTF-8 names
must work without transliteration or data loss.

Unicode normalization and case folding are not attempted because WoW's Lua 5.1
environment has no portable canonical normalization primitive. A consumer UI
may apply a display-oriented input limit, but the library does not.

`Automatic` and the current permanent-profile display names are reserved. A
new user profile whose normalized name exactly matches one of them is rejected.
Typed references remain authoritative if a later character, specialization,
realm, or locale introduces a display-name collision. In that case descriptors
must qualify the user entry as Custom so the UI remains unambiguous without
renaming stored data.

## Automatic Profile

With no stored character selection, Automatic chooses the first permanent
profile containing raw data:

```text
Character > Specialization > Class > Realm > Faction > Global
```

Global is always the final fallback even when empty. Other empty permanent
profiles are skipped only by Automatic; they remain valid explicit selections.

An Elemental Shaman with an empty Character profile uses the non-empty
Elemental profile. When Elemental is empty, Automatic checks Shaman, then the
current realm, faction, and Global.

Automatic selects one complete database. Values are not merged or resolved per
path across less-specific permanent profiles. LibSimpleDB defaults remain the
only per-path fallback for the selected database.

Automatic observes only the current manager's consumer-owned storage. A
matching Elemental profile in another addon's SavedVariables has no effect.

## Active-Root Architecture

The manager owns one stable LibSimpleDB instance:

```lua
local activeDB = LibSimpleDB:New(selectedData, defaults)
```

Profile changes rebind that instance:

```lua
activeDB:SetData(newSelectedData)
```

Consumers retain and read the active database directly:

```lua
local db = manager:GetActiveDB()
db:Get("display", "scale")
```

Do not expose a read facade that prepends profile identity:

```lua
-- Rejected design
manager:Get("specs", specID, "display", "scale")
```

The active database object remains stable for the manager's lifetime. Profile
resolution occurs only during initialization, selection, reset, identity, or
profile-management changes. Ordinary LibSimpleDB reads do not run through the
companion.

## Constructor And Core API

```lua
local Profiles = LibStub("LibSimpleDBProfiles-1.0")
local manager = Profiles:New(storage, defaults)
local db = manager:GetActiveDB()
```

Proposed unified profile API:

```lua
manager:GetActiveDB()
manager:GetProfiles()
manager:GetSelectedProfile()
manager:GetActiveProfile()
manager:SetProfile(profileRef)
manager:CreateProfile(name)
manager:CopyProfile(sourceRef, destinationRef, options)
manager:ResetProfile(profileRef, options)
manager:RenameProfile(profileRef, newName)
manager:DeleteProfile(profileRef)
```

`SetProfile()` is the only selection endpoint. It accepts Automatic, permanent,
and user references. `CreateProfile()` returns a user reference suitable for
passing directly to `SetProfile()`.

Passing a missing user reference to `SetProfile()` creates that user profile
before selecting it. Selecting the active profile in the same mode is a no-op.

`GetSelectedProfile()` returns the detached profile descriptor chosen by the
current character. `GetActiveProfile()` returns the detached descriptor whose
table supplies `activeDB`. Under Automatic these are different descriptors;
under a forced permanent or user profile they describe the same entry.

## Profile Operations

### Select

Selecting a user profile stores its normalized name for the current character.
Selecting a permanent profile stores its permanent profile type. Selecting
Automatic removes the current character's stored selection and immediately
runs automatic resolution.

An explicit user or permanent profile remains selected until another profile
reference is passed to `SetProfile()`.

### Create

`CreateProfile(name)` creates an empty user profile, rejects existing and
reserved names, and returns its typed reference. It does not select the profile
unless the returned reference is passed to `SetProfile()`.

### Copy

Copy only raw overrides. The destination receives a detached deep copy so
profiles never share nested tables.

Automatic may be used as a source and copies from its active permanent profile.
Automatic cannot be a destination because it owns no storage. Permanent and
user profiles may be destinations. Copying into an existing destination
requires `{ overwrite = true }`.

### Reset

`ResetProfile()` resets the supplied profile or the active profile when no
reference is supplied. Reset clears raw data in place and preserves table
identity.

Permanent profiles are never removed by reset. An explicitly selected
permanent profile stays selected after becoming empty. An explicitly selected
user profile also stays selected.

When Automatic is selected, resetting its active permanent profile keeps the
character in Automatic mode. If that profile becomes empty, Automatic
immediately selects the next less-specific non-empty permanent profile. Global
remains selected when every permanent profile is empty.

The explicit option below resets an active forced profile and then returns the
character to Automatic:

```lua
manager:ResetProfile(nil, {
    setAutomatic = true,
})
```

The option is rejected when resetting an inactive profile because changing the
current character's selection would be unrelated to that target.

### Rename

Only user profiles can be renamed. Move the stored table without copying it,
update every stored user selection referring to the old name, and preserve the
active data table when renaming the active profile.

Renaming a permanent or Automatic profile is rejected. Renaming to an existing
or reserved name is rejected.

### Delete

Permanent profiles and Automatic cannot be deleted. There is no public or
internal scope-deletion operation.

Only user profiles can be deleted. Deleting the active user profile is rejected.
Deleting an inactive user profile removes every stored selection referring to
it so those characters return to Automatic. Deletion never leaves a selection
pointing at missing data.

## Lifecycle And Callback Contract

Any active-root switch is a bulk data change:

- `activeDB:SetData()` fires LibSimpleDB `OnDataChanged`.
- It does not synthesize per-path callbacks.
- Cached consumers perform a full settings refresh after a switch.

The companion provides stable-snapshot, error-isolated lifecycle callbacks:

```text
OnProfileChanged(manager, newSelectedProfile, oldSelectedProfile,
    newActiveProfile, oldActiveProfile)
OnProfileCreated(manager, profile)
OnProfileCopied(manager, sourceProfile, destinationProfile, overwritten)
OnProfileRenamed(manager, oldProfile, newProfile)
OnProfileDeleted(manager, profile)
OnProfileReset(manager, profile)
```

Callback profile arguments are detached descriptors. `OnProfileChanged` fires
whenever the selected or active profile changes. When the active table changes,
it fires after `activeDB:SetData()` and the resulting LibSimpleDB
`OnDataChanged`. It is the single source of truth for UI that manages or
displays profiles.

Resetting the selected Automatic profile may dispatch `OnProfileReset` for the
active permanent profile followed by `OnProfileChanged` when Automatic falls
to another permanent profile.

Features that care only that effective data changed, and not profile identity,
listen to the active LibSimpleDB instance's `OnDataChanged`. They do not also
listen to `OnProfileChanged` for the same refresh path.

## Ownership And Validation

- Retain the outer consumer storage table by reference for persistence.
- Require account-wide `SavedVariables`, not `SavedVariablesPerCharacter`.
- Copy defaults through LibSimpleDB; never insert them into raw profile data.
- Normalize every current permanent profile table during construction.
- Normalize the user-profile and selection containers before resolution.
- Repair or remove malformed stored selections before exposing the active DB.
- Never derive canonical identity from localized display names.
- Never use a display name as a permanent profile's storage identity.
- Never create cross-profile, cross-addon, or outer-container reference cycles.
- Stored values follow LibSimpleDB's SavedVariables-compatible data model.

## Migration

An existing flat database cannot become its own nested permanent profile
because that would create a SavedVariables cycle:

```lua
-- Invalid
oldData.global = oldData
```

Migration requires a new outer container:

```lua
local oldData = MyAddonDB

MyAddonDB = {
    global = oldData,
    realms = {},
    characters = {},
    classes = {},
    specs = {},
    factions = {},
    profiles = {},
    selections = {},
}
```

Each consumer owns its schema version and decides whether legacy data belongs
in Global, a user profile, or another permanent profile. Migration runs before
the companion exposes the active database.

## Dependency And Packaging

Load order in a consumer package:

```text
Libs\LibStub\LibStub.lua
Libs\LibSimpleDB-2.0\embed.xml
Libs\LibSimpleDBProfiles-1.0\embed.xml
```

The companion fails clearly when `LibSimpleDB-2.0` or its required minor is
unavailable. Consumer packages pin reviewed Git tags for both libraries rather
than copying working-tree source manually.

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

The scaffold phase adds `.editorconfig` and `.gitattributes` with UTF-8, LF,
final-newline, and spaces-only policy before source files are created.

## Test Plan

- Constructor validation and first-load storage normalization
- Account-wide SavedVariables contract documentation
- Canonical nonlocalized realm, character, class, spec, and faction keys
- Localized permanent-profile display names that never become storage keys
- Failure behavior when required player identity is unavailable
- Independent managers and SavedVariables containers for two consumer addons
- No consumer profile data retained on the shared LibStub library table
- Unified descriptors for Automatic, permanent, and user profiles
- Descriptor selected/active states, capability flags, and detached reference
  snapshots
- Automatic `Character > Specialization > Class > Realm > Faction > Global`
  resolution using non-empty raw data
- Global fallback when every permanent profile is empty
- Whole-database selection with no per-path merging
- Stable active DB identity across every profile change
- Forced permanent, forced user, and return-to-Automatic persistence
- Specialization changes in Automatic, forced Specialization, other permanent,
  and user-profile modes
- User profile names colliding with reserved current display names
- Future/localized display-name collision disambiguation through typed refs
- User profile creation through a missing user reference passed to
  `SetProfile()`
- Copy between permanent and user profiles without aliasing
- Explicit copy overwrite and invalid Automatic destination behavior
- Permanent and user reset behavior
- Automatic reset fallthrough to a less-specific permanent profile
- Explicit reset-and-return-to-Automatic behavior
- Permanent rename/delete rejection
- Active user-profile deletion rejection
- Stored selection repair after user-profile rename or deletion
- Same-profile selection no-op behavior
- `OnDataChanged` and `OnProfileChanged` ordering and arguments
- No path callbacks synthesized during root switches or bulk operations
- Callback mutation snapshots and error isolation
- UTF-8 user profile names in Chinese, Japanese, Korean, Cyrillic, Arabic, and
  accented Latin scripts
- Invalid UTF-8, ASCII controls, whitespace normalization, case sensitivity,
  and unrestricted user-profile name length
- Reload persistence using the documented storage schema
- Flat-database migration without cycles or shared tables
- Actual `LibSimpleDB-2.0` dependency with both embedded load orders where valid
- Same-family companion minor upgrades before and after manager creation
- Multiple embedded copies and lower/newer companion minors
- Lua 5.1 syntax and unsupported-value/error contracts

## Performance Scope

No standalone benchmark suite is required. Profile selection and management are
infrequent operations outside combat-sensitive hot paths. The stable active
LibSimpleDB instance keeps ordinary reads outside the companion.

## Implementation Sequence

1. Keep the resolved contracts synchronized with API documentation and tests.
2. Scaffold repository text policy, license, metadata, LibStub declaration, and
   dependency check.
3. Write API documentation and storage/profile tests before implementation.
4. Implement storage normalization and canonical permanent-profile identity.
5. Implement profile references, descriptors, and capability validation.
6. Implement Automatic resolution and the stable active database.
7. Implement unified profile selection and lifecycle dispatch.
8. Implement user create, copy, reset, rename, and delete operations.
9. Add specialization-change handling, migrations, and tagged-dependency tests.
10. Smoke-test two independent consumers and one migrated LibSimpleDB consumer.
11. Review, tag `1.0.0`, then pin the companion from migrated consumers.

## Resolved Contract Decisions

- Profile is the only public selection concept; internal scopes are presented as
  permanent profiles.
- Permanent profiles are Character, Specialization, Class, Realm, Faction, and
  Global.
- Permanent profiles can be empty, selected, modified, copied, and reset, but
  never renamed or deleted.
- Automatic is a virtual permanent profile and owns no data table.
- Automatic priority is Character, Specialization, Class, Realm, Faction, then
  Global.
- Automatic skips empty permanent profiles except Global.
- Automatic resolution selects one complete database and never merges less-
  specific profiles per path.
- A forced profile remains selected when reset; Automatic falls through after
  its active profile becomes empty.
- `SetProfile()` is the only selection endpoint and accepts typed references.
- Profile descriptors expose capabilities for consumer UI generation.
- Every consumer owns an independent account-wide SavedVariables container.
- The library derives canonical, nonlocalized permanent-profile storage keys.
- User profile names are normalized UTF-8 keys and may use any language.
- Typed references prevent permanent/user display-name collisions from
  selecting incorrect data.
- User profile copy requires explicit overwrite intent; rename never
  overwrites.
- Permanent and Automatic deletion are rejected; deleting the active user
  profile is rejected.
- `OnProfileChanged` is authoritative for profile-aware UI refreshes.
- LibSimpleDB `OnDataChanged` is authoritative for profile-agnostic data-root
  refreshes.
- Benchmarks are not a release requirement.
