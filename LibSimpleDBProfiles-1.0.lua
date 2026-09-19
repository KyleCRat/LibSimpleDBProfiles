-- Reserve this LibStub implementation and prepare the persistent objects that
-- must survive compatible minor upgrades. Library.lua completes the load.
local LIBRARY_MAJOR, LIBRARY_MINOR = "LibSimpleDBProfiles-1.0", 2
local REQUIRED_SIMPLE_DB_MINOR = 1
local CALLER_ERROR_LEVEL = 2
local WEAK_KEYS = "k"
local WEAK_KEYS_AND_VALUES = "kv"

local SimpleDB, simpleDBMinor = LibStub("LibSimpleDB-2.0", true)

if not SimpleDB
    or type(simpleDBMinor) ~= "number"
    or simpleDBMinor < REQUIRED_SIMPLE_DB_MINOR then
    error(("%s requires LibSimpleDB-2.0 minor %d or newer"):format(
        LIBRARY_MAJOR,
        REQUIRED_SIMPLE_DB_MINOR
    ), CALLER_ERROR_LEVEL)
end

local lib, previousMinor = LibStub:NewLibrary(LIBRARY_MAJOR, LIBRARY_MINOR)

if not lib then
    return
end

local pairs = pairs
local setmetatable = setmetatable

local function clearTable(tableValue)
    for key in pairs(tableValue) do
        tableValue[key] = nil
    end
end

-- LibStub preserves lib itself. Preserve these child-table identities too so
-- managers created by an older compatible copy receive the new methods.
local Internal = lib._internal

if not Internal then
    Internal = {}
    lib._internal = Internal
else
    clearTable(Internal)
end

local managerPrototype = lib._managerPrototype or {}
local managerMetatable = lib._managerMetatable or {}
local adminPrototype = lib._adminPrototype or {}
local adminMetatable = lib._adminMetatable or {}
local migrationPrototype = lib._migrationPrototype or {}
local migrationMetatable = lib._migrationMetatable or {}

clearTable(managerPrototype)
clearTable(adminPrototype)
clearTable(migrationPrototype)
managerMetatable.__index = managerPrototype
adminMetatable.__index = adminPrototype
migrationMetatable.__index = migrationPrototype

lib._managerPrototype = managerPrototype
lib._managerMetatable = managerMetatable
lib._adminPrototype = adminPrototype
lib._adminMetatable = adminMetatable
lib._migrationPrototype = migrationPrototype
lib._migrationMetatable = migrationMetatable

local liveManagerSet = lib._liveManagerSet

if not liveManagerSet then
    -- Discovery must not keep a manager alive after its consumer releases it.
    liveManagerSet = setmetatable({}, { __mode = WEAK_KEYS })
    lib._liveManagerSet = liveManagerSet
end

local managerByStorage = lib._managerByStorage

if not managerByStorage then
    -- This lookup owns neither side. A manager holds its storage strongly, so
    -- weak keys and values avoid the registry retaining that manager-storage
    -- pair when the consumer releases it.
    managerByStorage = setmetatable({}, { __mode = WEAK_KEYS_AND_VALUES })
    lib._managerByStorage = managerByStorage
end

local previousPublishedMethodNames = lib._publishedMethodNames

if previousPublishedMethodNames then
    -- A compatible minor may intentionally remove a formerly public method.
    for name in pairs(previousPublishedMethodNames) do
        lib[name] = nil
    end
end

Internal.MAJOR = LIBRARY_MAJOR
Internal.MINOR = LIBRARY_MINOR
Internal.previousMinor = previousMinor
Internal.SimpleDB = SimpleDB
Internal.managerPrototype = managerPrototype
Internal.managerMetatable = managerMetatable
Internal.adminPrototype = adminPrototype
Internal.adminMetatable = adminMetatable
Internal.migrationPrototype = migrationPrototype
Internal.migrationMetatable = migrationMetatable
Internal.liveManagerSet = liveManagerSet
Internal.managerByStorage = managerByStorage

lib._publishedMethodNames = {}
-- Intermediate files only attach while this exact implementation is loading.
-- Library.lua clears the marker after every module has initialized.
lib._loadInProgressMinor = LIBRARY_MINOR
