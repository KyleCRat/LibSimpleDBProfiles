-- Refresh character identity on specialization changes and follow the new
-- specialization only when the manager explicitly selected that profile type.
local BUILD_MINOR = 1
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal

local pcall = pcall
local type = type

local SPECIALIZATION_CHANGED_EVENT = "ACTIVE_PLAYER_SPECIALIZATION_CHANGED"
local PLAYER_LOGIN_EVENT = "PLAYER_LOGIN"
local PLAYER_ENTERING_WORLD_EVENT = "PLAYER_ENTERING_WORLD"
local EVENT_HANDLER_SCRIPT = "OnEvent"

function Internal.HandleSpecializationChanged(manager, allowMissingSpecialization)
    local refreshedIdentity = Internal.CaptureCurrentIdentity()

    -- Specialization APIs can be briefly unavailable during startup and spec
    -- transitions. Preserve known identity until a later event resolves it.
    if not refreshedIdentity.specID then
        if allowMissingSpecialization then
            Internal.FinalizePendingSelection(manager, true)
            manager._specializationIdentityPending = manager._pendingSelection ~= nil
        else
            manager._specializationIdentityPending = true
        end

        return
    end

    local previousCharacter = Internal.BuildCharacterDescriptor(manager, manager._identity.guid)
    local previousProfile = Internal.BuildProfileDescriptor(manager, manager._activeProfileID, false)
    manager._identity = refreshedIdentity
    manager._specializationIdentityPending = false
    Internal.EnsureCurrentPermanentProfilePayloads(manager._storage, refreshedIdentity)
    local characterInfoChanged = Internal.UpdateCharacterInfo(
        manager._storage,
        refreshedIdentity
    )
    local currentCharacter = Internal.BuildCharacterDescriptor(manager, refreshedIdentity.guid)

    if characterInfoChanged then
        Internal.DispatchLifecycle(
            manager,
            "OnCharacterInfoChanged",
            currentCharacter,
            previousCharacter
        )
    end

    if Internal.FinalizePendingSelection(manager, false) then
        return
    end

    if manager._activeProfileRef.kind ~= "permanent"
        or manager._activeProfileRef.profile ~= "spec" then
        return
    end

    local currentProfileID = Internal.ResolveCurrentProfileID(manager, "spec")

    if not currentProfileID or Internal.ProfileIDEqual(manager._activeProfileID, currentProfileID) then
        return
    end

    local currentPayload = Internal.EnsureProfilePayload(manager._storage, currentProfileID)
    manager._activeProfileID = Internal.CopyValue(currentProfileID)
    manager._activePayload = currentPayload
    manager._activeDB:SetData(currentPayload)
    Internal.DispatchLifecycle(
        manager,
        "OnProfileChanged",
        Internal.BuildProfileDescriptor(manager, currentProfileID, false),
        previousProfile
    )
end

function Internal.InstallEventFrame()
    if type(CreateFrame) ~= "function" then
        return
    end

    local eventFrame = lib._eventFrame

    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        lib._eventFrame = eventFrame
    end

    -- Reuse the frame across compatible upgrades, but replace its handler so
    -- existing managers always execute the newest implementation.
    eventFrame:SetScript(EVENT_HANDLER_SCRIPT, function(_, event)
        if event ~= SPECIALIZATION_CHANGED_EVENT
            and event ~= PLAYER_LOGIN_EVENT
            and event ~= PLAYER_ENTERING_WORLD_EVENT then
            return
        end

        local managerSnapshot = {}

        for manager in pairs(Internal.liveManagerSet) do
            if event == SPECIALIZATION_CHANGED_EVENT
                or manager._specializationIdentityPending then
                managerSnapshot[#managerSnapshot + 1] = manager
            end
        end

        for index = 1, #managerSnapshot do
            local ok, errorMessage = pcall(
                Internal.HandleSpecializationChanged,
                managerSnapshot[index],
                event == PLAYER_ENTERING_WORLD_EVENT
            )

            if not ok then
                Internal.ReportCallbackError(errorMessage)
            end
        end
    end)

    eventFrame:RegisterEvent(SPECIALIZATION_CHANGED_EVENT)
    eventFrame:RegisterEvent(PLAYER_LOGIN_EVENT)
    eventFrame:RegisterEvent(PLAYER_ENTERING_WORLD_EVENT)
end
