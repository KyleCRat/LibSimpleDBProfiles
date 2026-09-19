-- Construct managers, own current-character selection, and keep one stable
-- LibSimpleDB instance connected to the active profile payload.
local BUILD_MINOR = 1
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal
local Manager = Internal.managerPrototype

local error = error
local next = next
local pairs = pairs
local setmetatable = setmetatable
local type = type

local CONSTRUCTOR_ERROR_LEVEL = 3
local METHOD_ERROR_LEVEL = 2
local ALLOWED_CONSTRUCTOR_OPTIONS = {
    displayName = true,
    migration = true,
    initialProfile = true,
}

local function validateConstructorArguments(addonName, storage, defaults, options)
    if type(addonName) ~= "string" or addonName == "" then
        error(
            "Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires a non-empty addonName",
            CONSTRUCTOR_ERROR_LEVEL
        )
    end

    if type(storage) ~= "table" then
        error(
            "Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires a storage table",
            CONSTRUCTOR_ERROR_LEVEL
        )
    end

    if defaults ~= nil and type(defaults) ~= "table" then
        error(
            "Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires defaults to be a table or nil",
            CONSTRUCTOR_ERROR_LEVEL
        )
    end

    if options ~= nil and type(options) ~= "table" then
        error(
            "Usage: LibSimpleDBProfiles:New(addonName, storage, defaults, options) requires options to be a table or nil",
            CONSTRUCTOR_ERROR_LEVEL
        )
    end

    options = options or {}

    for key in pairs(options) do
        if not ALLOWED_CONSTRUCTOR_OPTIONS[key] then
            error(("LibSimpleDBProfiles: unknown constructor option %q"):format(tostring(key)), CONSTRUCTOR_ERROR_LEVEL)
        end
    end

    if options.displayName ~= nil
        and (type(options.displayName) ~= "string" or options.displayName == "") then
        error("LibSimpleDBProfiles: options.displayName must be a non-empty string", CONSTRUCTOR_ERROR_LEVEL)
    end

    if options.initialProfile ~= nil
        and (type(options.initialProfile) ~= "string"
            or (options.initialProfile ~= "mostSpecific"
                and not Internal.permanentProfileDefinitions[options.initialProfile])) then
        error("LibSimpleDBProfiles: initialProfile must be mostSpecific or a permanent profile name", CONSTRUCTOR_ERROR_LEVEL)
    end

    return options
end

local function validateManagerOwnership(addonName, storage, displayName, hasExplicitDisplayName)
    if Internal.managerByStorage[storage] then
        error("LibSimpleDBProfiles: this storage table already has a live manager", CONSTRUCTOR_ERROR_LEVEL)
    end

    for manager in pairs(Internal.liveManagerSet) do
        if manager._addonName == addonName then
            if not hasExplicitDisplayName or not manager._hasExplicitDisplayName then
                error(
                    "LibSimpleDBProfiles: multiple managers for one addon require explicit unique displayName values",
                    CONSTRUCTOR_ERROR_LEVEL
                )
            end

            if manager._displayName == displayName then
                error(
                    ("LibSimpleDBProfiles: duplicate same-addon manager displayName %q"):format(displayName),
                    CONSTRUCTOR_ERROR_LEVEL
                )
            end
        end
    end
end

-- Run only when this character has no saved selection. The first non-empty
-- permanent payload wins; Global is always available as the final fallback.
local function chooseMostSpecificInitialProfile(storage, identity)
    for index = 1, #Internal.permanentProfileOrder do
        local profileType = Internal.permanentProfileOrder[index]
        local profileRef = { kind = "permanent", profile = profileType }
        local profileID = Internal.ResolveProfileRef(profileRef, identity.guid, identity)

        if profileID then
            local profilePayload = Internal.GetProfilePayload(storage, profileID)

            if profileType == "global" or next(profilePayload) ~= nil then
                return profileRef, profileID, profilePayload
            end
        end
    end

    error("LibSimpleDBProfiles: failed to resolve the Global fallback profile", CONSTRUCTOR_ERROR_LEVEL)
end

-- An explicit initial type may select an empty profile. Missing specialization
-- identity uses Global provisionally, then retries at the normal login boundary.
local function chooseInitialProfile(storage, identity, initialProfile)
    if initialProfile == "mostSpecific" then
        return chooseMostSpecificInitialProfile(storage, identity)
    end

    local profileRef = { kind = "permanent", profile = initialProfile }
    local profileID = Internal.ResolveProfileRef(profileRef, identity.guid, identity)

    if not profileID then
        profileRef = { kind = "permanent", profile = "global" }
        profileID = Internal.ResolveProfileRef(profileRef, identity.guid, identity)
    end

    return profileRef, profileID, Internal.EnsureProfilePayload(storage, profileID)
end

local function resolveSavedSelection(storage, identity, profileRef)
    if profileRef.kind == "user" then
        local profilePayload = storage.profiles[profileRef.name]

        if not profilePayload then
            return nil
        end

        return { kind = "user", name = profileRef.name }, profilePayload
    end

    local profileID = Internal.ResolveProfileRef(profileRef, identity.guid, identity)

    if not profileID then
        if profileRef.kind == "permanent"
            and profileRef.profile == "spec"
            and not identity.specID then
            return nil, nil, true
        end

        error(
            ("LibSimpleDBProfiles: selected %s profile cannot resolve for the current player"):format(
                profileRef.profile
            ),
            CONSTRUCTOR_ERROR_LEVEL
        )
    end

    local profilePayload = Internal.EnsureProfilePayload(storage, profileID)
    return profileID, profilePayload
end

function Internal.NewManager(addonName, storage, defaults, options)
    options = validateConstructorArguments(addonName, storage, defaults, options)
    local initialProfile = options.initialProfile or "mostSpecific"
    local hasExplicitDisplayName = options.displayName ~= nil
    local displayName = options.displayName or Internal.ResolveAddonDisplayName(addonName)
    validateManagerOwnership(addonName, storage, displayName, hasExplicitDisplayName)

    -- Establish canonical identity and make the entire storage tree valid before
    -- selecting a payload or constructing LibSimpleDB.
    local identity = Internal.CaptureCurrentIdentity()
    local storageMetadata, isFreshStorage = Internal.NormalizeStorage(storage, identity)
    Internal.RunConsumerMigrations(storage, storageMetadata, options.migration, isFreshStorage)
    Internal.UpdateCharacterInfo(storage, identity)

    local activeProfileRef = storage.selections[identity.guid]
    local activeProfileID, activePayload
    local pendingSelection

    if activeProfileRef then
        local savedSelectionPending
        activeProfileID, activePayload, savedSelectionPending = resolveSavedSelection(
            storage,
            identity,
            activeProfileRef
        )

        if savedSelectionPending then
            pendingSelection = {
                kind = "saved",
                profileRef = Internal.CopyValue(activeProfileRef),
            }
            activeProfileRef, activeProfileID, activePayload = chooseMostSpecificInitialProfile(
                storage,
                identity
            )
        elseif not activeProfileID then
            storage.selections[identity.guid] = nil
            activeProfileRef = nil
        end
    end

    if not activeProfileRef then
        activeProfileRef, activeProfileID, activePayload = chooseInitialProfile(
            storage,
            identity,
            initialProfile
        )

        local needsSpecialization = not identity.specID
            and (initialProfile == "spec"
                or (initialProfile == "mostSpecific" and activeProfileRef.profile ~= "character"))

        if needsSpecialization then
            pendingSelection = { kind = "initial" }
        else
            storage.selections[identity.guid] = Internal.CopyValue(activeProfileRef)
        end
    end

    -- The manager owns selection and storage; LibSimpleDB owns reads, writes,
    -- defaults, and callbacks within the selected payload.
    local manager = setmetatable({
        _addonName = addonName,
        _displayName = displayName,
        _hasExplicitDisplayName = hasExplicitDisplayName,
        _storage = storage,
        _identity = identity,
        _initialProfile = initialProfile,
        _activeProfileRef = Internal.CopyValue(activeProfileRef),
        _activeProfileID = Internal.CopyValue(activeProfileID),
        _activePayload = activePayload,
        _pendingSelection = pendingSelection,
        _specializationIdentityPending = not identity.specID,
        _lifecycleCallbacks = {},
    }, Internal.managerMetatable)
    manager._activeDB = Internal.SimpleDB:New(activePayload, defaults)

    Internal.managerByStorage[storage] = manager
    Internal.liveManagerSet[manager] = true
    return manager
end

-- Construction remains synchronous when specialization APIs are not ready.
-- Finalize the saved or initial relative selection once identity is available,
-- or at the world-entry boundary for a player who genuinely has no spec.
function Internal.FinalizePendingSelection(manager, allowMissingSpecialization)
    local pendingSelection = manager._pendingSelection

    if not pendingSelection then
        return false
    end

    local profileRef, profileID, profilePayload

    if pendingSelection.kind == "saved" then
        profileRef = pendingSelection.profileRef
        profileID = Internal.ResolveProfileRef(
            profileRef,
            manager._identity.guid,
            manager._identity
        )

        if not profileID then
            return false
        end

        profilePayload = Internal.EnsureProfilePayload(manager._storage, profileID)
    else
        if not manager._identity.specID and not allowMissingSpecialization then
            return false
        end

        profileRef, profileID, profilePayload = chooseInitialProfile(
            manager._storage,
            manager._identity,
            manager._initialProfile
        )
    end

    Internal.ActivateProfile(manager, profileRef, profileID, profilePayload)
    return true
end

-- Switch the payload beneath the stable LibSimpleDB object. Consumers keep the
-- same DB reference while LibSimpleDB emits its own bulk data-change callback.
function Internal.ActivateProfile(manager, profileRef, profileID, profilePayload)
    if Internal.ProfileIDEqual(manager._activeProfileID, profileID) then
        manager._activeProfileRef = Internal.CopyValue(profileRef)
        manager._pendingSelection = nil
        manager._storage.selections[manager._identity.guid] = Internal.CopyValue(profileRef)
        return Internal.BuildProfileDescriptor(manager, manager._activeProfileID, false), false
    end

    local previousProfile = Internal.BuildProfileDescriptor(manager, manager._activeProfileID, false)
    manager._activeProfileRef = Internal.CopyValue(profileRef)
    manager._activeProfileID = Internal.CopyValue(profileID)
    manager._activePayload = profilePayload
    manager._pendingSelection = nil
    manager._storage.selections[manager._identity.guid] = Internal.CopyValue(profileRef)
    manager._activeDB:SetData(profilePayload)
    local currentProfile = Internal.BuildProfileDescriptor(manager, profileID, false)
    Internal.DispatchLifecycle(manager, "OnProfileChanged", currentProfile, previousProfile)
    return currentProfile, true
end

-- Public manager reads and selection

function Manager:GetAddonName()
    return self._addonName
end

function Manager:GetDisplayName()
    return self._displayName
end

function Manager:GetActiveDB()
    return self._activeDB
end

function Manager:GetProfiles()
    return Internal.BuildCurrentProfileDescriptors(self)
end

function Manager:GetActiveProfile()
    return Internal.BuildProfileDescriptor(self, self._activeProfileID, false)
end

function Manager:SetProfile(profileRef)
    local normalizedRef, errorCode = Internal.NormalizeProfileRef(profileRef, "manager:SetProfile")

    if not normalizedRef then
        return nil, errorCode
    end

    local profileID = Internal.ResolveProfileRef(normalizedRef, self._identity.guid, self._identity)

    if not profileID then
        return nil, "PROFILE_NOT_FOUND"
    end

    local profilePayload = Internal.GetProfilePayload(self._storage, profileID)
    local profileWasCreated = false

    if not profilePayload then
        if normalizedRef.kind ~= "user" then
            profilePayload = Internal.EnsureProfilePayload(self._storage, profileID)
        else
            profilePayload = {}
            Internal.SetProfilePayload(self._storage, profileID, profilePayload)
            profileWasCreated = true
        end
    end

    if profileWasCreated then
        Internal.DispatchLifecycle(self, "OnProfileCreated", Internal.BuildProfileDescriptor(self, profileID, false))
    end

    return Internal.ActivateProfile(self, normalizedRef, profileID, profilePayload)
end

function Manager:GetProfileUsage(profileRef)
    local normalizedRef, errorCode = Internal.NormalizeProfileRef(profileRef, "manager:GetProfileUsage")

    if not normalizedRef then
        return nil, errorCode
    end

    local profileID = Internal.ResolveProfileRef(normalizedRef, self._identity.guid, self._identity)

    if not profileID or not Internal.GetProfilePayload(self._storage, profileID) then
        return nil, "PROFILE_NOT_FOUND"
    end

    return Internal.BuildProfileUsage(self, profileID)
end

-- Public lifecycle callback registration

function Manager:RegisterLifecycleCallback(event, callback)
    if not Internal.lifecycleEvents[event] or type(callback) ~= "function" then
        error(
            "Usage: manager:RegisterLifecycleCallback(event, callback) requires a supported event and function",
            METHOD_ERROR_LEVEL
        )
    end

    local callbacks = self._lifecycleCallbacks[event]

    if not callbacks then
        callbacks = {}
        self._lifecycleCallbacks[event] = callbacks
    end

    callbacks[callback] = true
    return callback
end

function Manager:UnregisterLifecycleCallback(event, callback)
    local callbacks = self._lifecycleCallbacks[event]

    if not callbacks or not callbacks[callback] then
        return false
    end

    callbacks[callback] = nil
    return true
end

function Manager:UnregisterAllLifecycleCallbacks(callback)
    if callback == nil then
        self._lifecycleCallbacks = {}
        return
    end

    if type(callback) ~= "function" then
        error("Usage: manager:UnregisterAllLifecycleCallbacks([callback])", METHOD_ERROR_LEVEL)
    end

    for _, callbacks in pairs(self._lifecycleCallbacks) do
        callbacks[callback] = nil
    end
end

-- A higher compatible LibStub minor reuses each live manager. Re-normalize
-- library-owned storage, then reconnect its stable DB if a schema step replaced
-- the active payload table.
function Internal.RefreshLiveManager(manager)
    if manager._initialProfile == nil then
        manager._initialProfile = "mostSpecific"
    end

    if manager._specializationIdentityPending == nil then
        manager._specializationIdentityPending = not manager._identity.specID
    end

    local previousProfileID = Internal.CopyValue(manager._activeProfileID)
    local previousProfile = Internal.BuildProfileDescriptor(manager, previousProfileID, false)
    local previousPayload = manager._activePayload
    Internal.NormalizeStorage(manager._storage, manager._identity)

    local currentProfileID = Internal.ResolveProfileRef(
        manager._activeProfileRef,
        manager._identity.guid,
        manager._identity
    )
    local currentPayload = currentProfileID
        and Internal.GetProfilePayload(manager._storage, currentProfileID)

    if not currentProfileID or not currentPayload then
        error("LibSimpleDBProfiles: compatible upgrade could not preserve the active profile", METHOD_ERROR_LEVEL)
    end

    manager._activeProfileID = Internal.CopyValue(currentProfileID)
    manager._activePayload = currentPayload

    if previousPayload ~= currentPayload then
        manager._activeDB:SetData(currentPayload)
    end

    if not Internal.ProfileIDEqual(previousProfileID, currentProfileID) then
        Internal.DispatchLifecycle(
            manager,
            "OnProfileChanged",
            Internal.BuildProfileDescriptor(manager, currentProfileID, false),
            previousProfile
        )
    end
end
