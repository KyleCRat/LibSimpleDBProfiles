# LibSimpleDBProfiles Plan

## Status

The initial multi-file implementation, Lua 5.1 test suite, and YvBags consumer
integration are complete and verified on WoW 12.1.0. The `1.0.0` candidate is
ready for final review and tagging after the required core API has a reviewed
`2.0.0` tag.

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
        payloadVersion = 1,
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
of the companion's LibStub minor and Git version.

`storage.__lsdbProfiles.payloadVersion` is the integer schema version shared by
the consumer-owned payload inside every profile. The library initializes it to
1 without requiring migration setup from a new consumer. It advances only
through the optional consumer Migration contract. Library-schema migrations may
move profile payload tables, but they preserve those opaque tables and do not
interpret or independently change `payloadVersion`.

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
resolved. Specialization is the exception because its APIs can remain
unavailable during the consumer's `ADDON_LOADED`. The manager binds its stable
active database to the best currently resolvable profile but does not persist a
lower-priority initial choice while a Specialization profile could still outrank
it. It retries at `PLAYER_LOGIN` and completes the one-time search by
`PLAYER_ENTERING_WORLD`. If the player still has no specialization then, the
lower-priority result is persisted as the final selection.

The library does not defer `New()` through `PLAYER_LOGIN`. A transparently
deferred constructor could not return a fully usable manager or active database
synchronously. Consumers do not need to wrap construction in a login callback
solely for specialization readiness.

The library listens for `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD`, and
`ACTIVE_PLAYER_SPECIALIZATION_CHANGED`:

- A pending initial selection is finalized exactly once when specialization
  identity resolves, or at world entry for a player with no specialization.
- A stored relative Specialization selection remains pending instead of being
  discarded or throwing when its exact ID is temporarily unavailable.
- An explicit `SetProfile()` call cancels any pending initial search.
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

## Profile IDs

`profileRef` is a relative selectable identity. A permanent reference resolves
against the identity of the character being selected:

```lua
{ kind = "permanent", profile = "class" }
```

For the current Shaman this selects the Shaman Class profile; for an offline Mage
passed to `admin:SetSelection()` it selects the Mage Class profile.

`profileID` is one exact stored identity within one manager. Administration and
consumer payload migrations use IDs when they must target or describe a specific
stored profile independently of the current character:

```lua
{ kind = "permanent", profile = "class", key = "SHAMAN" }
{ kind = "permanent", profile = "character", key = characterGUID }
{ kind = "permanent", profile = "global" }
{ kind = "user", name = "Raid" }
```

User-profile references and IDs have the same structure because the normalized
name is already the exact identity. The Global permanent reference and ID also
have the same structure because there is only one Global profile per manager.
Their roles remain distinct in method contracts.

A `profileID` is unique only within its manager's storage. Consumers receive
detached IDs from descriptors and round-trip them to administration APIs;
consumer migration callbacks receive the same ID shape alongside each payload.
Consumers do not derive permanent keys from localized values, persist IDs in
their own data, or pass exact keyed permanent IDs to selection methods. A keyed
permanent `profileID` is rejected by `manager:SetProfile()` and
`admin:SetSelection()` so a character cannot be assigned another identity's
Character, Specialization, Class, Realm, or Faction profile.

## Profile Descriptors

`GetProfiles()` returns descriptors for every current permanent profile and
every user profile. Consumers can build one selector without knowing separate
selection APIs.

```lua
{
    profileRef = {
        kind = "permanent",
        profile = "spec",
    },
    profileID = {
        kind = "permanent",
        profile = "spec",
        key = "262",
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
    profileRef = {
        kind = "user",
        name = "Raid",
    },
    profileID = {
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

Every ordinary current-profile descriptor contains both its selectable
`profileRef` and exact `profileID`. Every administration profile descriptor
contains `profileID`, `displayName`, `permanent`, `active`, `hasData`,
`selectionCount`, and operation capability flags. An administration descriptor
contains `profileRef` only when selecting that relative reference resolves to
the same exact identity: user profiles and current-identity permanent profiles.
Descriptors for inactive historical permanent identities omit `profileRef`
rather than expose a misleading selection reference.

Descriptors expose capabilities so a consumer UI can disable unsupported
commands without hard-coding profile kinds. Library methods still enforce the
same rules when called directly.

`displayName` is always the unqualified localized permanent name or exact
normalized user name. `nameCollision` is true when another descriptor in the
current result has the same display name. The library never appends a
presentation qualifier to `displayName`. A consumer may render a colliding user
profile as `Elemental (Custom)`, substitute different localized text or an icon,
group it separately, or omit the qualifier. The typed `profileRef` remains the
authoritative selection distinction regardless of presentation.

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

`options` is optional. It accepts the runtime-only `displayName` override and an
optional validated consumer `migration` object. A new consumer needs neither.

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

## Success Contract

Public operations return a non-nil primary result on success. Mutations include a
second result only when the operation has meaningful additional state:

```text
SetProfile        -> activeDescriptor, changed
CreateProfile     -> userRef
CopyProfile       -> destinationDescriptor, overwritten
ResetProfile      -> profileDescriptor
RenameProfile     -> newDescriptor
GetProfileUsage   -> usageDescriptor
DeleteProfile     -> deletedDescriptor, affectedCharacters

admin:SetSelection     -> characterDescriptor, changed
admin:ResetProfile     -> profileDescriptor
admin:CopyProfile      -> destinationDescriptor, overwritten
admin:ForgetCharacter  -> forgottenCharacterDescriptor
```

The primary result determines how to interpret the second return. A non-nil
primary result means success and any second value is operation-specific state. A
nil primary result means the second value is the stable error code from the
failure contract.

Consumers that need only the primary result may assign the call to one local;
Lua discards later returns. The first value still distinguishes success from
failure, but ignoring the second value also intentionally discards the specific
error code or operation state.

Operations with a boolean second result return their current or destination
descriptor and `false` for a successful no-op. Selecting the already active
profile and copying a profile onto itself therefore remain distinguishable from
failure without producing mutations or callbacks.
`overwritten` reports whether the destination contained raw data before a copy;
it is not a generic `changed` result. Returned descriptors are detached snapshots
and may become stale after later mutations.

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
admin:GetProfileUsage(profileID)
admin:GetSelection(characterGUID)
admin:SetSelection(characterGUID, profileRef)
admin:ResetProfile(profileID)
admin:CopyProfile(sourceProfileID, destinationProfileID)
admin:ForgetCharacter(characterGUID)
```

The object is scoped exclusively to the manager's consumer-owned storage table.
It requires no global registry and cannot see another manager's SavedVariables.

A future standalone SimpleDBAdmin may call `Profiles:GetManagers()` to enumerate
the existing weak live-manager registry. Each live manager exposes its required
`addonName` and resolved
`displayName` for grouping. This discovery hook is optional infrastructure for
that standalone addon; normal consumers continue to call only their own
`manager:GetAdmin()`. Disabled or not-yet-loaded addons have no live manager and
cannot be administered generically in that session.

`GetCharacters()` returns detached character descriptors for the union of GUIDs
found in `characterInfo`, `characters`, and `selections`. Every character
descriptor contains `guid`. Known `name`, `realmID`, `realmName`, `class`,
`classID`, `faction`, `specID`, `level`, and `lastSeen` metadata is included;
historically unavailable fields are nil rather than guessed. The descriptor also
contains the stored `profileRef` when one exists and its resolved `profileID`
when sufficient identity metadata is available.

`GetProfiles()` returns detached descriptors for every stored user profile and
every exact permanent identity instance, including inactive character, realm,
class, specialization, and faction keys. Descriptors expose exact `profileID`,
`hasData`, selection usage, and capability flags.

`GetProfileUsage(profileID)` returns the detached usage descriptor for one exact
profile. It reports confirmed `selectionCount` and `characters` separately from
`unresolvedCharacters` whose stored permanent reference cannot be resolved
without missing historical metadata. The ordinary manager method accepts a
relative selection reference; the administration method accepts the exact
profile IDs returned by `admin:GetProfiles()`.

An exact `profileID` is never partial. Partial history means supporting character
metadata is missing while a GUID, Character payload, or relative selection still
exists. A permanent selection that cannot be resolved retains its `profileRef`,
reports no resolved `profileID`, and appears in `unresolvedCharacters` for the
applicable permanent type. It is not guessed, deleted, or reassigned while the
character is offline. Logging into that character refreshes its metadata and
resolves the selection.

User, Global, and Character selections can resolve without Class,
Specialization, Realm, or Faction metadata. Malformed reference shapes and
wrong-type containers remain corruption errors rather than partial history.

Administration is intentionally profile-level. It supports enumeration,
selection, copy, reset, and explicit character cleanup, but does not expose raw
profile tables or create inactive LibSimpleDB instances for schema-specific
settings editing.

`ResetProfile(profileID)` clears the exact profile's raw overrides but retains its
profile table, character metadata, and selection. `ForgetCharacter(characterGUID)`
explicitly removes that GUID's Character data, `characterInfo`, and stored
selection. It does not remove shared realm, class, specialization, faction,
Global, or user-profile data. Forgetting the current character returns
`nil, "CURRENT_CHARACTER"` without side effects.

`SetSelection()` allows an administration UI to change a known offline
character's stored user or permanent profile selection. The current character
continues to use normal `SetProfile()` so the active database and established
callbacks remain authoritative.

Exact permanent `profileID` values are administration handles, not ordinary
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

Callback profile arguments are detached descriptors. Every callback profile
descriptor contains its exact `profileID`. It contains a
`profileRef` only when selecting that relative reference resolves to the same
exact profile. `OnProfileChanged` fires whenever the active profile changes. It
fires after `activeDB:SetData()` and the resulting LibSimpleDB `OnDataChanged`.
It is the authoritative source for UI reacting to an active profile selection
change. A UI displaying the full profile list also listens to the create, copy,
rename, delete, and reset lifecycle events as needed.

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

### Legacy Flat Database Adoption

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

### Library Storage Schema Migrations

Library migrations own only `__lsdbProfiles`, the permanent-profile containers,
`profiles`, `selections`, and `characterInfo`. Consumer payload tables inside
those containers remain opaque. A library migration may move or rename a
container but must carry each payload table forward intact without interpreting
addon-specific fields.

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

### Consumer Payload Migrations

An addon may independently change the schema of the raw overrides stored inside
every profile. For example, it may move `display.scale` to
`appearance.scale`. The addon owns that transformation; library storage
migrations never interpret it. LibSimpleDBProfiles participates only because its
normal and administration APIs intentionally do not expose every inactive raw
profile table.

New consumers require no data-version declaration or migration scaffolding:

```lua
local manager = Profiles:New(addonName, storage, defaults)
```

The library silently initializes `payloadVersion` to 1. A consumer creates a
validated Migration object only in the first addon release that changes its
payload schema:

```lua
local Migration = Profiles:CreateMigration(3)

Migration:Add(1, Migrate1To2)
Migration:Add(2, Migrate2To3)

local manager = Profiles:New(addonName, storage, defaults, {
    migration = Migration,
})
```

`CreateMigration(3)` declares the current consumer payload version.
`Migration:Add(1, callback)` declares the version-1-to-version-2 step. The public
type is named `Migration`, not `MigrationPlan`, and individual steps are not
separate objects. `Migration:Add()` returns the Migration so chaining remains
optional.

The Migration holds no manager or storage state. It may live in a separate file,
be stored on the addon's namespace, and be passed to `New()` by the database
initialization file. The migration file loads after the embedded libraries and
before database initialization.

Consumer migration callbacks:

- Are added only when the addon changes its stored payload structure.
- Once introduced, continue to be supplied by every later addon release.
- Retain every supported historical step so older installations can migrate
  through every intermediate version.
- Mutate only the raw overrides supplied to the callback and never materialize
  LibSimpleDB defaults when an old override is absent.
- Treat the callback payload as the exact staged table for that invocation.
- Do not require a manager or active LibSimpleDB instance; neither is exposed
  until all required migrations finish.
- Use the detached exact `profileID` argument only when migration behavior
  genuinely depends on profile identity.

Migration construction validates all of the following before execution:

- The current consumer payload version is a positive integer.
- Every source version is a positive integer below the current version.
- Every registered migration is a function.
- A source version may be registered only once.
- Steps are continuous from version 1 through one less than the current version.
- The Migration was created by the active `LibSimpleDBProfiles-1.0` family.

The Migration becomes immutable when first supplied to `New()`.

After the library-owned storage schema is migrated and validated, consumer
payload migration executes as follows:

1. Compare the stored `payloadVersion` with the Migration's current version.
2. For each required version step, build staged detached copies of every stored
   permanent and user payload.
3. Invoke the consumer callback once per staged payload as
   `(data, profileID)`.
4. Validate every migrated result as SavedVariables-compatible data.
5. Commit the complete version step only after every payload succeeds, then
   advance `payloadVersion`.
6. Construct the stable active LibSimpleDB instance only after every required
   step commits.

A failed step does not partially commit. Previously completed version steps and
their version markers remain committed so the next load resumes from that
version. A stored `payloadVersion` newer than the Migration's declared current
version fails clearly instead of attempting a downgrade.

Fresh storage supplied with a Migration initializes directly at its current
version without running historical callbacks. Existing storage already at that
version also skips them. Omitting `migration` preserves the stored payload
version and performs no consumer-payload migration work.

### LibSimpleDB Boundary

The Migration API belongs only to LibSimpleDBProfiles. Base LibSimpleDB wraps one
table the consumer already owns and can migrate directly before calling
`LibSimpleDB:New()`. LibSimpleDB owns no SavedVariables container schema, should
not reserve consumer migration metadata, and does not mirror this API.

Profiles needs the hook because it alone owns enumeration of multiple
inaccessible inactive payloads. A separate general migration utility is deferred
unless direct-table migration logic later becomes meaningfully duplicated across
consumers.

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

## Repository Layout

```text
LibSimpleDBProfiles/
  .editorconfig
  .gitattributes
  AGENTS.md
  LibSimpleDBProfiles-1.0.lua
  Internal/
    Util.lua
    Identity.lua
    Storage.lua
    Descriptors.lua
  Migration.lua
  Manager.lua
  Operations.lua
  Admin.lua
  Events.lua
  Library.lua
  embed.xml
  README.md
  API.md
  CHANGELOG.md
  LICENSE
  PLAN.md
  tests/
    run.lua
    harness.lua
    libstub.lua
    manager.lua
    admin.lua
    migration.lua
    compatibility.lua
```

`.editorconfig` and `.gitattributes` enforce the repository's UTF-8, LF,
final-newline, and spaces-only policy.

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
- Initial selection remains provisional while specialization identity is late,
  then inherits a matching Specialization profile before persistence
- A stored Specialization selection remains pending until its exact identity is
  available, without replacing the stable active database
- World entry finalizes the lower fallback for a player who still has no
  specialization, and later specialization availability does not promote it
- An explicit selection cancels pending initial inheritance
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
  through detached descriptors containing exact `profileID` values
- Relative `profileRef` selection versus exact manager-local `profileID`
  administration, including rejection of keyed permanent IDs by selection APIs
- Complete exact IDs, optional historical character metadata, and separate
  resolved versus unresolved profile usage
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
- Persistence only after the initial selection is final, never for a transient
  provisional profile
- Readiness callback order and the absence of duplicate refresh work when later
  readiness events do not change the active profile
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
- Primary success results for every public operation, optional operation-specific
  second results, and consumers ignoring additional Lua returns
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
- Consumer Migration construction, validation, immutability, chaining, and
  separation from library-owned schema migrations
- Fresh, current, older, and future consumer `payloadVersion` behavior
- Staged consumer callbacks across every permanent and user payload, exact
  `profileID` arguments, SavedVariables validation, and version-step atomicity
- Consumer payload migrations finish before active LibSimpleDB construction and
  are not mirrored by base LibSimpleDB
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

Steps 1 through 10 are represented by the current implementation, automated
tests, and YvBags consumer integration. Final review, tagging, and dependency
pinning remain release work.

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
9. Add specialization-change handling, library schema migrations, consumer
   Migration support, and tagged-dependency tests.
10. Smoke-test YvBags as the initial migrated consumer. Validate additional
    consumers during future integrations and update the library as needed.
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
  result once identity readiness permits, and does not re-evaluate after later
  data changes.
- An unavailable or zero specialization ID does not defer construction. The
  active database uses a provisional resolvable profile while the one-time
  initial selection waits through login and finalizes by world entry. Once
  finalized, the selection is not revised later.
- A permanent profile is non-empty for initial selection exactly when
  `next(rawProfileTable) ~= nil`; defaults are never consulted.
- Initial selection chooses one complete database and never merges less-specific
  profiles per path.
- The active profile remains selected when reset.
- `SetProfile()` is the only selection endpoint and accepts typed references.
- `SetProfile()` creates and selects a valid missing user profile; explicit
  `CreateProfile()` remains available for creation without selection.
- Profile descriptors expose capabilities for consumer UI generation.
- `profileRef` is the relative selectable identity; `profileID` is the exact
  manager-local identity used by administration and consumer migrations.
- Historical character metadata may be incomplete, but exact `profileID` values
  are never partial and unresolved selections are never guessed or discarded.
- Every consumer owns an independent account-wide SavedVariables container.
- `New()` requires `addonName`; one manager defaults to the addon's TOC title,
  while multiple same-addon managers require explicit unique `displayName`
  values.
- The library versions and automatically migrates its owned storage structure;
  library migrations move consumer payloads opaquely and never interpret them.
- Consumer payloads silently begin at version 1. An addon supplies a validated,
  stateless Migration object only when it later needs to migrate every active and
  inactive payload through consumer-owned schema changes.
- The Profiles Migration API exists because inactive payloads are private; base
  LibSimpleDB consumers migrate their directly owned table before construction.
- Only one live manager may own a storage table; duplicate construction is a
  usage error, while distinct child tables are independent.
- The library derives canonical, nonlocalized permanent-profile storage keys.
- User profile names are normalized UTF-8 keys and may use any language.
- Programming misuse and corrupt required state throw; expected user-facing
  conflicts return `nil, stableCode` without side effects.
- Successful operations return a non-nil primary result and only meaningful
  operation-specific secondary state; simple consumers may ignore later returns.
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
