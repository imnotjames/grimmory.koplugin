local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local util = require("util")
local md5 = require("ffi/sha2").md5

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

local SESSION_COLLAPSE_THRESHOLD = 180.0

local function getPluginPath()
    local source = debug.getinfo(1, "S").source
    local path = source:match("@(.*)/")
    if not path or not path:match("%.koplugin$") then
        path = DataStorage:getDataDir() .. "/plugins/grimmory.koplugin"
    end

    return path
end

---@alias ReadingSessionEventType
---| "page"
---| "session-start"
---| "session-end"

---@class ReadingSession
---@field book_partial_md5 string
---@field book_md5 string
---@field book_path string
---@field start_time number
---@field end_time number
---@field start_page number
---@field end_page number
---@field page_count number
---@field start_progress number
---@field end_progress number
---@field start_xpointer string | nil
---@field end_xpointer string | nil

---@class ReadingSessionEvent
---@field session_id number
---@field event_type ReadingSessionEventType
---@field book_partial_md5 string
---@field book_md5 string
---@field book_path string
---@field timestamp number
---@field page number
---@field page_count number
---@field xpointer string | nil

---@class ReadingSessionRepository
---@field migrations_path string
---@field sessions_database_path string
local ReadingSessionRepository = {
    migrations_path = getPluginPath() .. "/grimmory/reading/migrations/",
    sessions_database_path =  DataStorage:getSettingsDir() .. "/grimmory_sessions.sqlite3",
}

function ReadingSessionRepository:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function ReadingSessionRepository:getMigrations()
    if not util.directoryExists(self.migrations_path) then
        return {}
    end

    local sql_files = {}

    util.findFiles(
        self.migrations_path,
        function(sql_file)
            table.insert(sql_files, sql_file)
        end
    )

    table.sort(sql_files)

    return sql_files
end

function ReadingSessionRepository:runMigrations()
    local sql_files = self:getMigrations()

    for _, sql_filepath in ipairs(sql_files) do
        local sql = util.readFromFile(sql_filepath, "r")
        logger:dbg("Running SQL file path:", sql_filepath)

        if sql ~= nil then
            self:withSessionDatabase(
                function(database)
                    database:exec(sql)
                end,
                "rwc"
            )
        end
    end
end

function ReadingSessionRepository:init()
    self:runMigrations()
end

---@generic T
---@param callback (fun(database: any) | fun(database: any): `T`)
---@param flags? "ro" | "rw" | "rwc"
---@return boolean ok
---@return T result
function ReadingSessionRepository:withSessionDatabase(callback, flags)
    if flags == nil then
        flags = "ro"
    end

    local database = SQ3.open(
        self.sessions_database_path,
        flags
    )

    local ok, result = pcall(callback, database)

    database:close()

    return ok, result
end

---@param book_path string
---@return boolean ok
---@return integer | nil book_id
function ReadingSessionRepository:upsertBook(book_path)
    local full_md5 = md5(book_path)
    local partial_md5 = util.partialMD5(book_path)

    local ok, book_id = self:withSessionDatabase(
        function(conn)
            -- Remember that `OR IGNORE` will ignore almost all
            -- data type or constraint failures.
            local insert_stmt = conn:prepare([[
                INSERT OR IGNORE INTO book
                    (
                        book_path,
                        full_md5,
                        partial_md5
                    )
                VALUES (?, ?, ?);
            ]])

            insert_stmt:bind(book_path, full_md5, partial_md5)
            insert_stmt:step()
            insert_stmt:close()

            -- Cannot use last row ID because it's possible this book
            -- already had existed.
            local select_stmt = conn:prepare([[
                SELECT id FROM book
                WHERE book_path = ? AND full_md5 = ? AND partial_md5 = ?
            ]])

            select_stmt:bind(book_path, full_md5, partial_md5)
            local row = select_stmt:step()

            if not row then
                logger:err("Error during re-select insert")
                return error()
            end

            return tonumber(row[1])
        end,
        "rw"
    )

    if not ok or not book_id then
        logger:err("Failed to upsert book:", book_id)
        return false, nil
    end

    return true, book_id
end

---@param book_id number
---@return boolean ok
---@return integer | nil session_id
function ReadingSessionRepository:insertSession(book_id)
    local ok, session_id = self:withSessionDatabase(
        function(conn)
            local insert_stmt = conn:prepare([[
                INSERT INTO book_session
                    (
                        book_id
                    )
                VALUES (?);
            ]])

            insert_stmt:bind(book_id)
            insert_stmt:step()
            insert_stmt:close()

            local row_id = conn:rowexec("SELECT last_insert_rowid();")

            return tonumber(row_id)
        end,
        "rw"
    )

    if not ok or not session_id then
        logger:err("Failed to create session:", session_id)
        return false, nil
    end

    return true, session_id
end

---@param session_id number
---@param event_type ReadingSessionEventType
---@param current_page number
---@param page_count number
---@param xpointer string | nil
function ReadingSessionRepository:insertBookEvent(session_id, event_type, current_page, page_count, xpointer)
    local ok, result = self:withSessionDatabase(
        function(conn)
            local stmt = conn:prepare([[
                INSERT INTO book_event
                    (
                        session_id,
                        created_at,
                        event_type,
                        current_page,
                        page_count,
                        xpointer
                    )
                VALUES (?, ?, ?, ?, ?, ?)
            ]])

            stmt:bind(
                session_id,
                os.time(),
                event_type,
                current_page,
                page_count,
                xpointer
            )

            stmt:step()

            stmt:close()
        end,
        "rw"
    )

    if not ok then
        logger:err("Failed to create session event:", result)
    end
end

---@param since integer
---@return ReadingSessionEvent[]
function ReadingSessionRepository:getEvents(since)
    local ok, results = ReadingSessionRepository:withSessionDatabase(
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    b.book_path,
                    b.partial_md5,
                    b.full_md5,

                    e.session_id,
                    e.event_type,
                    e.created_at,
                    e.current_page,
                    e.page_count,
                    e.xpointer
                FROM book AS b
                JOIN book_session AS s ON s.book_id = b.id
                JOIN book_event AS e ON e.session_id = s.id
                WHERE e.created_at > ?
                ORDER BY b.id ASC, e.created_at ASC
            ]])

            stmt:bind(since)

            ---@type ReadingSessionEvent[]
            local results = {}

            for row in stmt:rows() do
                ---@type ReadingSessionEvent
                local event = {
                    book_path = row[1],
                    book_partial_md5 = row[2],
                    book_md5 = row[3],
                    session_id = row[4],
                    event_type = row[5],
                    timestamp = tonumber(row[6]) or 0,
                    page = tonumber(row[7]) or 0,
                    page_count = tonumber(row[8]) or 0,
                    xpointer = row[9],
                }

                table.insert(results, event)
            end

            stmt:close()

            return results
        end
    )

    if not ok then
        logger:err("Failed to read sessions", results)
        return {}
    end

    return results
end

---@param session ReadingSession
---@param event ReadingSessionEvent
---@return boolean
local function isPartOfSession(session, event)
    if event.book_md5 ~= session.book_md5 then
        logger:dbg("Book changed, cannot collapse session:", session.book_md5, "!=", event.book_md5)
        return false
    elseif math.abs(event.timestamp - session.end_time) > SESSION_COLLAPSE_THRESHOLD then
        logger:dbg("Outside collapse session:", event.book_md5)
        return false
    elseif event.page_count ~= session.page_count then
        logger:dbg("Page count changed, cannot combine sessions")
        return false
    elseif event.xpointer == nil and session.start_xpointer ~= nil then
        logger:dbg("Cannot mix xpointer / non-xpointer sessions")
        return false
    elseif event.xpointer ~= nil and session.start_xpointer == nil then
        logger:dbg("Cannot mix xpointer / non-xpointer sessions")
        return false
    else
        return true
    end
end

---@param since integer
---@return ReadingSession[]
function ReadingSessionRepository:getSessions(since)
    ---@type ReadingSession[]
    local sessions = {}

    for _, event in ipairs(ReadingSessionRepository:getEvents(since)) do
        -- Eventually we could figure out progress from start of page
        -- to end of page?  But for now the simplest is to count
        -- progress as a point-in-time.

        local read_progress = event.page / event.page_count

        -- If existing session, we should update.
        -- We can make the assumption that these are in
        -- order by book ID and start time to simplify.
        local collapsedSession = false

        if #sessions > 0 then

            if isPartOfSession(sessions[#sessions], event) then
                logger:dbg("Collapsed session for book", event.book_md5)
                collapsedSession = true
                sessions[#sessions].end_time = math.max(event.timestamp, sessions[#sessions].end_time)

                -- If the "progress" is further
                if read_progress > sessions[#sessions].end_progress then
                    sessions[#sessions].end_page = event.page
                    sessions[#sessions].end_progress = read_progress
                    sessions[#sessions].end_xpointer = event.xpointer
                end
            end
        end

        if not collapsedSession then
            logger:dbg("New Session found for book", event.book_md5)

            -- If new session, create a new session record
            ---@type ReadingSession
            local new_session = {
                book_md5 = event.book_md5,
                book_partial_md5 = event.book_partial_md5,
                book_path = event.book_path,
                start_time = event.timestamp,
                end_time = event.timestamp,
                start_page = event.page,
                end_page = event.page,
                page_count = event.page_count,
                start_progress = read_progress,
                end_progress = read_progress,
                start_xpointer = event.xpointer,
                end_xpointer = event.xpointer,
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

return ReadingSessionRepository