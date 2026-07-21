-- Publish the completed library only after every implementation module loaded.
local BUILD_MINOR = 1
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal

local sort = table.sort

local function publishPublicMethod(name, method)
    lib[name] = method
    lib._publishedMethodNames[name] = true
end

publishPublicMethod("GetVersion", function()
    return Internal.MAJOR, Internal.MINOR
end)

publishPublicMethod("New", function(_, addonName, storage, defaults, options)
    return Internal.NewManager(addonName, storage, defaults, options)
end)

publishPublicMethod("CreateMigration", function(_, currentVersion)
    return Internal.CreateMigration(currentVersion)
end)

publishPublicMethod("GetManagers", function()
    local managerSnapshot = {}

    for manager in pairs(Internal.liveManagerSet) do
        managerSnapshot[#managerSnapshot + 1] = manager
    end

    sort(managerSnapshot, function(left, right)
        if left._addonName == right._addonName then
            return left._displayName < right._displayName
        end

        return left._addonName < right._addonName
    end)

    return managerSnapshot
end)

-- A compatible LibStub upgrade updates persistent prototypes in place. Existing
-- managers then normalize their storage and reconnect their stable active DB.
if Internal.previousMinor then
    local managerSnapshot = {}

    for manager in pairs(Internal.liveManagerSet) do
        managerSnapshot[#managerSnapshot + 1] = manager
    end

    for index = 1, #managerSnapshot do
        Internal.RefreshLiveManager(managerSnapshot[index])
    end
end

Internal.InstallEventFrame()
lib.MAJOR = Internal.MAJOR
lib.MINOR = Internal.MINOR
lib._loadInProgressMinor = nil
