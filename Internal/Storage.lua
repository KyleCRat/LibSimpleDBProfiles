-- Own the private SavedVariables schema and raw payload containers. This file
-- never applies LibSimpleDB defaults to stored profile payloads.
local BUILD_MINOR = 2
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal

local error = error
local next = next
local pairs = pairs
local pcall = pcall
local type = type

local STORAGE_ERROR_LEVEL = 3
local STORAGE_METADATA_KEY = "__lsdbProfiles"
local CURRENT_STORAGE_SCHEMA_VERSION = 1
local INITIAL_PAYLOAD_VERSION = 1

-- Future library-owned schema migrations are indexed by their source version.
local storageMigrationsBySourceVersion = {}

local TABLE_CONTAINER_KEYS = {
    "realms",
    "characters",
    "characterInfo",
    "classes",
    "specs",
    "factions",
    "profiles",
    "selections",
}

local ALLOWED_STORAGE_ROOT_KEYS = {
    [STORAGE_METADATA_KEY] = true,
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

local CHARACTER_INFO_FIELD_TYPES = {
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

local function requireTable(value, label)
    if type(value) ~= "table" then
        error(("LibSimpleDBProfiles: corrupt storage: %s must be a table"):format(label), STORAGE_ERROR_LEVEL)
    end

    return value
end

local function validateRootKeys(storage)
    for key in pairs(storage) do
        if not ALLOWED_STORAGE_ROOT_KEYS[key] then
            error(
                ("LibSimpleDBProfiles: unrecognized unversioned storage key %q; wrap legacy data in a new profile container"):format(
                    tostring(key)
                ),
                STORAGE_ERROR_LEVEL
            )
        end
    end
end

local function validateMetadata(storageMetadata)
    for key in pairs(storageMetadata) do
        if key ~= "schema" and key ~= "payloadVersion" then
            error(
                ("LibSimpleDBProfiles: corrupt storage: unknown metadata field %q"):format(
                    tostring(key)
                ),
                STORAGE_ERROR_LEVEL
            )
        end
    end

    if not Internal.IsPositiveInteger(storageMetadata.schema) then
        error("LibSimpleDBProfiles: corrupt storage: schema must be a positive integer", STORAGE_ERROR_LEVEL)
    end

    if storageMetadata.payloadVersion ~= nil
        and not Internal.IsPositiveInteger(storageMetadata.payloadVersion) then
        error("LibSimpleDBProfiles: corrupt storage: payloadVersion must be a positive integer", STORAGE_ERROR_LEVEL)
    end
end

local function runStorageMigrations(storage, storageMetadata)
    if storageMetadata.schema > CURRENT_STORAGE_SCHEMA_VERSION then
        error(("LibSimpleDBProfiles: storage schema %d is newer than supported schema %d"):format(
            storageMetadata.schema,
            CURRENT_STORAGE_SCHEMA_VERSION
        ), STORAGE_ERROR_LEVEL)
    end

    while storageMetadata.schema < CURRENT_STORAGE_SCHEMA_VERSION do
        local sourceSchemaVersion = storageMetadata.schema
        local targetSchemaVersion = sourceSchemaVersion + 1
        local migrationStep = storageMigrationsBySourceVersion[sourceSchemaVersion]

        if type(migrationStep) ~= "function" then
            error(
                ("LibSimpleDBProfiles: no storage migration from schema %d"):format(
                    sourceSchemaVersion
                ),
                STORAGE_ERROR_LEVEL
            )
        end

        local stagedStorage = Internal.CopyValue(storage)
        local ok, message = pcall(migrationStep, stagedStorage)

        if not ok then
            error(("LibSimpleDBProfiles: storage migration %d to %d failed: %s"):format(
                sourceSchemaVersion,
                targetSchemaVersion,
                tostring(message)
            ), STORAGE_ERROR_LEVEL)
        end

        local stagedMetadata = requireTable(stagedStorage[STORAGE_METADATA_KEY], STORAGE_METADATA_KEY)
        stagedMetadata.schema = targetSchemaVersion
        Internal.ValidateValue(stagedStorage)
        Internal.ReplaceTable(storage, stagedStorage)
        storageMetadata = storage[STORAGE_METADATA_KEY]
    end

    return storageMetadata
end

local function normalizePermanentProfileContainer(profilePayloads, label)
    for key, profilePayload in pairs(profilePayloads) do
        if type(key) ~= "string" or key == "" then
            error(
                ("LibSimpleDBProfiles: corrupt storage: %s keys must be non-empty strings"):format(
                    label
                ),
                STORAGE_ERROR_LEVEL
            )
        end

        requireTable(profilePayload, label .. "[" .. key .. "]")
        Internal.ValidateValue(profilePayload)
    end
end

local function normalizeUserProfiles(profiles)
    local storedNames = Internal.SortedKeys(profiles)

    for index = 1, #storedNames do
        local storedName = storedNames[index]

        if type(storedName) ~= "string" then
            error("LibSimpleDBProfiles: corrupt storage: user profile keys must be strings", STORAGE_ERROR_LEVEL)
        end

        local normalizedName = Internal.NormalizeProfileName(storedName, "storage profile")

        if not normalizedName then
            error(
                ("LibSimpleDBProfiles: corrupt storage: invalid user profile name %q"):format(
                    storedName
                ),
                STORAGE_ERROR_LEVEL
            )
        end

        local profilePayload = requireTable(profiles[storedName], "profiles[" .. storedName .. "]")
        Internal.ValidateValue(profilePayload)

        if normalizedName ~= storedName then
            if profiles[normalizedName] ~= nil then
                error(
                    ("LibSimpleDBProfiles: corrupt storage: normalized user profile collision for %q"):format(
                        normalizedName
                    ),
                    STORAGE_ERROR_LEVEL
                )
            end

            profiles[normalizedName] = profilePayload
            profiles[storedName] = nil
        end
    end
end

local function normalizeCharacterInfo(characterInfoByGUID)
    for guid, characterInfo in pairs(characterInfoByGUID) do
        if type(guid) ~= "string" or guid == "" then
            error(
                "LibSimpleDBProfiles: corrupt storage: characterInfo keys must be non-empty GUID strings",
                STORAGE_ERROR_LEVEL
            )
        end

        requireTable(characterInfo, "characterInfo[" .. guid .. "]")

        for field, value in pairs(characterInfo) do
            local expectedType = CHARACTER_INFO_FIELD_TYPES[field]

            if not expectedType then
                error(
                    ("LibSimpleDBProfiles: corrupt storage: unknown characterInfo field %q"):format(
                        tostring(field)
                    ),
                    STORAGE_ERROR_LEVEL
                )
            end

            if value ~= nil and type(value) ~= expectedType then
                error(
                    ("LibSimpleDBProfiles: corrupt storage: characterInfo.%s must be a %s"):format(
                        field,
                        expectedType
                    ),
                    STORAGE_ERROR_LEVEL
                )
            end
        end
    end
end

local function normalizeSelections(storage)
    for guid, selection in pairs(storage.selections) do
        if type(guid) ~= "string" or guid == "" then
            error(
                "LibSimpleDBProfiles: corrupt storage: selection keys must be non-empty GUID strings",
                STORAGE_ERROR_LEVEL
            )
        end

        local normalizedRef, errorCode = Internal.NormalizeProfileRef(selection, "stored selection")

        if not normalizedRef then
            error(
                ("LibSimpleDBProfiles: corrupt storage: stored selection failed with %s"):format(
                    errorCode
                ),
                STORAGE_ERROR_LEVEL
            )
        end

        if normalizedRef.kind == "user" and storage.profiles[normalizedRef.name] == nil then
            storage.selections[guid] = nil
        else
            storage.selections[guid] = normalizedRef
            local profileID = Internal.ResolveProfileRef(
                normalizedRef,
                guid,
                storage.characterInfo[guid]
            )

            if profileID and profileID.kind == "permanent" then
                Internal.EnsureProfilePayload(storage, profileID)
            end
        end
    end
end

-- Raw payload access. These tables contain consumer overrides only; callers use
-- LibSimpleDB when they need defaults applied.

function Internal.GetProfilePayload(storage, profileID)
    if profileID.kind == "user" then
        return storage.profiles[profileID.name]
    end

    if profileID.profile == "global" then
        return storage.global
    end

    local container = storage[Internal.permanentProfileDefinitions[profileID.profile].container]
    return container[profileID.key]
end

function Internal.SetProfilePayload(storage, profileID, profilePayload)
    if profileID.kind == "user" then
        storage.profiles[profileID.name] = profilePayload
    elseif profileID.profile == "global" then
        storage.global = profilePayload
    else
        storage[Internal.permanentProfileDefinitions[profileID.profile].container][profileID.key] = profilePayload
    end

    return profilePayload
end

function Internal.EnsureProfilePayload(storage, profileID)
    local profilePayload = Internal.GetProfilePayload(storage, profileID)

    if profilePayload then
        return profilePayload, false
    end

    profilePayload = {}
    Internal.SetProfilePayload(storage, profileID, profilePayload)
    return profilePayload, true
end

function Internal.EnsureCurrentPermanentProfilePayloads(storage, identity)
    for index = 1, #Internal.permanentProfileOrder do
        local profileType = Internal.permanentProfileOrder[index]
        local profileID = Internal.ResolveProfileRef(
            { kind = "permanent", profile = profileType },
            identity.guid,
            identity
        )

        if profileID then
            Internal.EnsureProfilePayload(storage, profileID)
        end
    end
end

function Internal.NormalizeStorage(storage, identity)
    local isFreshStorage = next(storage) == nil
    local storageMetadata = storage[STORAGE_METADATA_KEY]

    if storageMetadata == nil then
        -- An unversioned table is accepted only when every key already belongs
        -- to this library. This prevents accidental capture of legacy addon data.
        validateRootKeys(storage)
        storageMetadata = {
            schema = CURRENT_STORAGE_SCHEMA_VERSION,
            payloadVersion = INITIAL_PAYLOAD_VERSION,
        }
        storage[STORAGE_METADATA_KEY] = storageMetadata
    else
        storageMetadata = requireTable(storageMetadata, STORAGE_METADATA_KEY)
        validateMetadata(storageMetadata)
        storageMetadata = runStorageMigrations(storage, storageMetadata)
    end

    validateMetadata(storageMetadata)

    if storageMetadata.payloadVersion == nil then
        storageMetadata.payloadVersion = INITIAL_PAYLOAD_VERSION
    end

    if storage.global == nil then
        storage.global = {}
    end

    requireTable(storage.global, "global")
    Internal.ValidateValue(storage.global)

    for index = 1, #TABLE_CONTAINER_KEYS do
        local containerKey = TABLE_CONTAINER_KEYS[index]

        if storage[containerKey] == nil then
            storage[containerKey] = {}
        end

        requireTable(storage[containerKey], containerKey)
    end

    normalizePermanentProfileContainer(storage.realms, "realms")
    normalizePermanentProfileContainer(storage.characters, "characters")
    normalizePermanentProfileContainer(storage.classes, "classes")
    normalizePermanentProfileContainer(storage.specs, "specs")
    normalizePermanentProfileContainer(storage.factions, "factions")
    normalizeUserProfiles(storage.profiles)
    normalizeCharacterInfo(storage.characterInfo)
    normalizeSelections(storage)
    Internal.EnsureCurrentPermanentProfilePayloads(storage, identity)

    return storageMetadata, isFreshStorage
end

function Internal.UpdateCharacterInfo(storage, identity)
    local previousCharacterInfo = storage.characterInfo[identity.guid]
    local currentCharacterInfo = Internal.BuildCharacterInfo(identity)
    storage.characterInfo[identity.guid] = currentCharacterInfo
    return not Internal.DeepEqual(previousCharacterInfo, currentCharacterInfo)
end

function Internal.CollectKnownCharacterGUIDs(storage)
    local seenGUIDs = {}
    local characterGUIDs = {}
    local characterKeyedContainers = {
        storage.characterInfo,
        storage.characters,
        storage.selections,
    }

    for index = 1, #characterKeyedContainers do
        for guid in pairs(characterKeyedContainers[index]) do
            if not seenGUIDs[guid] then
                seenGUIDs[guid] = true
                characterGUIDs[#characterGUIDs + 1] = guid
            end
        end
    end

    table.sort(characterGUIDs)
    return characterGUIDs
end

function Internal.CharacterExists(storage, characterGUID)
    return storage.characterInfo[characterGUID] ~= nil
        or storage.characters[characterGUID] ~= nil
        or storage.selections[characterGUID] ~= nil
end

function Internal.CollectProfileIDs(storage)
    local profileIDs = {
        { kind = "permanent", profile = "global" },
    }

    for index = 1, #Internal.permanentProfileOrder do
        local profileType = Internal.permanentProfileOrder[index]

        if profileType ~= "global" then
            local container = storage[Internal.permanentProfileDefinitions[profileType].container]
            local profileKeys = Internal.SortedKeys(container)

            for keyIndex = 1, #profileKeys do
                profileIDs[#profileIDs + 1] = {
                    kind = "permanent",
                    profile = profileType,
                    key = profileKeys[keyIndex],
                }
            end
        end
    end

    local userProfileNames = Internal.SortedKeys(storage.profiles)

    for index = 1, #userProfileNames do
        profileIDs[#profileIDs + 1] = { kind = "user", name = userProfileNames[index] }
    end

    return profileIDs
end

-- container/containerKey locators let migrations stage copied payloads and
-- replace the originals only after every profile succeeds for that version step.
function Internal.CollectPayloadEntries(storage)
    local payloadEntries = {
        {
            container = storage,
            containerKey = "global",
            payload = storage.global,
            profileID = { kind = "permanent", profile = "global" },
        },
    }

    for index = 1, #Internal.permanentProfileOrder do
        local profileType = Internal.permanentProfileOrder[index]

        if profileType ~= "global" then
            local container = storage[Internal.permanentProfileDefinitions[profileType].container]
            local profileKeys = Internal.SortedKeys(container)

            for keyIndex = 1, #profileKeys do
                local profileKey = profileKeys[keyIndex]
                payloadEntries[#payloadEntries + 1] = {
                    container = container,
                    containerKey = profileKey,
                    payload = container[profileKey],
                    profileID = { kind = "permanent", profile = profileType, key = profileKey },
                }
            end
        end
    end

    local userProfileNames = Internal.SortedKeys(storage.profiles)

    for index = 1, #userProfileNames do
        local profileName = userProfileNames[index]
        payloadEntries[#payloadEntries + 1] = {
            container = storage.profiles,
            containerKey = profileName,
            payload = storage.profiles[profileName],
            profileID = { kind = "user", name = profileName },
        }
    end

    return payloadEntries
end
