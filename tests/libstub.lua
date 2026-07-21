local LibStub = {
    libs = {},
    minors = {},
}

function LibStub:NewLibrary(major, minor)
    if type(major) ~= "string" or type(minor) ~= "number" then
        error("Usage: LibStub:NewLibrary(major, minor)", 2)
    end

    local oldMinor = self.minors[major]

    if oldMinor and oldMinor >= minor then
        return nil, oldMinor
    end

    local library = self.libs[major]

    if not library then
        library = {}
        self.libs[major] = library
    end

    self.minors[major] = minor
    return library, oldMinor
end

function LibStub:GetLibrary(major, silent)
    local library = self.libs[major]

    if not library and not silent then
        error(("Cannot find a library instance of %q"):format(major), 2)
    end

    return library, self.minors[major]
end

setmetatable(LibStub, {
    __call = function(self, major, silent)
        return self:GetLibrary(major, silent)
    end,
})

_G.LibStub = LibStub
return LibStub
