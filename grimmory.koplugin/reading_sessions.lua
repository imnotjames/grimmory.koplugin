local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")

local ReaderUI = require("apps/reader/readerui")

local logger = require("namespaced_logger").new("reading_sessions")

local SESSION_COLLAPSE_THRESHOLD = 120.0

local ReadingSessions = {
    statistics_database_file =  DataStorage:getSettingsDir() .. "/statistics.sqlite3"
}

function ReadingSessions.__open()
    return SQ3.open(
        ReadingSessions.statistics_database_file,
        SQ3.OPEN_READONLY
    )
end

function ReadingSessions.getPageStatistics(since)
    local conn = ReadingSessions.__open()

    local stmt = conn:prepare([[
        SELECT
            book.id,
            book.md5,

            p.start_time,
            p.start_time + p.duration,
            p.page,
            p.total_pages
        FROM book
        JOIN page_stat_data AS p ON p.id_book = book.id
        WHERE p.start_time > ?
        ORDER BY book.id ASC, p.start_time ASC
    ]])

    stmt:bind(since)

    local results = {}

    for row in stmt:rows() do
        table.insert(
            results,
            {
                bookId = tonumber(row[1]),
                bookMd5 = row[2],
                startTime = tonumber(row[3]),
                endTime = tonumber(row[4]),
                page = tonumber(row[5]),
                totalPages = tonumber(row[6])

            }
        )
    end

    stmt:close()
    conn:close()

    return results
end

function ReadingSessions.getSessions(since)
    local sessions = {}

    for _, stat in ipairs(ReadingSessions.getPageStatistics(since)) do
        -- Eventually we could figure out progress from start of page
        -- to end of page?  But for now the simplest is to count
        -- progress as a point-in-time.

        local progress = stat.page / stat.totalPages

        -- If existing session, we should update.
        -- We can make the assumption that these are in
        -- order by book ID and start time to simplify.
        local collapsedSession = false
        if #sessions > 0 then
            local lastBookId = sessions[#sessions].bookId
            local lastEndTime = sessions[#sessions].endTime
            local lastProgress = sessions[#sessions].endProgress

            if stat.bookId == lastBookId and math.abs(stat.startTime - lastEndTime) < SESSION_COLLAPSE_THRESHOLD then
                logger:dbg("Collapsed session for book", stat.bookId)
                collapsedSession = true
                sessions[#sessions].endTime = math.max(stat.endTime, lastEndTime)
                sessions[#sessions].endProgress = math.max(progress, lastProgress)
            end
        end

        if not collapsedSession then
            logger:dbg("New Session found for book", stat.bookId)

            -- If new session, create a new session record
            table.insert(
                sessions,
                {
                    bookId = stat.bookId,
                    bookMd5 = stat.bookMd5,
                    startTime = stat.startTime,
                    endTime = stat.endTime,
                    startProgress = progress,
                    endProgress = progress,
                }
            )
        end
    end

    -- TODO: Sort by start time?

    return sessions
end

return ReadingSessions