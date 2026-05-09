local ReadingSessions = require("reading_sessions")
local logger = require("namespaced_logger").new("GrimmorySynchronize")

local GrimmorySynchronize = {
    threshold_seconds = 0,
    threshold_pages = 0,
}

function ReadingSessions:setThresholds(seconds, pages)
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

function GrimmorySynchronize:synchronizeAll(connector, since, callback)
    self:synchronizeSessions(connector, since, callback)

    logger:info("Highlights not implemented yet")

    logger:info("Progress not implemented yet")

    logger:info("Shelves not implemented yet")

    logger:info("Personal ratings not implemented yet")

    logger:info("Done synchronizing")
end


return GrimmorySynchronize