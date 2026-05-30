local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local util = require("util")

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
---@field grimmory_id number | nil
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
---@field grimmory_id number | nil
---@field book_md5 string
---@field book_path string
---@field timestamp number
---@field page number
---@field page_count number
---@field xpointer string | nil

---@class ReadingSessionProgress
---@field grimmory_id number | nil
---@field book_md5 string
---@field book_path string
---@field end_time number
---@field end_progress number
---@field end_page number | nil
---@field end_xpointer string | nil

---@class GrimmoryLocalRepository
---@field migrations_path string
---@field database_path string
local GrimmoryLocalRepository = {
    migrations_path = getPluginPath() .. "/grimmory/migrations/",
    database_path =  DataStorage:getSettingsDir() .. "/grimmory.sqlite3",
}

function GrimmoryLocalRepository:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryLocalRepository:getMigrations()
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

function GrimmoryLocalRepository:runMigrations()
    local sql_files = self:getMigrations()

    for _, sql_filepath in ipairs(sql_files) do
        local sql = util.readFromFile(sql_filepath, "r")
        logger:dbg("Running SQL file path:", sql_filepath)

        if sql ~= nil then
            self:withDatabase(
                function(database)
                    database:exec(sql)
                end,
                "rwc"
            )
        end
    end
end

function GrimmoryLocalRepository:init()
    self:runMigrations()
end

---@generic T
---@param callback (fun(database: any) | fun(database: any): `T`)
---@param flags? "ro" | "rw" | "rwc"
---@return boolean ok
---@return T result
function GrimmoryLocalRepository:withDatabase(callback, flags)
    if flags == nil then
        flags = "ro"
    end

    local database = SQ3.open(
        self.database_path,
        flags
    )
    database:set_busy_timeout(1000)

    local ok, result = pcall(callback, database)

    database:close()

    return ok, result
end

---@param book_path string
---@param grimmory_id number | nil
---@return boolean ok
---@return integer | nil book_id
function GrimmoryLocalRepository:upsertBook(book_path, grimmory_id)
    local partial_md5 = util.partialMD5(book_path)

    local ok, book_id = self:withDatabase(
        function(conn)
            -- Remember that `OR IGNORE` will ignore almost all
            -- data type or constraint failures.
            local insert_stmt = conn:prepare([[
                INSERT OR IGNORE INTO book
                    (
                        book_path,
                        partial_md5
                    )
                VALUES (?, ?);
            ]])

            insert_stmt:bind(book_path, partial_md5)
            insert_stmt:step()
            insert_stmt:close()

            -- Cannot use last row ID because it's possible this book
            -- already had existed.
            local select_stmt = conn:prepare([[
                SELECT
                    id,
                    grimmory_id
                FROM book
                WHERE book_path = ? AND partial_md5 = ?
            ]])

            select_stmt:bind(book_path, partial_md5)
            local row = select_stmt:step()
            select_stmt:close()

            if not row then
                return error("Error during re-select insert")
            end

            local book_id = tonumber(row[1])
            local existing_grimmory_id = tonumber(row[2])

            if existing_grimmory_id ~= grimmory_id and grimmory_id ~= nil then
                local update_stmt = conn:prepare([[
                    UPDATE book
                    SET
                        grimmory_id = ?
                    WHERE
                        id = ?
                ]])

                update_stmt:bind(grimmory_id, book_id)
                update_stmt:step()
                update_stmt:close()
            end

            return book_id
        end,
        "rw"
    )

    if not ok or not book_id then
        logger:err("Failed to upsert book:", book_path, "-", book_id)
        return false, nil
    end

    return true, book_id
end

---@param grimmory_id number
---@return boolean ok
---@return string | nil book_path
---@return string | nil book_md5
function GrimmoryLocalRepository:getBookInfo(grimmory_id)
    local ok, book = self:withDatabase(
        function(conn)
            local select_stmt = conn:prepare([[
                SELECT
                    book_path,
                    partial_md5
                FROM book
                WHERE
                    grimmory_id = ?
            ]])

            select_stmt:bind(grimmory_id)
            local row = select_stmt:step()
            select_stmt:close()

            if not row then
                return error("Not Found")
            end

            return {
                book_path = row[1],
                book_md5 = row[2],
            }
        end
    )

    if not ok or not book then
        logger:err("Failed to find book:", grimmory_id, "-", book)
        return false, nil, nil
    end

    return true, book.book_path, book.book_md5
end

---@param book_id number
---@return boolean ok
---@return integer | nil session_id
function GrimmoryLocalRepository:insertSession(book_id)
    local ok, session_id = self:withDatabase(
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
function GrimmoryLocalRepository:insertBookEvent(session_id, event_type, current_page, page_count, xpointer)
    local ok, result = self:withDatabase(
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

---@param book_id number
---@param cutoff number | nil
---@return boolean ok
---@return ReadingSessionProgress | nil progress
function GrimmoryLocalRepository:getReadingProgress(book_id, cutoff)
    local ok, result = self:withDatabase(
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    book.grimmory_id,
                    book.book_path,
                    book.partial_md5,

                    book_event.created_at,
                    book_event.current_page,
                    book_event.page_count,
                    book_event.xpointer
                FROM (
                    SELECT
                        s.book_id,
                        MAX(e.id) AS event_id
                    FROM book_event e
                    JOIN book_session s ON s.id = e.session_id
                    WHERE
                        e.created_at < ?
                    GROUP BY s.book_id
                ) AS last_event
                JOIN book_event ON last_event.event_id = book_event.id
                JOIN book_session ON book_event.session_id = book_session.id
                JOIN book ON book_session.book_id = book.id
                WHERE
                    book.id = ?
            ]])

            if cutoff == nil then
                cutoff = os.time()
            end

            stmt:bind(cutoff, book_id)

            local row = stmt:step()
            stmt:close()

            if row == nil then
                return nil
            end

            local end_time = tonumber(row[4], 10) or 0
            local end_page = tonumber(row[5]) or 0
            local page_count = tonumber(row[6]) or 0

            local end_progress = 0

            if page_count > 0 then
                end_progress = (end_page / page_count) * 100
            end

            return {
                grimmory_id = tonumber(row[1]),
                book_path = row[2],
                book_md5 = row[3],
                end_time = end_time,
                end_page = end_page,
                end_progress = end_progress,
                end_xpointer = row[7],
            }
        end
    )

    if not ok then
        logger:err("Failed to get reading progress:", book_id, "-", result)
        return ok, nil
    end

    return ok, result
end

---@param book_id integer
---@return ReadingSessionEvent[]
function GrimmoryLocalRepository:getPendingSessionEvents(book_id)
    local ok, results = self:withDatabase(
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    b.grimmory_id,
                    b.book_path,
                    b.partial_md5,

                    e.session_id,
                    e.event_type,
                    e.created_at,
                    e.current_page,
                    e.page_count,
                    e.xpointer
                FROM book AS b
                LEFT JOIN book_sync_status AS bss
                    ON bss.book_id = b.id AND bss.sync_type = "sessions"
                JOIN book_session AS s ON s.book_id = b.id
                JOIN book_event AS e ON e.session_id = s.id
                WHERE
                    e.created_at > COALESCE(bss.last_synced_at, 0)
                    AND
                    b.id = ?
                ORDER BY b.id ASC, e.created_at ASC
            ]])

            stmt:bind(book_id)

            ---@type ReadingSessionEvent[]
            local results = {}

            for row in stmt:rows() do
                ---@type ReadingSessionEvent
                local event = {
                    grimmory_id = tonumber(row[1]),
                    book_path = row[2],
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

---@param book_id integer
---@return ReadingSession[]
function GrimmoryLocalRepository:getPendingSessions(book_id)
    ---@type ReadingSession[]
    local sessions = {}

    for _, event in ipairs(self:getPendingSessionEvents(book_id)) do
        -- Eventually we could figure out progress from start of page
        -- to end of page?  But for now the simplest is to count
        -- progress as a point-in-time.

        -- Percentage read via page count.
        local read_progress = 0
        if event.page_count > 0 then
            read_progress = (event.page / event.page_count) * 100
        end

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
                grimmory_id = event.grimmory_id,
                book_md5 = event.book_md5,
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

---@alias RepositorySyncType
---| "progress"
---| "sessions"

---@param book_id number
---@param sync_type RepositorySyncType
---@param timestamp number
function GrimmoryLocalRepository:updateBookSyncTimestamp(book_id, sync_type, timestamp)
    local ok, message = self:withDatabase(
        function(conn)
            local stmt = conn:prepare([[
                INSERT INTO book_sync_status
                    (book_id, sync_type, last_synced_at)
                VALUES (
                    ?,
                    ?,
                    ?
                )
                ON CONFLICT (book_id, sync_type)
                DO UPDATE SET
                    last_synced_at = excluded.last_synced_at
            ]])

            stmt:bind(
                book_id,
                sync_type,
                timestamp
            )
            stmt:step()
            stmt:close()
        end,
        "rw"
    )

    if not ok then
        logger:err("Failed to update book synced at:", book_id, "-", message)
        return false
    end

    return true

end

---@param with_sessions boolean
---@param with_progress boolean
---@return number[] book_ids
function GrimmoryLocalRepository:getBooksPendingSync(
    with_sessions,
    with_progress
)
    local ok, book_ids = self:withDatabase(
        function(conn)
            local stmt = conn:prepare([[
                SELECT
                    book.id
                FROM book
                JOIN book_session ON book.id = book_session.book_id
                JOIN book_event ON book_session.id = book_event.session_id
                LEFT JOIN book_sync_status AS sync_sessions
                    ON book.id = sync_sessions.book_id AND sync_sessions.sync_type = "sessions"
                LEFT JOIN book_sync_status AS sync_progress
                    ON book.id = sync_progress.book_id AND sync_progress.sync_type = "progress"
                WHERE
                    grimmory_id IS NOT NULL
                    AND
                    (
                        (
                            ? = 1
                            AND
                            book_event.created_at > COALESCE(sync_sessions.last_synced_at, 0)
                        )
                        OR
                        (
                            ? = 1
                            AND
                            book_event.created_at > COALESCE(sync_progress.last_synced_at, 0)
                        )
                    )
                GROUP BY book.id
            ]])

            stmt:bind(with_sessions and 1 or 0, with_progress and 1 or 0)

            ---@type number[]
            local results = {}

            for row in stmt:rows() do
                local book_id = tonumber(row[1])

                if book_id then
                    table.insert(results, book_id)
                end
            end

            stmt:close()

            return results
        end
    )

    if not ok or not book_ids then
        logger:err("Failed to get books for sync", book_ids)
        return {}
    end

    return book_ids
end

return GrimmoryLocalRepository