local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal

local error = error
local next = next
local pairs = pairs
local pcall = pcall
local type = type

Internal.currentStorageSchema = 1
Internal.storageMigrations = Internal.storageMigrations or {}

local rootContainers = {
    "realms",
    "characters",
    "characterInfo",
    "classes",
    "specs",
    "factions",
    "profiles",
    "selections",
}

local knownRootKeys = {
    __lsdbProfiles = true,
    global = true,
    realms = true,
    characters = true,
    characterInfo = true,
    classes = true,
    specs = true,
    factions = true,
    profiles = true,
    selections = true,
}

local characterInfoFields = {
    name = "string",
    realmID = "string",
    realmName = "string",
    class = "string",
    classID = "number",
    faction = "string",
    specID = "string",
    level = "number",
    lastSeen = "number",
}

local function assertTable(value, label)
    if type(value) ~= "table" then
        error(("LibSimpleDBProfiles: corrupt storage: %s must be a table"):format(label), 3)
    end

    return value
end

local function validateRootKeys(storage)
    for key in pairs(storage) do
        if not knownRootKeys[key] then
            error(("LibSimpleDBProfiles: unrecognized unversioned storage key %q; wrap legacy data in a new profile container"):format(tostring(key)), 3)
        end
    end
end

local function validateMetadata(metadata)
    for key in pairs(metadata) do
        if key ~= "schema" and key ~= "payloadVersion" then
            error(("LibSimpleDBProfiles: corrupt storage: unknown metadata field %q"):format(tostring(key)), 3)
        end
    end

    if not Internal.IsPositiveInteger(metadata.schema) then
        error("LibSimpleDBProfiles: corrupt storage: schema must be a positive integer", 3)
    end

    if metadata.payloadVersion ~= nil and not Internal.IsPositiveInteger(metadata.payloadVersion) then
        error("LibSimpleDBProfiles: corrupt storage: payloadVersion must be a positive integer", 3)
    end
end

local function migrateStorage(storage, metadata)
    local currentSchema = Internal.currentStorageSchema

    if metadata.schema > currentSchema then
        error(("LibSimpleDBProfiles: storage schema %d is newer than supported schema %d"):format(metadata.schema, currentSchema), 3)
    end

    while metadata.schema < currentSchema do
        local sourceSchema = metadata.schema
        local migration = Internal.storageMigrations[sourceSchema]

        if type(migration) ~= "function" then
            error(("LibSimpleDBProfiles: no storage migration from schema %d"):format(sourceSchema), 3)
        end

        local staged = Internal.CopyValue(storage)
        local ok, message = pcall(migration, staged)

        if not ok then
            error(("LibSimpleDBProfiles: storage migration %d to %d failed: %s"):format(
                sourceSchema,
                sourceSchema + 1,
                tostring(message)
            ), 3)
        end

        local stagedMetadata = assertTable(staged.__lsdbProfiles, "__lsdbProfiles")
        stagedMetadata.schema = sourceSchema + 1
        Internal.ValidateValue(staged)
        Internal.ReplaceTable(storage, staged)
        metadata = storage.__lsdbProfiles
    end

    return metadata
end

local function normalizeProfileMap(map, label)
    for key, value in pairs(map) do
        if type(key) ~= "string" or key == "" then
            error(("LibSimpleDBProfiles: corrupt storage: %s keys must be non-empty strings"):format(label), 3)
        end

        assertTable(value, label .. "[" .. key .. "]")
        Internal.ValidateValue(value)
    end
end

local function normalizeUserProfiles(profiles)
    local keys = Internal.SortedKeys(profiles)

    for index = 1, #keys do
        local oldName = keys[index]

        if type(oldName) ~= "string" then
            error("LibSimpleDBProfiles: corrupt storage: user profile keys must be strings", 3)
        end

        local normalized = Internal.NormalizeProfileName(oldName, "storage profile")

        if not normalized then
            error(("LibSimpleDBProfiles: corrupt storage: invalid user profile name %q"):format(oldName), 3)
        end

        local data = assertTable(profiles[oldName], "profiles[" .. oldName .. "]")
        Internal.ValidateValue(data)

        if normalized ~= oldName then
            if profiles[normalized] ~= nil then
                error(("LibSimpleDBProfiles: corrupt storage: normalized user profile collision for %q"):format(normalized), 3)
            end

            profiles[normalized] = data
            profiles[oldName] = nil
        end
    end
end

local function normalizeCharacterInfo(characterInfo)
    for guid, info in pairs(characterInfo) do
        if type(guid) ~= "string" or guid == "" then
            error("LibSimpleDBProfiles: corrupt storage: characterInfo keys must be non-empty GUID strings", 3)
        end

        assertTable(info, "characterInfo[" .. guid .. "]")

        for field, value in pairs(info) do
            local expectedType = characterInfoFields[field]

            if not expectedType then
                error(("LibSimpleDBProfiles: corrupt storage: unknown characterInfo field %q"):format(tostring(field)), 3)
            end

            if value ~= nil and type(value) ~= expectedType then
                error(("LibSimpleDBProfiles: corrupt storage: characterInfo.%s must be a %s"):format(field, expectedType), 3)
            end
        end
    end
end

local function normalizeSelections(storage)
    for guid, selection in pairs(storage.selections) do
        if type(guid) ~= "string" or guid == "" then
            error("LibSimpleDBProfiles: corrupt storage: selection keys must be non-empty GUID strings", 3)
        end

        local normalized, errorCode = Internal.NormalizeProfileRef(selection, "stored selection")

        if not normalized then
            error(("LibSimpleDBProfiles: corrupt storage: stored selection failed with %s"):format(errorCode), 3)
        end

        if normalized.kind == "user" and storage.profiles[normalized.name] == nil then
            storage.selections[guid] = nil
        else
            storage.selections[guid] = normalized
            local profileID = Internal.ResolveProfileRef(normalized, guid, storage.characterInfo[guid])

            if profileID and profileID.kind == "permanent" then
                Internal.EnsureProfileData(storage, profileID)
            end
        end
    end
end

function Internal.GetProfileData(storage, profileID)
    if profileID.kind == "user" then
        return storage.profiles[profileID.name]
    end

    if profileID.profile == "global" then
        return storage.global
    end

    local container = storage[Internal.permanentProfiles[profileID.profile].container]
    return container[profileID.key]
end

function Internal.SetProfileData(storage, profileID, data)
    if profileID.kind == "user" then
        storage.profiles[profileID.name] = data
    elseif profileID.profile == "global" then
        storage.global = data
    else
        storage[Internal.permanentProfiles[profileID.profile].container][profileID.key] = data
    end

    return data
end

function Internal.EnsureProfileData(storage, profileID)
    local data = Internal.GetProfileData(storage, profileID)

    if data then
        return data, false
    end

    data = {}
    Internal.SetProfileData(storage, profileID, data)
    return data, true
end

function Internal.EnsureCurrentPermanentProfiles(storage, identity)
    for index = 1, #Internal.permanentOrder do
        local profile = Internal.permanentOrder[index]
        local profileID = Internal.ResolveProfileRef(
            { kind = "permanent", profile = profile },
            identity.guid,
            identity
        )

        if profileID then
            Internal.EnsureProfileData(storage, profileID)
        end
    end
end

function Internal.NormalizeStorage(storage, identity)
    local wasFresh = next(storage) == nil
    local metadata = storage.__lsdbProfiles

    if metadata == nil then
        validateRootKeys(storage)
        metadata = {
            schema = Internal.currentStorageSchema,
            payloadVersion = 1,
        }
        storage.__lsdbProfiles = metadata
    else
        metadata = assertTable(metadata, "__lsdbProfiles")
        validateMetadata(metadata)
        metadata = migrateStorage(storage, metadata)
    end

    validateMetadata(metadata)

    if metadata.payloadVersion == nil then
        metadata.payloadVersion = 1
    end

    if storage.global == nil then
        storage.global = {}
    end

    assertTable(storage.global, "global")
    Internal.ValidateValue(storage.global)

    for index = 1, #rootContainers do
        local name = rootContainers[index]

        if storage[name] == nil then
            storage[name] = {}
        end

        assertTable(storage[name], name)
    end

    normalizeProfileMap(storage.realms, "realms")
    normalizeProfileMap(storage.characters, "characters")
    normalizeProfileMap(storage.classes, "classes")
    normalizeProfileMap(storage.specs, "specs")
    normalizeProfileMap(storage.factions, "factions")
    normalizeUserProfiles(storage.profiles)
    normalizeCharacterInfo(storage.characterInfo)
    normalizeSelections(storage)
    Internal.EnsureCurrentPermanentProfiles(storage, identity)

    return metadata, wasFresh
end

function Internal.UpdateCharacterInfo(storage, identity)
    local oldInfo = storage.characterInfo[identity.guid]
    local oldCopy = oldInfo and Internal.CopyValue(oldInfo) or nil
    local newInfo = Internal.IdentityToCharacterInfo(identity)
    storage.characterInfo[identity.guid] = newInfo
    return oldCopy, Internal.CopyValue(newInfo), not Internal.DeepEqual(oldCopy, newInfo)
end

function Internal.KnownCharacterGUIDs(storage)
    local seen = {}
    local guids = {}
    local containers = { storage.characterInfo, storage.characters, storage.selections }

    for index = 1, #containers do
        for guid in pairs(containers[index]) do
            if not seen[guid] then
                seen[guid] = true
                guids[#guids + 1] = guid
            end
        end
    end

    table.sort(guids)
    return guids
end

function Internal.CharacterExists(storage, guid)
    return storage.characterInfo[guid] ~= nil
        or storage.characters[guid] ~= nil
        or storage.selections[guid] ~= nil
end

function Internal.EnumerateProfileIDs(storage)
    local ids = {
        { kind = "permanent", profile = "global" },
    }

    for index = 1, #Internal.permanentOrder do
        local profile = Internal.permanentOrder[index]

        if profile ~= "global" then
            local container = storage[Internal.permanentProfiles[profile].container]
            local keys = Internal.SortedKeys(container)

            for keyIndex = 1, #keys do
                ids[#ids + 1] = {
                    kind = "permanent",
                    profile = profile,
                    key = keys[keyIndex],
                }
            end
        end
    end

    local names = Internal.SortedKeys(storage.profiles)

    for index = 1, #names do
        ids[#ids + 1] = { kind = "user", name = names[index] }
    end

    return ids
end

function Internal.EnumeratePayloadEntries(storage)
    local entries = {
        {
            parent = storage,
            key = "global",
            data = storage.global,
            profileID = { kind = "permanent", profile = "global" },
        },
    }

    for index = 1, #Internal.permanentOrder do
        local profile = Internal.permanentOrder[index]

        if profile ~= "global" then
            local container = storage[Internal.permanentProfiles[profile].container]
            local keys = Internal.SortedKeys(container)

            for keyIndex = 1, #keys do
                local key = keys[keyIndex]
                entries[#entries + 1] = {
                    parent = container,
                    key = key,
                    data = container[key],
                    profileID = { kind = "permanent", profile = profile, key = key },
                }
            end
        end
    end

    local names = Internal.SortedKeys(storage.profiles)

    for index = 1, #names do
        local name = names[index]
        entries[#entries + 1] = {
            parent = storage.profiles,
            key = name,
            data = storage.profiles[name],
            profileID = { kind = "user", name = name },
        }
    end

    return entries
end
