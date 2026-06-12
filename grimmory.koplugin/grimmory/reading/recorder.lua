local GrimmoryCFIResolver = require("grimmory/cfi_resolver")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class ReadingRecorder
---@field repository GrimmoryLocalRepository
---@field ui any
---@field last_page integer | nil
---@field session_book_path string | nil
---@field session_id integer | nil
local ReadingRecorder = {}

function ReadingRecorder:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function ReadingRecorder:init()

end

---@return number page
function ReadingRecorder:getOpenBookCurrentPage()
    if not self.ui then
        -- Not in a document or something else has gone wrong.
        return 0
    end

    return self.ui:getCurrentPage()
end

---@return number page_count
function ReadingRecorder:getOpenBookTotalPages()
    if not self.ui or not self.ui.document then
        return 0
    end

    return self.ui.document:getPageCount()
end

function ReadingRecorder:getOpenBookReadPercent()
    if not self.ui or not self.ui.document then
        return 0
    end

    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastPercent()
    else
        return self.ui.rolling:getLastPercent()
    end
end

---@return string | nil xpointer
function ReadingRecorder:getOpenBookXPointer()
    if not self.ui or not self.ui.document or self.ui.document.info.has_pages then
        return nil
    end

    return self.ui.rolling:getLastProgress()
end

function ReadingRecorder:getOpenBookCFI()
    if not self.ui or not self.ui.document or self.ui.document.info.has_pages then
        return nil
    end

    local xpointer = self.ui.rolling:getLastProgress()

    if xpointer == nil then
        return nil
    end

    local cfi_resolver = GrimmoryCFIResolver:new(self.ui.document)

    local ok, cfi = pcall(cfi_resolver.xpointerToCFI, cfi_resolver, xpointer)

    if not ok then
        logger:err("Could not convert xpointer:", cfi)
        return nil
    end

    return cfi
end

---@return string | nil book_path current book path
function ReadingRecorder:getOpenBookPath()
    if not self.ui or not self.ui.document then
        return nil
    end

    return self.ui.document.file
end

---@param session_id number
---@param event_type ReadingSessionEventType
function ReadingRecorder:emitSessionEvent(session_id, event_type)
    local current_page = self:getOpenBookCurrentPage()
    local total_pages = self:getOpenBookTotalPages()
    local xpointer = self:getOpenBookXPointer()
    local cfi = self:getOpenBookCFI()

    self.repository:insertBookEvent(session_id, event_type, current_page, total_pages, xpointer, cfi)
end

function ReadingRecorder:onSessionStart()
    local book_path = self:getOpenBookPath()

    if self.session_id ~= nil then
        if book_path ~= self.session_book_path then
            -- If the session is active and the book path has changed we
            -- somehow missed the end session event
            self:onSessionEnd()
        else
            return
        end
    end

    if self.session_id ~= nil then
        -- If an existing session exists, do nothing
        return
    end

    if not book_path then
        logger:dbg("No book currently open for session, skipping")
        return
    end

    local book_ok, book_id = self.repository:upsertBook(book_path)
    if not book_ok or not book_id then
        logger:err("Failed to create session for book:", book_path)
        return
    end

    local new_session_ok, new_session_id = self.repository:insertSession(book_id)
    if not new_session_ok or not new_session_id then
        logger:err("Failed to create session for book:", book_path)
        return
    end

    self.session_id = new_session_id
    self.session_book_path = book_path

    self:emitSessionEvent(self.session_id, "session-start")
end

function ReadingRecorder:onPageUpdate()
    -- If the session is active and the book path has changed we
    -- somehow missed the end session event
    local book_path = self:getOpenBookPath()
    if self.session_id and book_path ~= self.session_book_path then
        self:onSessionEnd()
    end

    local current_page = self:getOpenBookCurrentPage()
    if current_page == self.last_page then
        -- In some cases we get duplicate page update events
        -- This filters them out.
        return
    end

    -- Kick the session start in case it needs to be started
    self:onSessionStart()

    self.last_page = current_page


    self:emitSessionEvent(self.session_id, "page")
end

function ReadingRecorder:onSessionEnd()
    if self.session_id ~= nil then
        self:emitSessionEvent(self.session_id, "session-end")
    end

    self.last_page = nil
    self.session_id = nil
    self.session_book_path = nil
end

return ReadingRecorder