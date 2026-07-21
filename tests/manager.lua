local H = ...

H.test("reports the API family and dependency-backed constructor", function()
    local environment = H.freshLibrary()
    local major, minor = environment.library:GetVersion()
    H.assertEqual(major, "LibSimpleDBProfiles-1.0")
    H.assertEqual(minor, 1)
    H.assertEqual(environment.library.MAJOR, major)
    H.assertEqual(environment.library.MINOR, minor)
end)

H.test("normalizes fresh storage and selects Global", function()
    local environment = H.freshLibrary()
    local storage = {}
    local manager = environment.library:New("TestAddon", storage, { enabled = true })
    local activeDB = manager:GetActiveDB()

    H.assertEqual(storage.__lsdbProfiles.schema, 1)
    H.assertEqual(storage.__lsdbProfiles.payloadVersion, 1)
    H.assertTrue(type(storage.global) == "table")
    H.assertTrue(type(storage.specs["262"]) == "table")
    H.assertEqual(storage.selections[environment.identity.guid].profile, "global")
    H.assertEqual(manager:GetActiveProfile().profileID.profile, "global")
    H.assertTrue(activeDB:Get("enabled"))
    H.assertEqual(manager:GetDisplayName(), "Test Addon")
end)

H.test("performs one-time most-specific initial selection", function()
    local environment = H.freshLibrary()
    local storage = {
        specs = { ["262"] = { marker = "spec" } },
        classes = { SHAMAN = { marker = "class" } },
        global = { marker = "global" },
    }
    local manager = environment.library:New("TestAddon", storage)
    H.assertEqual(manager:GetActiveDB():Get("marker"), "spec")
    H.assertEqual(storage.selections[environment.identity.guid].profile, "spec")

    storage.characters[environment.identity.guid].marker = "character"
    H.assertEqual(manager:GetActiveProfile().profileID.profile, "spec")
end)

H.test("waits for specialization identity before initial selection", function()
    local environment = H.freshLibrary()
    environment.identity.specID = nil
    environment.identity.specName = nil
    local storage = {
        specs = { ["262"] = { marker = "spec" } },
        classes = { SHAMAN = { marker = "class" } },
        global = { marker = "global" },
    }
    local manager = environment.library:New("TestAddon", storage)
    local activeDB = manager:GetActiveDB()
    local events = {}

    H.assertEqual(manager:GetActiveProfile().profileID.profile, "class")
    H.assertNil(storage.selections[environment.identity.guid])
    H.assertEqual(storage.specs["262"].marker, "spec")
    H.assertNil(H.findProfile(manager:GetProfiles(), "permanent", "spec"))
    H.assertTrue(environment.frame.events.PLAYER_LOGIN)
    H.assertTrue(environment.frame.events.PLAYER_ENTERING_WORLD)

    activeDB:RegisterLifecycleCallback("OnDataChanged", function()
        events[#events + 1] = "data"
    end)

    manager:RegisterLifecycleCallback("OnCharacterInfoChanged", function()
        events[#events + 1] = "character"
    end)

    manager:RegisterLifecycleCallback("OnProfileChanged", function()
        events[#events + 1] = "profile"
    end)

    environment.frame:Fire("PLAYER_LOGIN")
    H.assertNil(storage.selections[environment.identity.guid])

    environment.identity.specID = 262
    environment.identity.specName = "Elemental"
    environment.now = environment.now + 10
    environment.frame:Fire("PLAYER_ENTERING_WORLD")
    H.assertEqual(manager:GetActiveDB(), activeDB)
    H.assertEqual(activeDB:Get("marker"), "spec")
    H.assertEqual(storage.selections[environment.identity.guid].profile, "spec")
    H.assertTrue(H.findProfile(manager:GetProfiles(), "permanent", "spec") ~= nil)
    H.assertEqual(events[1], "character")
    H.assertEqual(events[2], "data")
    H.assertEqual(events[3], "profile")
    H.assertEqual(#events, 3)
    environment.frame:Fire("PLAYER_ENTERING_WORLD")
    H.assertEqual(#events, 3)
end)

H.test("finalizes a lower initial profile when the player has no specialization", function()
    local environment = H.freshLibrary()
    environment.identity.specID = nil
    environment.identity.specName = nil
    local storage = {
        specs = { ["262"] = { marker = "spec" } },
        classes = { SHAMAN = { marker = "class" } },
        global = { marker = "global" },
    }
    local manager = environment.library:New("TestAddon", storage)

    H.assertNil(storage.selections[environment.identity.guid])
    environment.frame:Fire("PLAYER_ENTERING_WORLD")
    H.assertEqual(storage.selections[environment.identity.guid].profile, "class")

    environment.identity.specID = 262
    environment.identity.specName = "Elemental"
    environment.frame:Fire("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
    H.assertEqual(manager:GetActiveProfile().profileID.profile, "class")
end)

H.test("explicit selection cancels a pending initial search", function()
    local environment = H.freshLibrary()
    environment.identity.specID = nil
    environment.identity.specName = nil
    local storage = {
        global = { marker = "global" },
        specs = { ["262"] = { marker = "spec" } },
    }
    local manager = environment.library:New("TestAddon", storage)
    local selected, changed = manager:SetProfile({ kind = "permanent", profile = "global" })

    H.assertFalse(changed)
    H.assertEqual(selected.profileID.profile, "global")
    H.assertEqual(storage.selections[environment.identity.guid].profile, "global")
    environment.identity.specID = 262
    environment.identity.specName = "Elemental"
    environment.frame:Fire("PLAYER_LOGIN")
    H.assertEqual(manager:GetActiveProfile().profileID.profile, "global")
end)

H.test("keeps a stored Specialization selection pending until identity resolves", function()
    local environment = H.freshLibrary()
    environment.identity.specID = nil
    environment.identity.specName = nil
    local storage = {
        global = { marker = "global" },
        specs = { ["262"] = { marker = "spec" } },
        selections = {
            [environment.identity.guid] = { kind = "permanent", profile = "spec" },
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    local activeDB = manager:GetActiveDB()

    H.assertEqual(manager:GetActiveProfile().profileID.profile, "global")
    H.assertEqual(storage.selections[environment.identity.guid].profile, "spec")
    environment.identity.specID = 262
    environment.identity.specName = "Elemental"
    environment.frame:Fire("PLAYER_LOGIN")
    H.assertEqual(manager:GetActiveDB(), activeDB)
    H.assertEqual(activeDB:Get("marker"), "spec")
    H.assertEqual(manager:GetActiveProfile().profileID.profile, "spec")
end)

H.test("keeps independent storage and enforces manager ownership labels", function()
    local environment = H.freshLibrary()
    local firstStorage = {}
    local first = environment.library:New("TestAddon", firstStorage)

    H.assertError(function()
        environment.library:New("TestAddon", firstStorage)
    end, "already has a live manager")

    H.assertError(function()
        environment.library:New("TestAddon", {})
    end, "explicit unique displayName")

    local other = environment.library:New("OtherAddon", {})
    H.assertTrue(first:GetActiveDB() ~= other:GetActiveDB())
end)

H.test("allows multiple explicitly labeled child managers", function()
    local environment = H.freshLibrary()
    local storage = { settings = {}, layout = {} }
    local settings = environment.library:New("TestAddon", storage.settings, nil, {
        displayName = "Settings",
    })
    local layout = environment.library:New("TestAddon", storage.layout, nil, {
        displayName = "Layout",
    })
    H.assertEqual(settings:GetDisplayName(), "Settings")
    H.assertEqual(layout:GetDisplayName(), "Layout")
    H.assertEqual(#environment.library:GetManagers(), 2)
end)

H.test("normalizes multilingual user names without a length limit", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    local chinese = "  团队\t配置  "
    local profileRef = manager:CreateProfile(chinese)
    H.assertEqual(profileRef.name, "团队 配置")

    local longName = string.rep("界", 400)
    H.assertEqual(manager:CreateProfile(longName).name, longName)
    local invalid, errorCode = manager:CreateProfile("bad" .. string.char(255))
    H.assertNil(invalid)
    H.assertEqual(errorCode, "INVALID_NAME")
    invalid, errorCode = manager:CreateProfile("bad" .. string.char(1))
    H.assertNil(invalid)
    H.assertEqual(errorCode, "INVALID_NAME")
end)

H.test("reports permanent and user display collisions without ambiguity", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    manager:CreateProfile("Elemental")
    local profiles = manager:GetProfiles()
    local spec = H.findProfile(profiles, "permanent", "spec")
    local user = H.findProfile(profiles, "user", "Elemental")
    H.assertTrue(spec.nameCollision)
    H.assertTrue(user.nameCollision)
    H.assertEqual(spec.profileRef.profile, "spec")
    H.assertEqual(user.profileRef.name, "Elemental")
end)

H.test("SetProfile creates missing users and preserves active DB identity", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    local db = manager:GetActiveDB()
    local events = {}

    db:RegisterLifecycleCallback("OnDataChanged", function()
        events[#events + 1] = "data"
    end)

    manager:RegisterLifecycleCallback("OnProfileCreated", function()
        events[#events + 1] = "created"
    end)

    manager:RegisterLifecycleCallback("OnProfileChanged", function()
        events[#events + 1] = "changed"
    end)

    local descriptor, changed = manager:SetProfile({ kind = "user", name = "Raid" })
    H.assertTrue(changed)
    H.assertEqual(descriptor.profileID.name, "Raid")
    H.assertEqual(manager:GetActiveDB(), db)
    H.assertEqual(events[1], "created")
    H.assertEqual(events[2], "data")
    H.assertEqual(events[3], "changed")

    local same, sameChanged = manager:SetProfile({ kind = "user", name = "Raid" })
    H.assertEqual(same.profileID.name, "Raid")
    H.assertFalse(sameChanged)
    H.assertEqual(#events, 3)
end)

H.test("copies deeply, creates destinations, overwrites, and ignores self-copy", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    local sourceRef = manager:CreateProfile("Source")
    manager:SetProfile(sourceRef)
    manager:GetActiveDB():Set("nested", "value", 10)

    local destination, overwritten = manager:CopyProfile(sourceRef, { kind = "user", name = "Destination" })
    H.assertFalse(overwritten)
    H.assertEqual(destination.profileID.name, "Destination")
    manager:SetProfile({ kind = "user", name = "Destination" })
    manager:GetActiveDB():Set("nested", "value", 20)
    manager:SetProfile(sourceRef)
    H.assertEqual(manager:GetActiveDB():Get("nested", "value"), 10)

    destination, overwritten = manager:CopyProfile(sourceRef, { kind = "user", name = "Destination" })
    H.assertTrue(overwritten)
    local selfCopy, selfOverwritten = manager:CopyProfile(sourceRef, sourceRef)
    H.assertEqual(selfCopy.profileID.name, "Source")
    H.assertFalse(selfOverwritten)
end)

H.test("resets active data without changing selection", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    local profileRef = manager:CreateProfile("Raid")
    manager:SetProfile(profileRef)
    manager:GetActiveDB():Set("enabled", true)
    local events = {}

    manager:GetActiveDB():RegisterLifecycleCallback("OnReset", function()
        events[#events + 1] = "db"
    end)

    manager:RegisterLifecycleCallback("OnProfileReset", function()
        events[#events + 1] = "profile"
    end)

    local reset = manager:ResetProfile()
    H.assertEqual(reset.profileID.name, "Raid")
    H.assertEqual(manager:GetActiveProfile().profileID.name, "Raid")
    H.assertNil(manager:GetActiveDB():GetRaw("enabled"))
    H.assertEqual(events[1], "db")
    H.assertEqual(events[2], "profile")
end)

H.test("renames user profiles and updates every stored selection", function()
    local environment = H.freshLibrary()
    local storage = {}
    local manager = environment.library:New("TestAddon", storage)
    local oldRef = manager:CreateProfile("Raid")
    manager:SetProfile(oldRef)
    storage.characterInfo["Player-3676-00000002"] = {
        name = "Alt",
        realmID = "3676",
        realmName = "Area 52",
        class = "MAGE",
        classID = 8,
        faction = "Horde",
        specID = "62",
        level = 80,
        lastSeen = environment.now,
    }
    storage.selections["Player-3676-00000002"] = { kind = "user", name = "Raid" }

    local renamed = manager:RenameProfile(oldRef, "Mythic")
    H.assertEqual(renamed.profileID.name, "Mythic")
    H.assertEqual(storage.selections[environment.identity.guid].name, "Mythic")
    H.assertEqual(storage.selections["Player-3676-00000002"].name, "Mythic")
    local recreated = manager:SetProfile(oldRef)
    H.assertEqual(recreated.profileID.name, "Raid")
end)

H.test("deletes referenced inactive users without replacement", function()
    local environment = H.freshLibrary()
    local storage = {}
    local manager = environment.library:New("TestAddon", storage)
    local raid = manager:CreateProfile("Raid")
    storage.characterInfo["Player-3676-00000002"] = {
        name = "Alt",
        realmID = "3676",
        realmName = "Area 52",
        class = "MAGE",
        classID = 8,
        faction = "Horde",
        specID = "62",
        level = 80,
        lastSeen = environment.now,
    }
    storage.selections["Player-3676-00000002"] = raid
    local deleted, affected = manager:DeleteProfile(raid)
    H.assertEqual(deleted.profileID.name, "Raid")
    H.assertEqual(#affected, 1)
    H.assertNil(storage.selections["Player-3676-00000002"])
    H.assertNil(storage.profiles.Raid)

    local active = manager:CreateProfile("Active")
    manager:SetProfile(active)
    local result, errorCode = manager:DeleteProfile(active)
    H.assertNil(result)
    H.assertEqual(errorCode, "ACTIVE_PROFILE")

    H.assertError(function()
        manager:DeleteProfile({ kind = "permanent", profile = "global" })
    end, "cannot be deleted")
end)

H.test("throws programming errors but returns expected conflicts", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})

    H.assertError(function()
        manager:SetProfile("Raid")
    end, "typed profile reference")

    H.assertError(function()
        manager:SetProfile({ kind = "permanent", profile = "class", key = "SHAMAN" })
    end, "malformed profile reference")

    manager:CreateProfile("Raid")
    local result, errorCode = manager:CreateProfile("Raid")
    H.assertNil(result)
    H.assertEqual(errorCode, "PROFILE_EXISTS")
    result, errorCode = manager:ResetProfile({ kind = "user", name = "Missing" })
    H.assertNil(result)
    H.assertEqual(errorCode, "PROFILE_NOT_FOUND")

    H.assertError(function()
        manager:RenameProfile({ kind = "permanent", profile = "global" }, "Other")
    end, "cannot be renamed")
end)

H.test("ordinary usage returns affected characters through a relative reference", function()
    local environment = H.freshLibrary()
    local altGUID = "Player-3676-00000002"
    local storage = {}
    local manager = environment.library:New("TestAddon", storage)
    local raid = manager:CreateProfile("Raid")
    storage.characterInfo[altGUID] = {
        name = "Alt",
        realmID = "3676",
        realmName = "Area 52",
        class = "MAGE",
        classID = 8,
        faction = "Horde",
        specID = "62",
        level = 80,
        lastSeen = environment.now,
    }
    storage.selections[altGUID] = raid
    local usage = manager:GetProfileUsage(raid)
    H.assertEqual(usage.selectionCount, 1)
    H.assertEqual(usage.characters[1].guid, altGUID)
end)

H.test("fails clearly when required identity is unavailable", function()
    local environment = H.freshLibrary()
    environment.identity.realmID = 0

    H.assertError(function()
        environment.library:New("TestAddon", {})
    end, "realm ID is unavailable")
end)

H.test("lifecycle callbacks are idempotent, snapshot-based, and error-isolated", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    local calls = 0
    local laterCalls = 0

    local later = function()
        laterCalls = laterCalls + 1
    end

    local callback

    callback = function(instance)
        calls = calls + 1
        instance:UnregisterLifecycleCallback("OnProfileCreated", callback)
        instance:RegisterLifecycleCallback("OnProfileCreated", later)
        error("expected lifecycle error")
    end

    manager:RegisterLifecycleCallback("OnProfileCreated", callback)
    manager:RegisterLifecycleCallback("OnProfileCreated", callback)
    manager:CreateProfile("One")
    H.assertEqual(calls, 1)
    H.assertEqual(laterCalls, 0)
    H.assertEqual(#environment.callbackErrors, 1)
    manager:CreateProfile("Two")
    H.assertEqual(laterCalls, 1)
end)

H.test("forced Specialization follows active specialization changes", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    manager:SetProfile({ kind = "permanent", profile = "spec" })
    local db = manager:GetActiveDB()
    environment.identity.specID = 263
    environment.identity.specName = "Enhancement"
    environment.now = environment.now + 10
    environment.frame:Fire("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
    H.assertEqual(manager:GetActiveDB(), db)
    H.assertEqual(manager:GetActiveProfile().profileID.key, "263")
end)

H.test("non-Specialization selections do not switch on specialization changes", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    manager:SetProfile({ kind = "permanent", profile = "class" })
    local before = manager:GetActiveProfile().profileID.key
    environment.identity.specID = 263
    environment.identity.specName = "Enhancement"
    environment.frame:Fire("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
    H.assertEqual(manager:GetActiveProfile().profileID.key, before)
end)
