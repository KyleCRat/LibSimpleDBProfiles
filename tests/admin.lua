local H = ...

local function findExact(profiles, profile, key)
    for index = 1, #profiles do
        local profileID = profiles[index].profileID

        if profileID.kind == "permanent" and profileID.profile == profile and profileID.key == key then
            return profiles[index]
        end
    end

    return nil
end

local function characterInfo(name, class, classID, specID)
    return {
        name = name,
        realmID = "3676",
        realmName = "Area 52",
        class = class,
        classID = classID,
        faction = "Horde",
        specID = specID,
        level = 80,
        lastSeen = 1784246400,
    }
end

H.test("administration enumerates exact historical profiles", function()
    local environment = H.freshLibrary()
    local currentGUID = environment.identity.guid
    local mageGUID = "Player-3676-00000002"
    local partialGUID = "Player-3676-00000003"
    local storage = {
        global = {},
        classes = {
            SHAMAN = { marker = "shaman" },
            MAGE = { marker = "mage" },
        },
        characterInfo = {
            [mageGUID] = characterInfo("Magealt", "MAGE", 8, "62"),
            [partialGUID] = { name = "Oldalt", lastSeen = 1700000000 },
        },
        selections = {
            [currentGUID] = { kind = "permanent", profile = "class" },
            [mageGUID] = { kind = "permanent", profile = "class" },
            [partialGUID] = { kind = "permanent", profile = "class" },
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    local admin = manager:GetAdmin()
    local profiles = admin:GetProfiles()
    local shaman = findExact(profiles, "class", "SHAMAN")
    local mage = findExact(profiles, "class", "MAGE")

    H.assertTrue(shaman ~= nil)
    H.assertEqual(shaman.profileRef.profile, "class")
    H.assertEqual(shaman.selectionCount, 1)
    H.assertTrue(mage ~= nil)
    H.assertNil(mage.profileRef)
    H.assertEqual(mage.selectionCount, 1)

    local usage = admin:GetProfileUsage(shaman.profileID)
    H.assertEqual(usage.selectionCount, 1)
    H.assertEqual(#usage.characters, 1)
    H.assertEqual(usage.characters[1].guid, currentGUID)
    H.assertEqual(#usage.unresolvedCharacters, 1)
    H.assertEqual(usage.unresolvedCharacters[1].guid, partialGUID)
    H.assertNil(usage.unresolvedCharacters[1].profileID)
end)

H.test("character administration exposes metadata and detached selections", function()
    local environment = H.freshLibrary()
    local altGUID = "Player-3676-00000002"
    local storage = {
        characterInfo = {
            [altGUID] = characterInfo("Magealt", "MAGE", 8, "62"),
        },
        characters = {
            [altGUID] = { enabled = true },
        },
        selections = {
            [altGUID] = { kind = "permanent", profile = "character" },
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    local admin = manager:GetAdmin()
    local characters = admin:GetCharacters()
    H.assertEqual(#characters, 2)

    local selection = admin:GetSelection(altGUID)
    H.assertEqual(selection.profileRef.profile, "character")
    H.assertEqual(selection.profileID.key, altGUID)
    selection.profileRef.profile = "global"
    H.assertEqual(storage.selections[altGUID].profile, "character")

    local missing, errorCode = admin:GetSelection("Player-3676-99999999")
    H.assertNil(missing)
    H.assertEqual(errorCode, "CHARACTER_NOT_FOUND")
end)

H.test("administration changes offline selections and creates missing users", function()
    local environment = H.freshLibrary()
    local altGUID = "Player-3676-00000002"
    local storage = {
        characterInfo = {
            [altGUID] = characterInfo("Magealt", "MAGE", 8, "62"),
        },
        characters = {
            [altGUID] = {},
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    local admin = manager:GetAdmin()
    local events = {}

    manager:RegisterLifecycleCallback("OnProfileCreated", function()
        events[#events + 1] = "created"
    end)

    manager:RegisterLifecycleCallback("OnCharacterSelectionChanged", function()
        events[#events + 1] = "selection"
    end)

    local character, changed = admin:SetSelection(altGUID, { kind = "user", name = "Raid" })
    H.assertTrue(changed)
    H.assertEqual(character.profileID.name, "Raid")
    H.assertTrue(type(storage.profiles.Raid) == "table")
    H.assertEqual(events[1], "created")
    H.assertEqual(events[2], "selection")

    character, changed = admin:SetSelection(altGUID, { kind = "user", name = "Raid" })
    H.assertFalse(changed)
    H.assertEqual(#events, 2)

    local result, errorCode = admin:SetSelection(
        environment.identity.guid,
        { kind = "permanent", profile = "global" }
    )
    H.assertNil(result)
    H.assertEqual(errorCode, "CURRENT_CHARACTER")
end)

H.test("administration permits unresolved relative offline selections", function()
    local environment = H.freshLibrary()
    local oldGUID = "Player-3676-00000003"
    local storage = {
        characterInfo = {
            [oldGUID] = { name = "Oldalt", lastSeen = 1700000000 },
        },
        characters = {
            [oldGUID] = {},
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    local character, changed = manager:GetAdmin():SetSelection(oldGUID, {
        kind = "permanent",
        profile = "spec",
    })
    H.assertTrue(changed)
    H.assertEqual(character.profileRef.profile, "spec")
    H.assertNil(character.profileID)
end)

H.test("normalization creates backing data for resolvable offline permanent selections", function()
    local environment = H.freshLibrary()
    local altGUID = "Player-3676-00000002"
    local storage = {
        characterInfo = {
            [altGUID] = characterInfo("Magealt", "MAGE", 8, "62"),
        },
        selections = {
            [altGUID] = { kind = "permanent", profile = "class" },
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    H.assertTrue(type(storage.classes.MAGE) == "table")
    local usage = manager:GetAdmin():GetProfileUsage({
        kind = "permanent",
        profile = "class",
        key = "MAGE",
    })
    H.assertEqual(usage.selectionCount, 1)
end)

H.test("administration resets and copies exact profiles", function()
    local environment = H.freshLibrary()
    local storage = {
        global = { nested = { value = 10 } },
    }
    local manager = environment.library:New("TestAddon", storage)
    local admin = manager:GetAdmin()
    local globalID = { kind = "permanent", profile = "global" }
    local destinationID = { kind = "user", name = "Backup" }

    local copied, overwritten = admin:CopyProfile(globalID, destinationID)
    H.assertFalse(overwritten)
    H.assertEqual(copied.profileID.name, "Backup")
    storage.global.nested.value = 20
    H.assertEqual(storage.profiles.Backup.nested.value, 10)

    local reset = admin:ResetProfile(destinationID)
    H.assertFalse(reset.hasData)
    H.assertNil(next(storage.profiles.Backup))

    local same, sameOverwritten = admin:CopyProfile(globalID, globalID)
    H.assertEqual(same.profileID.profile, "global")
    H.assertFalse(sameOverwritten)
end)

H.test("ForgetCharacter removes only the offline character record", function()
    local environment = H.freshLibrary()
    local altGUID = "Player-3676-00000002"
    local storage = {
        classes = { MAGE = { shared = true } },
        characterInfo = {
            [altGUID] = characterInfo("Magealt", "MAGE", 8, "62"),
        },
        characters = {
            [altGUID] = { own = true },
        },
        selections = {
            [altGUID] = { kind = "permanent", profile = "class" },
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    local admin = manager:GetAdmin()
    local forgotten = admin:ForgetCharacter(altGUID)
    H.assertEqual(forgotten.guid, altGUID)
    H.assertNil(storage.characters[altGUID])
    H.assertNil(storage.characterInfo[altGUID])
    H.assertNil(storage.selections[altGUID])
    H.assertTrue(storage.classes.MAGE.shared)

    local result, errorCode = admin:ForgetCharacter(environment.identity.guid)
    H.assertNil(result)
    H.assertEqual(errorCode, "CURRENT_CHARACTER")
end)
