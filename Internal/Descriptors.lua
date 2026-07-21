-- Build detached character, profile, and usage snapshots for public callers.
local BUILD_MINOR = 1
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal

local pairs = pairs
local sort = table.sort

local CHARACTER_DESCRIPTOR_FIELDS = {
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

function Internal.BuildCharacterDescriptor(manager, guid)
    local storage = manager._storage
    local characterInfo = storage.characterInfo[guid]
    local descriptor = {
        guid = guid,
        current = guid == manager._identity.guid,
        canForget = guid ~= manager._identity.guid,
    }

    if characterInfo then
        for index = 1, #CHARACTER_DESCRIPTOR_FIELDS do
            local field = CHARACTER_DESCRIPTOR_FIELDS[index]
            descriptor[field] = characterInfo[field]
        end
    end

    local profileRef = storage.selections[guid]

    if profileRef then
        descriptor.profileRef = Internal.CopyValue(profileRef)
        local profileID = Internal.ResolveProfileRef(profileRef, guid, characterInfo)

        if profileID then
            descriptor.profileID = profileID
        end
    end

    return descriptor
end

local function sortCharacterDescriptors(characterDescriptors)
    sort(characterDescriptors, function(left, right)
        return left.guid < right.guid
    end)
end

function Internal.BuildProfileUsage(manager, profileID)
    local storage = manager._storage
    local selectedCharacters = {}
    local unresolvedCharacters = {}

    for guid, profileRef in pairs(storage.selections) do
        local characterInfo = storage.characterInfo[guid]
        local resolvedProfileID = Internal.ResolveProfileRef(profileRef, guid, characterInfo)

        if resolvedProfileID and Internal.ProfileIDEqual(resolvedProfileID, profileID) then
            selectedCharacters[#selectedCharacters + 1] = Internal.BuildCharacterDescriptor(manager, guid)
        elseif not resolvedProfileID
            and profileID.kind == "permanent"
            and profileRef.kind == "permanent"
            and profileRef.profile == profileID.profile then
            unresolvedCharacters[#unresolvedCharacters + 1] = Internal.BuildCharacterDescriptor(manager, guid)
        end
    end

    sortCharacterDescriptors(selectedCharacters)
    sortCharacterDescriptors(unresolvedCharacters)
    return {
        profileID = Internal.CopyValue(profileID),
        profileRef = Internal.SelectableProfileRefForID(manager, profileID),
        selectionCount = #selectedCharacters,
        characters = selectedCharacters,
        unresolvedCharacters = unresolvedCharacters,
    }
end

local function buildBaseProfileDescriptor(manager, profileID, includeSelectionCount)
    local profilePayload = Internal.GetProfilePayload(manager._storage, profileID)

    if not profilePayload then
        return nil
    end

    local isActive = Internal.ProfileIDEqual(manager._activeProfileID, profileID)
    local isPermanent = profileID.kind == "permanent"
    local descriptor = {
        profileID = Internal.CopyValue(profileID),
        profileRef = Internal.SelectableProfileRefForID(manager, profileID),
        displayName = Internal.ResolveProfileDisplayName(manager, profileID),
        permanent = isPermanent,
        active = isActive,
        hasData = next(profilePayload) ~= nil,
        nameCollision = false,
        canReset = true,
        canRename = not isPermanent,
        canDelete = not isPermanent and not isActive,
    }

    if includeSelectionCount then
        descriptor.selectionCount = Internal.BuildProfileUsage(manager, profileID).selectionCount
    end

    return descriptor
end

-- Single-profile operations need collision status too, so compare the display
-- name against either current selectable profiles or every historical ID.
function Internal.BuildProfileDescriptor(manager, profileID, includeSelectionCount)
    local descriptor = buildBaseProfileDescriptor(manager, profileID, includeSelectionCount)

    if not descriptor then
        return nil
    end

    local matchingDisplayNameCount = 0
    local profileIDs

    if includeSelectionCount then
        profileIDs = Internal.CollectProfileIDs(manager._storage)
    else
        profileIDs = {}

        for index = 1, #Internal.permanentProfileOrder do
            local profileType = Internal.permanentProfileOrder[index]
            local currentProfileID = Internal.ResolveCurrentProfileID(manager, profileType)

            if currentProfileID then
                profileIDs[#profileIDs + 1] = currentProfileID
            end
        end

        local userProfileNames = Internal.SortedKeys(manager._storage.profiles)

        for index = 1, #userProfileNames do
            profileIDs[#profileIDs + 1] = { kind = "user", name = userProfileNames[index] }
        end
    end

    for index = 1, #profileIDs do
        if Internal.ResolveProfileDisplayName(manager, profileIDs[index]) == descriptor.displayName then
            matchingDisplayNameCount = matchingDisplayNameCount + 1

            if matchingDisplayNameCount > 1 then
                descriptor.nameCollision = true
                break
            end
        end
    end

    return descriptor
end

local function applyNameCollisions(descriptors)
    local displayNameCounts = {}

    for index = 1, #descriptors do
        local displayName = descriptors[index].displayName
        displayNameCounts[displayName] = (displayNameCounts[displayName] or 0) + 1
    end

    for index = 1, #descriptors do
        descriptors[index].nameCollision = displayNameCounts[descriptors[index].displayName] > 1
    end

    return descriptors
end

function Internal.BuildCurrentProfileDescriptors(manager)
    local descriptors = {}

    for index = 1, #Internal.permanentProfileOrder do
        local profileType = Internal.permanentProfileOrder[index]
        local profileID = Internal.ResolveCurrentProfileID(manager, profileType)

        if profileID then
            descriptors[#descriptors + 1] = buildBaseProfileDescriptor(manager, profileID, false)
        end
    end

    local userProfileNames = Internal.SortedKeys(manager._storage.profiles)

    for index = 1, #userProfileNames do
        descriptors[#descriptors + 1] = buildBaseProfileDescriptor(manager, {
            kind = "user",
            name = userProfileNames[index],
        }, false)
    end

    return applyNameCollisions(descriptors)
end

function Internal.BuildAdminProfileDescriptors(manager)
    local profileIDs = Internal.CollectProfileIDs(manager._storage)
    local descriptors = {}

    for index = 1, #profileIDs do
        descriptors[index] = buildBaseProfileDescriptor(manager, profileIDs[index], true)
    end

    return applyNameCollisions(descriptors)
end
