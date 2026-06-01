local Cache = require("cache")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")
local logger = GrimmoryLogger:new()

---@class GrimmoryDocMetadata
---@field private props_cache any
local DocMetadata = {}

function DocMetadata:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function DocMetadata:init()
    self.props_cache = Cache:new({ slots = 1024 })
end

function DocMetadata:getDocSettings(path)
    local settings = DocSettings:open(path)

    return settings
end

function DocMetadata:getDocProps(path)
    local book_md5 = util.partialMD5(path)

    local cache_value = self.props_cache:get(book_md5)
    if cache_value ~= nil then
        logger:dbg("Props Cache Hit", path)
        return cache_value
    end

    local settings = self:getDocSettings(path)

    local props = settings:readSetting("doc_props")

    if props ~= nil then
        self.props_cache:insert(book_md5, props)
        return props
    end

    logger:dbg("Falling back to reading document directly")

    -- If still no book_props, open the document to get them
    local document = DocumentRegistry:hasProvider(path) and DocumentRegistry:openDocument(path)
    if document then
        local loaded = true
        if document.loadDocument then -- CreDocument
            -- load only metadata
            if not document:loadDocument(false) then
                -- failed loading, calling other methods would segfault
                loaded = false
            end
        end

        if loaded then
            props = document:getProps()
        end
        document:close()
    end

    if props ~= nil then
        self.props_cache:insert(book_md5, props)
        return props
    end

    logger:dbg("No props can be found")

    self.props_cache:insert(book_md5, {})
    return {}
end

function DocMetadata:getIdentifiers(path)
    local props = self:getDocProps(path)
    if type(props.identifiers) ~= "string" or props.identifiers == "" then
        return {}
    end

    local identifiers = {}

    for key, value in props.identifiers:gmatch("([^\n]+):([^\n:]+)") do
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
        {
            "isbn13",
            "urn:isbn13",
            "isbn10",
            "isbn",
            "urn:isbn",
        }
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

---@param path string
---@param book Book
function DocMetadata:isBook(path, book)
    local isbn = self:getISBN(path)
    local asin = self:getASIN(path)

    if isbn and isbn == book.metadata.isbn10 then
        return true
    end

    if isbn and isbn == book.metadata.isbn13 then
        return true
    end

    if asin and asin == book.metadata.asin then
        return true
    end

    return false
end

---@param path string
function DocMetadata:clearProgress(path)
    self:setProgress(path, nil, nil, nil)
end

---@param path string
---@param percent number | nil
---@param xpointer string | nil
---@param page number | nil
function DocMetadata:setProgress(path, percent, xpointer, page)
    local settings = self:getDocSettings(path)

    -- Hack to prevent us from getting a weird message from koreader
    -- There may be another way but this seems to be the simplest
    -- and we only set it if it's not already set.
    settings:readSetting(
        "cre_dom_version",
        settings:readSetting("cre_dom_version", 20200223)
    )

    if percent ~= nil then
        settings:saveSetting("percent_finished", percent / 100)
    else
        settings:delSetting("percent_finished")
    end

    if xpointer ~= nil then
        settings:saveSetting("last_xpointer", xpointer)
    else
        settings:delSetting("last_xpointer")
    end

    if page ~= nil then
        settings:saveSetting("last_page", page)
    else
        settings:delSetting("last_page")
    end

    settings:flush()
end

return DocMetadata