# LibSimpleDBProfiles

LibSimpleDBProfiles is an embedded World of Warcraft profile manager built on
`LibSimpleDB-2.0`. It provides one stable active database, permanent
identity-backed profiles, user-created profiles, lifecycle callbacks,
administration for offline characters, and staged consumer payload migrations.

The current API family is `LibSimpleDBProfiles-1.0`. It targets WoW Interface
`120100` and Lua 5.1.

## Status

The released baseline is `1.0.0`, built on `LibSimpleDB` `2.0.0` and verified
with YvBags on WoW 12.1.0. The configurable `initialProfile` option is currently
unreleased; see the changelog before updating a consumer's package pin.

## Embed And Create

Load LibStub, LibSimpleDB, and this library in order:

```text
Libs\LibStub\LibStub.lua
Libs\LibSimpleDB-2.0\embed.xml
Libs\LibSimpleDBProfiles-1.0\embed.xml
```

Pass an account-wide SavedVariables table owned by the consumer addon:

```toc
## SavedVariables: MyAddonDB
```

```lua
local addonName = ...
local Profiles = LibStub("LibSimpleDBProfiles-1.0")

MyAddonDB = MyAddonDB or {}

local manager = Profiles:New(addonName, MyAddonDB, {
    enabled = true,
    display = {
        scale = 1,
    },
})

local db = manager:GetActiveDB()
```

The returned LibSimpleDB object remains stable when profiles change. Consumers
read and write settings directly through that object.

## Profile Model

Permanent profiles are Character, Specialization, Class, Realm, Faction, and
Global. They use canonical nonlocalized identity keys and cannot be renamed or
deleted. User profiles use normalized, case-sensitive UTF-8 names with no
library-level length limit.

By default, when a character has no stored selection, the manager chooses the
first non-empty profile in this order:

```text
Character > Specialization > Class > Realm > Faction > Global
```

The choice is persisted once. Later data changes do not trigger another
specificity search. If specialization identity is not ready during addon load,
the manager uses a synchronous provisional profile without persisting it,
retries during login, and completes the one-time search by world entry. This
allows a new character to inherit an existing Specialization profile without
turning specialization into an ongoing automatic mode.

Consumers can instead pass `initialProfile = "global"` (or another permanent
profile type) in the constructor options. `"mostSpecific"` is the default.
The option applies only to characters without a valid saved selection and
never overrides a later user choice. An explicit `"spec"` waits for startup
specialization identity; it falls back to Global if none exists at world entry.

```lua
manager:SetProfile({ kind = "permanent", profile = "spec" })
manager:SetProfile({ kind = "user", name = "Raid" })
```

Selecting a valid missing user profile creates and selects it atomically.

See [API.md](API.md) for the complete contract and [PLAN.md](PLAN.md) for the
design rationale and storage model.

## Reading The Source

The implementation uses three identity terms consistently:

- `profileRef` is selectable and relative to a character, such as `spec`.
- `profileID` is exact, such as specialization `262`.
- `payload` is the consumer-owned raw overrides table for one exact profile.

`embed.xml` is also the implementation reading order:

| Files | Responsibility |
|---|---|
| `LibSimpleDBProfiles-1.0.lua` | Reserve the LibStub minor, preserve prototypes, and initialize weak live-object registries. |
| `Internal/Util.lua` through `Internal/Descriptors.lua` | Define shared values, identity resolution, storage normalization, migrations, and detached public snapshots. |
| `Manager.lua` and `Operations.lua` | Construct managers, bind the stable LibSimpleDB object, select profiles, and perform ordinary mutations. |
| `Admin.lua` and `Events.lua` | Provide exact-ID/offline administration and follow explicitly selected specialization profiles. |
| `Library.lua` | Publish the public library only after every preceding module loaded successfully. |

## Tests

Run from the repository root with Lua 5.1 and the sibling LibSimpleDB checkout:

```powershell
lua.exe tests/run.lua
```

The suite covers manager operations, exact administration IDs, offline
characters, payload migrations, callback ordering, storage corruption, and
mixed LibStub load orders.
