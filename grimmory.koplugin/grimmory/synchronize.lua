local ReadCollection = require("readcollection")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class GrimmorySynchronize
---@field repository GrimmoryLocalRepository
---@field reading_progress_manager ReadingProgressManager
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field doc_metadata GrimmoryDocMetadata
---@field cached_books Book[]
local GrimmorySynchronize = {
    synchronize_sessions_since = 0,
    cached_books = {},
}

function GrimmorySynchronize:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookProgress(book_id, callback)
    if not self.settings:getSyncReadingProgress() then
        logger:info("Reading progress skipped because feature is disabled for:", book_id)
        return
    end

    local progress_ok, progress = self.repository:getReadingProgress(book_id)

    if progress_ok and progress ~= nil then
        logger:info("Synchronizing reading progress for:", book_id)
        local ok = self.reading_progress_manager:pushRemoteProgress(progress)

        if ok then
            callback({
                state = "progress-pushed",
                book_path = progress.book_path,
                book_md5 = progress.book_md5,
            })

            self.repository:updateBookSyncTimestamp(book_id, "progress", progress.end_time)
        else
            callback({
                state = "progress-failed",
                book_path = progress.book_path,
                book_md5 = progress.book_md5,
            })
        end
    end
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookSessions(book_id, callback)
    if not self.settings:getSyncReadingSessions() then
        -- Since the reading session sync is disabled, skip them.
        logger:dbg("Reading sessions skipped because feature is disabled for:", book_id)
        return
    end

    local threshold_pages = self.settings:getSessionThresholdPages()
    local threshold_seconds = self.settings:getSessionThresholdSeconds()

    logger:info("Synchronizing reading sessions for:", book_id)

    local sessions = self.repository:getPendingSessions(book_id)

    for _, session in ipairs(sessions) do
        local total_seconds = session.end_time - session.start_time
        local total_pages = session.end_page - session.start_page + 1

        if total_seconds < threshold_seconds then
            logger:info("Skipped session below time threshold for book", book_id)
            callback({
                state = "session-skip",
                bookPath = session.book_path,
                since = session.end_time,
            })
        elseif total_pages < threshold_pages then
            logger:info("Skipped session below page threshold for book", book_id)
            callback({
                state = "session-skip",
                bookPath = session.book_path,
                since = session.end_time,
            })
        else
            logger:dbg(
                "Recording session",
                session.grimmory_id,
                session.book_path,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                session.start_xpointer,
                session.end_xpointer
            )

            local ok, body = self.api:recordSession(
                session.grimmory_id,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                session.start_xpointer,
                session.end_xpointer
            )

            if ok then
                logger:info("Session recorded successfully for book:", book_id)
                callback({
                    state = "session-recorded",
                    bookPath = session.book_path,
                    since = session.end_time,
                })

                self.repository:updateBookSyncTimestamp(book_id, "sessions", session.end_time)
            else
                logger:err("Session failed recording with error for book: ", book_id, " - ", body)
                callback({
                    state = "session-error",
                    bookPath = session.book_path,
                    since = session.end_time,
                })

                -- If an error happens for this session we bail early so
                -- retries can happen again later
                break
            end
        end
    end
end

---@param book_id integer
---@param callback function
function GrimmorySynchronize:pushBookMetadata(book_id, callback)
    self:pushBookProgress(book_id, callback)
    self:pushBookSessions(book_id, callback)
end

function GrimmorySynchronize:pushAllPendingBookMetadata(callback)
    local book_ids = self.repository:getBooksPendingSync(
        self.settings:getSyncReadingSessions(),
        self.settings:getSyncReadingProgress()
    )

    for _, book_id in ipairs(book_ids) do
        if book_id == nil then
            break
        end

        self:pushBookMetadata(book_id, callback)
    end
end

---@param book Book
---@return boolean
function GrimmorySynchronize:isTargetBook(book)
    if not book.primary_file or not book.primary_file.filename then
        return false
    end

    local target_shelves = self.settings:getSyncTargetShelves() or {}

    if #target_shelves == 0 then
        return true
    end

    if not book.shelves then
        return false
    end

    for _, shelf_id in ipairs(book.shelves) do
        if self:isTargetShelf(shelf_id) then
            return true
        end
    end

    return false
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

    -- Make sure we have our unique shelf names and ID mappings
    for _, shelf in ipairs(shelves) do
        if shelf.id and shelf.name and self:isTargetShelf(shelf.id) then
            local shelf_name = shelf.name

            logger:dbg("Shelf received from Grimmory", shelf.id, shelf_name)

            -- If there's a shelf with a duplicate name, we can't support
            -- that in koreader.  Instead, add something to the shelf name
            -- until it's unique.
            local unique_shelf_name = shelf_name
            local unique_shelf_index = 0
            while shelf_name_to_id[unique_shelf_name:lower()] do
                unique_shelf_index = unique_shelf_index + 1
                unique_shelf_name = shelf_name .. " (" .. unique_shelf_index .. ")"
            end

            if unique_shelf_name ~= shelf_name then
                logger:dbg("Duplicate shelf name found", shelf_name, "- used new name", unique_shelf_name)
            end

            shelf_name_to_id[unique_shelf_name:lower()] = shelf.id

            -- use tostring to get a sparse table
            shelf_id_to_name[tostring(shelf.id)] = unique_shelf_name
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
                if shelf_name:lower() ~= collection_name:lower() then
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

            logger:info(
                "Found an existing collection that can be attached to a shelf:",
                collection_name, ";" , shelf_id
            )

            ReadCollection.coll_settings[collection_name].connectorId = shelf_id

            callback({
                state = "shelf-connect",
                shelf_id = shelf_id,
                shelf_name = collection_name,
            })
        end
    end

    -- Make sure every shelf has a collection and create them if not
    for shelf_id, shelf_name in pairs(shelf_id_to_name) do
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

function GrimmorySynchronize:pullBookProgress(book_path)
    if not self.settings:getSyncReadingProgress() then
        return
    end

    local _, _, progress = self.reading_progress_manager:getRemoteProgressForBook(book_path)

    if progress then
        self.reading_progress_manager:applyProgress(progress)
    end
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

    local progress_ok, progress_result = pcall(self.pullBookProgress, self, download_path)

    if not progress_ok then
        logger:warn("Could not pull progress for book:", book_id, "-", progress_result)
    end

    return true, nil
end

---@param book Book
---@return string | nil download_path
function GrimmorySynchronize:getBookDownloadPath(book)
    local existing_book_ok, existing_book_path = self.repository:getBookInfo(book.id)
    if existing_book_ok and existing_book_path then
        return existing_book_path
    end

    local download_directory = self.settings:getSyncDownloadDirectory()

    if not download_directory or download_directory == "" then
        error("Download directory is invalid")
    end

    local download_path = download_directory .. "/" .. util.getSafeFilename(book.primary_file.filename)

    -- If this path doesn't exist yet, we're good, bail early
    if not util.fileExists(download_path) then
        return download_path
    end

    -- If the path exists we have to check to make sure that it is actually the book we care about
    if self.doc_metadata:isBook(download_path, book) then
        -- We have a match, this path is safe.
        return download_path
    end

    -- At this point we need a fallback name.  `downloaded-${BOOK_ID}.${EXT}` is not
    -- great but I don't know a better safe way off hand.

    local file_extension = util.getFileNameSuffix(book.primary_file.filename)

    if file_extension == "" or file_extension == nil then
        file_extension = "bin"
    end

    download_path = download_directory .. "/downloaded-" .. tonumber(book.id) .. "." .. file_extension

    -- If this path doesn't exist yet, we're good?
    if not util.fileExists(download_path) then
        return download_path
    end

    -- Okay, this file exists.  It's GOT to be our file, though, right?
    if self.doc_metadata:isBook(download_path, book) then
        -- We have a match, this path is safe.
        return download_path
    end

    -- Give up.
    logger:warn("Could not verify book, but proceeding anyway with path:", book.id, "at", download_path)
    return download_path
end

function GrimmorySynchronize:associateWithShelves(book_path, shelves)
    local local_shelves = {}
    local shelf_id_to_name = {}
    for collection_name, _ in pairs(ReadCollection.coll) do
        local shelf_id = ReadCollection.coll_settings[collection_name].connectorId

        if shelf_id then
            shelf_id_to_name[tostring(shelf_id)] = collection_name
        end

        if ReadCollection.coll[collection_name][book_path] ~= nil then
            local_shelves[collection_name] = true
        end
    end

    local remote_shelves = {}
    for _, shelf_id in ipairs(shelves) do
        local collection_name = shelf_id_to_name[tostring(shelf_id)]
        remote_shelves[collection_name] = true

        if collection_name and not local_shelves[collection_name] then
            logger:dbg("Adding book to collection:", book_path, collection_name)
            ReadCollection:addItem(book_path, collection_name)
        end
    end

    -- Remove any current collections that are not current shelves.
    for collection_name, _ in pairs(local_shelves) do
        if not remote_shelves[collection_name] then
            logger:dbg("Removing book from collection:", book_path, collection_name)
            ReadCollection:removeItem(book_path, collection_name)
        end
    end
end


---@param book Book
---@param callback function
function GrimmorySynchronize:pullBook(book, callback)
    local book_exists = false

    if book.primary_file == nil then
        logger:dbg("Skipping book without file:", book.id)
        callback({
            state = "book-skipped",
            book_id = book.id,
            download_path = nil,
        })
        return
    end

    local download_path = self:getBookDownloadPath(book)

    -- TODO: Search through known books from collections for this book
    --       If found, set the `download path to that value.

    if download_path ~= nil and util.fileExists(download_path) then
        book_exists = true
    end

    if not book_exists then
        if download_path ~= nil then
            logger:dbg("Downloading book", book.id, "to", download_path)

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

    if book_exists and download_path then
        -- After we're done, if the book exists we should attach it
        -- to associated shelves.
        self:associateWithShelves(download_path, book.shelves)
        self.repository:upsertBook(download_path, book.id)
    end
end

function GrimmorySynchronize:pullBooks(callback)
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
        error("Failed to create download directory", directory_error_message)
        return
    end

    local page = 0

    while true do
        logger:dbg("Fetching books to pull, page:", page)

        local books_ok, books_batch = self.api:getBooksPage(page)

        if books_ok and type(books_batch) == "table" then
            if #books_batch == 0 then
                break
            end

            for _, book in ipairs(books_batch) do
                if self:isTargetBook(book) then
                    self:pullBook(book, callback)
                end
            end
        else
            logger:err("Something went wrong pulling books, stopping book sync")
            break
        end

        page = page + 1
    end

    -- During pulling books we may have updated the collections that
    -- books are in which need to be persisted to disk
    ReadCollection:write()
end

---@return boolean ok
function GrimmorySynchronize:checkForHealthyServer()
    local ok, version = self.api:getServerVersion()

    if not ok then
        logger:err("Failed to contact server, cannot sync:", version)
        return false
    end

    return true
end

function GrimmorySynchronize:synchronizeAll(callback)
    if not self:checkForHealthyServer() then
        return error("Cannot connect to valid server")
    end

    -- First, tell Grimmory about all of our reading
    logger:info("Pushing pending book metadata")
    self:pushAllPendingBookMetadata(callback)

    -- Then pull the shelves
    logger:info("Synchronizing shelves")
    self:synchronizeShelves(callback)

    -- And only afterwards, pull new books because our
    -- reading progress may change the books we sync down
    logger:info("Pulling books")
    self:pullBooks(callback)

    logger:info("Done synchronizing")
end

return GrimmorySynchronize