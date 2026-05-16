local Cache = require("cache")
local ReadCollection = require("readcollection")
local random = require("random")
local md5 = require("ffi/sha2").md5
local util = require("util")

local DocMetadata = require("grimmory/doc_metadata")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class GrimmorySynchronize
---@field reading_sessions ReadingSessionRepository
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field identifiers_to_book_id table<string, number>
---@field cached_books Book[]
local GrimmorySynchronize = {
    synchronize_sessions_since = 0,
    md5_to_book_id_cache = Cache:new({ slots = 4096 }),
    identifiers_to_book_id = {},
    cached_books = {},
}

function GrimmorySynchronize:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function GrimmorySynchronize:getTitleIdentifier(title, author)
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

function GrimmorySynchronize:refreshBooksFromAPI()
    ---@type table<string, number>
    self.identifiers_to_book_id = {}

    ---@type Book[]
    self.cached_books = {}

    local ok, books = self.api:getBooks()

    if not ok or type(books) == "string" then
        logger:err("Something went wrong fetching books", books)
        return {}
    end

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
                local titleIdentifier = self:getTitleIdentifier(metadata.title, author)

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

        if filename then
            local shelves = {}

            if book.shelves then
                for _, shelf_id in ipairs(book.shelves) do
                    table.insert(shelves, shelf_id)
                end
            end

            local is_matching_shelf = false
            for _, shelf_id in ipairs(shelves) do
                if self:isTargetShelf(shelf_id) then
                    is_matching_shelf = true
                    break
                end
            end

            if is_matching_shelf then
                table.insert(self.cached_books, book)
            end
        end
    end
end

function GrimmorySynchronize:getBookId(book_path, book_md5)
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

    local title_id = self:getTitleIdentifier(title, author)
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

function GrimmorySynchronize:synchronizeSessions(callback)
    if not self.settings:getSyncReadingSessions() then
        logger:info("Reading sessions sync skipped because feature is disabled")
    end

    local since = self.settings:getSynchronizedUntil()
    logger:info("Synchronizing sessions since", since)

    local sessions = self.reading_sessions:getSessions(since)

    local threshold_pages = self.settings:getSessionThresholdPages()
    local threshold_seconds = self.settings:getSessionThresholdSeconds()

    for _, session in ipairs(sessions) do
        local total_seconds = session.end_time - session.start_time
        local total_pages = session.end_page - session.start_page + 1

        if total_seconds < threshold_seconds and total_pages < threshold_pages then
            logger:info("Session skipped for book", session.book_path)
            callback({
                state = "session-skip",
                bookPath = session.book_path,
                since = session.start_time,
            })
        else
            logger:dbg(
                "Recording session",
                session.book_path,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                session.start_xpointer,
                session.end_xpointer
            )

            local book_id = self:getBookId(session.book_path, session.book_md5)

            local ok = false
            local body = nil
            if book_id == nil then
                body = "Could not match local book to Grimmory"
            else
                ok, body = self.api:recordSession(
                    book_id,
                    session.start_time,
                    session.end_time,
                    session.start_progress,
                    session.end_progress,
                    session.start_xpointer,
                    session.end_xpointer
                )
            end

            if ok then
                logger:info("Session recorded successfully for book", session.book_path)
                callback({
                    state = "session-recorded",
                    bookPath = session.book_path,
                    since = session.start_time,
                })
            else
                logger:err("Session failed recording with error for book: ", session.book_path, " - ", body)
                callback({
                    state = "session-error",
                    bookPath = session.book_path,
                    since = session.start_time,
                })
            end
        end
    end
end

function GrimmorySynchronize:isTargetShelf(shelf_id)
    local target_shelves = self.settings:getSyncTargetShelves() or {}

    if #target_shelves == 0 then
        return true
    end

    for _, shelf in ipairs(target_shelves) do
        if shelf.id == shelf_id then
            return true
        end
    end

    return false
end

function GrimmorySynchronize:synchronizeShelves(callback)
    if not self.settings:getSyncShelves() then
        logger:info("Shelf sync skipped because feature is disabled")
        return
    end

    local ok, shelves = self.api:getShelves()

    if not ok or type(shelves) == "string" then
        logger:err("Could not connect to Grimmory to get shelves", shelves)
        return
    end

    local shelf_id_to_name = {}
    local shelf_name_to_id = {}

    for _, shelf in ipairs(shelves) do
        if shelf.id and shelf.name and self:isTargetShelf(shelf.id) then
            local shelf_name = shelf.name:lower()

            logger:dbg("Shelf received from Grimmory", shelf.id, shelf_name)

            -- If there's a shelf with a duplicate name, we can't support
            -- that in koreader.  Instead, add something to the shelf name
            -- until it's unique.
            local unique_shelf_name = shelf_name
            local unique_shelf_index = 0
            while shelf_name_to_id[unique_shelf_name] do
                unique_shelf_index = unique_shelf_index + 1
                unique_shelf_name = shelf_name .. " (" .. unique_shelf_index .. ")"
            end

            if unique_shelf_name ~= shelf_name then
                logger:dbg("Duplicate shelf name found", shelf_name, "- used new name", unique_shelf_name)
            end

            shelf_name_to_id[unique_shelf_name] = shelf.id

            -- use tostring to get a sparse table
            shelf_id_to_name[tostring(shelf.id)] = shelf_name
        end
    end

    -- Read through existing collections and compare against shelves
    for collection_name, _ in pairs(ReadCollection.coll) do
        local shelf_id = ReadCollection.coll_settings[collection_name].connectorId

        if shelf_id then
            if shelf_id_to_name[tostring(shelf_id)] then
                local shelf_name = shelf_id_to_name[tostring(shelf_id)]

                -- This collection exists as a shelf so we should update it
                -- if there's anything that needs to change.
                if shelf_name ~= collection_name:lower() then
                    -- This collection has been renamed!
                    logger:info("Renaming collection to match shelf name:", collection_name, ";", shelf_name)

                    ReadCollection:renameCollection(collection_name, shelf_name)

                    callback({
                        state = "shelf-rename",
                        shelf_id = shelf_id,
                        shelf_name = shelf_name,
                    })
                end
            else
                logger:info("Disconnecting collection from shelf:", collection_name)
                -- This was a shelf but the shelf is gone in the connector
                -- Don't delete the shelf but break the connection.
                ReadCollection.coll_settings[collection_name].connectorId = nil

                -- Set the shelf ID to nil so the block below will pick
                -- it up if it's a shelf being deleted and recreated
                shelf_id = nil

                callback({
                    state = "shelf-disconnect",
                    shelf_id = shelf_id,
                    shelf_name = collection_name,
                })
            end
        end

        if shelf_id == nil and shelf_name_to_id[collection_name:lower()] then
            -- If there is no shelf attached to this collection but we
            -- know one exists we should attach it.
            shelf_id = shelf_name_to_id[collection_name:lower()]

            logger:info("Found an existing collection that can be attached to a shelf:", collection_name, ";" , shelf_id)

            ReadCollection.coll_settings[collection_name].connectorId = shelf_id

            callback({
                state = "shelf-connect",
                shelf_id = shelf_id,
                shelf_name = collection_name,
            })
        end
    end

    -- Make sure every shelf has a collection and create them if not
    for shelf_name, shelf_id in pairs(shelf_name_to_id) do
        if not ReadCollection.coll_settings[shelf_name] then
            logger:info("Adding a collection from a shelf", shelf_name, shelf_id)

            ReadCollection:addCollection(shelf_name)
            ReadCollection.coll_settings[shelf_name].connectorId = shelf_id

            callback({
                state = "shelf-add",
                shelf_id = shelf_id,
                shelf_name = shelf_name,
            })
        end
    end

    -- Persist collections to the database now that we've finished our sync
    ReadCollection:write()
end

function GrimmorySynchronize:downloadBook(book_id, download_path)
    local success, result, message = pcall(function()
        return self.api:downloadBook(book_id, download_path)
    end)

    if not success then
        logger:err("Book download failed:", book_id, " - ", result)
        return false, result
    end

    if not result then
        return false, message
    end

    return true, nil
end

function GrimmorySynchronize:getBookDownloadPath(book)
    local download_directory = self.settings:getSyncDownloadDirectory()

    if not download_directory or download_directory == "" then
        return nil
    end

    local download_path = download_directory .. "/" .. util.getSafeFilename(book.primary_file.filename)

    -- If this path doesn't exist yet, we're good, bail early
    if not util.fileExists(download_path) then
        return download_path
    end

    -- If the path exists we have to check to make sure that it is actually the book we care about
    if self:getBookId(download_path) == book.id then
        -- We have a match, this path is safe.
        return download_path
    end

    -- At this point we need a fallback name.  `download-${BOOK_ID}.${EXT}` is not
    -- great but I don't know a better safe way off hand.

    local file_extension = util.getFileNameSuffix(book.filename)

    if file_extension == "" or file_extension == nil then
        file_extension = "bin"
    end

     download_path = download_directory .. "/downloaded-" .. tonumber(book.id) .. "." .. file_extension

    -- If this path doesn't exist yet, we're good?
    if not util.fileExists(download_path) then
        return download_path
    end

    -- Okay, this file exists.  It's GOT to be our file, though, right?
    if self:getBookId(download_path) == book.id then
        -- We have a match, this path is safe.
        return download_path
    end

    -- Give up.
    logger:err("Could not determine a valid download path for book:", book.id)
    return nil
end

function GrimmorySynchronize:associateWithShelves(book_path, shelves)
    local shelf_id_to_name = {}
    for collection_name, _ in pairs(ReadCollection.coll) do
        local shelf_id = ReadCollection.coll_settings[collection_name].connectorId

        if shelf_id then
            shelf_id_to_name[tostring(shelf_id)] = collection_name
        end
    end

    for _, shelf_id in ipairs(shelves) do
        local collection_name = shelf_id_to_name[tostring(shelf_id)]

        if collection_name then
            ReadCollection:addItem(book_path, collection_name)
        end
    end
end

function GrimmorySynchronize:synchronizeBooks(callback)
    if not self.settings:getSyncShelves() then
        logger:info("Book download skipped because feature is disabled")
        return
    end

    local download_directory = self.settings:getSyncDownloadDirectory()
    if not download_directory or download_directory == "" then
        logger:err("Book download skipped because download directory is not set")
        return
    end

    -- Ensure that the download directory exists
    local directory_exists, directory_error_message = util.makePath(download_directory)
    if not directory_exists then
        logger:err("Failed to create download directory", directory_error_message)
        return
    end

    -- Eventually we should support a "since" but for right
    -- now it's easiest to sync everything.
    local books = self.cached_books or {}

    -- TODO: Read known books from shelves in case we move the download directory

    for _, book in ipairs(books) do
        local book_exists = false

        local download_path = self:getBookDownloadPath(book)

        -- TODO: Search through known books from shelves for this book
        --       If found, set the `download path to that value.

        if download_path ~= nil and util.fileExists(download_path) then
            book_exists = true
        end

        if not book_exists then
            if not download_path ~= nil then
                logger:info("Downloading book", book.id, "to", download_path)

                local ok, message = self:downloadBook(book.id, download_path)
                if ok then
                    logger:info("Book downloaded:", book.id, " - ", download_path)
                    callback({
                        state = "book-downloaded",
                        book_id = book.id,
                        download_path = download_path,
                    })
                    book_exists = true
                else
                    logger:err("Book failed download:", book.id, "-", message)
                    callback({
                        state = "book-error",
                        book_id = book.id,
                        download_path = download_path,
                    })
                end
            else
                logger:err("Book skipped as download path could not be found")
                callback({
                    state = "book-skipped",
                    book_id = book.id,
                    download_path = download_path,
                })
            end
        end

        if book_exists then
            -- After we're done, if the book exists we should attach it
            -- to associated shelves.
            self:associateWithShelves(download_path, book.shelves)
            DocMetadata:setGrimmoryId(download_path, book.id)
        end
    end
end

function GrimmorySynchronize:synchronizeProgress(callback)
    local device_name = self.settings:getDeviceName()
    local device_id = self.settings:getDeviceId()

    local sync_ok, sync_enabled = self.api:getKoreaderSync()

    if not sync_ok then
        logger:err("Could not read sync status")
        return
    end

    if not sync_enabled then
        -- If sync isn't enabled, let's try to enable it.
        local ok = self.api:setKoreaderSync(true)

        if not ok then
            logger:err("Failed to set koreader sync status")
            return
        end
    end

    -- Get recent progress records
    local credentials_ok, koreader_auth_id, koreader_auth_secret = self.api:getKoreaderCredentials()

    if not credentials_ok then
        logger:err("Failed to get koreader sync credentials")
        return
    end

    if not koreader_auth_id or not koreader_auth_secret then
        logger:err("Koreader username or auth key are not set")

        koreader_auth_id = koreader_auth_id or random.uuid()
        koreader_auth_secret = koreader_auth_secret or random.uuid()

        local set_credentials_ok = self.api:setKoreaderCredentials(koreader_auth_id, koreader_auth_secret)

        if not set_credentials_ok then
            logger:err("Failed to set koreader credentials")
            return
        end
    end

    local koreader_auth_md5 = md5(koreader_auth_secret)

    local reading_progress_records = self.reading_sessions:getReadingProgress()

    -- From Koreader to grimmory
    for _, progress in ipairs(reading_progress_records) do
        self.api:pushReadingProgress(
            koreader_auth_id,
            koreader_auth_md5,
            device_name,
            device_id,
            progress.book_md5,
            progress.end_time,
            progress.end_progress,
            progress.end_xpointer
        )
    end
end

function GrimmorySynchronize:synchronizeAll(callback)
    -- Refresh so we pull fresh books
    self:refreshBooksFromAPI()

    self:synchronizeProgress(callback)

    self:synchronizeShelves(callback)

    self:synchronizeSessions(callback)

    self:synchronizeBooks(callback)

    logger:info("Highlights not implemented yet")

    logger:info("Personal ratings not implemented yet")

    logger:info("Done synchronizing")
end

return GrimmorySynchronize