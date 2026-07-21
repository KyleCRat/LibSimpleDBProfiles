local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
    return
end

local Internal = lib._internal

local pcall = pcall
local type = type

function Internal.HandleSpecializationChanged(manager)
    local newIdentity = Internal.CaptureCurrentIdentity()

    if manager._activeProfileRef.kind == "permanent"
        and manager._activeProfileRef.profile == "spec"
        and not newIdentity.specID then
        return
    end

    local oldCharacter = Internal.CharacterDescriptor(manager, manager._identity.guid)
    local oldProfile = Internal.ProfileSnapshot(manager, manager._activeProfileID, false)
    manager._identity = newIdentity
    Internal.EnsureCurrentPermanentProfiles(manager._storage, newIdentity)
    local _, _, infoChanged = Internal.UpdateCharacterInfo(manager._storage, newIdentity)
    local newCharacter = Internal.CharacterDescriptor(manager, newIdentity.guid)

    if infoChanged then
        Internal.DispatchLifecycle(manager, "OnCharacterInfoChanged", newCharacter, oldCharacter)
    end

    if manager._activeProfileRef.kind ~= "permanent"
        or manager._activeProfileRef.profile ~= "spec" then
        return
    end

    local newProfileID = Internal.CurrentProfileID(manager, "spec")

    if not newProfileID or Internal.ProfileIdentityEqual(manager._activeProfileID, newProfileID) then
        return
    end

    local newData = Internal.EnsureProfileData(manager._storage, newProfileID)
    manager._activeProfileID = Internal.CopyValue(newProfileID)
    manager._activeData = newData
    manager._activeDB:SetData(newData)
    Internal.DispatchLifecycle(
        manager,
        "OnProfileChanged",
        Internal.ProfileSnapshot(manager, newProfileID, false),
        oldProfile
    )
end

function Internal.InstallEventFrame()
    if type(CreateFrame) ~= "function" then
        return
    end

    local frame = lib._eventFrame

    if not frame then
        frame = CreateFrame("Frame")
        lib._eventFrame = frame
    end

    frame:SetScript("OnEvent", function(_, event)
        if event ~= "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
            return
        end

        local managers = {}

        for manager in pairs(Internal.liveManagers) do
            managers[#managers + 1] = manager
        end

        for index = 1, #managers do
            local ok, message = pcall(Internal.HandleSpecializationChanged, managers[index])

            if not ok then
                Internal.ReportCallbackError(message)
            end
        end
    end)

    frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
end
