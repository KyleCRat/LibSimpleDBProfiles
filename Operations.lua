-- Implement current-manager profile mutations that accept selectable
-- profileRef values.
local BUILD_MINOR = 1
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal
local Manager = Internal.managerPrototype

local error = error
local pairs = pairs

local METHOD_ERROR_LEVEL = 2

local function resolveSelectableProfile(manager, profileRef, operation)
    local normalizedRef, errorCode = Internal.NormalizeProfileRef(profileRef, operation)

    if not normalizedRef then
        return nil, nil, nil, errorCode
    end

    local profileID = Internal.ResolveProfileRef(
        normalizedRef,
        manager._identity.guid,
        manager._identity
    )

    if not profileID then
        return normalizedRef, nil, nil, "PROFILE_NOT_FOUND"
    end

    return normalizedRef,
        profileID,
        Internal.GetProfilePayload(manager._storage, profileID)
end

function Manager:CreateProfile(name)
    local normalizedName, errorCode = Internal.NormalizeProfileName(name, "CreateProfile")

    if not normalizedName then
        return nil, errorCode
    end

    if self._storage.profiles[normalizedName] then
        return nil, "PROFILE_EXISTS"
    end

    -- User profileRef and profileID shapes are identical because they do not
    -- depend on character identity.
    local profileRef = { kind = "user", name = normalizedName }
    self._storage.profiles[normalizedName] = {}
    Internal.DispatchLifecycle(self, "OnProfileCreated", Internal.BuildProfileDescriptor(self, profileRef, false))
    return profileRef
end

function Manager:CopyProfile(sourceRef, destinationRef)
    local normalizedSourceRef, sourceProfileID, sourcePayload, sourceErrorCode = resolveSelectableProfile(
        self,
        sourceRef,
        "manager:CopyProfile source"
    )

    if not normalizedSourceRef then
        return nil, sourceErrorCode
    end

    local normalizedDestinationRef,
        destinationProfileID,
        destinationPayload,
        destinationErrorCode = resolveSelectableProfile(
        self,
        destinationRef,
        "manager:CopyProfile destination"
    )

    if not normalizedDestinationRef or not destinationProfileID then
        return nil, destinationErrorCode
    end

    if not sourcePayload then
        return nil, sourceErrorCode or "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIDEqual(sourceProfileID, destinationProfileID) then
        return Internal.BuildProfileDescriptor(self, destinationProfileID, false), false
    end

    local copiedPayload = Internal.CopyValue(sourcePayload)
    local destinationWasMissing = destinationPayload == nil

    if destinationWasMissing and normalizedDestinationRef.kind ~= "user" then
        return nil, "PROFILE_NOT_FOUND"
    end

    local overwritten = destinationPayload ~= nil and next(destinationPayload) ~= nil
    local sourceDescriptor = Internal.BuildProfileDescriptor(self, sourceProfileID, false)

    Internal.SetProfilePayload(self._storage, destinationProfileID, copiedPayload)

    if Internal.ProfileIDEqual(self._activeProfileID, destinationProfileID) then
        self._activePayload = copiedPayload
        self._activeDB:SetData(copiedPayload)
    end

    local destinationDescriptor = Internal.BuildProfileDescriptor(self, destinationProfileID, false)

    if destinationWasMissing then
        Internal.DispatchLifecycle(self, "OnProfileCreated", destinationDescriptor)
    end

    Internal.DispatchLifecycle(
        self,
        "OnProfileCopied",
        sourceDescriptor,
        destinationDescriptor,
        overwritten
    )
    return destinationDescriptor, overwritten
end

function Manager:ResetProfile(profileRef)
    local profileID
    local profilePayload

    if profileRef == nil then
        profileID = Internal.CopyValue(self._activeProfileID)
        profilePayload = self._activePayload
    else
        local normalizedRef, errorCode
        normalizedRef, profileID, profilePayload, errorCode = resolveSelectableProfile(
            self,
            profileRef,
            "manager:ResetProfile"
        )

        if not normalizedRef then
            return nil, errorCode
        end

        if not profilePayload then
            return nil, errorCode or "PROFILE_NOT_FOUND"
        end
    end

    if Internal.ProfileIDEqual(self._activeProfileID, profileID) then
        self._activeDB:Reset()
    else
        Internal.ClearTable(profilePayload)
    end

    local descriptor = Internal.BuildProfileDescriptor(self, profileID, false)
    Internal.DispatchLifecycle(self, "OnProfileReset", descriptor)
    return descriptor
end

function Manager:RenameProfile(profileRef, newName)
    local normalizedRef, profileID, profilePayload, errorCode = resolveSelectableProfile(
        self,
        profileRef,
        "manager:RenameProfile"
    )

    if not normalizedRef then
        return nil, errorCode
    end

    if normalizedRef.kind == "permanent" then
        error("LibSimpleDBProfiles: permanent profiles cannot be renamed", METHOD_ERROR_LEVEL)
    end

    if not profilePayload then
        return nil, errorCode or "PROFILE_NOT_FOUND"
    end

    local normalizedName, nameError = Internal.NormalizeProfileName(newName, "RenameProfile")

    if not normalizedName then
        return nil, nameError
    end

    if normalizedName == normalizedRef.name then
        return Internal.BuildProfileDescriptor(self, profileID, false)
    end

    if self._storage.profiles[normalizedName] then
        return nil, "PROFILE_EXISTS"
    end

    local previousDescriptor = Internal.BuildProfileDescriptor(self, profileID, false)
    local newProfileRef = { kind = "user", name = normalizedName }
    local newProfileID = { kind = "user", name = normalizedName }
    self._storage.profiles[normalizedRef.name] = nil
    self._storage.profiles[normalizedName] = profilePayload

    for guid, selection in pairs(self._storage.selections) do
        if selection.kind == "user" and selection.name == normalizedRef.name then
            self._storage.selections[guid] = Internal.CopyValue(newProfileRef)
        end
    end

    if Internal.ProfileIDEqual(self._activeProfileID, profileID) then
        self._activeProfileRef = Internal.CopyValue(newProfileRef)
        self._activeProfileID = Internal.CopyValue(newProfileID)
    end

    local currentDescriptor = Internal.BuildProfileDescriptor(self, newProfileID, false)
    Internal.DispatchLifecycle(self, "OnProfileRenamed", previousDescriptor, currentDescriptor)
    return currentDescriptor
end

function Manager:DeleteProfile(profileRef)
    local normalizedRef, profileID, profilePayload, errorCode = resolveSelectableProfile(
        self,
        profileRef,
        "manager:DeleteProfile"
    )

    if not normalizedRef then
        return nil, errorCode
    end

    if normalizedRef.kind == "permanent" then
        error("LibSimpleDBProfiles: permanent profiles cannot be deleted", METHOD_ERROR_LEVEL)
    end

    if not profilePayload then
        return nil, errorCode or "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIDEqual(self._activeProfileID, profileID) then
        return nil, "ACTIVE_PROFILE"
    end

    local deletedDescriptor = Internal.BuildProfileDescriptor(self, profileID, false)
    local affectedCharacters = {}

    for guid, selection in pairs(self._storage.selections) do
        if selection.kind == "user" and selection.name == normalizedRef.name then
            affectedCharacters[#affectedCharacters + 1] = Internal.BuildCharacterDescriptor(self, guid)
        end
    end

    table.sort(affectedCharacters, function(left, right)
        return left.guid < right.guid
    end)

    self._storage.profiles[normalizedRef.name] = nil

    for index = 1, #affectedCharacters do
        local characterDescriptor = affectedCharacters[index]
        self._storage.selections[characterDescriptor.guid] = nil
        Internal.DispatchLifecycle(
            self,
            "OnCharacterSelectionChanged",
            Internal.BuildCharacterDescriptor(self, characterDescriptor.guid),
            nil,
            deletedDescriptor
        )
    end

    Internal.DispatchLifecycle(self, "OnProfileDeleted", deletedDescriptor, affectedCharacters)
    return deletedDescriptor, affectedCharacters
end
