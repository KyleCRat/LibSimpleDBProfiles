local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal

local pairs = pairs
local sort = table.sort

local characterFields = {
    "name",
    "realmID",
    "realmName",
    "class",
    "classID",
    "faction",
    "specID",
    "level",
    "lastSeen",
}

function Internal.CharacterDescriptor(manager, guid)
    local storage = manager._storage
    local info = storage.characterInfo[guid]
    local descriptor = {
        guid = guid,
        current = guid == manager._identity.guid,
        canForget = guid ~= manager._identity.guid,
    }

    if info then
        for index = 1, #characterFields do
            local field = characterFields[index]
            descriptor[field] = info[field]
        end
    end

    local profileRef = storage.selections[guid]

    if profileRef then
        descriptor.profileRef = Internal.CopyValue(profileRef)
        local profileID = Internal.ResolveProfileRef(profileRef, guid, info)

        if profileID then
            descriptor.profileID = profileID
        end
    end

    return descriptor
end

local function sortCharacters(characters)
    sort(characters, function(left, right)
        return left.guid < right.guid
    end)
end

function Internal.ProfileUsage(manager, profileID)
    local storage = manager._storage
    local characters = {}
    local unresolvedCharacters = {}

    for guid, profileRef in pairs(storage.selections) do
        local info = storage.characterInfo[guid]
        local resolvedID = Internal.ResolveProfileRef(profileRef, guid, info)

        if resolvedID and Internal.ProfileIdentityEqual(resolvedID, profileID) then
            characters[#characters + 1] = Internal.CharacterDescriptor(manager, guid)
        elseif not resolvedID
            and profileID.kind == "permanent"
            and profileRef.kind == "permanent"
            and profileRef.profile == profileID.profile then
            unresolvedCharacters[#unresolvedCharacters + 1] = Internal.CharacterDescriptor(manager, guid)
        end
    end

    sortCharacters(characters)
    sortCharacters(unresolvedCharacters)
    return {
        profileID = Internal.CopyValue(profileID),
        profileRef = Internal.ProfileRefForID(manager, profileID),
        selectionCount = #characters,
        characters = characters,
        unresolvedCharacters = unresolvedCharacters,
    }
end

function Internal.ProfileDescriptor(manager, profileID, includeSelectionCount)
    local data = Internal.GetProfileData(manager._storage, profileID)

    if not data then
        return nil
    end

    local active = Internal.ProfileIdentityEqual(manager._activeProfileID, profileID)
    local permanent = profileID.kind == "permanent"
    local descriptor = {
        profileID = Internal.CopyValue(profileID),
        profileRef = Internal.ProfileRefForID(manager, profileID),
        displayName = Internal.ProfileDisplayName(manager, profileID),
        permanent = permanent,
        active = active,
        hasData = next(data) ~= nil,
        nameCollision = false,
        canReset = true,
        canRename = not permanent,
        canDelete = not permanent and not active,
    }

    if includeSelectionCount then
        descriptor.selectionCount = Internal.ProfileUsage(manager, profileID).selectionCount
    end

    return descriptor
end

function Internal.ProfileSnapshot(manager, profileID, includeSelectionCount)
    local descriptor = Internal.ProfileDescriptor(manager, profileID, includeSelectionCount)

    if not descriptor then
        return nil
    end

    local matchingNames = 0
    local ids

    if includeSelectionCount then
        ids = Internal.EnumerateProfileIDs(manager._storage)
    else
        ids = {}

        for index = 1, #Internal.permanentOrder do
            local currentID = Internal.CurrentProfileID(manager, Internal.permanentOrder[index])

            if currentID then
                ids[#ids + 1] = currentID
            end
        end

        local names = Internal.SortedKeys(manager._storage.profiles)

        for index = 1, #names do
            ids[#ids + 1] = { kind = "user", name = names[index] }
        end
    end

    for index = 1, #ids do
        if Internal.ProfileDisplayName(manager, ids[index]) == descriptor.displayName then
            matchingNames = matchingNames + 1

            if matchingNames > 1 then
                descriptor.nameCollision = true
                break
            end
        end
    end

    return descriptor
end

function Internal.ApplyNameCollisions(descriptors)
    local counts = {}

    for index = 1, #descriptors do
        local name = descriptors[index].displayName
        counts[name] = (counts[name] or 0) + 1
    end

    for index = 1, #descriptors do
        descriptors[index].nameCollision = counts[descriptors[index].displayName] > 1
    end

    return descriptors
end

function Internal.CurrentProfileDescriptors(manager)
    local descriptors = {}

    for index = 1, #Internal.permanentOrder do
        local profile = Internal.permanentOrder[index]
        local profileID = Internal.CurrentProfileID(manager, profile)

        if profileID then
            descriptors[#descriptors + 1] = Internal.ProfileDescriptor(manager, profileID, false)
        end
    end

    local names = Internal.SortedKeys(manager._storage.profiles)

    for index = 1, #names do
        descriptors[#descriptors + 1] = Internal.ProfileDescriptor(manager, {
            kind = "user",
            name = names[index],
        }, false)
    end

    return Internal.ApplyNameCollisions(descriptors)
end

function Internal.AdminProfileDescriptors(manager)
    local ids = Internal.EnumerateProfileIDs(manager._storage)
    local descriptors = {}

    for index = 1, #ids do
        descriptors[index] = Internal.ProfileDescriptor(manager, ids[index], true)
    end

    return Internal.ApplyNameCollisions(descriptors)
end
