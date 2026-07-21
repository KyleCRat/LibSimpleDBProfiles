local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal

local sort = table.sort

local function publish(name, callback)
    lib[name] = callback
    lib._publicMethodNames[name] = true
end

publish("GetVersion", function()
    return Internal.MAJOR, Internal.MINOR
end)

publish("New", function(_, addonName, storage, defaults, options)
    return Internal.NewManager(addonName, storage, defaults, options)
end)

publish("CreateMigration", function(_, currentVersion)
    return Internal.CreateMigration(currentVersion)
end)

publish("GetManagers", function()
    local managers = {}

    for manager in pairs(Internal.liveManagers) do
        managers[#managers + 1] = manager
    end

    sort(managers, function(left, right)
        if left._addonName == right._addonName then
            return left._displayName < right._displayName
        end

        return left._addonName < right._addonName
    end)

    return managers
end)

if Internal.oldMinor then
    local managers = {}

    for manager in pairs(Internal.liveManagers) do
        managers[#managers + 1] = manager
    end

    for index = 1, #managers do
        Internal.UpgradeLiveManager(managers[index])
    end
end

Internal.InstallEventFrame()
lib.MAJOR = Internal.MAJOR
lib.MINOR = Internal.MINOR
lib._buildingMinor = nil
