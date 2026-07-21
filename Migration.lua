local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal
local methods = Internal.migrationPrototype

local error = error
local getmetatable = getmetatable
local pcall = pcall
local tostring = tostring
local type = type

function methods:Add(sourceVersion, callback)
    if self._locked then
        error("LibSimpleDBProfiles: Migration is immutable after it is supplied to New()", 2)
    end

    if not Internal.IsPositiveInteger(sourceVersion) or sourceVersion >= self._currentVersion then
        error("Usage: Migration:Add(sourceVersion, callback) requires a positive source version below the current version", 2)
    end

    if type(callback) ~= "function" then
        error("Usage: Migration:Add(sourceVersion, callback) requires a function", 2)
    end

    if self._steps[sourceVersion] then
        error(("LibSimpleDBProfiles: Migration already contains source version %d"):format(sourceVersion), 2)
    end

    self._steps[sourceVersion] = callback
    return self
end

function Internal.CreateMigration(currentVersion)
    if not Internal.IsPositiveInteger(currentVersion) then
        error("Usage: LibSimpleDBProfiles:CreateMigration(currentVersion) requires a positive integer", 3)
    end

    return setmetatable({
        _library = lib,
        _currentVersion = currentVersion,
        _steps = {},
        _locked = false,
    }, Internal.migrationMetatable)
end

local function validateMigration(migration)
    if type(migration) ~= "table"
        or getmetatable(migration) ~= Internal.migrationMetatable
        or migration._library ~= lib then
        error("LibSimpleDBProfiles: options.migration must be created by LibSimpleDBProfiles-1.0", 3)
    end

    if not Internal.IsPositiveInteger(migration._currentVersion) then
        error("LibSimpleDBProfiles: Migration current version is invalid", 3)
    end

    for sourceVersion = 1, migration._currentVersion - 1 do
        if type(migration._steps[sourceVersion]) ~= "function" then
            error(("LibSimpleDBProfiles: Migration is missing source version %d"):format(sourceVersion), 3)
        end
    end

    for sourceVersion, callback in pairs(migration._steps) do
        if not Internal.IsPositiveInteger(sourceVersion)
            or sourceVersion >= migration._currentVersion
            or type(callback) ~= "function" then
            error("LibSimpleDBProfiles: Migration contains an invalid step", 3)
        end
    end

    migration._locked = true
end

function Internal.RunConsumerMigrations(storage, metadata, migration, wasFresh)
    if migration == nil then
        return
    end

    validateMigration(migration)

    local targetVersion = migration._currentVersion

    if wasFresh then
        metadata.payloadVersion = targetVersion
        return
    end

    if metadata.payloadVersion > targetVersion then
        error(("LibSimpleDBProfiles: stored payloadVersion %d is newer than Migration version %d"):format(
            metadata.payloadVersion,
            targetVersion
        ), 3)
    end

    while metadata.payloadVersion < targetVersion do
        local sourceVersion = metadata.payloadVersion
        local callback = migration._steps[sourceVersion]
        local entries = Internal.EnumeratePayloadEntries(storage)
        local staged = {}

        for index = 1, #entries do
            local entry = entries[index]
            local data = Internal.CopyValue(entry.data)
            local profileID = Internal.CopyValue(entry.profileID)
            local ok, message = pcall(callback, data, profileID)

            if not ok then
                error(("LibSimpleDBProfiles: consumer migration %d to %d failed for %s: %s"):format(
                    sourceVersion,
                    sourceVersion + 1,
                    Internal.ProfileIDLabel(profileID),
                    tostring(message)
                ), 3)
            end

            Internal.ValidateValue(data)
            staged[index] = {
                parent = entry.parent,
                key = entry.key,
                data = data,
            }
        end

        for index = 1, #staged do
            local entry = staged[index]
            entry.parent[entry.key] = entry.data
        end

        metadata.payloadVersion = sourceVersion + 1
    end
end
