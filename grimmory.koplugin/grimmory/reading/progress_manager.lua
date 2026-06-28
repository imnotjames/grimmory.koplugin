local Event = require("ui/event")
local util = require("util")
local md5 = require("ffi/sha2").md5

local DocMetadata = require("grimmory/doc_metadata")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@param progress_a ReadingSessionProgress | nil
---@param progress_b ReadingSessionProgress | nil
---@return number comparison
local function compareProgress(progress_a, progress_b)
    if progress_a == nil and progress_b == nil then
        return 0
    elseif progress_b == nil then
        return -1
    elseif progress_a == nil then
        return 1
    end

    -- If the two progress values are very close to each other just say they're
    -- the same.
    if progress_b.end_xpointer ~= nil and progress_b.end_xpointer == progress_a.end_xpointer then
        return 0
    elseif math.abs(progress_b.end_progress - progress_a.end_progress) < 0.01 then
        return 0
    end

    -- Otherwise, suggest if newer.
    if progress_a.end_time == progress_b.end_time then
        return 0
    elseif progress_a.end_time < progress_b.end_time then
        return 1
    else
        return -1
    end
end

---@class ReadingProgressManager
---@field ui any
---@field api GrimmoryAPI
---@field repository GrimmoryLocalRepository
---@field settings GrimmorySettings
---@field reading_recorder ReadingRecorder
---@field private koreader_auth_id string | nil
---@field private koreader_auth_secret_md5 string | nil
local ReadingProgressManager = {}

function ReadingProgressManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function ReadingProgressManager:getNewerProgressForBook(book_path)
    -- Skip most recent session
    local local_progress = self:getLocalProgressForBook(book_path)
    local remote_name, remote_id, remote_progress = self:getRemoteProgressForBook(book_path)

    if compareProgress(local_progress, remote_progress) <= 0 then
        logger:dbg("No new progress for book:", book_path)
        return nil, nil, nil
    end

    return remote_name, remote_id, remote_progress
end

---@return ReadingSessionProgress | nil progress
function ReadingProgressManager:getLocalProgressForBook(book_path)
    local ok, book_id = self.repository:upsertBook(book_path)

    if not ok or book_id == nil then
        return nil
    end

    if self.ui.document and book_path == self.ui.document.file then
        -- This is a bit of a hack to handle the fact that the page event
        -- is fired before the reader is ready.
        -- Look back 30 seconds so the "current" session isn't counted
        local _, progress = self.repository:getReadingProgress(book_id, os.time() - 30)

        return progress
    else
        local _, progress = self.repository:getReadingProgress(book_id)

        return progress
    end
end

---@private
---@return string | nil koreader_auth_id
---@return string | nil koreader_auth_secret_md5
function ReadingProgressManager:getCredentials()
    if self.koreader_auth_id and self.koreader_auth_secret_md5 then
        return self.koreader_auth_id, self.koreader_auth_secret_md5
    end

    local sync_ok, sync_enabled = self.api:getKoreaderSync()

    if not sync_ok then
        logger:err("Could not read sync status")
        return nil, nil
    end

    if not sync_enabled then
        -- If sync isn't enabled, let's try to enable it.
        local ok = self.api:setKoreaderSync(true)

        if not ok then
            logger:err("Failed to set koreader sync status")
            return nil, nil
        end
    end

    -- Get recent progress records
    local credentials_ok, koreader_auth_id, koreader_auth_secret = self.api:getKoreaderCredentials()

    if not credentials_ok then
        logger:err("Failed to get koreader sync credentials")
        return nil, nil
    end

    local koreader_auth_secret_md5 = md5(koreader_auth_secret)

    self.koreader_auth_id = koreader_auth_id
    self.koreader_auth_secret_md5 = koreader_auth_secret_md5

    return koreader_auth_id, koreader_auth_secret_md5
end

---@param progress ReadingSessionProgress
function ReadingProgressManager:pushRemoteProgress(progress)
    local koreader_auth_id, koreader_auth_secret = self:getCredentials()

    if koreader_auth_id == nil or koreader_auth_secret == nil then
        logger:dbg("Skipping progress push because no credentials")
        return
    end

    local device_name = self.settings:getDeviceName()
    local device_id = self.settings:getDeviceId()

    local ok, result = self.api:pushReadingProgress(
        koreader_auth_id,
        koreader_auth_secret,
        device_name,
        device_id,
        progress.book_md5,
        progress.end_time,
        progress.end_progress / 100,
        progress.end_xpointer or progress.end_page
    )

    if not ok then
        self.koreader_auth_id = nil
        self.koreader_auth_secret_md5 = nil
    end

    return ok, result
end

---@return string | nil source_name
---@return string | nil source_id
---@return ReadingSessionProgress | nil progress
function ReadingProgressManager:getRemoteProgressForBook(book_path)
    local koreader_auth_id, koreader_auth_secret = self:getCredentials()

    if koreader_auth_id == nil or koreader_auth_secret == nil then
        logger:dbg("Skipping progress push because no credentials")
        return nil, nil, nil
    end

    local partial_md5 = util.partialMD5(book_path)
    if partial_md5 == nil then
        return nil, nil, nil
    end

    local ok, progress = self.api:getReadingProgress(
        koreader_auth_id,
        koreader_auth_secret,
        partial_md5
    )

    if not ok or type(progress) == "string" then
        self.koreader_auth_id = nil
        self.koreader_auth_secret_md5 = nil

        logger:err("Failed to get progress")
        return nil, nil, nil
    end

    if progress == nil then
        -- There's just no progress
        return nil, nil, nil
    end

    if type(progress.percentage) ~= "number" then
        -- This is sometimes a `json.util.null` - perhaps if the record
        -- exists but has been reset?  The value is `null` in the JSON
        return nil, nil, nil
    end

    local source_name = progress.device or "Unknown Device"
    local source_id = progress.device_id or ""

    local xpointer = nil
    local page = tonumber(progress.progress, 10)

    if page == nil then
        xpointer = progress.progress
    end

    ---@type ReadingSessionProgress
    local source_progress = {
        book_path = book_path,
        book_md5 = progress.document,
        end_time = progress.timestamp,
        end_progress = progress.percentage * 100,
        end_page = page,
        end_xpointer = xpointer,
    }

    return source_name, source_id, source_progress
end

---@param progress ReadingSessionProgress
function ReadingProgressManager:applyProgress(progress)
    -- If book path is the currently open book, use the go to command
    -- DocMetadata -> "last_xpointer" to progress
    if self.ui.document and progress.book_path == self.ui.document.file then
        self.reading_recorder:onSessionEnd()

        if self.ui.document.info.has_pages then
            if progress.end_page then
                self.ui:handleEvent(Event:new("GotoPage", tonumber(progress.end_page)))
                return
            end
        else
            if progress.end_xpointer then
                self.ui:handleEvent(Event:new("GotoXPointer", progress.end_xpointer))
                return
            end
        end

        self.ui:handleEvent(Event:new("GoToPercent", tonumber(progress.end_progress)))
    else
        -- Write doc metadata
        DocMetadata:setProgress(
            progress.book_path,
            progress.end_progress,
            progress.end_xpointer,
            progress.end_page
        )
    end
end

return ReadingProgressManager
