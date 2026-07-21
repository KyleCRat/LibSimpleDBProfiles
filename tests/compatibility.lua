local H = ...

H.test("fails clearly when LibSimpleDB-2.0 is missing or too old", function()
    dofile("tests/libstub.lua")

    H.assertError(function()
        dofile("LibSimpleDBProfiles-1.0.lua")
    end, "requires LibSimpleDB-2.0 minor 1")

    H.assertNil(LibStub("LibSimpleDBProfiles-1.0", true))
    H.loadSimpleDB()
    H.loadProfileLibrary(1)
    H.assertEqual(LibStub("LibSimpleDBProfiles-1.0").MINOR, 1)

    dofile("tests/libstub.lua")
    LibStub:NewLibrary("LibSimpleDB-2.0", 0)

    H.assertError(function()
        dofile("LibSimpleDBProfiles-1.0.lua")
    end, "requires LibSimpleDB-2.0 minor 1")
end)

H.test("equal embedded copies do not rebuild the active library", function()
    local environment = H.freshLibrary()
    local manager = environment.library:New("TestAddon", {})
    local oldMethod = manager.GetActiveDB
    local oldFrame = environment.library._eventFrame

    H.loadProfileLibrary(1)
    H.assertEqual(manager.GetActiveDB, oldMethod)
    H.assertEqual(environment.library._eventFrame, oldFrame)
    H.assertEqual(manager:GetActiveDB():GetDefault("missing"), nil)
end)

H.test("higher compatible minors update live instances and reject lower overwrite", function()
    local environment = H.freshLibrary()
    local storage = { global = { value = 10 } }
    local manager = environment.library:New("TestAddon", storage)
    local activeDB = manager:GetActiveDB()
    local oldMethod = manager.GetActiveProfile

    local upgraded = H.loadProfileLibrary(2)
    H.assertEqual(upgraded, environment.library)
    H.assertEqual(upgraded.MINOR, 2)
    H.assertEqual(manager:GetActiveDB(), activeDB)
    H.assertEqual(manager:GetActiveDB():Get("value"), 10)
    H.assertTrue(manager.GetActiveProfile ~= oldMethod)

    local upgradedMethod = manager.GetActiveProfile
    H.loadProfileLibrary(1)
    H.assertEqual(upgraded.MINOR, 2)
    H.assertEqual(manager.GetActiveProfile, upgradedMethod)
    H.assertEqual(manager:GetActiveDB(), activeDB)
end)

H.test("rejects future schemas, wrong containers, and unwrapped legacy data", function()
    local environment = H.freshLibrary()

    H.assertError(function()
        environment.library:New("TestAddon", {
            __lsdbProfiles = { schema = 2, payloadVersion = 1 },
        })
    end, "newer than supported")

    environment = H.freshLibrary()
    local wrong = { profiles = "broken" }

    H.assertError(function()
        environment.library:New("TestAddon", wrong)
    end, "profiles must be a table")

    H.assertEqual(wrong.profiles, "broken")

    environment = H.freshLibrary()

    H.assertError(function()
        environment.library:New("TestAddon", { enabled = true })
    end, "unrecognized unversioned storage key")

    environment = H.freshLibrary()

    H.assertError(function()
        environment.library:New("TestAddon", {
            selections = {
                [environment.identity.guid] = { kind = "unexpected" },
            },
        })
    end, "unknown profile reference kind")
end)

H.test("recovers a dangling current user selection through initial selection", function()
    local environment = H.freshLibrary()
    local guid = environment.identity.guid
    local storage = {
        global = { fallback = true },
        selections = {
            [guid] = { kind = "user", name = "Removed" },
        },
    }
    local manager = environment.library:New("TestAddon", storage)
    H.assertEqual(manager:GetActiveProfile().profileID.profile, "global")
    H.assertEqual(storage.selections[guid].profile, "global")
end)
