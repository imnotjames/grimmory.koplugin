local ReadCollection = require("readcollection")
local ReadingSessions = require("reading_sessions")
local logger = require("namespaced_logger").new("GrimmorySynchronize")

local GrimmorySynchronize = {
    threshold_seconds = 0,
    threshold_pages = 0,
}

function GrimmorySynchronize:setThresholds(seconds, pages)
    self.threshold_seconds = seconds
    self.threshold_pages = pages
end

function GrimmorySynchronize:getConnectorBookId(connector, bookId, bookMd5)
    -- TODO: translate from koreader book ID to grimmory book ID

    -- Get ISBN and check for that first
    -- Search all books by title and author
    return bookId
end

function GrimmorySynchronize:synchronizeSessions(connector, since, callback)
    logger:info("Synchronizing sessions since", since)

    local sessions = ReadingSessions.getSessions(since)

    for _, session in ipairs(sessions) do
        local totalSeconds = session.endTime - sessions.startTime
        local totalPages = sessions.endPage - sessions.startPage + 1

        if totalSeconds > self.threshold_seconds or totalPages > self.threshold_pages then
            logger:err("Session skipped for book", session.bookId)
            callback({
                state = "session-skip",
                bookId = session.bookId,
                since = session.startTime,
            })
        else
            logger:dbg(
                "Recording session",
                session.bookId,
                session.startTime,
                session.endTime,
                session.startProgress,
                session.endProgress
            )

            local connectorBookId = self:getConnectorBookId(connector, session.bookId, session.bookMd5)

            local ok = connector:recordSession(
                connectorBookId,
                session.startTime,
                session.endTime,
                session.startProgress,
                session.endProgress
            )

            if ok then
                logger:info("Session recorded successfully for book", session.bookId)
                callback({
                    state = "session-success",
                    bookId = session.bookId,
                    since = session.startTime,
                })
            else
                logger:err("Session failed recording with error for book", session.bookId)
                callback({
                    state = "session-error",
                    bookId = session.bookId,
                    since = session.startTime,
                })
            end
        end
    end
end

function GrimmorySynchronize:synchronizeShelves(connector, since, callback)
    local ok, shelves = connector:getShelves()

    if not ok then
        logger:err("Could not connect to connector to get shelves", shelves)
    end

    local shelfIdToName = {}
    local shelfNameToId = {}

    for _, shelf in ipairs(shelves) do
        if shelf.id and shelf.name then
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

            shelfIdToName[shelf.id] = shelfName
            shelfNameToId[uniqueShelfName] = shelf.id
        end
    end

    -- Read through existing collections and compare against shelves
    for collectionName, _ in pairs(ReadCollection.coll) do
        local connectorId = ReadCollection.coll_settings[collectionName].connectorId

        if connectorId then
            if shelfIdToName[connectorId] then
                -- This collection exists as a shelf so we should update it
                -- if there's anything that needs to change.
                if shelfIdToName[connectorId] ~= collectionName then
                    -- This collection has been renamed!
                    ReadCollection:renameCollection(collectionName, shelfIdToName[connectorId])
                end
            else
                -- This was a shelf but the shelf is gone in the connector
                -- Don't delete the shelf but break the connection.
                ReadCollection.coll_settings[collectionName].connectorId = nil

                -- Set the connector ID to nil so the block below will pick
                -- it up if it's a shelf being deleted and recreated
                connectorId = nil
            end
        end

        if connectorId ~= nil and shelfNameToId[collectionName] then
            -- If there is no shelf attached to this collection but we
            -- know one exists we should attach it.
            connectorId = shelfNameToId[collectionName]

            logger:info("Found an existing collection that can be attached to a shelf:", collectionName, connectorId)

            ReadCollection.coll_settings[collectionName].connectorId = connectorId
        end
    end

    -- Make sure every shelf has a collection and create them if not
    for connectorId, shelfName in ipairs(shelfIdToName) do
        if not ReadCollection.coll_settings[shelfName] then
            logger:info("Adding a collection from a shelf", shelfName, connectorId)

            ReadCollection:addCollection(shelfName)
            ReadCollection.coll_settings[shelfName].connectorId = connectorId
        end
    end

    -- Persist collections to the database now that we've finished our sync
    ReadCollection:write()
end

function GrimmorySynchronize:synchronizeAll(connector, since, callback)
    self:synchronizeShelves(connector, since, callback)

    self:synchronizeSessions(connector, since, callback)

    logger:info("Book download not implemented yet")

    logger:info("Highlights not implemented yet")

    logger:info("Progress not implemented yet")

    logger:info("Personal ratings not implemented yet")

    logger:info("Done synchronizing")
end


return GrimmorySynchronize