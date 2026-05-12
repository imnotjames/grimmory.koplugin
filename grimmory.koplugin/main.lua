local _ = require("gettext")
local T = require("ffi/util").template

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmoryDialogManager = require("grimmory/ui/dialog_manager")
local GrimmoryMenu = require("grimmory/ui/menu")
local GrimmoryWifiManager = require("grimmory/wifi_manager")
local GrimmorySettings = require("grimmory/settings")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")
local GrimmoryScheduler = require("grimmory/scheduler")
local GrimmoryReadingSessions = require("grimmory/reading_sessions")

local logger = require("grimmory/logger").new("Grimmory")

local Grimmory = WidgetContainer:extend{
    name = "grimmory",
    is_doc_only = false,
    is_stub = false,
    periodic_sync_cancel = nil,
    periodic_sync_update = nil,
    wifi_manager = nil,
    dialog_manager = nil,
    scheduler = nil,
    menu = nil,
    synchronizer = nil,
}

function Grimmory:onDispatcherRegisterActions()
  Dispatcher:registerAction("grimmory_sync", {
    category = "none",
    event = "GrimmorySync",
    title = _("Grimmory: Sync Now"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_settings", {
    category = "none",
    event = "GrimmorySettingsChanged",
    title = _("Grimmory: Settings Changed"),
    general = true,
  })
end

function Grimmory:init()
    self.scheduler = GrimmoryScheduler:new()
    self.settings = GrimmorySettings:new()

    self.reading_sessions = GrimmoryReadingSessions:new()

    self.api = GrimmoryAPI:new({
        settings = self.settings
    })

    self.dialog_manager = GrimmoryDialogManager:new({
        settings = self.settings,
        api = self.api,
    })

    self.wifi_manager = GrimmoryWifiManager:new({
        settings = self.settings
    })

    self.menu = GrimmoryMenu:new({
        settings = self.settings,
        dialog_manager = self.dialog_manager,
    })

    self.synchronizer = GrimmorySynchronize:new({
        settings = self.settings,
        reading_sessions = self.reading_sessions,
        api = self.api,
    })

    self:onGrimmorySettingsChanged()

    self.ui.menu:registerToMainMenu(self.menu)

    self:onDispatcherRegisterActions()

    logger:dbg("Initialized")
end

function Grimmory:onExit()
    logger:dbg("Exiting")

    self.scheduler:clear()
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")

    if self.settings:getSyncOnSuspend() then
       self:onGrimmorySync()
    end
end

function Grimmory:onPowerOff()
    logger:dbg("Device is powering off")

    if self.settings:getSyncOnPowerOff() then
       self:onGrimmorySync()
    end
end

function Grimmory:onReaderReady()
    logger:dbg("Document open and ready")
end

function Grimmory:onCloseDocument()
    logger:dbg("Document closing")

    if self.settings:getSyncOnCloseDocument() then
        -- Do not block the UI thread
        UIManager:nextTick(function()
            self:onGrimmorySync()
        end)
    end
end

function Grimmory:onGrimmorySettingsChanged()
    logger:dbg("Settings Changed")

    self:onSchedulePeriodicPush()
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
                    self:onGrimmorySync()
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

function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false
    end

    return true
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

        if verbose then
            self.dialog_manager:toast(
                _("Starting Grimmory sync...")
            )
        end

        local sessionCount = 0
        local sessionErrorCount = 0
        local bookCount = 0
        local bookErrorCount = 0

        -- In the future, we should limit what we sync
        -- to current or recent books.  For now, we sync everything.

        local ok, result = pcall(function()
            self.synchronizer:synchronizeAll(
                function(progress)
                    if progress.since then
                        -- Update since
                        self.settings:setSynchronizedUntil(progress.since)
                    end

                    if progress.state == "session-recorded" then
                        sessionCount = sessionCount + 1
                    elseif progress.state == "session-error" then
                        sessionErrorCount = sessionErrorCount + 1
                    elseif progress.state == "book-downloaded" then
                        bookCount = bookCount + 1
                    elseif progress.state == "book-error" then
                        bookErrorCount = bookErrorCount + 1
                    end
                end
            )
        end)

        if not ok then
            logger:err("Failed sync", result)

            if verbose then
                self.dialog_manager:toast(
                    T(_("Failed to Synchronize to Grimmory"))
                )
            end

            return
        end

        if verbose then
            local message
            if sessionErrorCount > 0 or bookErrorCount > 0 then
                message = T(
                    _("Completed Grimmory sync\n%1 session(s) recorded\n%2 session(s) failed\n%3 book(s) downloaded\n%4 book(s) failed"),
                    sessionCount,
                    sessionErrorCount,
                    bookCount,
                    bookErrorCount
                )
            else
                message = T(
                    _("Completed Grimmory sync\n%1 session(s) recorded\n%2 book(s) downloaded"),
                    sessionCount,
                    bookCount
                )
            end

            self.dialog_manager:toast(message)
        end
    end

    if self.settings:getSyncEnableWifi() then
        self.wifi_manager:withWifi(sync_callback)
    else
        UIManager:nextTick(sync_callback)
    end
end

return Grimmory