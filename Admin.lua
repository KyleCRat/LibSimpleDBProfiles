local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal
local managerMethods = Internal.managerPrototype
local methods = Internal.adminPrototype

local error = error
local setmetatable = setmetatable
local type = type

local function validateCharacterGUID(characterGUID, operation)
    if type(characterGUID) ~= "string" or characterGUID == "" then
        error(("Usage: admin:%s(characterGUID, ...) requires a non-empty GUID string"):format(operation), 3)
    end
end

local function resolveCharacterProfile(manager, characterGUID, profileRef)
    if not profileRef then
        return nil, nil
    end

    local profileID = Internal.ResolveProfileRef(
        profileRef,
        characterGUID,
        manager._storage.characterInfo[characterGUID]
    )

    if not profileID then
        return nil, nil
    end

    return profileID, Internal.GetProfileData(manager._storage, profileID)
end

function managerMethods:GetAdmin()
    if not self._admin then
        self._admin = setmetatable({ _manager = self }, Internal.adminMetatable)
    end

    return self._admin
end

function methods:GetCharacters()
    local manager = self._manager
    local guids = Internal.KnownCharacterGUIDs(manager._storage)
    local characters = {}

    for index = 1, #guids do
        characters[index] = Internal.CharacterDescriptor(manager, guids[index])
    end

    return characters
end

function methods:GetProfiles()
    return Internal.AdminProfileDescriptors(self._manager)
end

function methods:GetProfileUsage(profileID)
    local normalized, errorCode = Internal.NormalizeProfileID(profileID, "admin:GetProfileUsage")

    if not normalized then
        return nil, errorCode
    end

    if not Internal.GetProfileData(self._manager._storage, normalized) then
        return nil, "PROFILE_NOT_FOUND"
    end

    return Internal.ProfileUsage(self._manager, normalized)
end

function methods:GetSelection(characterGUID)
    validateCharacterGUID(characterGUID, "GetSelection")
    local manager = self._manager

    if not Internal.CharacterExists(manager._storage, characterGUID) then
        return nil, "CHARACTER_NOT_FOUND"
    end

    local profileRef = manager._storage.selections[characterGUID]
    local profileID = profileRef and Internal.ResolveProfileRef(
        profileRef,
        characterGUID,
        manager._storage.characterInfo[characterGUID]
    ) or nil
    return {
        profileRef = profileRef and Internal.CopyValue(profileRef) or nil,
        profileID = profileID and Internal.CopyValue(profileID) or nil,
    }
end

function methods:SetSelection(characterGUID, profileRef)
    validateCharacterGUID(characterGUID, "SetSelection")
    local manager = self._manager
    local storage = manager._storage
    local normalized, errorCode = Internal.NormalizeProfileRef(profileRef, "admin:SetSelection")

    if not normalized then
        return nil, errorCode
    end

    if characterGUID == manager._identity.guid then
        return nil, "CURRENT_CHARACTER"
    end

    if not Internal.CharacterExists(storage, characterGUID) then
        return nil, "CHARACTER_NOT_FOUND"
    end

    local oldRef = storage.selections[characterGUID]

    if oldRef and Internal.ProfileRefEqual(oldRef, normalized) then
        return Internal.CharacterDescriptor(manager, characterGUID), false
    end

    local oldID, oldData = resolveCharacterProfile(manager, characterGUID, oldRef)
    local oldDescriptor = oldID and oldData and Internal.ProfileSnapshot(manager, oldID, true) or nil
    local newID = Internal.ResolveProfileRef(
        normalized,
        characterGUID,
        storage.characterInfo[characterGUID]
    )
    local newData = newID and Internal.GetProfileData(storage, newID) or nil

    if normalized.kind == "user" and not newData then
        newData = {}
        Internal.SetProfileData(storage, newID, newData)
        Internal.DispatchLifecycle(manager, "OnProfileCreated", Internal.ProfileSnapshot(manager, newID, true))
    elseif newID and not newData then
        newData = Internal.EnsureProfileData(storage, newID)
    end

    storage.selections[characterGUID] = Internal.CopyValue(normalized)
    local character = Internal.CharacterDescriptor(manager, characterGUID)
    local newDescriptor = newID and newData and Internal.ProfileSnapshot(manager, newID, true) or nil
    Internal.DispatchLifecycle(
        manager,
        "OnCharacterSelectionChanged",
        character,
        newDescriptor,
        oldDescriptor
    )
    return character, true
end

function methods:ResetProfile(profileID)
    local normalized, errorCode = Internal.NormalizeProfileID(profileID, "admin:ResetProfile")

    if not normalized then
        return nil, errorCode
    end

    local manager = self._manager
    local data = Internal.GetProfileData(manager._storage, normalized)

    if not data then
        return nil, "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIdentityEqual(manager._activeProfileID, normalized) then
        manager._activeDB:Reset()
    else
        Internal.ClearTable(data)
    end

    local descriptor = Internal.ProfileSnapshot(manager, normalized, true)
    Internal.DispatchLifecycle(manager, "OnProfileReset", descriptor)
    return descriptor
end

function methods:CopyProfile(sourceProfileID, destinationProfileID)
    local source, sourceError = Internal.NormalizeProfileID(sourceProfileID, "admin:CopyProfile source")

    if not source then
        return nil, sourceError
    end

    local destination, destinationError = Internal.NormalizeProfileID(
        destinationProfileID,
        "admin:CopyProfile destination"
    )

    if not destination then
        return nil, destinationError
    end

    local manager = self._manager
    local sourceData = Internal.GetProfileData(manager._storage, source)

    if not sourceData then
        return nil, "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIdentityEqual(source, destination) then
        return Internal.ProfileSnapshot(manager, destination, true), false
    end

    local destinationData = Internal.GetProfileData(manager._storage, destination)
    local destinationWasMissing = destinationData == nil

    if destinationWasMissing and destination.kind ~= "user" then
        return nil, "PROFILE_NOT_FOUND"
    end

    local overwritten = destinationData ~= nil and next(destinationData) ~= nil
    local copiedData = Internal.CopyValue(sourceData)
    local sourceDescriptor = Internal.ProfileSnapshot(manager, source, true)
    Internal.SetProfileData(manager._storage, destination, copiedData)

    if Internal.ProfileIdentityEqual(manager._activeProfileID, destination) then
        manager._activeData = copiedData
        manager._activeDB:SetData(copiedData)
    end

    local destinationDescriptor = Internal.ProfileSnapshot(manager, destination, true)

    if destinationWasMissing then
        Internal.DispatchLifecycle(manager, "OnProfileCreated", destinationDescriptor)
    end

    Internal.DispatchLifecycle(
        manager,
        "OnProfileCopied",
        sourceDescriptor,
        destinationDescriptor,
        overwritten
    )
    return destinationDescriptor, overwritten
end

function methods:ForgetCharacter(characterGUID)
    validateCharacterGUID(characterGUID, "ForgetCharacter")
    local manager = self._manager
    local storage = manager._storage

    if characterGUID == manager._identity.guid then
        return nil, "CURRENT_CHARACTER"
    end

    if not Internal.CharacterExists(storage, characterGUID) then
        return nil, "CHARACTER_NOT_FOUND"
    end

    local character = Internal.CharacterDescriptor(manager, characterGUID)
    storage.characters[characterGUID] = nil
    storage.characterInfo[characterGUID] = nil
    storage.selections[characterGUID] = nil
    Internal.DispatchLifecycle(manager, "OnCharacterForgotten", character)
    return character
end
