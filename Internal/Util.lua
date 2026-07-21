-- Shared SavedVariables, profile-name, callback, and identity helpers.
local BUILD_MINOR = 1
local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._loadInProgressMinor ~= BUILD_MINOR then
    return
end

local Internal = lib._internal

local error = error
local getErrorHandler = geterrorhandler
local pairs = pairs
local pcall = pcall
local sort = table.sort
local stringByte = string.byte
local stringChar = string.char
local tableConcat = table.concat
local type = type

local INTERNAL_CALLER_ERROR_LEVEL = 3
local ASCII_MAX_BYTE = 0x7F
local ASCII_CONTROL_MAX_BYTE = 0x1F
local ASCII_DELETE_BYTE = 0x7F
local ASCII_TAB_BYTE = 0x09
local ASCII_CARRIAGE_RETURN_BYTE = 0x0D
local ASCII_SPACE_BYTE = 0x20
local UTF8_CONTINUATION_MIN_BYTE = 0x80
local UTF8_CONTINUATION_MAX_BYTE = 0xBF
local UTF8_TWO_BYTE_LEAD_MIN = 0xC2
local UTF8_TWO_BYTE_LEAD_MAX = 0xDF
local UTF8_THREE_BYTE_LOW_LEAD = 0xE0
local UTF8_THREE_BYTE_LOW_SECOND_MIN = 0xA0
local UTF8_THREE_BYTE_GENERAL_LOW_MIN = 0xE1
local UTF8_THREE_BYTE_GENERAL_LOW_MAX = 0xEC
local UTF8_THREE_BYTE_HIGH_LEAD = 0xED
local UTF8_THREE_BYTE_HIGH_SECOND_MAX = 0x9F
local UTF8_THREE_BYTE_GENERAL_HIGH_MIN = 0xEE
local UTF8_THREE_BYTE_GENERAL_HIGH_MAX = 0xEF
local UTF8_FOUR_BYTE_LOW_LEAD = 0xF0
local UTF8_FOUR_BYTE_LOW_SECOND_MIN = 0x90
local UTF8_FOUR_BYTE_GENERAL_MIN = 0xF1
local UTF8_FOUR_BYTE_GENERAL_MAX = 0xF3
local UTF8_FOUR_BYTE_HIGH_LEAD = 0xF4
local UTF8_FOUR_BYTE_HIGH_SECOND_MAX = 0x8F

-- These are the only lifecycle event names accepted by manager registration.
Internal.lifecycleEvents = {
    OnCharacterForgotten = true,
    OnCharacterInfoChanged = true,
    OnCharacterSelectionChanged = true,
    OnProfileChanged = true,
    OnProfileCopied = true,
    OnProfileCreated = true,
    OnProfileDeleted = true,
    OnProfileRenamed = true,
    OnProfileReset = true,
}

-- SavedVariables-safe value handling

function Internal.ClearTable(tableValue)
    for key in pairs(tableValue) do
        tableValue[key] = nil
    end
end

function Internal.IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function isSavedVariablesKey(key)
    local keyType = type(key)
    return keyType == "string" or (keyType == "number" and key == key)
end

local function copyValue(value, activeAncestors, callerErrorLevel)
    local valueType = type(value)

    if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return value
    end

    if valueType ~= "table" then
        error("LibSimpleDBProfiles: values must be SavedVariables-compatible primitives or tables", callerErrorLevel)
    end

    activeAncestors = activeAncestors or {}

    if activeAncestors[value] then
        error("LibSimpleDBProfiles: cyclic tables are not supported", callerErrorLevel)
    end

    activeAncestors[value] = true

    local copiedTable = {}

    for key, childValue in pairs(value) do
        if not isSavedVariablesKey(key) then
            error("LibSimpleDBProfiles: table keys must be strings or numbers", callerErrorLevel)
        end

        copiedTable[key] = copyValue(childValue, activeAncestors, callerErrorLevel)
    end

    activeAncestors[value] = nil
    return copiedTable
end

function Internal.CopyValue(value)
    return copyValue(value, nil, INTERNAL_CALLER_ERROR_LEVEL)
end

local function validateValue(value, activeAncestors, callerErrorLevel)
    local valueType = type(value)

    if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return
    end

    if valueType ~= "table" then
        error("LibSimpleDBProfiles: values must be SavedVariables-compatible primitives or tables", callerErrorLevel)
    end

    if activeAncestors[value] then
        error("LibSimpleDBProfiles: cyclic tables are not supported", callerErrorLevel)
    end

    activeAncestors[value] = true

    for key, childValue in pairs(value) do
        if not isSavedVariablesKey(key) then
            error("LibSimpleDBProfiles: table keys must be strings or numbers", callerErrorLevel)
        end

        validateValue(childValue, activeAncestors, callerErrorLevel)
    end

    activeAncestors[value] = nil
end

function Internal.ValidateValue(value)
    validateValue(value, {}, INTERNAL_CALLER_ERROR_LEVEL)
    return value
end

function Internal.ReplaceTable(destination, source)
    local copiedSource = Internal.CopyValue(source)
    Internal.ClearTable(destination)

    for key, value in pairs(copiedSource) do
        destination[key] = value
    end

    return destination
end

function Internal.DeepEqual(left, right)
    if type(left) ~= type(right) then
        return false
    end

    if type(left) ~= "table" then
        return left == right
    end

    for key, value in pairs(left) do
        if not Internal.DeepEqual(value, right[key]) then
            return false
        end
    end

    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end

    return true
end

function Internal.SortedKeys(tableValue)
    local keys = {}

    for key in pairs(tableValue) do
        keys[#keys + 1] = key
    end

    sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    return keys
end

-- UTF-8 profile-name validation and normalization. Hex constants mirror the
-- Unicode scalar-value ranges and make the special E0, ED, F0, and F4 cases
-- visible without requiring readers to decode decimal byte values.

local function isByteInRange(byte, minimum, maximum)
    return byte and byte >= minimum and byte <= maximum
end

local function isContinuation(byte)
    return isByteInRange(byte, UTF8_CONTINUATION_MIN_BYTE, UTF8_CONTINUATION_MAX_BYTE)
end

local function hasContinuationBytes(value, firstIndex, count)
    for offset = 0, count - 1 do
        if not isContinuation(stringByte(value, firstIndex + offset)) then
            return false
        end
    end

    return true
end

function Internal.IsValidUTF8(value)
    local length = #value
    local index = 1

    while index <= length do
        local first = stringByte(value, index)

        if first <= ASCII_MAX_BYTE then
            index = index + 1
        elseif isByteInRange(first, UTF8_TWO_BYTE_LEAD_MIN, UTF8_TWO_BYTE_LEAD_MAX) then
            if not hasContinuationBytes(value, index + 1, 1) then
                return false
            end

            index = index + 2
        elseif first == UTF8_THREE_BYTE_LOW_LEAD then
            local second = stringByte(value, index + 1)

            if not isByteInRange(second, UTF8_THREE_BYTE_LOW_SECOND_MIN, UTF8_CONTINUATION_MAX_BYTE)
                or not hasContinuationBytes(value, index + 2, 1) then
                return false
            end

            index = index + 3
        elseif isByteInRange(
            first,
            UTF8_THREE_BYTE_GENERAL_LOW_MIN,
            UTF8_THREE_BYTE_GENERAL_LOW_MAX
        ) or isByteInRange(
            first,
            UTF8_THREE_BYTE_GENERAL_HIGH_MIN,
            UTF8_THREE_BYTE_GENERAL_HIGH_MAX
        ) then
            if not hasContinuationBytes(value, index + 1, 2) then
                return false
            end

            index = index + 3
        elseif first == UTF8_THREE_BYTE_HIGH_LEAD then
            local second = stringByte(value, index + 1)

            if not isByteInRange(second, UTF8_CONTINUATION_MIN_BYTE, UTF8_THREE_BYTE_HIGH_SECOND_MAX)
                or not hasContinuationBytes(value, index + 2, 1) then
                return false
            end

            index = index + 3
        elseif first == UTF8_FOUR_BYTE_LOW_LEAD then
            local second = stringByte(value, index + 1)

            if not isByteInRange(second, UTF8_FOUR_BYTE_LOW_SECOND_MIN, UTF8_CONTINUATION_MAX_BYTE)
                or not hasContinuationBytes(value, index + 2, 2) then
                return false
            end

            index = index + 4
        elseif isByteInRange(first, UTF8_FOUR_BYTE_GENERAL_MIN, UTF8_FOUR_BYTE_GENERAL_MAX) then
            if not hasContinuationBytes(value, index + 1, 3) then
                return false
            end

            index = index + 4
        elseif first == UTF8_FOUR_BYTE_HIGH_LEAD then
            local second = stringByte(value, index + 1)

            if not isByteInRange(second, UTF8_CONTINUATION_MIN_BYTE, UTF8_FOUR_BYTE_HIGH_SECOND_MAX)
                or not hasContinuationBytes(value, index + 2, 2) then
                return false
            end

            index = index + 4
        else
            return false
        end
    end

    return true
end

local function isASCIIWhitespace(byte)
    return byte == ASCII_SPACE_BYTE
        or isByteInRange(byte, ASCII_TAB_BYTE, ASCII_CARRIAGE_RETURN_BYTE)
end

function Internal.NormalizeProfileName(value, operation)
    if type(value) ~= "string" then
        error(("Usage: manager:%s(...) requires a string profile name"):format(operation), INTERNAL_CALLER_ERROR_LEVEL)
    end

    if not Internal.IsValidUTF8(value) then
        return nil, "INVALID_NAME"
    end

    local normalizedBytes = {}
    local hasContent = false
    local pendingSpace = false

    for index = 1, #value do
        local byte = stringByte(value, index)

        if isASCIIWhitespace(byte) then
            if hasContent then
                pendingSpace = true
            end
        elseif byte <= ASCII_CONTROL_MAX_BYTE or byte == ASCII_DELETE_BYTE then
            return nil, "INVALID_NAME"
        else
            if pendingSpace then
                normalizedBytes[#normalizedBytes + 1] = " "
                pendingSpace = false
            end

            normalizedBytes[#normalizedBytes + 1] = stringChar(byte)
            hasContent = true
        end
    end

    if not hasContent then
        return nil, "INVALID_NAME"
    end

    return tableConcat(normalizedBytes)
end

-- Lifecycle callback dispatch

function Internal.ReportCallbackError(errorMessage)
    if type(getErrorHandler) ~= "function" then
        return
    end

    local ok, errorHandler = pcall(getErrorHandler)

    if ok and type(errorHandler) == "function" then
        pcall(errorHandler, errorMessage)
    end
end

function Internal.CallSafely(callback, ...)
    local ok, errorMessage = pcall(callback, ...)

    if not ok then
        Internal.ReportCallbackError(errorMessage)
    end
end

function Internal.DispatchLifecycle(manager, event, ...)
    local callbacks = manager._lifecycleCallbacks[event]

    if not callbacks then
        return
    end

    local callbackSnapshot = {}

    for callback in pairs(callbacks) do
        callbackSnapshot[#callbackSnapshot + 1] = callback
    end

    for index = 1, #callbackSnapshot do
        Internal.CallSafely(callbackSnapshot[index], manager, event, ...)
    end
end

-- profileID values include exact permanent keys; profileRef values intentionally
-- omit those keys and resolve relative to a character.

function Internal.ProfileIDEqual(left, right)
    if left == right then
        return true
    end

    if type(left) ~= "table" or type(right) ~= "table" or left.kind ~= right.kind then
        return false
    end

    if left.kind == "user" then
        return left.name == right.name
    end

    return left.profile == right.profile and left.key == right.key
end

function Internal.ProfileRefEqual(left, right)
    if left == right then
        return true
    end

    if type(left) ~= "table" or type(right) ~= "table" or left.kind ~= right.kind then
        return false
    end

    if left.kind == "user" then
        return left.name == right.name
    end

    return left.profile == right.profile and left.key == nil and right.key == nil
end
