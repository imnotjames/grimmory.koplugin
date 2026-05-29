--[[--
Grimmory KOReader Plugin

@module koplugin.Grimmory
--]]--
local _ = require("gettext")
local T = require("ffi/util").template

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmoryBookResolver = require("grimmory/book_resolver")
local GrimmoryDialogManager = require("grimmory/ui/dialog_manager")
local GrimmoryExecutor = require("grimmory/executor")
local GrimmoryMenu = require("grimmory/ui/menu")
local GrimmoryWifiManager = require("grimmory/wifi_manager")
local GrimmorySettings = require("grimmory/settings")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")
local GrimmoryScheduler = require("grimmory/scheduler")
local GrimmorySelfUpdater = require("grimmory/ota/self_updater")
local GithubAPI = require("grimmory/ota/github_api")
local GrimmoryLogger = require("grimmory/logger")
local GrimmoryReadingRecorder = require("grimmory/reading/recorder")
local GrimmoryReadingSessions = require("grimmory/reading/repository")
local GrimmoryReadingProgressManager = require("grimmory/reading/progress_manager")


local logger = GrimmoryLogger:new()

---@class Grimmory
---@field wifi_manager WifiManager
---@field dialog_manager DialogManager
---@field scheduler GrimmoryScheduler
---@field synchronizer GrimmorySynchronize
---@field ui any This is a ReaderUI
local Grimmory = WidgetContainer:extend{
    name = "grimmory",
    is_doc_only = false,
    periodic_sync_cancel = nil,
    periodic_sync_update = nil,
    release_check_cancel = nil,
    menu = nil,
}

function Grimmory:onDispatcherRegisterActions()
  Dispatcher:registerAction("grimmory_sync_foreground", {
    category = "none",
    event = "GrimmorySyncForegound",
    title = _("Grimmory: Sync Now"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_background", {
    category = "none",
    event = "GrimmorySyncBackground",
    title = _("Grimmory: Sync in Background"),
    general = true,
  })
end

function Grimmory:init()
    self.scheduler = GrimmoryScheduler:new()
    self.settings = GrimmorySettings:new()

    self.reading_sessions = GrimmoryReadingSessions:new({
        settings = self.settings,
    })

    self.reading_recorder = GrimmoryReadingRecorder:new({
        repository = self.reading_sessions,
        settings = self.settings,
        ui = self.ui,
    })

    self.updater = GrimmorySelfUpdater:new({
        github_api = GithubAPI:new(),
        settings = self.settings,
        scheduler = self.scheduler,
    })

    self.api = GrimmoryAPI:new({
        settings = self.settings
    })

    self.book_resolver = GrimmoryBookResolver:new()

    self.reading_progress_manager = GrimmoryReadingProgressManager:new({
        ui = self.ui,
        api = self.api,
        settings = self.settings,
        reading_sessions = self.reading_sessions,
    })

    self.dialog_manager = GrimmoryDialogManager:new({
        settings = self.settings,
        api = self.api,
        updater = self.updater,
        reading_progress_manager = self.reading_progress_manager,
    })

    self.wifi_manager = GrimmoryWifiManager:new({
        settings = self.settings
    })

    self.menu = GrimmoryMenu:new({
        settings = self.settings,
        dialog_manager = self.dialog_manager,
        updater = self.updater,
    })

    self.synchronizer = GrimmorySynchronize:new({
        settings = self.settings,
        reading_sessions = self.reading_sessions,
        api = self.api,
        book_resolver = self.book_resolver,
        reading_progress_manager = self.reading_progress_manager,
    })

    self.executor = GrimmoryExecutor:new()

    self:onGrimmorySettingsChanged()

    self.ui.menu:registerToMainMenu(self.menu)

    self:onDispatcherRegisterActions()

    logger:dbg("Initialized")
end

function Grimmory:onExit()
    logger:dbg("Exiting")

    self.scheduler:clear()
    self.executor:clear()
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnSuspend() then
       self:onGrimmorySync(false)
    end
end

function Grimmory:onResume()
    logger:dbg("Device is resuming")

    if self.settings:getSyncReadingProgress() then
        self:syncProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()
end

function Grimmory:onPowerOff()
    logger:dbg("Device is powering off")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnPowerOff() then
       self:onGrimmorySync(false)
    end
end

function Grimmory:onReaderReady()
    logger:dbg("Document open and ready")

    if self.settings:getSyncReadingProgress() then
        self:syncProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()
end

function Grimmory:onPageUpdate(page)
    logger:dbg("Page Update", page)

    -- Run after everything else does for a page event.
    -- This prevents issues like the previous page's xpointer being
    -- returned for a given page.
    UIManager:nextTick(function()
        self.reading_recorder:onPageUpdate()
    end)
end

function Grimmory:onCloseDocument()
    logger:dbg("Document closing")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnCloseDocument() then
        -- Do not block the UI thread
        UIManager:nextTick(function()
            self:onGrimmorySync(false)
        end)
    end
end

function Grimmory:onGrimmorySettingsChanged()
    logger:dbg("Settings Changed")

    self:onSchedulePeriodicPush()
    self:onScheduleAutomaticUpdates()
end

function Grimmory:onSchedulePeriodicPush()
    if self.settings:getSyncPeriodically() then
        -- If we want to sync we need to either update
        -- and existing schedule if we already scheduled

        local frequency_seconds = self.settings:getSyncFrequency() * 60

        if self.periodic_sync_update then
            -- We already have an interval set up, so we should update
            -- it with a new frequency
            self.periodic_sync_update(frequency_seconds)
        else
            -- We don't have an existing sync update helper so we need
            -- to schedule a new interval.
            local cancel, update = self.scheduler:interval(
                frequency_seconds,
                function()
                    self:onGrimmorySync(false)
                end
            )

            self.periodic_sync_cancel = cancel
            self.periodic_sync_update = update
        end
    else
        -- We don't want to sync anymore so we need to cancel
        -- if it's defined and clean up the cancel / update props
        if self.periodic_sync_cancel then
            self.periodic_sync_cancel()
        end

        self.periodic_sync_cancel = nil
        self.periodic_sync_update = nil
    end
end

function Grimmory:onScheduleAutomaticUpdates()
    -- If automatic updates is enabled, schedule interval.
    if self.settings:getAutomaticCheckUpdates() then
        if not self.release_check_cancel then
            local cancel, _ = self.scheduler:interval(
                7200,
                self.updater.fetchLatestVersion,
                self.updater
            )

            self.release_check_cancel = cancel
        end

        self.scheduler:schedule(
            5,
            self.updater.fetchLatestVersion,
            self.updater
        )
    else
        if self.release_check_cancel then
            self.release_check_cancel()
        end

        self.release_check_cancel = nil
    end
end

function Grimmory:syncProgressForOpenBook()
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        return
    end

    local book_path = self.ui.document.file

    local callback = function()
        local ok, latest_progress = self.executor:run(
            function()
                local _, _, latest_progress = self.reading_progress_manager:getNewerProgressForBook(book_path)
                return latest_progress
            end
        )

        if not ok or not latest_progress then
            return
        end

        self.dialog_manager:showApplyProgressConfirmation(latest_progress)
    end

    self.executor:wrap(function()
        if self.settings:getSyncEnableWifi() then
            self.wifi_manager:withWifi(callback)
        else
            callback()
        end
    end)
end

function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false
    end

    return true
end

function Grimmory:onGrimmorySyncForegound()
    return self:onGrimmorySync(true)
end

function Grimmory:onGrimmorySyncBackground()
    return self:onGrimmorySync(false)
end

function Grimmory:onGrimmorySync(verbose)
    if not self:isReadyToSync() then
        return false
    end

    local function sync_callback()
        if not self.wifi_manager:isConnected() then
            logger:err("Cannot sync without connectivity")
            return
        end

        logger:info("Synchronizing to Grimmory")

        local should_terminate = false

        local update_callback, close_callback
        if verbose then
            update_callback, close_callback = self.dialog_manager:showProgressDialog(
                _("Synchronizing to Grimmory"),
                function()
                    should_terminate = true
                end,
                _("Are you sure you want to interrupt synchronization?")
            )
        end

        self.menu:onGrimmorySyncStart(function() should_terminate = true end)

        local indeterminate_progress = 0
        local session_count = 0
        local session_error_count = 0
        local book_count = 0
        local book_error_count = 0

        -- In the future, we should limit what we sync
        -- to current or recent books.  For now, we sync everything.

        local ok, result = self.executor:run(
            function(progress_callback)
                self.synchronizer:synchronizeAll(progress_callback)
            end,
            function(progress, terminate)
                if should_terminate then
                    terminate()
                end

                if type(progress) ~= "table" then
                    return
                end

                indeterminate_progress = (indeterminate_progress + 1) % 20
                if update_callback ~= nil then
                    pcall(update_callback, indeterminate_progress, 20)
                end

                if progress.since then
                    -- Update since
                    self.settings:setSynchronizedUntil(progress.since)
                end

                if progress.state == "session-recorded" then
                    session_count = session_count + 1
                elseif progress.state == "session-error" then
                    session_error_count = session_error_count + 1
                elseif progress.state == "book-downloaded" then
                    book_count = book_count + 1

                    if book_count % 20 then
                        -- If we're updating a lot of books we should
                        -- emit a refresh event every once in a while
                        -- so background refresh sees these come
                        -- through quickly
                        UIManager:broadcastEvent(Event:new("RefreshContent"))
                    end

                elseif progress.state == "book-error" then
                    book_error_count = book_error_count + 1
                end
            end
        )

        if close_callback then
            close_callback()
        end

        if not ok then
            if should_terminate then
                logger:info("Sync was interrupted by user")

                if verbose then
                    self.dialog_manager:toast(
                        _("Grimmory synchronization has been interrupted")
                    )
                end
            else
                logger:err("Failed sync", result)

                if verbose then
                    self.dialog_manager:toast(
                        _("Failed to Synchronize to Grimmory")
                    )
                end
            end

            return
        end

        if book_count > 0 then
            -- If we have any books downloaded we need to emit a refresh
            -- event so the file manager knows it should refresh
            UIManager:broadcastEvent(Event:new("RefreshContent"))
        end

        if verbose then
            local message
            if session_error_count > 0 or book_error_count > 0 then
                message = T(
                    _(
                        "Completed Grimmory sync\n" ..
                        "%1 session(s) recorded\n" ..
                        "%2 session(s) failed\n" ..
                        "%3 book(s) downloaded\n" ..
                        "%4 book(s) failed"
                    ),
                    session_count,
                    session_error_count,
                    book_count,
                    book_error_count
                )
            else
                message = T(
                    _("Completed Grimmory sync\n%1 session(s) recorded\n%2 book(s) downloaded"),
                    session_count,
                    book_count
                )
            end

            self.dialog_manager:toast(message)
        end

        self.menu:onGrimmorySyncComplete()
    end

    self.executor:wrap(function()
        if self.settings:getSyncEnableWifi() then
            self.wifi_manager:withWifi(sync_callback)
        else
            sync_callback()
        end
    end)
end

return Grimmory