local Cache = require("cache")
local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local ReadHistory = require("readhistory")
local util = require("util")

local logger = require("namespaced_logger").new("reading_sessions")

local SESSION_COLLAPSE_THRESHOLD = 60.0

local ReadingSessions = {
    statistics_database_file =  DataStorage:getSettingsDir() .. "/statistics.sqlite3",
    book_path_md5_cache = Cache:new({ slots = 2048 }),
    last_book_md5_scan = 0,
}

function ReadingSessions.__open()
    return SQ3.open(
        ReadingSessions.statistics_database_file,
        SQ3.OPEN_READONLY
    )
end

function ReadingSessions:getBookPath(targetMd5)
    if not self.book_path_md5_cache:check(targetMd5) and self.last_book_md5_scan < os.time() + 10 then
        self.last_book_md5_scan = os.time()
        -- Look through every recent book and md5 them
        for _, v in ipairs(ReadHistory.hist) do
            local partialMd5 = util.partialMD5(v.file)
            self.book_path_md5_cache:insert(partialMd5, v.file)
        end
    end

    return self.book_path_md5_cache:get(targetMd5)
end

function ReadingSessions:getPageStatistics(since)
    local conn = ReadingSessions.__open()

    local stmt = conn:prepare([[
        SELECT
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
                bookMd5 = row[1],
                bookPath = self:getBookPath(row[1]),
                startTime = tonumber(row[2]),
                endTime = tonumber(row[3]),
                page = tonumber(row[4]),
                totalPages = tonumber(row[5])

            }
        )
    end

    stmt:close()
    conn:close()

    return results
end

function ReadingSessions:getSessions(since)
    local sessions = {}

    for _, stat in ipairs(ReadingSessions:getPageStatistics(since)) do
        -- Eventually we could figure out progress from start of page
        -- to end of page?  But for now the simplest is to count
        -- progress as a point-in-time.

        local progress = stat.page / stat.totalPages

        -- If existing session, we should update.
        -- We can make the assumption that these are in
        -- order by book ID and start time to simplify.
        local collapsedSession = false

        if #sessions > 0 then
            local lastBookMd5 = sessions[#sessions].bookMd5
            local lastEndTime = sessions[#sessions].endTime
            local lastProgress = sessions[#sessions].endProgress
            local lastPage = sessions[#sessions].endPage
            local lastPageCount = sessions[#sessions].pageCount

            if stat.bookMd5 ~= lastBookMd5 then
                logger:dbg("Book changed, cannot collapse session:", lastBookMd5, "!=", stat.bookMd5)
            elseif math.abs(stat.startTime - lastEndTime) > SESSION_COLLAPSE_THRESHOLD then
                logger:dbg("Outside collapse session:", stat.bookId)
            elseif stat.totalPages ~= lastPageCount then
                logger:dbg("Page count changed, cannot combine sessions")
            else
                logger:dbg("Collapsed session for book", stat.bookMd5)
                collapsedSession = true
                sessions[#sessions].endTime = math.max(stat.endTime, lastEndTime)
                sessions[#sessions].endProgress = math.max(progress, lastProgress)
                sessions[#sessions].endPage = math.max(stat.page, lastPage)
            end
        end

        if not collapsedSession then
            logger:dbg("New Session found for book", stat.bookMd5)

            -- If new session, create a new session record
            table.insert(
                sessions,
                {
                    bookMd5 = stat.bookMd5,
                    bookPath = stat.bookPath,
                    startTime = stat.startTime,
                    endTime = stat.endTime,
                    startProgress = progress,
                    endProgress = progress,
                    startPage = stat.page,
                    endPage = stat.page,
                    pageCount = stat.totalPages,
                }
            )
        end
    end

    table.sort(
        sessions,
        function (a, b)
            return a.endTime < b.endTime
        end
    )

    return sessions
end

return ReadingSessions