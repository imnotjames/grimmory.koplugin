local Cache = require("cache")
local ReadCollection = require("readcollection")
local util = require("util")

local DocMetadata = require("doc_metadata")
local ReadingSessions = require("reading_sessions")
local logger = require("namespaced_logger").new("GrimmorySynchronize")

local GrimmorySynchronize = {
    synchronize_sessions_since = 0,
    threshold_seconds = 0,
    threshold_pages = 0,
    sync_shelves = true,
    sync_sessions = true,
    target_shelves = {},
    download_directory = nil,
    md5_to_connector_id_cache = Cache:new({ slots = 4096 }),
    identifiers_to_connector_id = nil,
    connector_books = nil,
}

function GrimmorySynchronize:setThresholds(seconds, pages)
    self.threshold_seconds = seconds
    self.threshold_pages = pages
end

function GrimmorySynchronize:setDownloadDirectory(path)
    self.download_directory = path
end

function GrimmorySynchronize:setTargetShelves(shelves)
    self.target_shelves = shelves
end

function GrimmorySynchronize:setFeaturesEnabled(shelves, sessions)
    self.sync_shelves = shelves
    self.sync_sessions = sessions
end

function GrimmorySynchronize:setSynchronizeSessionsSince(since)
    self.synchronize_sessions_since = since
end

function GrimmorySynchronize:getTitleIdentifier(title, author)
    if title == nil then
        return nil
    end

    if author == nil then
        author = "NA"
    end

    local titleIdentifier = title:lower():gsub("[^a-z0-9]+", "") .. "--" .. author:lower():gsub("[^a-z0-9]+", "")

    if string.len(titleIdentifier) < 5 then
        return nil
    end

    return titleIdentifier
end

function GrimmorySynchronize:refreshBooksFromConnector(connector)
    local identifiersToConnectorId = {}
    local connectorBooks = {}

    local ok, books = connector:getBooks()

    if not ok then
        logger:err("Something went wrong fetching books", books)
        return {}
    end

    for _, book in ipairs(books) do
        local metadata = book["metadata"]

        if metadata then
            if metadata["asin"] then
                identifiersToConnectorId["asin:" .. metadata["asin"]:lower()] = book.id
            end

            if metadata["isbn13"] then
                identifiersToConnectorId["isbn:" .. metadata["isbn13"]] = book.id
            elseif metadata["isbn10"] then
                identifiersToConnectorId["isbn:" .. metadata["isbn10"]] = book.id
            end

            if metadata["title"] and metadata["authors"] then
                local author = metadata["authors"][0] or metadata["authors"][1]
                local titleIdentifier = self:getTitleIdentifier(metadata["title"], author)

                if titleIdentifier then
                    identifiersToConnectorId["title-id:" .. titleIdentifier] = book.id
                end
            end
        end

        local fileName = nil
        if book["primaryFile"] and book["primaryFile"]["fileName"] then
            fileName = book["primaryFile"]["fileName"]
            identifiersToConnectorId["filename:" .. fileName] = book.id
        end

        if fileName then
            local shelves = {}

            if book["shelves"] then
                for _, shelf in ipairs(book["shelves"]) do
                    table.insert(shelves, shelf.id)
                end
            end

            local isMatchingShelf = false
            for _, shelfId in ipairs(shelves) do
                if self:isTargetShelf(shelfId) then
                    isMatchingShelf = true
                    break
                end
            end

            if isMatchingShelf then
                table.insert(
                    connectorBooks,
                    {
                        id = book["id"],
                        shelves = shelves,
                        fileName = fileName
                    }
                )
            end
        end
    end

    self.identifiers_to_connector_id = identifiersToConnectorId
    self.connector_books = connectorBooks
end

function GrimmorySynchronize:getConnectorBookId(connector, bookPath, bookMd5)
    if bookMd5 == nil then
        bookMd5 = util.partialMD5(bookPath)
    end

    local cacheValue = self.md5_to_connector_id_cache:get(bookMd5:lower())
    if cacheValue ~= nil then
        logger:dbg("ID Cache hit", bookMd5, bookPath)
        if cacheValue < 0 then
            return nil
        end

        return cacheValue
    end

    logger:dbg("ID Cache miss", bookMd5, bookPath)

    local isbn = DocMetadata:getISBN(bookPath)
    local asin = DocMetadata:getASIN(bookPath)
    local title = DocMetadata:getTitle(bookPath)
    local author = DocMetadata:getAuthor(bookPath)

    local bookId = -1

    -- Instead of this, we should use a Grimmory search functionality.
    -- This works well enough for today, though.
    local identifiers = self.identifiers_to_connector_id

    local titleId = self:getTitleIdentifier(title, author)
    local _, filename = util.splitFilePathName(bookPath)
    if identifiers ~= nil then
        if isbn and identifiers["isbn:" .. isbn] then
            bookId = identifiers["isbn:" .. isbn]
        elseif asin and identifiers["asin:" .. asin:lower()] then
            bookId = identifiers["asin:" .. asin:lower()]
        elseif titleId and identifiers["title-id:" .. titleId] then
            bookId = identifiers["title-id:" .. titleId]
        elseif filename and identifiers["filename:" .. filename] then
            bookId = identifiers["filename:" .. filename]
        end
    end

    self.md5_to_connector_id_cache:insert(bookMd5:lower(), bookId)

    if bookId < 0 then
        return nil
    else
        return bookId
    end
end

function GrimmorySynchronize:synchronizeSessions(connector, callback)
    logger:info("Synchronizing sessions since", self.synchronize_sessions_since)

    local sessions = ReadingSessions.getSessions(self.synchronize_sessions_since)

    for _, session in ipairs(sessions) do
        local totalSeconds = session.endTime - session.startTime
        local totalPages = session.endPage - session.startPage + 1

        if not self.sync_sessions or (totalSeconds < self.threshold_seconds and totalPages < self.threshold_pages) then
            logger:info("Session skipped for book", session.bookPath)
            callback({
                state = "session-skip",
                bookPath = session.bookPath,
                since = session.startTime,
            })
        else
            logger:dbg(
                "Recording session",
                session.bookPath,
                session.startTime,
                session.endTime,
                session.startProgress,
                session.endProgress
            )

            local connectorBookId = self:getConnectorBookId(connector, session.bookPath, session.bookMd5)

            local ok = false
            local body = nil
            if connectorBookId == nil then
                body = "Could not match local book to connector"
            else
                ok, body = connector:recordSession(
                    connectorBookId,
                    session.startTime,
                    session.endTime,
                    session.startProgress,
                    session.endProgress
                )
            end

            if ok then
                logger:info("Session recorded successfully for book", session.bookPath)
                callback({
                    state = "session-recorded",
                    bookPath = session.bookPath,
                    since = session.startTime,
                })
            else
                logger:err("Session failed recording with error for book: ", session.bookPath, " - ", body)
                callback({
                    state = "session-error",
                    bookPath = session.bookPath,
                    since = session.startTime,
                })
            end
        end
    end
end

function GrimmorySynchronize:isTargetShelf(shelfId)
    if #self.target_shelves == 0 then
        return true
    end

    for _, shelf in ipairs(self.target_shelves) do
        if shelf.id == shelfId then
            return true
        end
    end

    return false
end

function GrimmorySynchronize:synchronizeShelves(connector, callback)
    if not self.sync_shelves then
        logger:info("Shelf sync skipped because feature is disabled")
        return
    end

    local ok, shelves = connector:getShelves()

    if not ok then
        logger:err("Could not connect to connector to get shelves", shelves)
        return
    end

    local shelfIdToName = {}
    local shelfNameToId = {}

    for _, shelf in ipairs(shelves) do
        if shelf.id and shelf.name and self:isTargetShelf(shelf.id) then
            local shelfName = shelf.name:lower()

            logger:dbg("Shelf received from connector", shelf.id, shelfName)

            -- If there's a shelf with a duplicate name, we can't support
            -- that in koreader.  Instead, add something to the shelf name
            -- until it's unique.
            local uniqueShelfName = shelfName
            local uniqueShelfIndex = 0
            while shelfNameToId[uniqueShelfName] do
                uniqueShelfIndex = uniqueShelfName + 1
                uniqueShelfName = shelfName .. " (" .. uniqueShelfIndex .. ")"
            end

            if uniqueShelfName ~= shelfName then
                logger:dbg("Duplicate shelf name found", shelfName, "- used new name", uniqueShelfName)
            end

            shelfNameToId[uniqueShelfName] = shelf.id

            -- use tostring to get a sparse table
            shelfIdToName[tostring(shelf.id)] = shelfName
        end
    end

    -- Read through existing collections and compare against shelves
    for collectionName, _ in pairs(ReadCollection.coll) do
        local connectorId = ReadCollection.coll_settings[collectionName].connectorId

        if connectorId then
            if shelfIdToName[tostring(connectorId)] then
                local shelfName = shelfIdToName[tostring(connectorId)]

                -- This collection exists as a shelf so we should update it
                -- if there's anything that needs to change.
                if shelfName ~= collectionName:lower() then
                    -- This collection has been renamed!
                    logger:info("Renaming collection to match shelf name:", collectionName, ";", shelfName)

                    ReadCollection:renameCollection(collectionName, shelfName)

                    callback({
                        state = "shelf-rename",
                        shelfId = connectorId,
                        shelfName = shelfName,
                    })
                end
            else
                logger:info("Disconnecting collection from shelf:", collectionName)
                -- This was a shelf but the shelf is gone in the connector
                -- Don't delete the shelf but break the connection.
                ReadCollection.coll_settings[collectionName].connectorId = nil

                -- Set the connector ID to nil so the block below will pick
                -- it up if it's a shelf being deleted and recreated
                connectorId = nil

                callback({
                    state = "shelf-disconnect",
                    shelfId = connectorId,
                    shelfName = collectionName,
                })
            end
        end

        if connectorId == nil and shelfNameToId[collectionName:lower()] then
            -- If there is no shelf attached to this collection but we
            -- know one exists we should attach it.
            connectorId = shelfNameToId[collectionName:lower()]

            logger:info("Found an existing collection that can be attached to a shelf:", collectionName, ";" , connectorId)

            ReadCollection.coll_settings[collectionName].connectorId = connectorId

            callback({
                state = "shelf-connect",
                shelfId = connectorId,
                shelfName = collectionName,
            })
        end
    end

    -- Make sure every shelf has a collection and create them if not
    for shelfName, connectorId in pairs(shelfNameToId) do
        if not ReadCollection.coll_settings[shelfName] then
            logger:info("Adding a collection from a shelf", shelfName, connectorId)

            ReadCollection:addCollection(shelfName)
            ReadCollection.coll_settings[shelfName].connectorId = connectorId

            callback({
                state = "shelf-add",
                shelfId = connectorId,
                shelfName = shelfName,
            })
        end
    end

    -- Persist collections to the database now that we've finished our sync
    ReadCollection:write()
end

function GrimmorySynchronize:downloadBook(connector, connectorId, downloadPath)
    local success, result, message = pcall(function()
        return connector:downloadBook(connectorId, downloadPath)
    end)

    if not success then
        logger:err("Book download failed:", connectorId, " - ", result)
        return false, result
    end

    if not result then
        return false, message
    end

    return true, nil
end

function GrimmorySynchronize:getBookDownloadPath(connector, book)
    local downloadPath = self.download_directory .. "/" .. util.getSafeFilename(book.fileName)

    -- If this path doesn't exist yet, we're good, bail early
    if not util.fileExists(downloadPath) then
        return downloadPath
    end

    -- If the path exists we have to check to make sure that it is actually the book we care about
    if self:getConnectorBookId(connector, downloadPath) == book.id then
        -- We have a match, this path is safe.
        return downloadPath
    end

    -- At this point we need a fallback name.  `download-${BOOK_ID}.${EXT}` is not
    -- great but I don't know a better safe way off hand.

     downloadPath = "downloaded-" .. tonumber(book.id) .. "." .. util.getFileNameSuffix(book.fileName)

    -- If this path doesn't exist yet, we're good?
    if not util.fileExists(downloadPath) then
        return downloadPath
    end
    
    -- Okay, this file exists.  It's GOT to be our file, though, right?
    if self:getConnectorBookId(connector, downloadPath) == book.id then
        -- We have a match, this path is safe.
        return downloadPath
    end

    -- Give up.
    logger:err("Could not determine a valid download path for book:", book.id)
    return nil
end

function GrimmorySynchronize:associateWithShelves(bookPath, shelves)
    local connectorIdToName = {}
    for collectionName, _ in pairs(ReadCollection.coll) do
        local connectorId = ReadCollection.coll_settings[collectionName].connectorId

        if connectorId then
            connectorIdToName[tostring(connectorId)] = collectionName
        end
    end

    for _, shelfId in ipairs(shelves) do
        local collectionName = connectorIdToName[tostring(shelfId)]

        if collectionName then
            ReadCollection:addItem(bookPath, collectionName)
        end
    end
end

function GrimmorySynchronize:synchronizeBooks(connector, callback)
    if not self.sync_shelves then
        logger:info("Book download skipped because feature is disabled")
        return
    end

    if self.download_directory == nil then
        logger:err("Book download skipped because download directory is not set")
        return
    end

    -- Ensure that the download directory exists
    local directoryExists, directoryErrorMessage = util.makePath(self.download_directory)
    if not directoryExists then
        logger:err("Failed to create download directory", directoryErrorMessage)
        return
    end

    -- Eventually we should support a "since" but for right
    -- now it's easiest to sync everything.
    local books = self.connector_books or {}

    -- TODO: Read known books from shelves in case we move the download directory

    for _, book in ipairs(books) do
        local bookExists = false

        local downloadPath = self:getBookDownloadPath(connector, book)

        -- TODO: Search through known books from shelves for this book
        --       If found, set the `download path to that value.

        if util.fileExists(downloadPath) then
            bookExists = true
        end

        if not bookExists and downloadPath ~= nil then
            logger:dbg("Downloading book", book.id, "to", downloadPath)

            local ok, message = self:downloadBook(connector, book.id, downloadPath)
            if ok then
                logger:info("Book downloaded:", book.id, " - ", downloadPath)
                callback({
                    state = "book-downloaded",
                    bookId = book.id,
                    downloadPath = downloadPath,
                })
                bookExists = true
            else
                logger:err("Book failed download:", book.id, "-", message)
                callback({
                    state = "book-error",
                    bookId = book.id,
                    downloadPath = downloadPath,
                })
            end
        else
            callback({
                state = "book-skipped",
                bookId = book.id,
                downloadPath = downloadPath,
            })
        end

        if bookExists then
            -- After we're done, if the book exists we should attach it
            -- to associated shelves.
            self:associateWithShelves(downloadPath, book.shelves)
        end
    end
end

function GrimmorySynchronize:synchronizeAll(connector, callback)
    -- Refresh so we pull fresh books
    self:refreshBooksFromConnector(connector)

    self:synchronizeShelves(connector, callback)

    self:synchronizeSessions(connector, callback)

    self:synchronizeBooks(connector, callback)

    logger:info("Highlights not implemented yet")

    logger:info("Progress not implemented yet")

    logger:info("Personal ratings not implemented yet")

    logger:info("Done synchronizing")
end


return GrimmorySynchronize