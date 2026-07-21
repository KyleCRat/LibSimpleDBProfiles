local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal

local error = error
local pairs = pairs
local tostring = tostring
local type = type

Internal.permanentOrder = {
    "character",
    "spec",
    "class",
    "realm",
    "faction",
    "global",
}

Internal.permanentProfiles = {
    character = { container = "characters", identityField = "guid" },
    spec = { container = "specs", identityField = "specID" },
    class = { container = "classes", identityField = "class" },
    realm = { container = "realms", identityField = "realmID" },
    faction = { container = "factions", identityField = "faction" },
    global = { container = "global" },
}

local function requiredString(value, label)
    if type(value) ~= "string" or value == "" then
        error(("LibSimpleDBProfiles: player %s is unavailable; construct after SavedVariables and player identity are ready"):format(label), 3)
    end

    return value
end

local function getSpecializationIdentity()
    local specializationIndex = C_SpecializationInfo.GetSpecialization()

    if not specializationIndex then
        return nil, nil
    end

    local specID, specName = C_SpecializationInfo.GetSpecializationInfo(specializationIndex)

    if type(specID) ~= "number" or specID == 0 then
        return nil, nil
    end

    return tostring(specID), specName
end

function Internal.CaptureCurrentIdentity()
    local guid = requiredString(UnitGUID("player"), "GUID")
    local name = requiredString(UnitName("player"), "name")
    local realmIDValue = GetRealmID()

    if type(realmIDValue) ~= "number" and type(realmIDValue) ~= "string" then
        error("LibSimpleDBProfiles: player realm ID is unavailable; construct after player identity is ready", 2)
    end

    if realmIDValue == 0 or realmIDValue == "" or realmIDValue == "0" then
        error("LibSimpleDBProfiles: player realm ID is unavailable; construct after player identity is ready", 2)
    end

    local realmID = requiredString(tostring(realmIDValue), "realm ID")
    local realmName = GetRealmName()

    if type(realmName) ~= "string" or realmName == "" then
        realmName = GetNormalizedRealmName()
    end

    realmName = requiredString(realmName, "realm name")

    local class, classID = UnitClassBase("player")
    class = requiredString(class, "class")

    if type(classID) ~= "number" then
        error("LibSimpleDBProfiles: player class ID is unavailable; construct after player identity is ready", 2)
    end

    local className = UnitClass("player")

    if type(className) ~= "string" or className == "" then
        className = class
    end

    local faction, factionName = UnitFactionGroup("player")
    faction = requiredString(faction, "faction")

    if type(factionName) ~= "string" or factionName == "" then
        factionName = faction
    end

    local specID, specName = getSpecializationIdentity()
    local level = UnitLevel("player")

    if type(level) ~= "number" then
        level = nil
    end

    return {
        guid = guid,
        name = name,
        realmID = realmID,
        realmName = realmName,
        class = class,
        classID = classID,
        className = className,
        faction = faction,
        factionName = factionName,
        specID = specID,
        specName = specName,
        level = level,
        lastSeen = time(),
    }
end

function Internal.IdentityToCharacterInfo(identity)
    return {
        name = identity.name,
        realmID = identity.realmID,
        realmName = identity.realmName,
        class = identity.class,
        classID = identity.classID,
        faction = identity.faction,
        specID = identity.specID,
        level = identity.level,
        lastSeen = identity.lastSeen,
    }
end

local function validateShape(value, allowed, operation, label)
    for key in pairs(value) do
        if not allowed[key] then
            error(("LibSimpleDBProfiles: %s: malformed %s field %q"):format(operation, label, tostring(key)), 4)
        end
    end
end

function Internal.NormalizeProfileRef(profileRef, operation)
    if type(profileRef) ~= "table" then
        error(("Usage: %s(profileRef) requires a typed profile reference"):format(operation), 3)
    end

    if profileRef.kind == "user" then
        validateShape(profileRef, { kind = true, name = true }, operation, "profile reference")
        local name, errorCode = Internal.NormalizeProfileName(profileRef.name, operation)

        if not name then
            return nil, errorCode
        end

        return { kind = "user", name = name }
    end

    if profileRef.kind == "permanent" then
        validateShape(profileRef, { kind = true, profile = true }, operation, "profile reference")

        if not Internal.permanentProfiles[profileRef.profile] then
            error(("LibSimpleDBProfiles: %s: unsupported permanent profile %q"):format(operation, tostring(profileRef.profile)), 3)
        end

        return { kind = "permanent", profile = profileRef.profile }
    end

    error(("LibSimpleDBProfiles: %s: unknown profile reference kind %q"):format(operation, tostring(profileRef.kind)), 3)
end

function Internal.NormalizeProfileID(profileID, operation)
    if type(profileID) ~= "table" then
        error(("Usage: %s(profileID) requires a typed profile ID"):format(operation), 3)
    end

    if profileID.kind == "user" then
        validateShape(profileID, { kind = true, name = true }, operation, "profile ID")
        local name, errorCode = Internal.NormalizeProfileName(profileID.name, operation)

        if not name then
            return nil, errorCode
        end

        return { kind = "user", name = name }
    end

    if profileID.kind ~= "permanent" then
        error(("LibSimpleDBProfiles: %s: unknown profile ID kind %q"):format(operation, tostring(profileID.kind)), 3)
    end

    validateShape(profileID, { kind = true, profile = true, key = true }, operation, "profile ID")
    local definition = Internal.permanentProfiles[profileID.profile]

    if not definition then
        error(("LibSimpleDBProfiles: %s: unsupported permanent profile %q"):format(operation, tostring(profileID.profile)), 3)
    end

    if profileID.profile == "global" then
        if profileID.key ~= nil then
            error(("LibSimpleDBProfiles: %s: Global profile ID must not contain a key"):format(operation), 3)
        end

        return { kind = "permanent", profile = "global" }
    end

    if type(profileID.key) ~= "string" or profileID.key == "" then
        error(("LibSimpleDBProfiles: %s: permanent profile ID requires a non-empty string key"):format(operation), 3)
    end

    return { kind = "permanent", profile = profileID.profile, key = profileID.key }
end

function Internal.ResolveProfileRef(profileRef, guid, characterInfo)
    if profileRef.kind == "user" then
        return { kind = "user", name = profileRef.name }
    end

    local profile = profileRef.profile

    if profile == "global" then
        return { kind = "permanent", profile = "global" }
    end

    if profile == "character" then
        if type(guid) ~= "string" or guid == "" then
            return nil
        end

        return { kind = "permanent", profile = "character", key = guid }
    end

    local definition = Internal.permanentProfiles[profile]
    local key = characterInfo and characterInfo[definition.identityField]

    if type(key) ~= "string" or key == "" then
        return nil
    end

    return { kind = "permanent", profile = profile, key = key }
end

function Internal.CurrentProfileID(manager, profile)
    return Internal.ResolveProfileRef(
        { kind = "permanent", profile = profile },
        manager._identity.guid,
        manager._identity
    )
end

function Internal.ProfileRefForID(manager, profileID)
    if profileID.kind == "user" then
        return { kind = "user", name = profileID.name }
    end

    local profileRef = { kind = "permanent", profile = profileID.profile }
    local currentID = Internal.CurrentProfileID(manager, profileID.profile)

    if currentID and Internal.ProfileIdentityEqual(currentID, profileID) then
        return profileRef
    end

    return nil
end

local function findCharacterInfo(storage, field, value)
    for _, info in pairs(storage.characterInfo) do
        if info[field] == value then
            return info
        end
    end

    return nil
end

local function getClassDisplayName(manager, key)
    if manager._identity.class == key then
        return manager._identity.className
    end

    local info = findCharacterInfo(manager._storage, "class", key)

    if info and type(GetClassInfo) == "function" and info.classID then
        local name = GetClassInfo(info.classID)

        if type(name) == "string" and name ~= "" then
            return name
        end
    end

    local localized = _G.LOCALIZED_CLASS_NAMES_MALE
    return localized and localized[key] or key
end

local function getSpecDisplayName(manager, key)
    if manager._identity.specID == key and manager._identity.specName then
        return manager._identity.specName
    end

    local numericID = tonumber(key)

    if numericID and C_SpecializationInfo.GetSpecializationNameForSpecID then
        local name = C_SpecializationInfo.GetSpecializationNameForSpecID(numericID)

        if type(name) == "string" and name ~= "" then
            return name
        end
    end

    return key
end

function Internal.ProfileDisplayName(manager, profileID)
    if profileID.kind == "user" then
        return profileID.name
    end

    local profile = profileID.profile

    if profile == "global" then
        return _G.GLOBAL or "Global"
    end

    if profile == "character" then
        local info = manager._storage.characterInfo[profileID.key]
        return info and info.name or profileID.key
    end

    if profile == "realm" then
        if manager._identity.realmID == profileID.key then
            return manager._identity.realmName
        end

        local info = findCharacterInfo(manager._storage, "realmID", profileID.key)
        return info and info.realmName or profileID.key
    end

    if profile == "class" then
        return getClassDisplayName(manager, profileID.key)
    end

    if profile == "spec" then
        return getSpecDisplayName(manager, profileID.key)
    end

    if profile == "faction" then
        if manager._identity.faction == profileID.key then
            return manager._identity.factionName
        end

        if profileID.key == "Horde" then
            return _G.FACTION_HORDE or profileID.key
        end

        if profileID.key == "Alliance" then
            return _G.FACTION_ALLIANCE or profileID.key
        end

        return profileID.key
    end

    return profile
end

function Internal.ProfileIDLabel(profileID)
    if profileID.kind == "user" then
        return "user:" .. profileID.name
    end

    if profileID.key then
        return profileID.profile .. ":" .. profileID.key
    end

    return profileID.profile
end

function Internal.ResolveAddonDisplayName(addonName)
    local title

    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        title = C_AddOns.GetAddOnMetadata(addonName, "Title")
    end

    if type(title) ~= "string" or title == "" then
        return addonName
    end

    return title
end
