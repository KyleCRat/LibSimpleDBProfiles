# LibSimpleDBProfiles

LibSimpleDBProfiles is an embedded World of Warcraft profile manager built on
`LibSimpleDB-2.0`. It provides one stable active database, permanent
identity-backed profiles, user-created profiles, lifecycle callbacks,
administration for offline characters, and staged consumer payload migrations.

The current API family is `LibSimpleDBProfiles-1.0`. It targets WoW Interface
`120007` and Lua 5.1.

## Status

The initial implementation and Lua 5.1 test suite are complete. The library is
not released yet and remains dependent on the reviewed `LibSimpleDB-2.0`
`2.0.0` release.

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

When a character has no stored selection, the manager chooses the first
non-empty profile in this order:

```text
Character > Specialization > Class > Realm > Faction > Global
```

The choice is persisted once. Later data changes do not trigger another
specificity search.

```lua
manager:SetProfile({ kind = "permanent", profile = "spec" })
manager:SetProfile({ kind = "user", name = "Raid" })
```

Selecting a valid missing user profile creates and selects it atomically.

See [API.md](API.md) for the complete contract and [PLAN.md](PLAN.md) for the
design rationale and storage model.

## Tests

Run from the repository root with Lua 5.1 and the sibling LibSimpleDB checkout:

```powershell
lua.exe tests/run.lua
```

The suite covers manager operations, exact administration IDs, offline
characters, payload migrations, callback ordering, storage corruption, and
mixed LibStub load orders.
