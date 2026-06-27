local ReadCollection = require("readcollection")
local md5 = require("ffi/MD5")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class GrimmorySynchronize
---@field repository GrimmoryLocalRepository
---@field reading_annotations GrimmoryReadingAnnotations
---@field reading_progress_manager ReadingProgressManager
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field doc_metadata GrimmoryDocMetadata
local GrimmorySynchronize = {}

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

    if not progress_ok or progress == nil then
        logger:dbg("No local reading progress for book:", book_id)
        return
    end

    local sync_status_ok, last_synced_at = self.repository:getBookSyncTimestamp(book_id, "progress")

    if not sync_status_ok then
        logger:err("Unable to get sync status for book, not blindly syncing:", book_id)
        return
    end

    if last_synced_at ~= nil and last_synced_at >= progress.end_time then
        logger:dbg("Book progress already synced, skipping:", book_id, "-", last_synced_at)
        return
    end

    logger:info("Synchronizing reading progress for:", book_id, ";", last_synced_at, "->", progress.end_time)
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

        elseif session.grimmory_id == nil then
            logger:err("Session failed recording with error for book: ", book_id, " - ", "No Grimmory ID")
            callback({
                state = "session-error",
                bookPath = session.book_path,
            })

            -- If an error happens for this session we bail early so
            -- retries can happen again later
            break
        else
            logger:dbg(
                "Recording session",
                session.grimmory_id,
                session.book_path,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                session.start_page,
                session.end_page
            )

            local ok, body = self.api:recordSession(
                session.grimmory_id,
                session.start_time,
                session.end_time,
                session.start_progress,
                session.end_progress,
                tostring(session.start_page),
                tostring(session.end_page)
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

---@param book_path string
---@param book_grimmory_id integer
function GrimmorySynchronize:pushBookAnnotations(book_path, book_grimmory_id)
    local local_annotations = self.reading_annotations:getAnnotations(book_path)

    local modified_grimmory_annotations = self.doc_metadata:getModifiedGrimmoryAnnotations(book_path)

    local is_modified_by_id = {}
    for _, modified_id in ipairs(modified_grimmory_annotations) do
        is_modified_by_id[tostring(modified_id)] = true

        logger:dbg("Deleting annotation frim Grimmory:", book_path, "-", modified_id)
        self.api:deleteAnnotation(modified_id)

        -- Even if the delete fails - which it does today with a 5xx instead of 404 - we
        -- should continue to remove the annotation and assume it's just gone.
        --
        -- Once this bug (grimmory-tools/grimmory#1858) is fixed we can add the check
        -- back in for the `ok` of `deleteAnnotation` calls.
        self.doc_metadata:removeModifiedGrimmoryAnnotation(book_path, modified_id)
    end

    for _, annotation in ipairs(local_annotations) do
        if annotation.id ~= nil and is_modified_by_id[tostring(annotation.id)] then
            annotation.id = nil
        end

        if annotation.id == nil then
            -- This is a "new" annotation.
            local create_ok, remote_annotation = self.api:createAnnotation(
                book_grimmory_id,
                annotation.cfi,
                annotation.chapter,
                annotation.text,
                annotation.color,
                annotation.style,
                annotation.note
            )

            if create_ok then
                logger:dbg("Created annotation for book:", book_path)
            else
                logger:err("Failed to push annotation", remote_annotation)
            end
        end
    end
end

---@param book_path string
---@param book_grimmory_id integer
function GrimmorySynchronize:pullBookAnnotations(book_path, book_grimmory_id)
    local annotations_ok, annotations = self.api:getAnnotations(book_grimmory_id)

    if not annotations_ok or annotations == nil then
        logger:err("Failed pulling annotations from Grimmory:", book_grimmory_id)
        return
    end

    logger:dbg("Writing annotations to:", book_path)

    self.reading_annotations:applyAnnotations(
        book_path,
        annotations
    )
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

    for index, book_id in ipairs(book_ids) do
        if book_id == nil then
            break
        end

        pcall(self.pushBookMetadata, self, book_id, callback)

        callback({
            state = "push-book-metadata",
            book_id = book_id,
            pushed_books = index,
            total_books = #book_ids,
        })

    end
end

---@param book Book
---@return boolean
function GrimmorySynchronize:isTargetBook(book)
    if not book.primary_file or not book.primary_file.filename then
        return false
    end

    local target_shelves = self.settings:getDownloadTargetShelves() or {}

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
    local target_shelves = self.settings:getDownloadTargetShelves() or {}

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
        if shelf.id and shelf.name then
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

function GrimmorySynchronize:removeEmptyShelves(callback)
    if self.settings:getSyncRetainEmptyShelves() then
        logger:info("Shelf clean up sync skipped because feature is disabled")
        return
    end

    -- Read through existing collections and compare against shelves
    for collection_name, _ in pairs(ReadCollection.coll) do
        local shelf_id = ReadCollection.coll_settings[collection_name].connectorId
        local books = ReadCollection:getOrderedCollection(collection_name)

        if shelf_id and #books == 0 then
            -- This is a grimmory shelf and is empty
            logger:info("Removing empty shelf:", collection_name)

            callback({
                state = "shelf-remove",
                shelf_id = shelf_id,
                shelf_name = collection_name,
            })

            ReadCollection:removeCollection(collection_name)
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

    return true, nil
end

---@param book Book
---@return string download_path
function GrimmorySynchronize:getBookDownloadPath(book)
    local existing_book_ok, existing_books = self.repository:findBooksByGrimmoryId(book.id)
    if existing_book_ok then
        for _, local_book in ipairs(existing_books) do
            if (
                util.fileExists(local_book.book_path) and
                util.partialMD5(local_book.book_path) == local_book.book_md5
            ) then
                return local_book.book_path
            end
        end
    end

    local download_directory = self.settings:getDownloadDirectory()

    if not download_directory or download_directory == "" then
        error("Download directory is invalid")
    end

    if book.primary_file then
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
    end

    -- At this point we need a fallback name.  `downloaded-${BOOK_ID}.${EXT}` is not
    -- great but I don't know a better safe way off hand.

    local file_extension = nil

    if book.primary_file ~= nil then
        file_extension = util.getFileNameSuffix(book.primary_file.filename)
    end

    if file_extension == "" or file_extension == nil then
        file_extension = "bin"
    end

    local download_path = download_directory .. "/downloaded-" .. tonumber(book.id) .. "." .. file_extension

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

---@param book_path string
---@param shelves integer[]
function GrimmorySynchronize:associateWithShelves(book_path, shelves)
    local local_shelves = {}
    local shelf_id_to_name = {}
    for collection_name, _ in pairs(ReadCollection.coll) do
        local shelf_id = ReadCollection.coll_settings[collection_name].connectorId

        if shelf_id then
            shelf_id_to_name[tostring(shelf_id)] = collection_name

            if ReadCollection.coll[collection_name][book_path] ~= nil then
                local_shelves[collection_name] = true
            end
        end
    end

    local remote_shelves = {}
    for _, shelf_id in ipairs(shelves) do
        local collection_name = shelf_id_to_name[tostring(shelf_id)]

        if collection_name then
            remote_shelves[collection_name] = true

            if not local_shelves[collection_name] then
                logger:dbg("Adding book to collection:", book_path, collection_name)
                ReadCollection:addItem(book_path, collection_name)
            end
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

---@param book_path string
---@return integer | nil grimmory_id
function GrimmorySynchronize:associateBook(book_path)
    for book in self.api:getBooks() do
        if self.doc_metadata:isBook(book_path, book) then
            local ok = self.repository:upsertBook(book_path, book.id)

            if not ok then
                logger:err("Failed to write book association:", book_path)
                return nil
            end

            return book.id
        end
    end

    return nil
end

---@param book_path string
---@param grimmory_id number
function GrimmorySynchronize:refreshBook(book_path, book_id, grimmory_id)
    local temp_path = book_path .. ".tmp"

    -- Download book to temp path
    local download_ok, download_message = self:downloadBook(grimmory_id, temp_path)
    if not download_ok then
        util.removeFile(temp_path)
        return false, download_message
    end

    local temp_md5 = md5.sumFile(temp_path)
    local book_md5 = md5.sumFile(book_path)

    if temp_md5 == book_md5 then
        -- Things were completely the same so we can delete the temp file
        logger:info("File is identical with Grimmory:", book_path, "-", temp_md5)
        util.removeFile(temp_path)
        return true, book_id
    end

    local temp_partial_md5 = util.partialMD5(temp_path)
    local book_partial_md5 = util.partialMD5(book_path)


    local backup_path = book_path .. ".bak"

    if util.fileExists(backup_path) then
        logger:dbg("Cleaning up existing backup file")
        util.removeFile(backup_path)
    end

    local finalize_ok, finalize_message = pcall(function()
        local backup_ok, backup_message = os.rename(book_path, backup_path)

        if not backup_ok then
            error(backup_message)
        end

        local move_ok, move_message = os.rename(temp_path, book_path)

        if not move_ok then
            error(move_message)
        end

        if temp_partial_md5 == book_partial_md5 then
            logger:dbg("Partial md5 is a match, no database changes needed")
        else
            logger:info("Partial MD5 is a mismatch so we need to rewrite database")
            -- Update session data from old_book_id to new_book_id
            local update_book_ok, update_book_message = self.repository:updateBook(book_id, temp_partial_md5)

            if not update_book_ok then
                error(update_book_message)
            end
        end
    end)

    if not finalize_ok then
        if util.fileExists(backup_path) then
            logger:dbg("Rolling back: Renaming", backup_path, "to", book_path)
            os.rename(backup_path, book_path)
        end

        util.removeFile(backup_path)
        util.removeFile(temp_path)

        logger:err("Failed to replace files:", book_path, finalize_message)
        return false, finalize_message
    end

    logger:dbg("Cleaning up files from rename")
    util.removeFile(backup_path)
    util.removeFile(temp_path)

    return true, book_id
end

---@param book Book
---@return string download_path
---@return boolean is_downloaded
function GrimmorySynchronize:pullBook(book)
    local book_exists = false
    local is_downloaded = false

    local download_path = self:getBookDownloadPath(book)

    -- TODO: Search through known books from collections for this book
    --       If found, set the `download path to that value.

    if download_path ~= nil and util.fileExists(download_path) then
        book_exists = true
    end

    if not book_exists then
        if download_path ~= nil then
            is_downloaded = true

            logger:dbg("Downloading book", book.id, "to", download_path)

            local ok, message = self:downloadBook(book.id, download_path)
            if ok then
                logger:info("Book downloaded:", book.id, " - ", download_path)
                book_exists = true
            else
                error(message)
            end
        else
            error("Download path could not be found")
        end
    end

    if book_exists and download_path then
        self.repository:upsertBook(download_path, book.id)

        -- After we're done, if the book exists we should attach it
        -- to associated shelves and pull the book progress.
        self:associateWithShelves(download_path, book.shelves or {})
        self:pullBookProgress(download_path)
    end

    return download_path, is_downloaded
end

---@param book_path string
function GrimmorySynchronize:removeBook(book_path)
    logger:info("Removing book at:", book_path)

    -- Remove book file
    local ok = util.removeFile(book_path)

    if not ok then
        logger:err("Failed to remove file at:", book_path)
        return
    end

    -- Remove from all collections (skip writes)
    ReadCollection:removeItem(book_path, nil, true)

    -- Remove sidecar
    self.doc_metadata:purge(book_path)
end

function GrimmorySynchronize:pullBooks(callback)
    if not self.settings:getDownloadsBooks() then
        logger:info("Book download skipped because feature is disabled")
        return
    end

    local download_directory = self.settings:getDownloadDirectory()
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

    local seen_books = {}
    local seen_grimmory_ids = {}

    for book, element_count, total_books in self.api:getBooks() do
        if self:isTargetBook(book) then
            seen_grimmory_ids[tostring(book.id)] = true

            local pull_ok, pull_path_or_message, is_downloaded = pcall(self.pullBook, self, book, callback)
            if pull_ok then
                seen_books[pull_path_or_message] = true

                if is_downloaded then
                    callback({
                        state = "book-downloaded",
                        book_id = book.id,
                        book_path = pull_path_or_message,
                        viewed_books = element_count,
                        total_books = total_books,
                    })
                else
                    callback({
                        state = "book-pull-metadata",
                        book_id = book.id,
                        book_path = pull_path_or_message,
                        viewed_books = element_count,
                        total_books = total_books,
                    })
                end
            else
                logger:err("Book failed to pull:", book.id, "-", pull_path_or_message)
                callback({
                    state = "book-error",
                    book_id = book.id,
                    message = pull_path_or_message,
                    viewed_books = element_count,
                    total_books = total_books,
                })
            end
        end
    end

    logger:dbg("Checking existing books on disk in download directory")

    -- Iterate through books in download directory and
    -- remove when not in the `seen_books` set
    util.findFiles(
        download_directory,
        function(path)
            local ok, result = pcall(function()
                if path:match("%.sdr/") then
                    -- Ignore sidecar directory
                    return
                end

                if seen_books[path] then
                    -- We saw this specific file and can skip
                    -- We don't need to do the database lookup
                    return
                end

                local partial_md5 = util.partialMD5(path)
                local found_ok, _, grimmory_id = self.repository:findBookByFile(path, partial_md5)

                if not found_ok or not grimmory_id then
                    -- Skip file, not tracked in database for some reason
                    logger:dbg("Skipping file removal, not in database:", path, partial_md5)
                    return
                end

                if seen_grimmory_ids[tostring(grimmory_id)] then
                    -- We saw this Grimmory ID as a valid book to keep on-device.
                    return
                end

                logger:dbg("Book removed from upstream:", path)

                if self.settings:getDownloadRemoveBooks() then
                    self:removeBook(path)
                else
                    -- Even if we don't remove the book we should remove it
                    -- from all Grimmory shelves.
                    self:associateWithShelves(path, {})
                end
            end)

            if not ok then
                logger:err("Failed during cleanup:", path, "-", result)
            end
        end,
        true
    )

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

    -- Clean up empty shelves
    self:removeEmptyShelves(callback)

    logger:info("Done synchronizing")
end

function GrimmorySynchronize:synchronizeBook(book_path, refresh_book, callback)
    if not self:checkForHealthyServer() then
        error("Cannot connect to valid server")
    end

    -- Get book ID
    local book_ok, book_id, grimmory_id = self.repository:upsertBook(book_path)

    if not book_ok or not book_id then
        error("Could not track book")
    end

    if refresh_book then
        if not grimmory_id then
            error("Book not associated to Grimmory")
        end

        local refresh_ok, refreshed_book_id = self:refreshBook(book_path, book_id, grimmory_id)

        if not refresh_ok or not refreshed_book_id then
            logger:err("Could not refresh book:", book_path, refreshed_book_id)
            error("Could not refresh book")
        end
    end

    if grimmory_id == nil then
        -- Try to find a grimmory ID for this book
        logger:info("Searching Grimmory for book:", book_path)

        grimmory_id = self:associateBook(book_path)
        if grimmory_id ~= nil then
            logger:info("Found book in Grimmory:", book_path)
        else
            logger:warn("Unable to locate book in Grimmory:", book_path)
        end
    end

    -- Pull annotations from Grimmory
    if grimmory_id then
        logger:info("Pushing book annotations:", book_path)
        self:pushBookAnnotations(book_path, grimmory_id)

        logger:info("Pulling book annotations:", book_path)
        self:pullBookAnnotations(book_path, grimmory_id)
    end

    -- First, tell Grimmory about all of our reading
    logger:info("Pushing pending book metadata:", book_path)
    self:pushBookMetadata(book_id, callback)

    callback({
        state = "book-push-metadata",
        book_id = book_id,
        pushed_books = 1,
        total_books = 1,
    })

    -- Then, try to get progress
    self:pullBookProgress(book_path)

    logger:info("Done synchronizing book:", book_path)
end

return GrimmorySynchronize