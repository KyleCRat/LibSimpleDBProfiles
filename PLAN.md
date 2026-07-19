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

When a character has no stored selection, the library performs one initial
specificity lookup, selects the most specific matching permanent profile, and
persists that selection. There is no virtual profile or continuing specificity
mode, and ordinary data changes never cause a profile switch.

Consumers use the same profile-selection, active-database, reset, copy, and
lifecycle APIs for permanent and user profiles. Internal canonical storage
remains separated because each permanent profile has different identity and
storage semantics, but the term `scope` is not part of the
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

Every consumer passes its required addon folder name and an addon-owned
account-wide SavedVariables table by reference:

```toc
## SavedVariables: MyAddonDB
```

```lua
local addonName = ...
local manager = Profiles:New(addonName, MyAddonDB, defaults)
```

`addonName` is the required addon folder name supplied to addon Lua files. The
manager uses the addon's TOC `Title` as its default runtime display name, falling
back to `addonName` when no title is available. Consumers may override only the
presentation label:

```lua
local manager = Profiles:New(addonName, MyAddonDB, defaults, {
    displayName = "My Profiles",
})
```

There is no addon-name override, database identifier, or storage-key option.
`displayName` is runtime-only and is never stored in SavedVariables.

Do not use character-specific SavedVariables for manager storage:

```toc
## SavedVariablesPerCharacter: MyAddonDB
```

A per-character table would isolate every permanent and user profile to one
character and prevent cross-character sharing. The storage argument is still only
a table reference; `addonName` does not reveal which TOC field declared that
table. Account-wide ownership therefore remains a documented consumer
requirement.

The outer table is the consumer namespace. Profile data must never be stored on
the shared LibStub library table.

Two addons using the library remain independent:

```lua
local managerA = Profiles:New("AddonA", AddonADB, defaultsA)
local managerB = Profiles:New("AddonB", AddonBDB, defaultsB)
```

A permanent Elemental profile in `AddonADB` is invisible to `AddonBDB`.
Consumers do not add another addon-name key inside their storage because their
outer SavedVariables table already supplies that namespace. Each addon must use
a unique TOC SavedVariables global name.

An addon needing independently selectable profile collections supplies separate
child tables. Multiple managers are an advanced case; ordinary modules should
normally share one manager and use nested active-database paths.

```lua
local settings = Profiles:New(addonName, MyAddonDB.settings, settingsDefaults, {
    displayName = "Settings Profiles",
})

local layout = Profiles:New(addonName, MyAddonDB.layout, layoutDefaults, {
    displayName = "Layout Profiles",
})
```

Every manager created by the same addon must supply an explicit, unique
`displayName` when more than one manager is live. Creating the additional manager
raises a usage error when an existing same-addon manager lacks an explicit label
or the labels collide. A single manager may omit the option and use the TOC-title
default.

Only one live manager may own a given storage table. Passing the same table to
`New()` again raises a clear usage error, even when the same defaults are
supplied.

The library tracks live storage ownership in a non-persistent weak registry.
The registry must not keep a manager, storage table, or consumer data alive and
must survive compatible LibStub minor upgrades. Distinct child tables remain
independent and may each have their own manager.

## Storage Schema

Permanent profiles retain canonical internal containers. User profiles retain
their normalized name as their exact storage key:

```lua
MyAddonDB = {
    __lsdbProfiles = {
        schema = 1,
    },
    global = {},
    realms = {
        ["3676"] = {},
    },
    characters = {
        ["Player-3676-01234567"] = {},
    },
    characterInfo = {
        ["Player-3676-01234567"] = {
            name = "Example",
            realmID = "3676",
            realmName = "Area 52",
            class = "SHAMAN",
            classID = 7,
            faction = "Horde",
            specID = "262",
            level = 80,
            lastSeen = 1784246400,
        },
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

`storage.__lsdbProfiles.schema` is the library-owned integer storage-schema
version. Consumers must not write or migrate this metadata. It is independent
of the companion's LibStub minor, Git version, and any addon-data schema stored
inside individual profiles.

A forced permanent-profile selection stores the permanent profile type rather
than its current derived identity key:

```lua
storage.selections[characterGUID] = {
    kind = "permanent",
    profile = "class",
}
```

`characterGUID` is the current logged-in character's `UnitGUID("player")`, such
as `Player-3676-01234567`. It is not an account GUID. The outer SavedVariables
table is account-wide, while this key gives each character its own stored profile
selection.

`storage.characterInfo` is library-owned roster metadata. `New()` records the
current character's name, realm ID and name, class token and ID, faction, current
spec ID when available, level, and `time()` as `lastSeen`. Canonical identifiers
remain nonlocalized; UIs derive localized class and specialization names. The
library updates fields when it observes relevant identity changes and migrates
this container as part of its internal schema.

No stored selection means the character has not been initialized. Construction
performs the initial profile selection and persists the resulting permanent
profile reference:

```lua
storage.selections[characterGUID] = nil
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
construction and is never deleted by ordinary profile operations. A table may be
empty, but its permanent profile remains selectable and resettable. Explicitly
forgetting an offline Character record through the advanced administration API
is the sole character-instance cleanup operation and does not remove the
permanent Character profile type.

The library never automatically prunes historical character or other canonical
identity data based on age, last login, or whether an identity is current. The
advanced administration API below enumerates and manages inactive stored
instances without changing the ordinary profile-selection API.

`New()` must run after the consumer's SavedVariables are loaded and player
identity APIs are available. It fails clearly when required identity cannot be
resolved. Specialization is the exception: an unavailable or zero specialization
ID is treated as no usable Specialization profile during initial selection. The
lookup continues with Class and persists the resulting selection. It does not
revise that selection if specialization data becomes available later.

The library does not defer `New()` through `PLAYER_LOGIN`. A transparently
deferred constructor could not return a fully usable manager or active database
synchronously. Consumers do not need to wrap construction in a login callback
solely for specialization readiness.

The library listens for `ACTIVE_PLAYER_SPECIALIZATION_CHANGED`:

- A forced Specialization profile follows the new active specialization and
  stays explicitly selected even when the new profile is empty.
- A forced user or other permanent profile remains unchanged.

Tests mock identity APIs. The public API does not expose arbitrary identity
overrides solely for tests.

## Profile References

Profile selection uses typed references, never visible names alone. This keeps
permanent and user profiles unambiguous even when their display names match.

```lua
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

## Profile Descriptors

`GetProfiles()` returns descriptors for every current permanent profile and
every user profile. Consumers can build one selector without knowing separate
selection APIs.

```lua
{
    ref = {
        kind = "permanent",
        profile = "spec",
    },
    displayName = "Elemental",
    permanent = true,
    active = true,
    hasData = true,
    nameCollision = false,
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
    active = false,
    hasData = true,
    nameCollision = false,
    canReset = true,
    canRename = true,
    canDelete = true,
}
```

`active` identifies the single selected profile supplying `activeDB` data.

Descriptors expose capabilities so a consumer UI can disable unsupported
commands without hard-coding profile kinds. Library methods still enforce the
same rules when called directly.

`displayName` is always the unqualified localized permanent name or exact
normalized user name. `nameCollision` is true when another descriptor in the
current result has the same display name. The library never appends a
presentation qualifier to `displayName`. A consumer may render a colliding user
profile as `Elemental (Custom)`, substitute different localized text or an icon,
group it separately, or omit the qualifier. The typed `ref` remains the
authoritative distinction regardless of presentation.

The default descriptor order is:

```text
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

User profile names may match permanent-profile display names, including fixed
category labels and identity-derived names. Typed references remain authoritative
and `nameCollision` lets a consumer qualify current collisions without
renaming stored data. Collisions introduced by a future character or locale are
recomputed whenever descriptors are requested.

## Initial Profile Selection

With no stored character selection, construction chooses the first permanent
profile containing raw data:

```text
Character > Specialization > Class > Realm > Faction > Global
```

Global is always the final fallback even when empty. Other empty permanent
profiles are skipped during initial selection but remain valid explicit
selections.

For this lookup, a profile contains raw data exactly when
`next(rawProfileTable) ~= nil`. The library does not recursively discard empty
structural tables or compare stored values with defaults. This keeps selection
independent of defaults that may change between addon versions. Consumers and
migrations should avoid writing empty structural branches when they intend a
profile to be treated as empty.

An Elemental Shaman with an empty Character profile uses the non-empty
Elemental profile. When Elemental is empty, initial selection checks Shaman,
then the current realm, faction, and Global.

Initial selection persists the chosen permanent profile type for the current
character. It is a one-time choice, not a continuing mode. Later data changes do
not switch the active profile based on specificity.

Initial selection chooses one complete database. Values are not merged or
inherited per path across less-specific permanent profiles. LibSimpleDB
defaults remain the only per-path fallback for the active database.

Initial selection observes only the current manager's consumer-owned storage.
A matching Elemental profile in another addon's SavedVariables has no effect.

## Active-Root Architecture

The manager owns one stable LibSimpleDB instance:

```lua
local activeDB = LibSimpleDB:New(activeProfileData, defaults)
```

Profile changes rebind that instance:

```lua
activeDB:SetData(newActiveProfileData)
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
binding occurs only during initialization, selection, identity, or
profile-management changes. Ordinary LibSimpleDB reads do not run through the
companion.

## Constructor And Core API

```lua
local Profiles = LibStub("LibSimpleDBProfiles-1.0")
local manager = Profiles:New(addonName, storage, defaults, options)
local db = manager:GetActiveDB()
```

`options` is optional and currently accepts only `displayName`.

Proposed unified profile API:

```lua
manager:GetActiveDB()
manager:GetProfiles()
manager:GetActiveProfile()
manager:SetProfile(profileRef)
manager:CreateProfile(name)
manager:CopyProfile(sourceRef, destinationRef)
manager:ResetProfile(profileRef)
manager:RenameProfile(profileRef, newName)
manager:GetProfileUsage(profileRef)
manager:DeleteProfile(profileRef)
```

`SetProfile()` is the only selection endpoint. It accepts permanent and user
references. `CreateProfile()` returns a user reference suitable for passing
directly to `SetProfile()`.

Passing a valid missing user reference to `SetProfile()` creates the empty user
profile and selects it in one operation. Selecting an existing active profile is
a no-op. Creation through selection applies the same name normalization,
validation, and duplicate-user-name policy as `CreateProfile()`. A matching
permanent-profile display name is valid.

`GetActiveProfile()` returns the detached descriptor whose table supplies
`activeDB`.

## Failure Contract

Programming errors throw with a clear usage message. These include invalid
argument types, malformed or unknown profile-reference kinds, unsupported
permanent profile identifiers, invalid option types, duplicate construction for
one storage table, missing or invalid `addonName`, invalid same-addon manager
labels, and attempts to rename or delete a permanent profile.

Corrupt required storage state also throws rather than silently discarding data.
Recognized older library schemas and missing owned containers are repaired by the
automatic migration contract. Wrong-type containers, invalid schema metadata,
unknown future schemas, and unrecognized selection records still throw. A
structurally valid user selection whose named profile no longer exists is a
recognized recoverable state: construction clears it and performs normal initial
selection for that character.

Expected user-facing conflicts return `nil, errorCode` and do not mutate storage,
rebind the active database, or dispatch callbacks. Initial stable codes are:

| Error code | Meaning |
|---|---|
| `INVALID_NAME` | User-supplied name fails normalization or validation |
| `PROFILE_EXISTS` | Normalized user-profile name already exists |
| `PROFILE_NOT_FOUND` | An operation requires an existing profile that is missing |
| `ACTIVE_PROFILE` | Requested operation is prohibited for the active profile |
| `CHARACTER_NOT_FOUND` | An administration operation requires an unknown character |
| `CURRENT_CHARACTER` | Requested administration operation cannot target the current character |

Codes are additive once published and are never used as localized display text.

## Profile Operations

### Select

Selecting a user profile stores its normalized name for the current character.
Selecting a permanent profile stores its permanent profile type.

An explicit user or permanent profile remains selected until another profile
reference is passed to `SetProfile()`.

### Create

`CreateProfile(name)` creates an empty user profile, rejects an existing
normalized name, and returns its typed reference. It does not select the profile
unless the returned reference is passed to `SetProfile()`. A permanent-profile
display-name match is valid and does not count as an existing user profile.

### Copy

Copy only raw overrides. The destination receives a detached deep copy so
profiles never share nested tables.

Permanent and user profiles may be sources and destinations. A valid missing user
destination is created and populated in the same operation. An existing
destination is replaced whether empty or non-empty; the library does not require
an overwrite option or attempt to prove user confirmation.

Human confirmation is a consumer-UI responsibility. Profile selectors use the
destination descriptor's `hasData` field to decide whether to prompt before
calling `CopyProfile()`. Headless consumers may intentionally overwrite in one
call.

Copying a profile onto itself succeeds as a no-op. It returns the destination
descriptor with `overwritten = false` and performs no copying, mutation, table
replacement, or callback dispatch.

For every other copy, build and validate the detached deep copy before mutating
the destination. `CopyProfile()` returns the destination descriptor and an
`overwritten` boolean that is true only when the destination contained raw data
before the copy.

Creating a missing destination dispatches `OnProfileCreated`, then
`OnProfileCopied`. Copying into an inactive existing destination dispatches only
`OnProfileCopied`.

Copying into the active profile replaces its stored raw table, keeps the
LibSimpleDB object stable, and calls `activeDB:SetData(copiedTable)`. LibSimpleDB
therefore dispatches `OnDataChanged` before the manager dispatches
`OnProfileCopied`. It does not synthesize path callbacks or dispatch
`OnProfileChanged` because active profile identity did not change.

### Reset

`ResetProfile()` resets the supplied profile or the active profile when no
reference is supplied. Reset clears raw data in place and preserves table
identity.

Permanent profiles are never removed by reset. An explicitly selected
permanent profile stays selected after becoming empty. An explicitly selected
user profile also stays selected.

### Rename

Only user profiles can be renamed. Move the stored table without copying it,
update every stored user selection referring to the old name, and preserve the
active data table when renaming the active profile.

Renaming a permanent profile is rejected. Renaming to an existing normalized
user name is rejected. Renaming to a permanent-profile display name is valid.

### Delete

Permanent profile types cannot be deleted through `DeleteProfile()`. Advanced
`ForgetCharacter()` removes one offline character's stored record and roster
metadata, not the permanent Character profile type.

Only user profiles can be deleted. Deleting the active user profile is rejected.
Any inactive user profile may be deleted, including one selected by offline
characters. Deletion requires neither an overwrite flag nor a replacement
profile.

`GetProfileUsage(profileRef)` returns a detached usage descriptor with
`selectionCount` and `characters`. The character list contains the same detached
metadata descriptors used by the administration API. Consumers may use this
information to show a confirmation dialog before deletion, but the library does
not require or attempt to verify confirmation.

Deletion gathers all affected characters before mutation, removes the user
profile, and clears every matching stored selection as one operation. It returns
the deleted profile descriptor and the affected character list. Each affected
character is then equivalent to one with no stored selection. Its next
construction runs normal initial selection using that character's identity at
login and persists the result. No replacement is selected while the character is
offline.

Construction applies the same recovery when it encounters a structurally valid
user selection whose profile is already missing, such as after an external
SavedVariables edit. This recognized dangling reference is cleared and
reinitialized rather than treated as corrupt storage.

## Advanced Administration API

The normal consumer obtains an administration object from its own manager:

```lua
local admin = manager:GetAdmin()

admin:GetCharacters()
admin:GetProfiles()
admin:GetProfileUsage(recordRef)
admin:GetSelection(characterGUID)
admin:SetSelection(characterGUID, profileRef)
admin:ResetProfile(recordRef)
admin:CopyProfile(sourceRecordRef, destinationRecordRef)
admin:ForgetCharacter(characterGUID)
```

The object is scoped exclusively to the manager's consumer-owned storage table.
It requires no global registry and cannot see another manager's SavedVariables.

A future standalone SimpleDBAdmin may enumerate the existing weak live-manager
registry. Each live manager exposes its required `addonName` and resolved
`displayName` for grouping. This discovery hook is optional infrastructure for
that standalone addon; normal consumers continue to call only their own
`manager:GetAdmin()`. Disabled or not-yet-loaded addons have no live manager and
cannot be administered generically in that session.

`GetCharacters()` returns detached metadata and selection descriptors for the
union of GUIDs found in `characterInfo`, `characters`, and `selections`.
`GetProfiles()` returns detached descriptors for every stored user profile and
every exact permanent identity instance, including inactive character, realm,
class, specialization, and faction keys. Descriptors expose exact `recordRef`,
`hasData`, character-selection references, and capability flags.
`GetProfileUsage(recordRef)` returns the detached usage descriptor for one exact
record. The ordinary manager method accepts a selection reference; the
administration method accepts the exact record references returned by
`admin:GetProfiles()`.

Administration is intentionally profile-level. It supports enumeration,
selection, copy, reset, and explicit character cleanup, but does not expose raw
profile tables or create inactive LibSimpleDB instances for schema-specific
settings editing.

`ResetProfile(recordRef)` clears the exact record's raw overrides but retains its
record, character metadata, and selection. `ForgetCharacter(characterGUID)`
explicitly removes that GUID's Character data, `characterInfo`, and stored
selection. It does not remove shared realm, class, specialization, faction,
Global, or user-profile data. Forgetting the current character returns
`nil, "CURRENT_CHARACTER"` without side effects.

`SetSelection()` allows an administration UI to change a known offline
character's stored user or permanent profile selection. The current character
continues to use normal `SetProfile()` so the active database and established
callbacks remain authoritative.

Exact offline `recordRef` values are administration handles, not ordinary
selection references, and are rejected by `SetProfile()`. Administration
mutations use manager validation and existing profile lifecycle events. Offline
selection changes and explicit character cleanup additionally emit
`OnCharacterSelectionChanged` and `OnCharacterForgotten` so management UIs never
need to watch SavedVariables directly.

## Lifecycle And Callback Contract

Any active-root switch is a bulk data change:

- `activeDB:SetData()` fires LibSimpleDB `OnDataChanged`.
- It does not synthesize per-path callbacks.
- Cached consumers perform a full settings refresh after a switch.

The manager mirrors LibSimpleDB's lifecycle registration surface:

```lua
manager:RegisterLifecycleCallback(event, callback)
manager:UnregisterLifecycleCallback(event, callback)
manager:UnregisterAllLifecycleCallbacks(callback)
```

Callbacks receive `(manager, event, ...)`. Registering the same callback for the
same event more than once is idempotent. `UnregisterLifecycleCallback()` returns
whether the callback was registered. `UnregisterAllLifecycleCallbacks()` removes
every lifecycle callback when called without an argument, or removes one
function from every event when supplied a callback.

The companion provides stable-snapshot, error-isolated lifecycle events:

| Event | Additional arguments |
|---|---|
| `OnProfileChanged` | `newProfile, oldProfile` |
| `OnProfileCreated` | `profile` |
| `OnProfileCopied` | `sourceProfile, destinationProfile, overwritten` |
| `OnProfileRenamed` | `oldProfile, newProfile` |
| `OnProfileDeleted` | `profile, affectedCharacters` |
| `OnProfileReset` | `profile` |
| `OnCharacterInfoChanged` | `newCharacter, oldCharacter` |
| `OnCharacterSelectionChanged` | `character, newProfile, oldProfile` |
| `OnCharacterForgotten` | `character` |

Callback profile arguments are detached descriptors. `OnProfileChanged` fires
whenever the active profile changes. It fires after `activeDB:SetData()` and the
resulting LibSimpleDB `OnDataChanged`. It is the authoritative source for UI
reacting to an active profile selection change. A UI displaying the full profile
list also listens to the create, copy, rename, delete, and reset lifecycle events
as needed.

When `SetProfile()` creates a missing user profile, dispatch order is
`OnProfileCreated`, LibSimpleDB `OnDataChanged`, then `OnProfileChanged`.
Consumers must discard or refresh cached profile descriptors after rename and
delete lifecycle events; detached references are snapshots and are not rewritten
in place.

Other settled ordering rules are:

- Selecting an existing profile dispatches LibSimpleDB `OnDataChanged`, then
  `OnProfileChanged`.
- Resetting the active profile dispatches LibSimpleDB `OnReset`, then
  `OnProfileReset`.
- Renaming the active user profile dispatches only `OnProfileRenamed`; neither
  its data nor active database changes.
- Deleting a referenced inactive user profile clears all matching selections,
  dispatches `OnCharacterSelectionChanged(character, nil, oldProfile)` once for
  each affected character, then dispatches
  `OnProfileDeleted(profile, affectedCharacters)`.
- Creating, copying, renaming, resetting, or deleting an inactive profile emits
  its corresponding companion event without a LibSimpleDB active-data event.

Copying into the active profile dispatches LibSimpleDB `OnDataChanged` before
`OnProfileCopied`.

Features that care only that effective data changed, and not profile identity,
listen to the active LibSimpleDB instance's `OnDataChanged`. They do not also
listen to `OnProfileChanged` for the same refresh path.

## Ownership And Validation

- Retain the outer consumer storage table by reference for persistence.
- Require account-wide `SavedVariables`, not `SavedVariablesPerCharacter`.
- Copy defaults through LibSimpleDB; never insert them into raw profile data.
- Normalize every current permanent profile table during construction.
- Normalize the user-profile and selection containers before initial selection.
- Create missing library-owned containers, but never replace a present value of
  the wrong type.
- Automatically migrate every recognized older library schema before exposing
  its manager or active database.
- Reject invalid schema metadata, unknown future schemas, wrong-type containers,
  and unrecognized selection records without discarding data.
- Treat a recognized user selection that names a missing user profile as an
  uninitialized character selection and run normal initial selection.
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

MyAddonDB = { global = oldData }
```

The consumer decides that its legacy flat data belongs in Global and creates the
new outer table. `New()` supplies the remaining library-owned containers and
schema metadata.

Each consumer owns its addon-data schema version and migrations inside profile
payloads. The companion treats those payloads as opaque and owns migrations only
for `__lsdbProfiles`, permanent-profile containers, `profiles`, and `selections`.
`characterInfo` is also library-owned and migrates with those containers.

On `New()`, the library:

1. Validates the schema marker and owned container types.
2. Initializes a fresh or recognized unversioned schema-1 container.
3. Runs each registered migration sequentially from the stored schema to the
   current schema.
4. Validates the resulting structure and exposes the manager only after every
   step succeeds.

Each migration preserves raw profile payloads and records its new schema number
only after that step succeeds. Migration failures throw without replacing
unrecognized data. A stored schema newer than the running library also throws so
an older embedded copy cannot downgrade the structure.

A higher compatible LibStub minor that loads after live managers exist migrates
each live manager through the ownership registry before using the new structure.
The manager and active LibSimpleDB object remain stable. If migration moves the
active raw table, the library rebinds it and emits LibSimpleDB `OnDataChanged`;
it emits `OnProfileChanged` only if active profile identity also changes. A
structure change that cannot preserve these live-manager guarantees requires a
new incompatible library family rather than a compatible minor.

Internal schema migration does not imply public API compatibility. A release
that changes consumer call sites follows the library's incompatible-version
policy, but consumers still do not manually migrate library-owned storage.

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
- Required addon folder name, TOC-title display fallback, optional runtime
  `displayName`, and no persisted presentation metadata
- Multiple same-addon managers require explicit unique labels, while a single
  manager needs no options table
- Account-wide SavedVariables contract documentation
- Canonical nonlocalized realm, character, class, spec, and faction keys
- Localized permanent-profile display names that never become storage keys
- Failure behavior when required player identity is unavailable
- Initial selection skips an unavailable or zero specialization ID, persists the
  next matching profile, and does not later promote the selection
- Independent managers and SavedVariables containers for two consumer addons
- Independent child-table managers for one addon retain separate selections,
  user profiles, defaults, callbacks, and administration objects
- Duplicate manager construction for the same storage table is rejected, while
  distinct child-table managers remain valid
- Weak live-manager ownership tracking does not persist consumer data or keep an
  otherwise unreachable manager alive
- No consumer profile data retained on the shared LibStub library table
- Historical identity data is retained regardless of age and is never
  automatically pruned
- Character roster metadata capture, canonical identifiers, and union-based
  enumeration across info, data, and selection containers
- Per-manager administration remains scoped to its consumer storage without a
  global registry
- Administration enumerates all stored permanent instances and user profiles
  through exact detached record descriptors
- Offline selection changes, reset versus forget behavior, current-character
  forget rejection, and administration lifecycle events
- Profile-level administration never exposes raw inactive profile databases
- Unified descriptors for permanent and user profiles
- Descriptor active state, capability flags, and detached reference snapshots
- One-time `Character > Specialization > Class > Realm > Faction > Global`
  initial selection using non-empty raw data
- Initial data detection using `next(rawProfileTable) ~= nil`, independent of
  nested empty tables and LibSimpleDB defaults
- Global fallback when every permanent profile is empty
- Immediate persistence of the initial selection
- No selection change when a more-specific profile later gains or loses data
- Whole-database selection with no per-path merging
- Stable active DB identity across every profile change
- Permanent- and user-profile selection persistence
- Specialization changes while Specialization, another permanent profile, or a
  user profile is active
- Permanent/user display-name collisions remain valid and are reported through
  `nameCollision` without modifying `displayName`
- Consumer-controlled collision presentation using typed refs, localized text,
  icons, grouping, or no qualifier
- Atomic user-profile creation through a missing reference passed to
  `SetProfile()`, including lifecycle callback order
- Copy between permanent and user profiles without aliasing
- Missing-destination creation, unconditional replacement, same-profile no-op,
  detached copy construction, and returned `overwritten` state
- Permanent and user reset behavior
- Active profile remains active after reset
- Permanent rename/delete rejection
- Active user-profile deletion rejection
- Stored selection updates after user-profile rename
- Usage enumeration for active, unreferenced, and multiply referenced profiles
- Referenced inactive user-profile deletion without a replacement, including
  cleared stored selections, returned affected characters, and callback order
- Missing user-profile selection recovery through normal initial selection on
  the affected character's next login
- Same-profile selection no-op behavior
- Usage and corrupt-state failures throw, while expected user conflicts return
  `nil, stableCode` without mutation or callbacks
- Stable error codes for invalid names, duplicate names, missing profiles, and
  active profile restrictions
- `OnDataChanged` and `OnProfileChanged` ordering and arguments
- Lifecycle registration parity with LibSimpleDB, including idempotent duplicate
  registration, targeted removal, and all-event cleanup
- No path callbacks synthesized during root switches or bulk operations
- Callback mutation snapshots and error isolation
- Reset, rename, inactive-operation, and create-and-select callback ordering
- UTF-8 user profile names in Chinese, Japanese, Korean, Cyrillic, Arabic, and
  accented Latin scripts
- Invalid UTF-8, ASCII controls, whitespace normalization, case sensitivity,
  and unrestricted user-profile name length
- Reload persistence using the documented storage schema
- Fresh, unversioned, recognized older, current, invalid, and unknown-future
  library schema handling
- Sequential automatic migrations preserve opaque profile payloads and commit
  schema markers only after successful steps
- Compatible LibStub schema upgrades migrate live managers while preserving the
  manager and active LibSimpleDB objects
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

1. Keep this plan, API documentation, and tests synchronized as implementation
   refines pre-release details without changing settled behavior implicitly.
2. Scaffold repository text policy, license, metadata, LibStub declaration, and
   dependency check.
3. Write API documentation and storage/profile tests before implementation.
4. Implement storage normalization and canonical permanent-profile identity.
5. Implement profile references, descriptors, and capability validation.
6. Implement one-time initial selection and the stable active database.
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
  never renamed or deleted through ordinary profile operations.
- Historical canonical identity data is never automatically deleted or pruned.
- Each manager exposes a storage-scoped profile administration API with character
  metadata, offline selection management, reset, copy, and explicit forget.
- Administration is profile-level and does not expose raw inactive databases.
- A character with no stored selection receives one initial permanent profile
  selection in Character, Specialization, Class, Realm, Faction, Global order.
- Initial selection skips empty permanent profiles except Global, persists its
  result immediately, and does not re-evaluate after later data changes.
- An unavailable or zero specialization ID is skipped during initial selection;
  construction is not deferred and the resulting lower-priority selection is
  not revised later.
- A permanent profile is non-empty for initial selection exactly when
  `next(rawProfileTable) ~= nil`; defaults are never consulted.
- Initial selection chooses one complete database and never merges less-specific
  profiles per path.
- The active profile remains selected when reset.
- `SetProfile()` is the only selection endpoint and accepts typed references.
- `SetProfile()` creates and selects a valid missing user profile; explicit
  `CreateProfile()` remains available for creation without selection.
- Profile descriptors expose capabilities for consumer UI generation.
- Every consumer owns an independent account-wide SavedVariables container.
- `New()` requires `addonName`; one manager defaults to the addon's TOC title,
  while multiple same-addon managers require explicit unique `displayName`
  values.
- The library versions and automatically migrates its owned storage structure;
  consumers migrate only their addon payload schema and never library containers.
- Only one live manager may own a storage table; duplicate construction is a
  usage error, while distinct child tables are independent.
- The library derives canonical, nonlocalized permanent-profile storage keys.
- User profile names are normalized UTF-8 keys and may use any language.
- Programming misuse and corrupt required state throw; expected user-facing
  conflicts return `nil, stableCode` without side effects.
- Typed references prevent permanent/user display-name collisions from
  selecting incorrect data.
- Display-name collisions are allowed; descriptors report them without baking a
  qualifier into the consumer-visible name.
- Profile copy creates a missing user destination, replaces existing destination
  data without an overwrite flag, and treats same-profile copy as a no-op.
- Permanent-profile deletion and active user-profile deletion are rejected.
- Referenced inactive user profiles may be deleted without a replacement.
  `GetProfileUsage()` exposes affected characters for optional consumer
  confirmation, and deletion clears their selections so normal initial selection
  runs on their next login.
- `OnProfileChanged` is authoritative for active-profile selection refreshes;
  other companion lifecycle events report management of inactive profiles.
- Manager lifecycle registration mirrors LibSimpleDB and dispatches
  `(manager, event, ...)` from error-isolated stable snapshots.
- LibSimpleDB `OnDataChanged` is authoritative for profile-agnostic data-root
  refreshes.
- Benchmarks are not a release requirement.
