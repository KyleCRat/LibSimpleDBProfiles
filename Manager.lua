local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal
local methods = Internal.managerPrototype

local error = error
local next = next
local pairs = pairs
local setmetatable = setmetatable
local type = type

local function validateConstructor(addonName, storage, defaults, options)
    if type(addonName) ~= "string" or addonName == "" then
        error("Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires a non-empty addonName", 3)
    end

    if type(storage) ~= "table" then
        error("Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires a storage table", 3)
    end

    if defaults ~= nil and type(defaults) ~= "table" then
        error("Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires defaults to be a table or nil", 3)
    end

    if options ~= nil and type(options) ~= "table" then
        error("Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires options to be a table or nil", 3)
    end

    options = options or {}

    for key in pairs(options) do
        if key ~= "displayName" and key ~= "migration" then
            error(("LibSimpleDBProfiles: unknown constructor option %q"):format(tostring(key)), 3)
        end
    end

    if options.displayName ~= nil
        and (type(options.displayName) ~= "string" or options.displayName == "") then
        error("LibSimpleDBProfiles: options.displayName must be a non-empty string", 3)
    end

    return options
end

local function validateOwnershipAndLabel(addonName, storage, displayName, explicitDisplayName)
    if Internal.storageOwners[storage] then
        error("LibSimpleDBProfiles: this storage table already has a live manager", 3)
    end

    for manager in pairs(Internal.liveManagers) do
        if manager._addonName == addonName then
            if not explicitDisplayName or not manager._explicitDisplayName then
                error("LibSimpleDBProfiles: multiple managers for one addon require explicit unique displayName values", 3)
            end

            if manager._displayName == displayName then
                error(("LibSimpleDBProfiles: duplicate same-addon manager displayName %q"):format(displayName), 3)
            end
        end
    end
end

local function chooseInitialProfile(storage, identity)
    for index = 1, #Internal.permanentOrder do
        local profile = Internal.permanentOrder[index]
        local profileRef = { kind = "permanent", profile = profile }
        local profileID = Internal.ResolveProfileRef(profileRef, identity.guid, identity)

        if profileID then
            local data = Internal.GetProfileData(storage, profileID)

            if profile == "global" or next(data) ~= nil then
                return profileRef, profileID, data
            end
        end
    end

    error("LibSimpleDBProfiles: failed to resolve the Global fallback profile", 3)
end

local function resolveStoredProfile(storage, identity, profileRef)
    if profileRef.kind == "user" then
        local data = storage.profiles[profileRef.name]

        if not data then
            return nil
        end

        return { kind = "user", name = profileRef.name }, data
    end

    local profileID = Internal.ResolveProfileRef(profileRef, identity.guid, identity)

    if not profileID then
        error(("LibSimpleDBProfiles: selected %s profile cannot resolve for the current player"):format(profileRef.profile), 3)
    end

    local data = Internal.EnsureProfileData(storage, profileID)
    return profileID, data
end

function Internal.NewManager(addonName, storage, defaults, options)
    options = validateConstructor(addonName, storage, defaults, options)
    local explicitDisplayName = options.displayName ~= nil
    local displayName = options.displayName or Internal.ResolveAddonDisplayName(addonName)
    validateOwnershipAndLabel(addonName, storage, displayName, explicitDisplayName)

    local identity = Internal.CaptureCurrentIdentity()
    local metadata, wasFresh = Internal.NormalizeStorage(storage, identity)
    Internal.RunConsumerMigrations(storage, metadata, options.migration, wasFresh)
    Internal.EnsureCurrentPermanentProfiles(storage, identity)
    Internal.UpdateCharacterInfo(storage, identity)

    local profileRef = storage.selections[identity.guid]
    local profileID, data

    if profileRef then
        profileID, data = resolveStoredProfile(storage, identity, profileRef)

        if not profileID then
            storage.selections[identity.guid] = nil
            profileRef = nil
        end
    end

    if not profileRef then
        profileRef, profileID, data = chooseInitialProfile(storage, identity)
        storage.selections[identity.guid] = Internal.CopyValue(profileRef)
    end

    local manager = setmetatable({
        _addonName = addonName,
        _displayName = displayName,
        _explicitDisplayName = explicitDisplayName,
        _storage = storage,
        _storageMetadata = metadata,
        _identity = identity,
        _migration = options.migration,
        _activeProfileRef = Internal.CopyValue(profileRef),
        _activeProfileID = Internal.CopyValue(profileID),
        _activeData = data,
        _lifecycleCallbacks = {},
    }, Internal.managerMetatable)
    manager._activeDB = Internal.SimpleDB:New(data, defaults)

    Internal.storageOwners[storage] = manager
    Internal.liveManagers[manager] = true
    return manager
end

function Internal.ActivateProfile(manager, profileRef, profileID, data)
    if Internal.ProfileIdentityEqual(manager._activeProfileID, profileID) then
        return Internal.ProfileSnapshot(manager, manager._activeProfileID, false), false
    end

    local oldProfile = Internal.ProfileSnapshot(manager, manager._activeProfileID, false)
    manager._activeProfileRef = Internal.CopyValue(profileRef)
    manager._activeProfileID = Internal.CopyValue(profileID)
    manager._activeData = data
    manager._storage.selections[manager._identity.guid] = Internal.CopyValue(profileRef)
    manager._activeDB:SetData(data)
    local newProfile = Internal.ProfileSnapshot(manager, profileID, false)
    Internal.DispatchLifecycle(manager, "OnProfileChanged", newProfile, oldProfile)
    return newProfile, true
end

function methods:GetAddonName()
    return self._addonName
end

function methods:GetDisplayName()
    return self._displayName
end

function methods:GetActiveDB()
    return self._activeDB
end

function methods:GetProfiles()
    return Internal.CurrentProfileDescriptors(self)
end

function methods:GetActiveProfile()
    return Internal.ProfileSnapshot(self, self._activeProfileID, false)
end

function methods:SetProfile(profileRef)
    local normalized, errorCode = Internal.NormalizeProfileRef(profileRef, "manager:SetProfile")

    if not normalized then
        return nil, errorCode
    end

    local profileID = Internal.ResolveProfileRef(normalized, self._identity.guid, self._identity)

    if not profileID then
        return nil, "PROFILE_NOT_FOUND"
    end

    local data = Internal.GetProfileData(self._storage, profileID)
    local created = false

    if not data then
        if normalized.kind ~= "user" then
            data = Internal.EnsureProfileData(self._storage, profileID)
        else
            data = {}
            Internal.SetProfileData(self._storage, profileID, data)
            created = true
        end
    end

    if created then
        Internal.DispatchLifecycle(self, "OnProfileCreated", Internal.ProfileSnapshot(self, profileID, false))
    end

    return Internal.ActivateProfile(self, normalized, profileID, data)
end

function methods:GetProfileUsage(profileRef)
    local normalized, errorCode = Internal.NormalizeProfileRef(profileRef, "manager:GetProfileUsage")

    if not normalized then
        return nil, errorCode
    end

    local profileID = Internal.ResolveProfileRef(normalized, self._identity.guid, self._identity)

    if not profileID or not Internal.GetProfileData(self._storage, profileID) then
        return nil, "PROFILE_NOT_FOUND"
    end

    return Internal.ProfileUsage(self, profileID)
end

function methods:RegisterLifecycleCallback(event, callback)
    if not Internal.lifecycleEvents[event] or type(callback) ~= "function" then
        error("Usage: manager:RegisterLifecycleCallback(event, callback) requires a supported event and function", 2)
    end

    local callbacks = self._lifecycleCallbacks[event]

    if not callbacks then
        callbacks = {}
        self._lifecycleCallbacks[event] = callbacks
    end

    callbacks[callback] = true
    return callback
end

function methods:UnregisterLifecycleCallback(event, callback)
    local callbacks = self._lifecycleCallbacks[event]

    if not callbacks or not callbacks[callback] then
        return false
    end

    callbacks[callback] = nil
    return true
end

function methods:UnregisterAllLifecycleCallbacks(callback)
    if callback == nil then
        self._lifecycleCallbacks = {}
        return
    end

    if type(callback) ~= "function" then
        error("Usage: manager:UnregisterAllLifecycleCallbacks([callback])", 2)
    end

    for _, callbacks in pairs(self._lifecycleCallbacks) do
        callbacks[callback] = nil
    end
end

function Internal.UpgradeLiveManager(manager)
    local oldProfileID = Internal.CopyValue(manager._activeProfileID)
    local oldProfile = Internal.ProfileSnapshot(manager, oldProfileID, false)
    local oldData = manager._activeData
    local metadata = Internal.NormalizeStorage(manager._storage, manager._identity)
    manager._storageMetadata = metadata

    local profileID = Internal.ResolveProfileRef(
        manager._activeProfileRef,
        manager._identity.guid,
        manager._identity
    )
    local data = profileID and Internal.GetProfileData(manager._storage, profileID)

    if not profileID or not data then
        error("LibSimpleDBProfiles: compatible upgrade could not preserve the active profile", 2)
    end

    manager._activeProfileID = Internal.CopyValue(profileID)
    manager._activeData = data

    if oldData ~= data then
        manager._activeDB:SetData(data)
    end

    if not Internal.ProfileIdentityEqual(oldProfileID, profileID) then
        Internal.DispatchLifecycle(
            manager,
            "OnProfileChanged",
            Internal.ProfileSnapshot(manager, profileID, false),
            oldProfile
        )
    end
end
