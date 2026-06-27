--[[--
Grimmory KOReader Plugin

@module koplugin.Grimmory
--]]--
local _ = require("gettext")
local T = require("ffi/util").template

local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ReadCollection = require("readcollection")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmoryDocMetadata = require("grimmory/doc_metadata")
local GrimmoryDialogManager = require("grimmory/ui/dialog_manager")
local GrimmoryExecutor = require("grimmory/executor")
local GrimmoryMenu = require("grimmory/ui/menu")
local GrimmorySettings = require("grimmory/settings")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")
local GrimmoryScheduler = require("grimmory/scheduler")
local GrimmorySelfUpdater = require("grimmory/ota/self_updater")
local GithubAPI = require("grimmory/ota/github_api")
local GrimmoryLogger = require("grimmory/logger")
local GrimmoryReadingRecorder = require("grimmory/reading/recorder")
local GrimmoryLocalRepository = require("grimmory/repository")
local GrimmoryReadingProgressManager = require("grimmory/reading/progress_manager")


local logger = GrimmoryLogger:new()

---@class Grimmory
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
    is_synchronizing = false,
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

  Dispatcher:registerAction("grimmory_sync_open_book_foreground", {
    category = "none",
    event = "GrimmorySyncOpenBookForeground",
    title = _("Grimmory: Sync Open Book Now"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_open_book_background", {
    category = "none",
    event = "GrimmorySyncOpenBookBackground",
    title = _("Grimmory: Sync Open Book in Background"),
    general = true,
  })
end

function Grimmory:init()
    self.scheduler = GrimmoryScheduler:new()
    self.settings = GrimmorySettings:new()

    self.repository = GrimmoryLocalRepository:new({
        settings = self.settings,
    })

    self.doc_metadata = GrimmoryDocMetadata:new({
        ui = self.ui,
    })

    self.reading_recorder = GrimmoryReadingRecorder:new({
        repository = self.repository,
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

    self.reading_progress_manager = GrimmoryReadingProgressManager:new({
        ui = self.ui,
        api = self.api,
        settings = self.settings,
        repository = self.repository,
    })

    self.dialog_manager = GrimmoryDialogManager:new({
        settings = self.settings,
        api = self.api,
        updater = self.updater,
        reading_progress_manager = self.reading_progress_manager,
    })

    self.menu = GrimmoryMenu:new({
        ui = self.ui,
        settings = self.settings,
        dialog_manager = self.dialog_manager,
        updater = self.updater,
    })

    self.synchronizer = GrimmorySynchronize:new({
        settings = self.settings,
        repository = self.repository,
        api = self.api,
        doc_metadata = self.doc_metadata,
        reading_progress_manager = self.reading_progress_manager,
    })

    self.executor = GrimmoryExecutor:new()

    self:onGrimmorySettingsChanged()

    self.ui.menu:registerToMainMenu(self.menu)

    FileManager:addFileDialogButtons(
        "grimmory_actions",
        function(file, is_file)
            if not is_file then
                return nil
            end

            return {
                {
                    text = _("Sync with Grimmory"),
                    callback = function()
                        local file_chooser = FileManager.instance.file_chooser

                        if file_chooser and file_chooser.file_dialog then
                            UIManager:close(file_chooser.file_dialog)
                        end

                        self:onGrimmorySync(true, file)
                    end,
                },
                {
                    text = _("Reload from Grimmory"),
                    callback = function()
                        local file_chooser = FileManager.instance.file_chooser

                        if file_chooser and file_chooser.file_dialog then
                            UIManager:close(file_chooser.file_dialog)
                        end

                        -- Mark book for refresh
                        self:onGrimmorySync(true, file, true)
                    end
                }
            }
        end
    )

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
        self:pullProgressForOpenBook()
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
        self:pullProgressForOpenBook()
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

function Grimmory:onAnnotationsModified(annotation_info)
    logger:dbg("Annotations modified", annotation_info)

    -- annotation is at annotation_info[1]

    if annotation_info.index_modified == nil then
        self.reading_recorder:onAnnotationUpdated()
    elseif annotation_info.index_modified < 0 then
        self.reading_recorder:onAnnotationRemoved()
    else
        self.reading_recorder:onAnnotationAdded()
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

function Grimmory:pullProgressForOpenBook()
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        return
    end

    local book_path = self.ui.document.file

    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    self.executor:background(
        function(run)
            local ok, latest_progress = run(
                function()
                    local _, _, latest_progress = self.reading_progress_manager:getNewerProgressForBook(book_path)
                    return latest_progress
                end
            )

            if not ok or not latest_progress then
                return
            end

            self.dialog_manager:showApplyProgressConfirmation(latest_progress)
        end,
        self.settings:getSyncEnableWifi()
    )
end

function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false
    end

    if self.is_synchronizing then
        logger:info("Synchronization is already happening, not ready to sync again")
        return false
    end

    return true
end

function Grimmory:isWifiConnected()
    local ok, result = pcall(function()
        return NetworkManager:isConnected()
    end)

    if not ok then
        logger:err("Something went wrong checking wifi connectivity", result)
        return true
    end

    return result
end

function Grimmory:onGrimmorySyncForegound()
    return self:onGrimmorySync(true)
end

function Grimmory:onGrimmorySyncBackground()
    return self:onGrimmorySync(false)
end

function Grimmory:onGrimmorySyncOpenBookForeground()
    return self:onGrimmorySyncOpenBook(true)
end

function Grimmory:onGrimmorySyncOpenBookBackground()
    return self:onGrimmorySyncOpenBook(false)
end

function Grimmory:onGrimmorySyncOpenBook(verbose)
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        logger:info("No open book, skipping sync")
        return
    end

    local book_path = self.ui.document.file

    return self:onGrimmorySync(verbose, book_path)
end

function Grimmory:refreshUI()
   if self.ui == nil then
        return
    end

    if self.ui.document == nil or self.ui.document.file == nil then
        logger:dbg("No file is open, cannot refresh")
        return
    end

    local settings = self.doc_metadata:getDocSettings(self.ui.document.file, true)

    if self.ui.annotation then
        -- Refresh annotations for any open document
        self.ui.annotation.annotations = settings:readSetting("annotations")
        pcall(self.ui.annotation.updateAnnotations, self.ui.annotation, true, true)
    end

    -- Reload document so any changes apply
    self.ui:reloadDocument()
end

function Grimmory:onGrimmorySync(verbose, book_path, refresh_book)
    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    local function background_callback(run, terminate)
        if not self:isReadyToSync() then
            return
        end

        logger:info("Synchronizing to Grimmory")

        local terminated_early = false

        local queue_terminate = function()
            logger:dbg("Terminate requested")
            terminated_early = true
            terminate()
        end

        self.is_synchronizing = true
        self.menu:onGrimmorySyncStart(queue_terminate)

        local update_callback, close_callback
        if verbose then
            update_callback, close_callback = self.dialog_manager:showProgressDialog(
                _("Synchronizing to Grimmory"),
                queue_terminate,
                _("Continue synchronization?")
            )
        end

        local last_progress_step = 0
        local session_count = 0
        local session_error_count = 0
        local book_download_count = 0
        local book_refresh_count = 0
        local book_error_count = 0

        local update_progress_step = function(progress_step)
            if progress_step <= last_progress_step then
                return
            end

            last_progress_step = progress_step

            if update_callback ~= nil then
                pcall(update_callback, progress_step, 10)
            end
        end

        -- In the future, we should limit what we sync
        -- to current or recent books.  For now, we sync everything.

        local ok, result = run(
            function(progress_callback)
                if not self:isWifiConnected() then
                    logger:err("Cannot sync without connectivity")
                    error("Cannot sync without connectivity")
                end

                if book_path then
                    self.synchronizer:synchronizeBook(book_path, refresh_book, progress_callback)
                else
                    self.synchronizer:synchronizeAll(progress_callback)
                end
            end,
            function(progress)
                if type(progress) ~= "table" then
                    return
                end

                if progress.state == "book-push-metadata" then
                    local pushed_books = progress.pushed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        pushed_books = 1
                        total_books = 1
                    end

                    -- Pushing sessions is 1, 2, and 3
                    update_progress_step(math.floor((pushed_books / total_books) * 3))
                end

                if progress.state:find("^shelf-") ~= nil then
                    -- If we are still seeing shelves we are at step 3
                    -- Because complete with shelves is step 4.
                    update_progress_step(3)
                end

                if (
                    progress.state == "book-downloaded" or
                    progress.state == "book-error" or
                    progress.state == "book-pull-metadata"
                ) then
                    local viewed_books = progress.viewed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        viewed_books = 1
                        total_books = 1
                    end

                    -- Step 5, 6, 7, 8, 9 are all pulling books down
                    update_progress_step(4 + math.floor((viewed_books / total_books) * 5))
                end

                if progress.state == "session-recorded" then
                    session_count = session_count + 1
                elseif progress.state == "session-error" then
                    session_error_count = session_error_count + 1
                elseif progress.state == "book-downloaded" then
                    book_download_count = book_download_count + 1

                    if book_download_count % 20 == 0 then
                        -- If we're updating a lot of books we should
                        -- emit a refresh event every once in a while
                        -- so background refresh sees these come
                        -- through quickly
                        UIManager:broadcastEvent(Event:new("RefreshContent"))

                        -- Also refresh collections in this process
                        ReadCollection:_read()
                    end

                elseif progress.state == "book-error" then
                    book_error_count = book_error_count + 1
                elseif progress.state == "book-pull-metadata" then
                    book_refresh_count = book_refresh_count + 1
                end
            end
        )

        self.is_synchronizing = false
        self.menu:onGrimmorySyncComplete()

        if close_callback then
            pcall(close_callback)
        end

        if not ok then
            if terminated_early then
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
                        _("Failed to Synchronize with Grimmory")
                    )
                end
            end

            return
        end

        -- If we have any books downloaded we need to emit a refresh
        -- event so the file manager knows it should refresh
        UIManager:broadcastEvent(Event:new("RefreshContent"))

        -- Also force refresh collections in this process
        ReadCollection.last_read_time = 0
        ReadCollection:_read()

        self:refreshUI()

        if verbose then
            local message = {
                _("Completed Grimmory sync")
            }

            if session_count > 0 then
                table.insert(message, T(_("%1 session(s) recorded"), session_count))
            end

            if session_error_count > 0 then
                table.insert(message, T(_("%1 session(s) failed"), session_error_count))
            end

            if book_download_count > 0 then
                table.insert(message, T(_("%1 book(s) downloaded"), book_download_count))
            end

            if book_refresh_count > 0 then
                table.insert(message, T(_("%1 book(s) refreshed"), book_refresh_count))
            end

            if book_error_count > 0 then
                table.insert(message, T(_("%1 book(s) failed"), book_error_count))
            end

            self.dialog_manager:toast(table.concat(message, "\n"))
        end
    end

    self.executor:background(
        background_callback,
        self.settings:getSyncEnableWifi()
    )
end

return Grimmory