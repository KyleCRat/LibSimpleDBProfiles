-- Implement exact profileID and offline-character administration without a UI.
local BUILD_MINOR = 2
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal
local Manager = Internal.managerPrototype
local Admin = Internal.adminPrototype

local error = error
local setmetatable = setmetatable
local type = type

local ARGUMENT_ERROR_LEVEL = 3

local function validateCharacterGUID(characterGUID, operation)
    if type(characterGUID) ~= "string" or characterGUID == "" then
        error(
            ("Usage: admin:%s(characterGUID, ...) requires a non-empty GUID string"):format(
                operation
            ),
            ARGUMENT_ERROR_LEVEL
        )
    end
end

local function resolveCharacterSelection(manager, characterGUID, profileRef)
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

    return profileID, Internal.GetProfilePayload(manager._storage, profileID)
end

function Manager:GetAdmin()
    if not self._adminAPI then
        self._adminAPI = setmetatable({ _manager = self }, Internal.adminMetatable)
    end

    return self._adminAPI
end

function Admin:GetCharacters()
    local manager = self._manager
    local characterGUIDs = Internal.CollectKnownCharacterGUIDs(manager._storage)
    local characters = {}

    for index = 1, #characterGUIDs do
        characters[index] = Internal.BuildCharacterDescriptor(manager, characterGUIDs[index])
    end

    return characters
end

function Admin:GetProfiles()
    return Internal.BuildAdminProfileDescriptors(self._manager)
end

function Admin:GetProfileUsage(profileID)
    local normalizedProfileID, errorCode = Internal.NormalizeProfileID(profileID, "admin:GetProfileUsage")

    if not normalizedProfileID then
        return nil, errorCode
    end

    if not Internal.GetProfilePayload(self._manager._storage, normalizedProfileID) then
        return nil, "PROFILE_NOT_FOUND"
    end

    return Internal.BuildProfileUsage(self._manager, normalizedProfileID)
end

function Admin:GetSelection(characterGUID)
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

function Admin:SetSelection(characterGUID, profileRef)
    validateCharacterGUID(characterGUID, "SetSelection")
    local manager = self._manager
    local storage = manager._storage
    local normalizedRef, errorCode = Internal.NormalizeProfileRef(profileRef, "admin:SetSelection")

    if not normalizedRef then
        return nil, errorCode
    end

    if characterGUID == manager._identity.guid then
        return nil, "CURRENT_CHARACTER"
    end

    if not Internal.CharacterExists(storage, characterGUID) then
        return nil, "CHARACTER_NOT_FOUND"
    end

    local previousProfileRef = storage.selections[characterGUID]

    if previousProfileRef and Internal.ProfileRefEqual(previousProfileRef, normalizedRef) then
        return Internal.BuildCharacterDescriptor(manager, characterGUID), false
    end

    local previousProfileID, previousPayload = resolveCharacterSelection(
        manager,
        characterGUID,
        previousProfileRef
    )
    local previousDescriptor = previousProfileID
        and previousPayload
        and Internal.BuildProfileDescriptor(manager, previousProfileID, true)
        or nil
    local newProfileID = Internal.ResolveProfileRef(
        normalizedRef,
        characterGUID,
        storage.characterInfo[characterGUID]
    )
    local newPayload = newProfileID and Internal.GetProfilePayload(storage, newProfileID) or nil

    if normalizedRef.kind == "user" and not newPayload then
        newPayload = {}
        Internal.SetProfilePayload(storage, newProfileID, newPayload)
        Internal.DispatchLifecycle(
            manager,
            "OnProfileCreated",
            Internal.BuildProfileDescriptor(manager, newProfileID, true)
        )
    elseif newProfileID and not newPayload then
        newPayload = Internal.EnsureProfilePayload(storage, newProfileID)
    end

    storage.selections[characterGUID] = Internal.CopyValue(normalizedRef)
    local characterDescriptor = Internal.BuildCharacterDescriptor(manager, characterGUID)
    local currentDescriptor = newProfileID
        and newPayload
        and Internal.BuildProfileDescriptor(manager, newProfileID, true)
        or nil
    Internal.DispatchLifecycle(
        manager,
        "OnCharacterSelectionChanged",
        characterDescriptor,
        currentDescriptor,
        previousDescriptor
    )
    return characterDescriptor, true
end

function Admin:ResetProfile(profileID)
    local normalizedProfileID, errorCode = Internal.NormalizeProfileID(profileID, "admin:ResetProfile")

    if not normalizedProfileID then
        return nil, errorCode
    end

    local manager = self._manager
    local profilePayload = Internal.GetProfilePayload(manager._storage, normalizedProfileID)

    if not profilePayload then
        return nil, "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIDEqual(manager._activeProfileID, normalizedProfileID) then
        manager._activeDB:Reset()
    else
        Internal.ClearTable(profilePayload)
    end

    local descriptor = Internal.BuildProfileDescriptor(manager, normalizedProfileID, true)
    Internal.DispatchLifecycle(manager, "OnProfileReset", descriptor)
    return descriptor
end

function Admin:CopyProfile(sourceProfileID, destinationProfileID)
    local normalizedSourceID, sourceError = Internal.NormalizeProfileID(
        sourceProfileID,
        "admin:CopyProfile source"
    )

    if not normalizedSourceID then
        return nil, sourceError
    end

    local normalizedDestinationID, destinationError = Internal.NormalizeProfileID(
        destinationProfileID,
        "admin:CopyProfile destination"
    )

    if not normalizedDestinationID then
        return nil, destinationError
    end

    local manager = self._manager
    local sourcePayload = Internal.GetProfilePayload(manager._storage, normalizedSourceID)

    if not sourcePayload then
        return nil, "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIDEqual(normalizedSourceID, normalizedDestinationID) then
        return Internal.BuildProfileDescriptor(manager, normalizedDestinationID, true), false
    end

    local destinationPayload = Internal.GetProfilePayload(manager._storage, normalizedDestinationID)
    local destinationWasMissing = destinationPayload == nil

    if destinationWasMissing and normalizedDestinationID.kind ~= "user" then
        return nil, "PROFILE_NOT_FOUND"
    end

    local overwritten = destinationPayload ~= nil and next(destinationPayload) ~= nil
    local copiedPayload = Internal.CopyValue(sourcePayload)
    local sourceDescriptor = Internal.BuildProfileDescriptor(manager, normalizedSourceID, true)
    Internal.SetProfilePayload(manager._storage, normalizedDestinationID, copiedPayload)

    if Internal.ProfileIDEqual(manager._activeProfileID, normalizedDestinationID) then
        manager._activePayload = copiedPayload
        manager._activeDB:SetData(copiedPayload)
    end

    local destinationDescriptor = Internal.BuildProfileDescriptor(manager, normalizedDestinationID, true)

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

function Admin:ForgetCharacter(characterGUID)
    validateCharacterGUID(characterGUID, "ForgetCharacter")
    local manager = self._manager
    local storage = manager._storage

    if characterGUID == manager._identity.guid then
        return nil, "CURRENT_CHARACTER"
    end

    if not Internal.CharacterExists(storage, characterGUID) then
        return nil, "CHARACTER_NOT_FOUND"
    end

    local characterDescriptor = Internal.BuildCharacterDescriptor(manager, characterGUID)
    storage.characters[characterGUID] = nil
    storage.characterInfo[characterGUID] = nil
    storage.selections[characterGUID] = nil
    Internal.DispatchLifecycle(manager, "OnCharacterForgotten", characterDescriptor)
    return characterDescriptor
end
