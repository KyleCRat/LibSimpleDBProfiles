local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal
local methods = Internal.managerPrototype

local error = error
local pairs = pairs

local function resolveOrdinaryProfile(manager, profileRef, operation)
    local normalized, errorCode = Internal.NormalizeProfileRef(profileRef, operation)

    if not normalized then
        return nil, nil, nil, errorCode
    end

    local profileID = Internal.ResolveProfileRef(normalized, manager._identity.guid, manager._identity)

    if not profileID then
        return normalized, nil, nil, "PROFILE_NOT_FOUND"
    end

    return normalized, profileID, Internal.GetProfileData(manager._storage, profileID)
end

function methods:CreateProfile(name)
    local normalized, errorCode = Internal.NormalizeProfileName(name, "CreateProfile")

    if not normalized then
        return nil, errorCode
    end

    if self._storage.profiles[normalized] then
        return nil, "PROFILE_EXISTS"
    end

    local profileRef = { kind = "user", name = normalized }
    local profileID = { kind = "user", name = normalized }
    self._storage.profiles[normalized] = {}
    Internal.DispatchLifecycle(self, "OnProfileCreated", Internal.ProfileSnapshot(self, profileID, false))
    return profileRef
end

function methods:CopyProfile(sourceRef, destinationRef)
    local normalizedSource, sourceID, sourceData, sourceError = resolveOrdinaryProfile(
        self,
        sourceRef,
        "manager:CopyProfile source"
    )

    if not normalizedSource then
        return nil, sourceError
    end

    local normalizedDestination, destinationID, destinationData, destinationError = resolveOrdinaryProfile(
        self,
        destinationRef,
        "manager:CopyProfile destination"
    )

    if not normalizedDestination or not destinationID then
        return nil, destinationError
    end

    if not sourceData then
        return nil, sourceError or "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIdentityEqual(sourceID, destinationID) then
        return Internal.ProfileSnapshot(self, destinationID, false), false
    end

    local copiedData = Internal.CopyValue(sourceData)
    local destinationWasMissing = destinationData == nil

    if destinationWasMissing and normalizedDestination.kind ~= "user" then
        return nil, "PROFILE_NOT_FOUND"
    end

    local overwritten = destinationData ~= nil and next(destinationData) ~= nil
    local sourceDescriptor = Internal.ProfileSnapshot(self, sourceID, false)

    Internal.SetProfileData(self._storage, destinationID, copiedData)

    if Internal.ProfileIdentityEqual(self._activeProfileID, destinationID) then
        self._activeData = copiedData
        self._activeDB:SetData(copiedData)
    end

    local destinationDescriptor = Internal.ProfileSnapshot(self, destinationID, false)

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

function methods:ResetProfile(profileRef)
    local profileID
    local data

    if profileRef == nil then
        profileID = Internal.CopyValue(self._activeProfileID)
        data = self._activeData
    else
        local normalized, errorCode
        normalized, profileID, data, errorCode = resolveOrdinaryProfile(
            self,
            profileRef,
            "manager:ResetProfile"
        )

        if not normalized then
            return nil, errorCode
        end

        if not data then
            return nil, errorCode or "PROFILE_NOT_FOUND"
        end
    end

    if Internal.ProfileIdentityEqual(self._activeProfileID, profileID) then
        self._activeDB:Reset()
    else
        Internal.ClearTable(data)
    end

    local descriptor = Internal.ProfileSnapshot(self, profileID, false)
    Internal.DispatchLifecycle(self, "OnProfileReset", descriptor)
    return descriptor
end

function methods:RenameProfile(profileRef, newName)
    local normalizedRef, profileID, data, errorCode = resolveOrdinaryProfile(
        self,
        profileRef,
        "manager:RenameProfile"
    )

    if not normalizedRef then
        return nil, errorCode
    end

    if normalizedRef.kind == "permanent" then
        error("LibSimpleDBProfiles: permanent profiles cannot be renamed", 2)
    end

    if not data then
        return nil, errorCode or "PROFILE_NOT_FOUND"
    end

    local normalizedName, nameError = Internal.NormalizeProfileName(newName, "RenameProfile")

    if not normalizedName then
        return nil, nameError
    end

    if normalizedName == normalizedRef.name then
        return Internal.ProfileSnapshot(self, profileID, false)
    end

    if self._storage.profiles[normalizedName] then
        return nil, "PROFILE_EXISTS"
    end

    local oldDescriptor = Internal.ProfileSnapshot(self, profileID, false)
    local newRef = { kind = "user", name = normalizedName }
    local newID = { kind = "user", name = normalizedName }
    self._storage.profiles[normalizedRef.name] = nil
    self._storage.profiles[normalizedName] = data

    for guid, selection in pairs(self._storage.selections) do
        if selection.kind == "user" and selection.name == normalizedRef.name then
            self._storage.selections[guid] = Internal.CopyValue(newRef)
        end
    end

    if Internal.ProfileIdentityEqual(self._activeProfileID, profileID) then
        self._activeProfileRef = Internal.CopyValue(newRef)
        self._activeProfileID = Internal.CopyValue(newID)
    end

    local newDescriptor = Internal.ProfileSnapshot(self, newID, false)
    Internal.DispatchLifecycle(self, "OnProfileRenamed", oldDescriptor, newDescriptor)
    return newDescriptor
end

function methods:DeleteProfile(profileRef)
    local normalizedRef, profileID, data, errorCode = resolveOrdinaryProfile(
        self,
        profileRef,
        "manager:DeleteProfile"
    )

    if not normalizedRef then
        return nil, errorCode
    end

    if normalizedRef.kind == "permanent" then
        error("LibSimpleDBProfiles: permanent profiles cannot be deleted", 2)
    end

    if not data then
        return nil, errorCode or "PROFILE_NOT_FOUND"
    end

    if Internal.ProfileIdentityEqual(self._activeProfileID, profileID) then
        return nil, "ACTIVE_PROFILE"
    end

    local deletedDescriptor = Internal.ProfileSnapshot(self, profileID, false)
    local affectedCharacters = {}

    for guid, selection in pairs(self._storage.selections) do
        if selection.kind == "user" and selection.name == normalizedRef.name then
            affectedCharacters[#affectedCharacters + 1] = Internal.CharacterDescriptor(self, guid)
        end
    end

    table.sort(affectedCharacters, function(left, right)
        return left.guid < right.guid
    end)

    self._storage.profiles[normalizedRef.name] = nil

    for index = 1, #affectedCharacters do
        local character = affectedCharacters[index]
        self._storage.selections[character.guid] = nil
        Internal.DispatchLifecycle(
            self,
            "OnCharacterSelectionChanged",
            Internal.CharacterDescriptor(self, character.guid),
            nil,
            deletedDescriptor
        )
    end

    Internal.DispatchLifecycle(self, "OnProfileDeleted", deletedDescriptor, affectedCharacters)
    return deletedDescriptor, affectedCharacters
end
