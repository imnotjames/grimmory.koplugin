local Cache = require("cache")
local util = require("util")

local DocMetadata = require("grimmory/doc_metadata")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

local function getTitleIdentifier(title, author)
    if title == nil then
        return nil
    end

    if author == nil then
        author = "NA"
    end

    local title_identifier = title:lower():gsub("[^a-z0-9]+", "") .. "--" .. author:lower():gsub("[^a-z0-9]+", "")

    if string.len(title_identifier) < 5 then
        return nil
    end

    return title_identifier
end

---@class GrimmoryBookResolver
---@field private md5_to_book_id_cache any
---@field private identifiers_to_book_id table<string, number>
local GrimmoryBookResolver = {
    md5_to_book_id_cache = Cache:new({ slots = 4096 }),
    identifiers_to_book_id = {},
}

function GrimmoryBookResolver:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param books Book[]
function GrimmoryBookResolver:refreshBooks(books)
    ---@type table<string, number>
    self.identifiers_to_book_id = {}

    for _, book in ipairs(books) do
        local metadata = book.metadata

        if metadata then
            if metadata.asin then
                self.identifiers_to_book_id["asin:" .. metadata.asin:lower()] = book.id
            end

            if metadata.isbn13 then
                self.identifiers_to_book_id["isbn:" .. metadata.isbn13] = book.id
            elseif metadata.isbn10 then
                self.identifiers_to_book_id["isbn:" .. metadata.isbn10] = book.id
            end

            if metadata.title and metadata.authors then
                local author = metadata.authors[0] or metadata.authors[1]
                local titleIdentifier = getTitleIdentifier(metadata.title, author)

                if titleIdentifier then
                    self.identifiers_to_book_id["title-id:" .. titleIdentifier] = book.id
                end
            end
        end

        local filename = nil
        if book.primary_file and book.primary_file.filename then
            filename = book.primary_file.filename
            self.identifiers_to_book_id["filename:" .. filename] = book.id
        end
    end
end

function GrimmoryBookResolver:getBookId(book_path, book_md5)
    if book_md5 == nil then
        book_md5 = util.partialMD5(book_path)
    end

    local cache_value = self.md5_to_book_id_cache:get(book_md5:lower())
    if cache_value ~= nil then
        logger:dbg("ID Cache hit", book_md5, book_path)
        if cache_value < 0 then
            return nil
        end

        return cache_value
    end

    logger:dbg("ID Cache miss", book_md5, book_path)

    local book_id = DocMetadata:getGrimmoryId(book_path) or -1

    if book_id >= 0 then
        self.md5_to_book_id_cache:insert(book_md5:lower(), book_id)
        return book_id
    end

    local isbn = DocMetadata:getISBN(book_path)
    local asin = DocMetadata:getASIN(book_path)
    local title = DocMetadata:getTitle(book_path)
    local author = DocMetadata:getAuthor(book_path)

    -- Instead of this, we should use a Grimmory search functionality.
    -- This works well enough for today, though.
    local identifiers = self.identifiers_to_book_id

    local title_id = getTitleIdentifier(title, author)
    local _, filename = util.splitFilePathName(book_path)

    if identifiers ~= nil then
        if isbn and identifiers["isbn:" .. isbn] then
            book_id = identifiers["isbn:" .. isbn]
        elseif asin and identifiers["asin:" .. asin:lower()] then
            book_id = identifiers["asin:" .. asin:lower()]
        elseif title_id and identifiers["title-id:" .. title_id] then
            book_id = identifiers["title-id:" .. title_id]
        elseif filename and identifiers["filename:" .. filename] then
            book_id = identifiers["filename:" .. filename]
        end
    end

    self.md5_to_book_id_cache:insert(book_md5:lower(), book_id)

    if book_id < 0 then
        return nil
    else
        return book_id
    end
end

return GrimmoryBookResolver