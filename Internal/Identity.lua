-- Capture canonical character identity and translate between selectable
-- profileRef values, exact profileID values, and localized display names.
local BUILD_MINOR = 2
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal

local error = error
local pairs = pairs
local tostring = tostring
local type = type

local CAPTURE_ERROR_LEVEL = 2
local IDENTITY_FIELD_ERROR_LEVEL = 3
local REFERENCE_ERROR_LEVEL = 3
local RECORD_FIELD_ERROR_LEVEL = 4
local PLAYER_UNIT = "player"
local INVALID_NUMERIC_ID = 0
local INVALID_ID_TEXT = "0"
local ADDON_TITLE_METADATA_FIELD = "Title"
local HORDE_FACTION = "Horde"
local ALLIANCE_FACTION = "Alliance"

-- This order is also the one-time initial-selection priority, from most to
-- least character-specific. Global is the guaranteed final fallback.
Internal.permanentProfileOrder = {
    "character",
    "spec",
    "class",
    "realm",
    "faction",
    "global",
}

-- A permanent profileRef names one definition. Its exact profileID key comes
-- from the corresponding canonical character-identity field.
Internal.permanentProfileDefinitions = {
    character = { container = "characters", characterField = "guid" },
    spec = { container = "specs", characterField = "specID" },
    class = { container = "classes", characterField = "class" },
    realm = { container = "realms", characterField = "realmID" },
    faction = { container = "factions", characterField = "faction" },
    global = { container = "global" },
}

-- Current-character identity capture

local function requireIdentityString(value, label)
    if type(value) ~= "string" or value == "" then
        error(
            ("LibSimpleDBProfiles: player %s is unavailable; construct after SavedVariables and player identity are ready"):format(
                label
            ),
            IDENTITY_FIELD_ERROR_LEVEL
        )
    end

    return value
end

local function captureSpecializationIdentity()
    local specializationIndex = C_SpecializationInfo.GetSpecialization()

    if not specializationIndex then
        return nil, nil
    end

    local specID, specName = C_SpecializationInfo.GetSpecializationInfo(specializationIndex)

    if type(specID) ~= "number" or specID == INVALID_NUMERIC_ID then
        return nil, nil
    end

    return tostring(specID), specName
end

function Internal.CaptureCurrentIdentity()
    local guid = requireIdentityString(UnitGUID(PLAYER_UNIT), "GUID")
    local name = requireIdentityString(UnitName(PLAYER_UNIT), "name")
    local realmIDValue = GetRealmID()

    if type(realmIDValue) ~= "number" and type(realmIDValue) ~= "string" then
        error(
            "LibSimpleDBProfiles: player realm ID is unavailable; construct after player identity is ready",
            CAPTURE_ERROR_LEVEL
        )
    end

    if realmIDValue == INVALID_NUMERIC_ID
        or realmIDValue == ""
        or realmIDValue == INVALID_ID_TEXT then
        error(
            "LibSimpleDBProfiles: player realm ID is unavailable; construct after player identity is ready",
            CAPTURE_ERROR_LEVEL
        )
    end

    local realmID = requireIdentityString(tostring(realmIDValue), "realm ID")
    local realmName = GetRealmName()

    if type(realmName) ~= "string" or realmName == "" then
        realmName = GetNormalizedRealmName()
    end

    realmName = requireIdentityString(realmName, "realm name")

    local class, classID = UnitClassBase(PLAYER_UNIT)
    class = requireIdentityString(class, "class")

    if type(classID) ~= "number" then
        error(
            "LibSimpleDBProfiles: player class ID is unavailable; construct after player identity is ready",
            CAPTURE_ERROR_LEVEL
        )
    end

    local className = UnitClass(PLAYER_UNIT)

    if type(className) ~= "string" or className == "" then
        className = class
    end

    local faction, factionName = UnitFactionGroup(PLAYER_UNIT)
    faction = requireIdentityString(faction, "faction")

    if type(factionName) ~= "string" or factionName == "" then
        factionName = faction
    end

    local specID, specName = captureSpecializationIdentity()
    local level = UnitLevel(PLAYER_UNIT)

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

function Internal.BuildCharacterInfo(identity)
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

-- profileRef and profileID validation and resolution

local function validateRecordFields(value, allowedFields, operation, label)
    for key in pairs(value) do
        if not allowedFields[key] then
            error(
                ("LibSimpleDBProfiles: %s: malformed %s field %q"):format(
                    operation,
                    label,
                    tostring(key)
                ),
                RECORD_FIELD_ERROR_LEVEL
            )
        end
    end
end

function Internal.NormalizeProfileRef(profileRef, operation)
    if type(profileRef) ~= "table" then
        error(("Usage: %s(profileRef) requires a typed profile reference"):format(operation), REFERENCE_ERROR_LEVEL)
    end

    if profileRef.kind == "user" then
        validateRecordFields(profileRef, { kind = true, name = true }, operation, "profile reference")
        local normalizedName, errorCode = Internal.NormalizeProfileName(profileRef.name, operation)

        if not normalizedName then
            return nil, errorCode
        end

        return { kind = "user", name = normalizedName }
    end

    if profileRef.kind == "permanent" then
        validateRecordFields(profileRef, { kind = true, profile = true }, operation, "profile reference")

        if not Internal.permanentProfileDefinitions[profileRef.profile] then
            error(
                ("LibSimpleDBProfiles: %s: unsupported permanent profile %q"):format(
                    operation,
                    tostring(profileRef.profile)
                ),
                REFERENCE_ERROR_LEVEL
            )
        end

        return { kind = "permanent", profile = profileRef.profile }
    end

    error(
        ("LibSimpleDBProfiles: %s: unknown profile reference kind %q"):format(
            operation,
            tostring(profileRef.kind)
        ),
        REFERENCE_ERROR_LEVEL
    )
end

function Internal.NormalizeProfileID(profileID, operation)
    if type(profileID) ~= "table" then
        error(("Usage: %s(profileID) requires a typed profile ID"):format(operation), REFERENCE_ERROR_LEVEL)
    end

    if profileID.kind == "user" then
        validateRecordFields(profileID, { kind = true, name = true }, operation, "profile ID")
        local normalizedName, errorCode = Internal.NormalizeProfileName(profileID.name, operation)

        if not normalizedName then
            return nil, errorCode
        end

        return { kind = "user", name = normalizedName }
    end

    if profileID.kind ~= "permanent" then
        error(
            ("LibSimpleDBProfiles: %s: unknown profile ID kind %q"):format(
                operation,
                tostring(profileID.kind)
            ),
            REFERENCE_ERROR_LEVEL
        )
    end

    validateRecordFields(profileID, { kind = true, profile = true, key = true }, operation, "profile ID")
    local permanentProfileDefinition = Internal.permanentProfileDefinitions[profileID.profile]

    if not permanentProfileDefinition then
        error(
            ("LibSimpleDBProfiles: %s: unsupported permanent profile %q"):format(
                operation,
                tostring(profileID.profile)
            ),
            REFERENCE_ERROR_LEVEL
        )
    end

    if profileID.profile == "global" then
        if profileID.key ~= nil then
            error(
                ("LibSimpleDBProfiles: %s: Global profile ID must not contain a key"):format(
                    operation
                ),
                REFERENCE_ERROR_LEVEL
            )
        end

        return { kind = "permanent", profile = "global" }
    end

    if type(profileID.key) ~= "string" or profileID.key == "" then
        error(
            ("LibSimpleDBProfiles: %s: permanent profile ID requires a non-empty string key"):format(
                operation
            ),
            REFERENCE_ERROR_LEVEL
        )
    end

    return { kind = "permanent", profile = profileID.profile, key = profileID.key }
end

function Internal.ResolveProfileRef(profileRef, guid, characterInfo)
    if profileRef.kind == "user" then
        return { kind = "user", name = profileRef.name }
    end

    local profileType = profileRef.profile

    if profileType == "global" then
        return { kind = "permanent", profile = "global" }
    end

    if profileType == "character" then
        if type(guid) ~= "string" or guid == "" then
            return nil
        end

        return { kind = "permanent", profile = "character", key = guid }
    end

    local permanentProfileDefinition = Internal.permanentProfileDefinitions[profileType]
    local key = characterInfo and characterInfo[permanentProfileDefinition.characterField]

    if type(key) ~= "string" or key == "" then
        return nil
    end

    return { kind = "permanent", profile = profileType, key = key }
end

function Internal.ResolveCurrentProfileID(manager, profileType)
    return Internal.ResolveProfileRef(
        { kind = "permanent", profile = profileType },
        manager._identity.guid,
        manager._identity
    )
end

function Internal.SelectableProfileRefForID(manager, profileID)
    if profileID.kind == "user" then
        return { kind = "user", name = profileID.name }
    end

    local profileRef = { kind = "permanent", profile = profileID.profile }
    local currentProfileID = Internal.ResolveCurrentProfileID(manager, profileID.profile)

    if currentProfileID and Internal.ProfileIDEqual(currentProfileID, profileID) then
        return profileRef
    end

    return nil
end

-- Localized display-name resolution

local function findCharacterInfoByField(storage, field, value)
    for _, characterInfo in pairs(storage.characterInfo) do
        if characterInfo[field] == value then
            return characterInfo
        end
    end

    return nil
end

local function getClassDisplayName(manager, classKey)
    if manager._identity.class == classKey then
        return manager._identity.className
    end

    local characterInfo = findCharacterInfoByField(manager._storage, "class", classKey)

    if characterInfo and type(GetClassInfo) == "function" and characterInfo.classID then
        local name = GetClassInfo(characterInfo.classID)

        if type(name) == "string" and name ~= "" then
            return name
        end
    end

    local localized = _G.LOCALIZED_CLASS_NAMES_MALE
    return localized and localized[classKey] or classKey
end

local function getSpecDisplayName(manager, specKey)
    if manager._identity.specID == specKey and manager._identity.specName then
        return manager._identity.specName
    end

    local numericSpecID = tonumber(specKey)

    if numericSpecID and C_SpecializationInfo.GetSpecializationNameForSpecID then
        local specName = C_SpecializationInfo.GetSpecializationNameForSpecID(numericSpecID)

        if type(specName) == "string" and specName ~= "" then
            return specName
        end
    end

    return specKey
end

function Internal.ResolveProfileDisplayName(manager, profileID)
    if profileID.kind == "user" then
        return profileID.name
    end

    local profileType = profileID.profile

    if profileType == "global" then
        return _G.GLOBAL or "Global"
    end

    if profileType == "character" then
        local characterInfo = manager._storage.characterInfo[profileID.key]
        return characterInfo and characterInfo.name or profileID.key
    end

    if profileType == "realm" then
        if manager._identity.realmID == profileID.key then
            return manager._identity.realmName
        end

        local characterInfo = findCharacterInfoByField(manager._storage, "realmID", profileID.key)
        return characterInfo and characterInfo.realmName or profileID.key
    end

    if profileType == "class" then
        return getClassDisplayName(manager, profileID.key)
    end

    if profileType == "spec" then
        return getSpecDisplayName(manager, profileID.key)
    end

    if profileType == "faction" then
        if manager._identity.faction == profileID.key then
            return manager._identity.factionName
        end

        if profileID.key == HORDE_FACTION then
            return _G.FACTION_HORDE or profileID.key
        end

        if profileID.key == ALLIANCE_FACTION then
            return _G.FACTION_ALLIANCE or profileID.key
        end

        return profileID.key
    end

    return profileType
end

function Internal.FormatProfileID(profileID)
    if profileID.kind == "user" then
        return "user:" .. profileID.name
    end

    if profileID.key then
        return profileID.profile .. ":" .. profileID.key
    end

    return profileID.profile
end

function Internal.ResolveAddonDisplayName(addonName)
    local addonTitle

    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        addonTitle = C_AddOns.GetAddOnMetadata(addonName, ADDON_TITLE_METADATA_FIELD)
    end

    if type(addonTitle) ~= "string" or addonTitle == "" then
        return addonName
    end

    return addonTitle
end
