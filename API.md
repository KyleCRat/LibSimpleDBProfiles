# LibSimpleDBProfiles-1.0 API

## Data Ownership

`Profiles:New()` retains the consumer's account-wide SavedVariables table by
reference. The library owns its profile containers, selections, character
metadata, and internal version markers. Raw profile payloads remain
consumer-owned SavedVariables-compatible tables.

Do not pass `SavedVariablesPerCharacter`. Do not construct two live managers for
the same storage table.

## Library API

### `Profiles:GetVersion()`

Return the LibStub family and implementation minor.

### `Profiles:New(addonName, storage[, defaults[, options]])`

Create a manager synchronously. `addonName` is the required addon folder name.
`storage` must be an account-wide consumer table. `defaults` is passed to the
stable active LibSimpleDB instance.

Supported options:

```lua
{
    displayName = "Settings Profiles",
    migration = Migration,
    initialProfile = "mostSpecific",
}
```

One manager may omit `displayName` and use the addon's TOC Title. Multiple live
managers for the same addon require explicit unique display names.

`initialProfile` applies only when a character has no valid saved selection.
Omit it or use `"mostSpecific"` for the existing first-nonempty-profile search.
Alternatively select `"global"`, `"character"`, `"spec"`, `"class"`, `"realm"`,
or `"faction"` even when that profile is empty. Existing selections always win.
This option does not copy data or introduce profile inheritance.

An explicit `"spec"` waits for specialization identity using Global provisionally.
If the player still has no specialization at world entry, Global is selected
permanently; later acquiring a specialization does not override that selection.
Other explicit types resolve immediately and do not wait for specialization.

With `"mostSpecific"`, construction does not wait for `PLAYER_LOGIN`. If
specialization identity is temporarily unavailable, the stable active database
is synchronously bound to the best profile that can already be resolved. For a character without a stored
selection, that provisional choice is not persisted when a non-empty
Specialization profile could still outrank it. The manager retries at
`PLAYER_LOGIN` and finalizes the one-time selection by
`PLAYER_ENTERING_WORLD`. A player who still has no specialization at world
entry receives the normal lower-priority fallback.

An existing relative Specialization selection also remains pending rather than
being discarded or treated as corrupt. It is rebound when specialization
identity resolves. Calling `SetProfile()` before readiness is an explicit
selection and cancels any pending initial search. After finalization, later
profile data or specialization availability never promotes a non-Specialization
selection automatically.

### `Profiles:CreateMigration(currentVersion)`

Create a stateless consumer payload Migration. See Consumer Migrations below.

### `Profiles:GetManagers()`

Return the live managers in addon-name and display-name order. This is the
discovery hook for a future standalone profile administration addon.

## Profile References And IDs

Manager selection methods accept relative `profileRef` values:

```lua
{ kind = "permanent", profile = "class" }
{ kind = "user", name = "Raid" }
```

Permanent references resolve against the selected character's identity.
Accepted permanent names are `character`, `spec`, `class`, `realm`, `faction`,
and `global`.

Administration and migration callbacks use exact manager-local `profileID`
values:

```lua
{ kind = "permanent", profile = "class", key = "SHAMAN" }
{ kind = "permanent", profile = "character", key = characterGUID }
{ kind = "permanent", profile = "global" }
{ kind = "user", name = "Raid" }
```

Receive IDs from descriptors and pass them back to the same manager. Do not
persist them in consumer payloads or construct keys from localized values.
Keyed permanent IDs are rejected by selection methods.

## Profile Descriptors

Profile methods and callbacks return detached descriptors:

```lua
{
    profileRef = { kind = "permanent", profile = "spec" },
    profileID = { kind = "permanent", profile = "spec", key = "262" },
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

Administration descriptors additionally contain `selectionCount`. Historical
permanent descriptors omit `profileRef` when the relative reference would
resolve to another exact identity.

Descriptors are snapshots. Refresh them after mutations rather than expecting
an old table to update in place.

## Manager API

### Reads

```lua
manager:GetAddonName()
manager:GetDisplayName()
manager:GetActiveDB()
manager:GetProfiles()
manager:GetActiveProfile()
manager:GetProfileUsage(profileRef)
manager:GetAdmin()
```

`GetProfiles()` returns current permanent profiles followed by user profiles.
`GetProfileUsage()` returns:

```lua
{
    profileID = profileID,
    profileRef = profileRef,
    selectionCount = 2,
    characters = { ... },
    unresolvedCharacters = { ... },
}
```

### Mutations

```lua
manager:SetProfile(profileRef)
manager:CreateProfile(name)
manager:CopyProfile(sourceRef, destinationRef)
manager:ResetProfile([profileRef])
manager:RenameProfile(profileRef, newName)
manager:DeleteProfile(profileRef)
```

Successful results are:

```text
SetProfile      -> activeDescriptor, changed
CreateProfile   -> userRef
CopyProfile     -> destinationDescriptor, overwritten
ResetProfile    -> profileDescriptor
RenameProfile   -> newDescriptor
DeleteProfile   -> deletedDescriptor, affectedCharacters
```

`SetProfile()` creates a missing user destination. `CopyProfile()` also creates
a missing user destination and replaces existing data without an overwrite
flag. Copying onto itself succeeds as a no-op with `overwritten = false`.

Reset clears raw overrides and preserves selection. Permanent profiles cannot
be renamed or deleted. The active user profile cannot be deleted. Deleting a
referenced inactive user profile clears those offline selections without
choosing replacements.

Consumers may assign only the first return value. Lua discards later values;
the first result still distinguishes success from failure, while the error code
or operation state is intentionally ignored.

## User Profile Names

Every user name is normalized consistently:

1. Validate UTF-8, including overlong, surrogate, and range checks.
2. Trim leading and trailing ASCII whitespace.
3. Collapse internal ASCII whitespace runs to one space.
4. Reject empty names and ASCII controls.
5. Preserve case and all non-ASCII bytes.

Names are case-sensitive and have no library-level length limit. Unicode
normalization and case folding are not performed.

## Administration API

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

The object can access only its manager's storage.

`GetCharacters()` returns the union of GUIDs found in character metadata,
Character payloads, and selections. Character descriptors always contain
`guid`; known name, realm, class, faction, specialization, level, and last-seen
metadata is included. Missing historical metadata remains nil.

`GetSelection()` returns a detached selection descriptor with optional
`profileRef` and resolved `profileID` fields.

`SetSelection()` targets offline characters. A missing user profile is created.
An unresolved permanent reference may be stored until that character logs in
and refreshes its identity. Use ordinary `SetProfile()` for the current
character.

Administration mutation results are:

```text
SetSelection     -> characterDescriptor, changed
ResetProfile     -> profileDescriptor
CopyProfile      -> destinationDescriptor, overwritten
ForgetCharacter  -> forgottenCharacterDescriptor
```

`ForgetCharacter()` removes only one offline Character payload, metadata record,
and selection. It never deletes shared permanent or user data and rejects the
current character.

## Consumer Migrations

New addons do not declare a payload version. The library initializes version 1.
Add a Migration only when the addon first changes its payload schema:

```lua
local Migration = Profiles:CreateMigration(3)

Migration:Add(1, function(data, profileID)
    if data.display and data.display.scale ~= nil then
        data.appearance = data.appearance or {}
        data.appearance.scale = data.display.scale
        data.display.scale = nil
        if next(data.display) == nil then
            data.display = nil
        end
    end
end)

Migration:Add(2, function(data)
    data.legacyOption = nil
end)

local manager = Profiles:New(addonName, storage, defaults, {
    migration = Migration,
})
```

`Migration:Add(sourceVersion, callback)` declares one source-to-next-version
step and returns the Migration. Steps must be continuous from 1 through one less
than the current version. The object becomes immutable when first supplied to
`New()` and must continue to be supplied in later addon releases.

Each callback receives a staged raw payload and detached exact `profileID`.
Callbacks mutate only that raw table and do not materialize defaults. Every
payload in one version step must migrate and validate before the step commits.
Earlier completed version steps remain committed if a later step fails.

Fresh storage starts directly at the declared current version without running
historical callbacks. A stored version newer than the supplied Migration throws
instead of downgrading.

## Lifecycle Callbacks

```lua
manager:RegisterLifecycleCallback(event, callback)
manager:UnregisterLifecycleCallback(event, callback)
manager:UnregisterAllLifecycleCallbacks([callback])
```

Callbacks receive `(manager, event, ...)` and use snapshot dispatch with error
isolation.

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

An active root switch fires LibSimpleDB `OnDataChanged` before
`OnProfileChanged`. Copying into the active profile fires LibSimpleDB
`OnDataChanged` before `OnProfileCopied`. Resetting the active profile fires
LibSimpleDB `OnReset` before `OnProfileReset`.

When startup specialization readiness changes the provisional active root,
`OnCharacterInfoChanged` fires first, followed by LibSimpleDB `OnDataChanged`
and then `OnProfileChanged`. A readiness event that does not change the active
root emits no duplicate data or profile callback.

Listen to `OnProfileChanged` when UI cares about profile identity. Listen to the
active LibSimpleDB `OnDataChanged` when a feature cares only that effective data
changed.

## Failures

Programming misuse and corrupt required storage throw. Expected user-facing
conflicts return `nil, errorCode` without mutation or callbacks:

| Error code | Meaning |
|---|---|
| `INVALID_NAME` | User name normalization or validation failed |
| `PROFILE_EXISTS` | Normalized user profile already exists |
| `PROFILE_NOT_FOUND` | Required profile is missing |
| `ACTIVE_PROFILE` | Operation is prohibited for the active profile |
| `CHARACTER_NOT_FOUND` | Administration target is unknown |
| `CURRENT_CHARACTER` | Administration operation cannot target the current character |
