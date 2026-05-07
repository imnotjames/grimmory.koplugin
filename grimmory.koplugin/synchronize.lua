local ReadingSessions = require("reading_sessions")
local logger = require("namespaced_logger").new("GrimmorySynchronize")

local GrimmorySynchronize = {}

function GrimmorySynchronize:getConnectorBookId(connector, bookId, bookMd5)
    return bookId
end

function GrimmorySynchronize:synchronizeAll(connector, since, callback)
    logger:info("Synchronizing sessions since", since)

    for _, session in ipairs(ReadingSessions.getSessions(since)) do
        logger:dbg(
            "Recording session",
            session.bookId,
            session.startTime,
            session.endTime,
            session.startProgress,
            session.endProgress
        )

        -- TODO: translate from koreader book ID to grimmory book ID
        connectorBookId = self:getConnectorBookId(connector, session.bookId, session.bookMd5)

        ok = connector:recordSession(
            grimmoryBookId,
            session.startTime,
            session.endTime,
            session.startProgress,
            session.endProgress
        )

        if ok then
            logger:info("Session recorded successfully for book", bookId)
            callback({
                state = "success",
                bookId = session.bookId,
                since = session.startTime,
            })
        else
            logger:err("Session failed recording with error for book", bookId)
            callback({
                state = "error",
                bookId = session.bookId,
                since = session.startTime,
            })
        end
    end

    logger:info("Highlights not implemented yet")

    logger:info("Progress not implemented yet")

    logger:info("Shelves not implemented yet")

    logger:info("Personal ratings not implemented yet")

    logger:info("Done synchronizing")
end


return GrimmorySynchronize