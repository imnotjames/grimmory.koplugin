local ReadCollection = require("readcollection")
local ReadingSessions = require("reading_sessions")
local logger = require("namespaced_logger").new("GrimmorySynchronize")

local GrimmorySynchronize = {
    synchronize_sessions_since = 0,
    threshold_seconds = 0,
    threshold_pages = 0,
    sync_shelves = true,
    sync_sessions = true,
    target_shelves = {},
}

function GrimmorySynchronize:setThresholds(seconds, pages)
    self.threshold_seconds = seconds
    self.threshold_pages = pages
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

function GrimmorySynchronize:getConnectorBookId(connector, bookId, bookMd5)
    -- TODO: translate from koreader book ID to grimmory book ID

    -- Get ISBN and check for that first
    -- Search all books by title and author
    return bookId
end

function GrimmorySynchronize:synchronizeSessions(connector, callback)
    logger:info("Synchronizing sessions since", self.synchronize_sessions_since)

    local sessions = ReadingSessions.getSessions(self.synchronize_sessions_since)

    for _, session in ipairs(sessions) do
        local totalSeconds = session.endTime - sessions.startTime
        local totalPages = sessions.endPage - sessions.startPage + 1

        if not self.sync_sessions or (totalSeconds < self.threshold_seconds and totalPages < self.threshold_pages) then
            logger:info("Session skipped for book", session.bookId)
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

function GrimmorySynchronize:isTargetShelf(shelfId)
    if #self.target_shelves == 0 then
        return true
    end

    for _, shelf in self.target_shelves do
        if shelf.id == shelfId then
            return true
        end
    end

    return false
end

function GrimmorySynchronize:synchronizeShelves(connector, callback)
    if not self.sync_shelves then
        logger:info("Session sync skipped because feature is disabled")
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

function GrimmorySynchronize:synchronizeAll(connector, callback)
    self:synchronizeShelves(connector, callback)

    self:synchronizeSessions(connector, callback)

    logger:info("Book download not implemented yet")

    logger:info("Highlights not implemented yet")

    logger:info("Progress not implemented yet")

    logger:info("Personal ratings not implemented yet")

    logger:info("Done synchronizing")
end


return GrimmorySynchronize