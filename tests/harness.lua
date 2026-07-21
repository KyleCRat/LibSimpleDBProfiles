local Harness = {
    tests = {},
}

local profileFiles = {
    "LibSimpleDBProfiles-1.0.lua",
    "Internal/Util.lua",
    "Internal/Identity.lua",
    "Internal/Storage.lua",
    "Migration.lua",
    "Internal/Descriptors.lua",
    "Manager.lua",
    "Operations.lua",
    "Admin.lua",
    "Events.lua",
    "Library.lua",
}
Harness.profileFiles = profileFiles

local function fail(message, level)
    error(message, (level or 1) + 1)
end

function Harness.test(name, callback)
    Harness.tests[#Harness.tests + 1] = { name = name, callback = callback }
end

function Harness.assertEqual(actual, expected, message)
    if actual ~= expected then
        fail((message or "values differ") .. (": expected %s, got %s"):format(tostring(expected), tostring(actual)), 2)
    end
end

function Harness.assertNil(actual, message)
    Harness.assertEqual(actual, nil, message)
end

function Harness.assertTrue(actual, message)
    Harness.assertEqual(actual, true, message)
end

function Harness.assertFalse(actual, message)
    Harness.assertEqual(actual, false, message)
end

function Harness.assertDeepEqual(actual, expected, message)
    if type(actual) ~= type(expected) then
        fail(message or ("different types: %s and %s"):format(type(actual), type(expected)), 2)
    end

    if type(actual) ~= "table" then
        Harness.assertEqual(actual, expected, message)
        return
    end

    for key, value in pairs(actual) do
        Harness.assertDeepEqual(value, expected[key], message)
    end

    for key in pairs(expected) do
        if actual[key] == nil then
            fail(message or ("missing key %s"):format(tostring(key)), 2)
        end
    end
end

function Harness.assertError(callback, expectedText)
    local ok, message = pcall(callback)

    if ok then
        fail("expected an error", 2)
    end

    if expectedText and not tostring(message):find(expectedText, 1, true) then
        fail(("expected error containing %q, got %q"):format(expectedText, tostring(message)), 2)
    end
end

function Harness.findProfile(profiles, kind, identity)
    for index = 1, #profiles do
        local profileID = profiles[index].profileID

        if profileID.kind == kind then
            if kind == "user" and profileID.name == identity then
                return profiles[index]
            end

            if kind == "permanent" and profileID.profile == identity then
                return profiles[index]
            end
        end
    end

    return nil
end

local function installWoWMocks(environment)
    _G.GLOBAL = "Global"
    _G.FACTION_HORDE = "Horde"
    _G.FACTION_ALLIANCE = "Alliance"
    _G.LOCALIZED_CLASS_NAMES_MALE = {
        MAGE = "Mage",
        SHAMAN = "Shaman",
    }

    _G.UnitGUID = function()
        return environment.identity.guid
    end

    _G.UnitName = function()
        return environment.identity.name
    end

    _G.GetRealmID = function()
        return environment.identity.realmID
    end

    _G.GetRealmName = function()
        return environment.identity.realmName
    end

    _G.GetNormalizedRealmName = function()
        return environment.identity.realmName:gsub(" ", "")
    end

    _G.UnitClassBase = function()
        return environment.identity.class, environment.identity.classID
    end

    _G.UnitClass = function()
        return environment.identity.className, environment.identity.class, environment.identity.classID
    end

    _G.UnitFactionGroup = function()
        return environment.identity.faction, environment.identity.factionName
    end

    _G.UnitLevel = function()
        return environment.identity.level
    end

    _G.GetClassInfo = function(classID)
        return environment.classNames[classID]
    end

    _G.time = function()
        return environment.now
    end

    _G.C_SpecializationInfo = {
        GetSpecialization = function()
            return environment.identity.specID and 1 or nil
        end,

        GetSpecializationInfo = function()
            return environment.identity.specID, environment.identity.specName
        end,

        GetSpecializationNameForSpecID = function(specID)
            return environment.specNames[specID]
        end,
    }
    _G.C_AddOns = {
        GetAddOnMetadata = function(addonName, field)
            if field == "Title" then
                return environment.addonTitles[addonName]
            end
        end,
    }

    _G.geterrorhandler = function()
        return function(message)
            environment.callbackErrors[#environment.callbackErrors + 1] = tostring(message)
        end
    end

    _G.CreateFrame = function()
        local frame = {
            events = {},
            scripts = {},
        }

        function frame:RegisterEvent(event)
            self.events[event] = true
        end

        function frame:SetScript(script, callback)
            self.scripts[script] = callback
        end

        function frame:Fire(event, ...)
            if self.events[event] and self.scripts.OnEvent then
                self.scripts.OnEvent(self, event, ...)
            end
        end

        environment.frames[#environment.frames + 1] = frame
        return frame
    end
end

function Harness.freshLibrary(overrides)
    local environment = {
        identity = {
            guid = "Player-3676-00000001",
            name = "Example",
            realmID = 3676,
            realmName = "Area 52",
            class = "SHAMAN",
            classID = 7,
            className = "Shaman",
            faction = "Horde",
            factionName = "Horde",
            specID = 262,
            specName = "Elemental",
            level = 80,
        },
        classNames = {
            [7] = "Shaman",
            [8] = "Mage",
        },
        specNames = {
            [62] = "Arcane",
            [262] = "Elemental",
            [263] = "Enhancement",
        },
        addonTitles = {
            TestAddon = "Test Addon",
        },
        callbackErrors = {},
        frames = {},
        now = 1784246400,
    }

    if overrides then
        for key, value in pairs(overrides) do
            environment.identity[key] = value
        end
    end

    installWoWMocks(environment)
    dofile("tests/libstub.lua")
    dofile("../LibSimpleDB/LibSimpleDB-2.0.lua")

    for index = 1, #profileFiles do
        dofile(profileFiles[index])
    end

    environment.library = LibStub("LibSimpleDBProfiles-1.0")
    environment.frame = environment.frames[#environment.frames]
    return environment
end

function Harness.loadSuite(path)
    local chunk, message = loadfile(path)

    if not chunk then
        error(message, 2)
    end

    chunk(Harness)
end

function Harness.loadProfileLibrary(minor)
    for index = 1, #profileFiles do
        local path = profileFiles[index]

        if not minor or minor == 1 then
            dofile(path)
        else
            local handle = assert(io.open(path, "rb"))
            local source = handle:read("*a")
            handle:close()
            source = source:gsub(
                'local LIBRARY_MAJOR, LIBRARY_MINOR = "LibSimpleDBProfiles%-1%.0", 1',
                ('local LIBRARY_MAJOR, LIBRARY_MINOR = "LibSimpleDBProfiles-1.0", %d'):format(minor),
                1
            )
            source = source:gsub("local BUILD_MINOR = 1", "local BUILD_MINOR = " .. minor)
            local chunk, message = loadstring(source, "@" .. path)

            if not chunk then
                error(message, 2)
            end

            chunk()
        end
    end

    return LibStub("LibSimpleDBProfiles-1.0")
end

function Harness.run()
    local passed = 0
    local failed = 0

    for index = 1, #Harness.tests do
        local current = Harness.tests[index]
        local ok, message = pcall(current.callback)

        if ok then
            passed = passed + 1
            io.write(("ok %d - %s\n"):format(index, current.name))
        else
            failed = failed + 1
            io.write(("not ok %d - %s\n%s\n"):format(index, current.name, tostring(message)))
        end
    end

    io.write(("\n%d passed, %d failed\n"):format(passed, failed))

    if failed > 0 then
        os.exit(1)
    end
end

return Harness
