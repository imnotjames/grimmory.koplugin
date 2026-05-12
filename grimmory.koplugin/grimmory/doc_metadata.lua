local DocSettings = require("docsettings")

local DocMetadata = {}
DocMetadata.__index = DocMetadata

function DocMetadata:new(o)
  return setmetatable(o, self)
end

function DocMetadata:getDocSettings(path)
    local settings = DocSettings:open(path)
    if not settings then
        return nil
    end

    return settings
end

function DocMetadata:getDocProps(path)
    local settings = self:getDocSettings(path)

    if settings == nil then
        return {}
    end

    local props = settings:readSetting("doc_props")

    if props == nil then
        return {}
    end

    return props
end

function DocMetadata:getIdentifiers(path)
    local props = self:getDocProps(path)
    local identifiersProp = props.identifiers or ""

    local identifiers = {}

    for key, value in identifiersProp:gmatch("([^\n]+):([^\n:]+)") do
        identifiers[key:lower()] = value
    end

    return identifiers
end

function DocMetadata:getIdentifier(path, typeOrTypes)
    local identifiers = self:getIdentifiers(path)

    if type(typeOrTypes) ~= "table" then
        typeOrTypes = { typeOrTypes }
    end

    for _, key in ipairs(typeOrTypes) do
        if identifiers[key] then
            return identifiers[key]
        end
    end

    return nil
end

function DocMetadata:getISBN(path)
    return self:getIdentifier(
        path,
        { "isbn13", "isbn10", "isbn" }
    )
end

function DocMetadata:getASIN(path)
    return self:getIdentifier(
        path,
        { "amazon", "urn:amazon", "mobi-asin" }
    )
end

function DocMetadata:getTitle(path)
    return self:getDocProps(path).title
end

function DocMetadata:getAuthor(path)
    return self:getDocProps(path).authors
end

return DocMetadata