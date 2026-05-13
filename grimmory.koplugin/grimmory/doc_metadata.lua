local DocSettings = require("docsettings")

local DocMetadata = {}

function DocMetadata:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function DocMetadata:getDocSettings(path)
    local settings = DocSettings:open(path)

    return settings
end

function DocMetadata:getDocProps(path)
    local settings = self:getDocSettings(path)

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

function DocMetadata:setIdentifier(path, type, identifier)
    local identifiers = self:getIdentifiers(path)

    if tostring(identifiers[type]) == tostring(identifier) then
        -- Do nothing, no change needed
        return
    end

    identifiers[type] = identifier

    local serialized = ""
    for key, value in pairs(identifiers) do
        if #serialized > 0 then
            serialized = serialized .. "\n"
        end

        serialized = serialized .. key .. ":" .. value
    end

    local settings = self:getDocSettings(path)

    local props = settings:readSetting("doc_props") or {}

    props.identifiers = serialized

    settings:saveSetting("doc_props", props)
    settings:flush()
end

function DocMetadata:getGrimmoryId(path)
    local value = self:getIdentifier(
        path,
        { "grimmory" }
    )

    if value == nil then
        return nil
    end

    return tonumber(value)
end

function DocMetadata:setGrimmoryId(path, grimmory_id)
    self:setIdentifier(path, "grimmory", grimmory_id)
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