-- Define consumer Migration objects and apply each payload-version step
-- atomically across every profile payload.
local BUILD_MINOR = 1
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal
local Migration = Internal.migrationPrototype

local error = error
local getmetatable = getmetatable
local pcall = pcall
local tostring = tostring
local type = type

local METHOD_ERROR_LEVEL = 2
local INTERNAL_ERROR_LEVEL = 3
local INITIAL_PAYLOAD_VERSION = 1

function Migration:Add(sourceVersion, migrationStep)
    if self._isLocked then
        error("LibSimpleDBProfiles: Migration is immutable after it is supplied to New()", METHOD_ERROR_LEVEL)
    end

    if not Internal.IsPositiveInteger(sourceVersion)
        or sourceVersion >= self._targetPayloadVersion then
        error(
            "Usage: Migration:Add(sourceVersion, callback) requires a positive source version below the current version",
            METHOD_ERROR_LEVEL
        )
    end

    if type(migrationStep) ~= "function" then
        error("Usage: Migration:Add(sourceVersion, callback) requires a function", METHOD_ERROR_LEVEL)
    end

    if self._stepsBySourceVersion[sourceVersion] then
        error(
            ("LibSimpleDBProfiles: Migration already contains source version %d"):format(
                sourceVersion
            ),
            METHOD_ERROR_LEVEL
        )
    end

    self._stepsBySourceVersion[sourceVersion] = migrationStep
    return self
end

function Internal.CreateMigration(currentVersion)
    if not Internal.IsPositiveInteger(currentVersion) then
        error(
            "Usage: LibSimpleDBProfiles:CreateMigration(currentVersion) requires a positive integer",
            INTERNAL_ERROR_LEVEL
        )
    end

    return setmetatable({
        _ownerLibrary = lib,
        _targetPayloadVersion = currentVersion,
        _stepsBySourceVersion = {},
        _isLocked = false,
    }, Internal.migrationMetatable)
end

local function validateMigrationDefinition(migration)
    if type(migration) ~= "table"
        or getmetatable(migration) ~= Internal.migrationMetatable
        or migration._ownerLibrary ~= lib then
        error("LibSimpleDBProfiles: options.migration must be created by LibSimpleDBProfiles-1.0", INTERNAL_ERROR_LEVEL)
    end

    if not Internal.IsPositiveInteger(migration._targetPayloadVersion) then
        error("LibSimpleDBProfiles: Migration current version is invalid", INTERNAL_ERROR_LEVEL)
    end

    for sourceVersion = INITIAL_PAYLOAD_VERSION, migration._targetPayloadVersion - 1 do
        if type(migration._stepsBySourceVersion[sourceVersion]) ~= "function" then
            error(
                ("LibSimpleDBProfiles: Migration is missing source version %d"):format(
                    sourceVersion
                ),
                INTERNAL_ERROR_LEVEL
            )
        end
    end

    for sourceVersion, migrationStep in pairs(migration._stepsBySourceVersion) do
        if not Internal.IsPositiveInteger(sourceVersion)
            or sourceVersion >= migration._targetPayloadVersion
            or type(migrationStep) ~= "function" then
            error("LibSimpleDBProfiles: Migration contains an invalid step", INTERNAL_ERROR_LEVEL)
        end
    end

    migration._isLocked = true
end

function Internal.RunConsumerMigrations(storage, storageMetadata, migration, isFreshStorage)
    if migration == nil then
        return
    end

    validateMigrationDefinition(migration)

    local targetPayloadVersion = migration._targetPayloadVersion

    -- Fresh storage contains no old payloads, so it starts at the consumer's
    -- declared version without invoking historical migration steps.
    if isFreshStorage then
        storageMetadata.payloadVersion = targetPayloadVersion
        return
    end

    if storageMetadata.payloadVersion > targetPayloadVersion then
        error(("LibSimpleDBProfiles: stored payloadVersion %d is newer than Migration version %d"):format(
            storageMetadata.payloadVersion,
            targetPayloadVersion
        ), INTERNAL_ERROR_LEVEL)
    end

    while storageMetadata.payloadVersion < targetPayloadVersion do
        local sourceVersion = storageMetadata.payloadVersion
        local nextVersion = sourceVersion + 1
        local migrationStep = migration._stepsBySourceVersion[sourceVersion]
        local payloadEntries = Internal.CollectPayloadEntries(storage)
        local stagedPayloads = {}

        -- Stage the entire version step before writing any profile. A failure in
        -- one callback therefore leaves every stored payload at sourceVersion.
        for index = 1, #payloadEntries do
            local payloadEntry = payloadEntries[index]
            local payload = Internal.CopyValue(payloadEntry.payload)
            local profileID = Internal.CopyValue(payloadEntry.profileID)
            local ok, message = pcall(migrationStep, payload, profileID)

            if not ok then
                error(("LibSimpleDBProfiles: consumer migration %d to %d failed for %s: %s"):format(
                    sourceVersion,
                    nextVersion,
                    Internal.FormatProfileID(profileID),
                    tostring(message)
                ), INTERNAL_ERROR_LEVEL)
            end

            Internal.ValidateValue(payload)
            stagedPayloads[index] = {
                container = payloadEntry.container,
                containerKey = payloadEntry.containerKey,
                payload = payload,
            }
        end

        for index = 1, #stagedPayloads do
            local stagedPayload = stagedPayloads[index]
            stagedPayload.container[stagedPayload.containerKey] = stagedPayload.payload
        end

        storageMetadata.payloadVersion = nextVersion
    end
end
