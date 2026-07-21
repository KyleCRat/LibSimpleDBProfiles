local MAJOR, MINOR = "LibSimpleDBProfiles-1.0", 1
local SimpleDB, simpleDBMinor = LibStub("LibSimpleDB-2.0", true)

if not SimpleDB or type(simpleDBMinor) ~= "number" or simpleDBMinor < 1 then
    error("LibSimpleDBProfiles-1.0 requires LibSimpleDB-2.0 minor 1 or newer", 2)
end

local lib, oldMinor = LibStub:NewLibrary(MAJOR, MINOR)

if not lib then
    return
end

local pairs = pairs
local setmetatable = setmetatable

local function clearTable(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

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

local liveManagers = lib._liveManagers

if not liveManagers then
    liveManagers = setmetatable({}, { __mode = "k" })
    lib._liveManagers = liveManagers
end

local storageOwners = lib._storageOwners

if not storageOwners then
    storageOwners = setmetatable({}, { __mode = "kv" })
    lib._storageOwners = storageOwners
end

local previousPublicMethods = lib._publicMethodNames

if previousPublicMethods then
    for name in pairs(previousPublicMethods) do
        lib[name] = nil
    end
end

Internal.MAJOR = MAJOR
Internal.MINOR = MINOR
Internal.oldMinor = oldMinor
Internal.SimpleDB = SimpleDB
Internal.managerPrototype = managerPrototype
Internal.managerMetatable = managerMetatable
Internal.adminPrototype = adminPrototype
Internal.adminMetatable = adminMetatable
Internal.migrationPrototype = migrationPrototype
Internal.migrationMetatable = migrationMetatable
Internal.liveManagers = liveManagers
Internal.storageOwners = storageOwners

lib._publicMethodNames = {}
lib._buildingMinor = MINOR
