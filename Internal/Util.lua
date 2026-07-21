local lib = LibStub("LibSimpleDBProfiles-1.0", true)

if not lib or lib._buildingMinor ~= 1 then
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

function Internal.ClearTable(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

function Internal.IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function isStorageKey(key)
    local keyType = type(key)
    return keyType == "string" or (keyType == "number" and key == key)
end

local function copyValue(value, ancestors, errorLevel)
    local valueType = type(value)

    if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return value
    end

    if valueType ~= "table" then
        error("LibSimpleDBProfiles: values must be SavedVariables-compatible primitives or tables", errorLevel)
    end

    ancestors = ancestors or {}

    if ancestors[value] then
        error("LibSimpleDBProfiles: cyclic tables are not supported", errorLevel)
    end

    ancestors[value] = true

    local copy = {}

    for key, child in pairs(value) do
        if not isStorageKey(key) then
            error("LibSimpleDBProfiles: table keys must be strings or numbers", errorLevel)
        end

        copy[key] = copyValue(child, ancestors, errorLevel)
    end

    ancestors[value] = nil
    return copy
end

function Internal.CopyValue(value)
    return copyValue(value, nil, 3)
end

local function validateValue(value, ancestors, errorLevel)
    local valueType = type(value)

    if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return
    end

    if valueType ~= "table" then
        error("LibSimpleDBProfiles: values must be SavedVariables-compatible primitives or tables", errorLevel)
    end

    if ancestors[value] then
        error("LibSimpleDBProfiles: cyclic tables are not supported", errorLevel)
    end

    ancestors[value] = true

    for key, child in pairs(value) do
        if not isStorageKey(key) then
            error("LibSimpleDBProfiles: table keys must be strings or numbers", errorLevel)
        end

        validateValue(child, ancestors, errorLevel)
    end

    ancestors[value] = nil
end

function Internal.ValidateValue(value)
    validateValue(value, {}, 3)
    return value
end

function Internal.ReplaceTable(destination, source)
    local copy = Internal.CopyValue(source)
    Internal.ClearTable(destination)

    for key, value in pairs(copy) do
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

function Internal.SortedKeys(tbl)
    local keys = {}

    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end

    sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    return keys
end

local function isContinuation(byte)
    return byte and byte >= 128 and byte <= 191
end

function Internal.IsValidUTF8(value)
    local length = #value
    local index = 1

    while index <= length do
        local first = stringByte(value, index)

        if first <= 127 then
            index = index + 1
        elseif first >= 194 and first <= 223 then
            if not isContinuation(stringByte(value, index + 1)) then
                return false
            end

            index = index + 2
        elseif first == 224 then
            local second = stringByte(value, index + 1)

            if not second or second < 160 or second > 191 or not isContinuation(stringByte(value, index + 2)) then
                return false
            end

            index = index + 3
        elseif (first >= 225 and first <= 236) or (first >= 238 and first <= 239) then
            if not isContinuation(stringByte(value, index + 1))
                or not isContinuation(stringByte(value, index + 2)) then
                return false
            end

            index = index + 3
        elseif first == 237 then
            local second = stringByte(value, index + 1)

            if not second or second < 128 or second > 159 or not isContinuation(stringByte(value, index + 2)) then
                return false
            end

            index = index + 3
        elseif first == 240 then
            local second = stringByte(value, index + 1)

            if not second or second < 144 or second > 191
                or not isContinuation(stringByte(value, index + 2))
                or not isContinuation(stringByte(value, index + 3)) then
                return false
            end

            index = index + 4
        elseif first >= 241 and first <= 243 then
            if not isContinuation(stringByte(value, index + 1))
                or not isContinuation(stringByte(value, index + 2))
                or not isContinuation(stringByte(value, index + 3)) then
                return false
            end

            index = index + 4
        elseif first == 244 then
            local second = stringByte(value, index + 1)

            if not second or second < 128 or second > 143
                or not isContinuation(stringByte(value, index + 2))
                or not isContinuation(stringByte(value, index + 3)) then
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
    return byte == 32 or (byte >= 9 and byte <= 13)
end

function Internal.NormalizeProfileName(value, operation)
    if type(value) ~= "string" then
        error(("Usage: manager:%s(...) requires a string profile name"):format(operation), 3)
    end

    if not Internal.IsValidUTF8(value) then
        return nil, "INVALID_NAME"
    end

    local normalized = {}
    local hasContent = false
    local pendingSpace = false

    for index = 1, #value do
        local byte = stringByte(value, index)

        if isASCIIWhitespace(byte) then
            if hasContent then
                pendingSpace = true
            end
        elseif byte < 32 or byte == 127 then
            return nil, "INVALID_NAME"
        else
            if pendingSpace then
                normalized[#normalized + 1] = " "
                pendingSpace = false
            end

            normalized[#normalized + 1] = stringChar(byte)
            hasContent = true
        end
    end

    if not hasContent then
        return nil, "INVALID_NAME"
    end

    return tableConcat(normalized)
end

function Internal.ReportCallbackError(message)
    if type(getErrorHandler) ~= "function" then
        return
    end

    local ok, handler = pcall(getErrorHandler)

    if ok and type(handler) == "function" then
        pcall(handler, message)
    end
end

function Internal.CallSafely(callback, ...)
    local ok, message = pcall(callback, ...)

    if not ok then
        Internal.ReportCallbackError(message)
    end
end

function Internal.DispatchLifecycle(manager, event, ...)
    local callbacks = manager._lifecycleCallbacks[event]

    if not callbacks then
        return
    end

    local snapshot = {}

    for callback in pairs(callbacks) do
        snapshot[#snapshot + 1] = callback
    end

    for index = 1, #snapshot do
        Internal.CallSafely(snapshot[index], manager, event, ...)
    end
end

function Internal.ProfileIdentityEqual(left, right)
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
