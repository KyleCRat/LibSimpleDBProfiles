local H = ...

local function addSteps(library, currentVersion, callbacks)
    local migration = library:CreateMigration(currentVersion)

    for sourceVersion = 1, currentVersion - 1 do
        migration:Add(sourceVersion, callbacks[sourceVersion])
    end

    return migration
end

H.test("fresh consumers require no migration scaffolding", function()
    local environment = H.freshLibrary()
    local storage = {}
    environment.library:New("TestAddon", storage)
    H.assertEqual(storage.__lsdbProfiles.payloadVersion, 1)
end)

H.test("fresh storage starts at the supplied Migration version without callbacks", function()
    local environment = H.freshLibrary()
    local calls = 0
    local migration = addSteps(environment.library, 3, {
        function()
            calls = calls + 1
        end,

        function()
            calls = calls + 1
        end,
    })
    local storage = {}
    environment.library:New("TestAddon", storage, nil, { migration = migration })
    H.assertEqual(storage.__lsdbProfiles.payloadVersion, 3)
    H.assertEqual(calls, 0)

    H.assertError(function()
        migration:Add(1, function() end)
    end, "immutable")
end)

H.test("consumer migrations visit every payload with exact profile IDs", function()
    local environment = H.freshLibrary()
    local currentGUID = environment.identity.guid
    local storage = {
        __lsdbProfiles = { schema = 1, payloadVersion = 1 },
        global = { display = { scale = 1 } },
        classes = { SHAMAN = { display = { scale = 2 } } },
        profiles = { Raid = { display = { scale = 3 } } },
        selections = {
            [currentGUID] = { kind = "user", name = "Raid" },
        },
    }
    local seen = {}
    local migration = addSteps(environment.library, 3, {
        function(data, profileID)
            seen[profileID.kind .. ":" .. (profileID.profile or profileID.name)] = true

            if data.display then
                data.appearance = data.appearance or {}
                data.appearance.scale = data.display.scale
                data.display = nil
            end

            data.migratedTo = 2
        end,

        function(data)
            data.migratedTo = 3
        end,
    })

    local manager = environment.library:New("TestAddon", storage, nil, { migration = migration })
    H.assertEqual(storage.__lsdbProfiles.payloadVersion, 3)
    H.assertEqual(storage.global.appearance.scale, 1)
    H.assertEqual(storage.classes.SHAMAN.appearance.scale, 2)
    H.assertEqual(storage.profiles.Raid.appearance.scale, 3)
    H.assertEqual(manager:GetActiveDB():Get("appearance", "scale"), 3)
    H.assertTrue(seen["permanent:global"])
    H.assertTrue(seen["permanent:character"])
    H.assertTrue(seen["permanent:spec"])
    H.assertTrue(seen["permanent:class"])
    H.assertTrue(seen["permanent:realm"])
    H.assertTrue(seen["permanent:faction"])
    H.assertTrue(seen["user:Raid"])
end)

H.test("migration steps commit atomically one version at a time", function()
    local environment = H.freshLibrary()
    local storage = {
        __lsdbProfiles = { schema = 1, payloadVersion = 1 },
        global = { original = true },
        profiles = { Raid = { original = true } },
    }
    local migration = addSteps(environment.library, 3, {
        function(data)
            data.stepOne = true
        end,

        function(data, profileID)
            data.stepTwo = true

            if profileID.kind == "user" then
                error("expected step-two failure")
            end
        end,
    })

    H.assertError(function()
        environment.library:New("TestAddon", storage, nil, { migration = migration })
    end, "expected step-two failure")

    H.assertEqual(storage.__lsdbProfiles.payloadVersion, 2)
    H.assertTrue(storage.global.stepOne)
    H.assertTrue(storage.profiles.Raid.stepOne)
    H.assertNil(storage.global.stepTwo)
    H.assertNil(storage.profiles.Raid.stepTwo)
end)

H.test("a failed first migration step commits no payload", function()
    local environment = H.freshLibrary()
    local storage = {
        __lsdbProfiles = { schema = 1, payloadVersion = 1 },
        global = { original = true },
        profiles = { Raid = { original = true } },
    }
    local migration = environment.library:CreateMigration(2)

    migration:Add(1, function(data, profileID)
        data.changed = true

        if profileID.kind == "user" then
            error("expected migration failure")
        end
    end)

    H.assertError(function()
        environment.library:New("TestAddon", storage, nil, { migration = migration })
    end, "expected migration failure")

    H.assertEqual(storage.__lsdbProfiles.payloadVersion, 1)
    H.assertNil(storage.global.changed)
    H.assertNil(storage.profiles.Raid.changed)
end)

H.test("migration validation rejects gaps, duplicates, foreign objects, and future data", function()
    local environment = H.freshLibrary()
    local migration = environment.library:CreateMigration(3)

    H.assertEqual(migration:Add(1, function() end), migration)

    H.assertError(function()
        migration:Add(1, function() end)
    end, "already contains")

    H.assertError(function()
        environment.library:New("TestAddon", {}, nil, { migration = migration })
    end, "missing source version 2")

    environment = H.freshLibrary()

    H.assertError(function()
        environment.library:New("TestAddon", {}, nil, { migration = { currentVersion = 2 } })
    end, "must be created")

    environment = H.freshLibrary()
    local futureStorage = {
        __lsdbProfiles = { schema = 1, payloadVersion = 4 },
    }
    local current = environment.library:CreateMigration(3)

    current:Add(1, function() end)

    current:Add(2, function() end)

    H.assertError(function()
        environment.library:New("TestAddon", futureStorage, nil, { migration = current })
    end, "newer than Migration")
end)

H.test("migration output must remain SavedVariables compatible", function()
    local environment = H.freshLibrary()
    local storage = {
        __lsdbProfiles = { schema = 1, payloadVersion = 1 },
        global = {},
    }
    local migration = environment.library:CreateMigration(2)

    migration:Add(1, function(data)
        data.invalid = function() end
    end)

    H.assertError(function()
        environment.library:New("TestAddon", storage, nil, { migration = migration })
    end, "SavedVariables-compatible")

    H.assertEqual(storage.__lsdbProfiles.payloadVersion, 1)
    H.assertNil(storage.global.invalid)
end)
