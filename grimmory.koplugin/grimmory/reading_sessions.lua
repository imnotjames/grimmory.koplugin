local Cache = require("cache")
local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local ReadHistory = require("readhistory")
local util = require("util")

local logger = require("grimmory/logger").new("reading_sessions")

local SESSION_COLLAPSE_THRESHOLD = 60.0

---@class ReadingSession
---@field book_md5 string
---@field book_path string
---@field start_time number
---@field end_time number
---@field start_progress number
---@field end_progress number
---@field start_page number
---@field end_page number
---@field page_count number

---@class ReadingSessionEvent
---@field book_md5 string
---@field book_path string
---@field start_time number
---@field end_time number
---@field page number
---@field page_count number

---@class ReadingSessions
local ReadingSessions = {
    statistics_database_file =  DataStorage:getSettingsDir() .. "/statistics.sqlite3",
    book_path_md5_cache = Cache:new({ slots = 2048 }),
    last_book_md5_scan = 0,
}
ReadingSessions.__index = ReadingSessions

function ReadingSessions:new()
  return setmetatable({}, self)
end

function ReadingSessions:withSessionDatabase(callback)
    local database = SQ3.open(
        ReadingSessions.statistics_database_file,
        SQ3.OPEN_READONLY
    )

    local ok, results = pcall(callback, database)

    database:close()

    if not ok then
        error(results)
    else
        return results
    end
end

function ReadingSessions:getBookPath(target_md5)
    if not self.book_path_md5_cache:check(target_md5) and self.last_book_md5_scan < os.time() + 10 then
        self.last_book_md5_scan = os.time()
        -- Look through every recent book and md5 them
        for _, v in ipairs(ReadHistory.hist) do
            local partial_md5 = util.partialMD5(v.file)
            self.book_path_md5_cache:insert(partial_md5, v.file)
        end
    end

    return self.book_path_md5_cache:get(target_md5)
end

---@param since integer
---@return ReadingSessionEvent[]
function ReadingSessions:getPageStatistics(since)
    return ReadingSessions:withSessionDatabase(function(conn)
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

        ---@type ReadingSessionEvent[]
        local results = {}

        for row in stmt:rows() do
            local event = {
                book_md5 = row[1],
                book_path = self:getBookPath(row[1]),
                start_time = tonumber(row[2]),
                end_time = tonumber(row[3]),
                page = tonumber(row[4]),
                page_count = tonumber(row[5])
            }

            table.insert(results, event)
        end

        stmt:close()

        return results
    end)
end

---@param since integer
---@return ReadingSession[]
function ReadingSessions:getSessions(since)
    ---@type ReadingSession[]
    local sessions = {}

    for _, stat in ipairs(ReadingSessions:getPageStatistics(since)) do
        -- Eventually we could figure out progress from start of page
        -- to end of page?  But for now the simplest is to count
        -- progress as a point-in-time.

        local progress = stat.page / stat.page_count

        -- If existing session, we should update.
        -- We can make the assumption that these are in
        -- order by book ID and start time to simplify.
        local collapsedSession = false

        if #sessions > 0 then
            local last_book_md5 = sessions[#sessions].book_md5
            local last_end_time = sessions[#sessions].end_time
            local last_progress = sessions[#sessions].end_progress
            local last_page = sessions[#sessions].end_page
            local last_page_count = sessions[#sessions].page_count

            if stat.book_md5 ~= last_book_md5 then
                logger:dbg("Book changed, cannot collapse session:", last_book_md5, "!=", stat.book_md5)
            elseif math.abs(stat.start_time - last_end_time) > SESSION_COLLAPSE_THRESHOLD then
                logger:dbg("Outside collapse session:", stat.book_md5)
            elseif stat.page_count ~= last_page_count then
                logger:dbg("Page count changed, cannot combine sessions")
            else
                logger:dbg("Collapsed session for book", stat.book_md5)
                collapsedSession = true
                sessions[#sessions].end_time = math.max(stat.end_time, last_end_time)
                sessions[#sessions].end_progress = math.max(progress, last_progress)
                sessions[#sessions].end_page = math.max(stat.page, last_page)
            end
        end

        if not collapsedSession then
            logger:dbg("New Session found for book", stat.book_md5)

            -- If new session, create a new session record
            ---@type ReadingSession
            local new_session = {
                book_md5 = stat.book_md5,
                book_path = stat.book_path,
                start_time = stat.start_time,
                end_time = stat.end_time,
                start_progress = progress,
                end_progress = progress,
                start_page = stat.page,
                end_page = stat.page,
                page_count = stat.page_count,
            }

            table.insert(sessions, new_session)
        end
    end

    table.sort(
        sessions,
        function (a, b)
            return a.end_time < b.end_time
        end
    )

    return sessions
end

return ReadingSessions