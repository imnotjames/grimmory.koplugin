local _ = require("gettext")
local T = require("ffi/util").template

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkManager = require("ui/network/manager")
local Socket = require("socket")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmorySettings = require("settings")
local GrimmoryConnector = require("connectors/grimmory_connector")
local GrimmorySynchronize = require("synchronize")

local logger = require("namespaced_logger").new("Grimmory")

local Grimmory = WidgetContainer:extend{
    name = "grimmory",
    is_doc_only = false,
    is_stub = false,
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

function Grimmory:addToMainMenu(menu_items)
    menu_items.grimmory = {
        text = "Grimmory",
        sub_item_table = {
            {
                text = _("Force Sync Now"),
                enabled_func = function()
                    return self:isReadyToSync()
                end,
                callback = function()
                    -- Do not block the UI thread
                    UIManager:scheduleIn(0.1, function()
                        self:synchronize(true)
                    end)
                end,
                separator = true,
            },
            {
                text = _("Connection Settings"),
                callback = function()
                    self.settings:showConnectionSettings()
                end,
            },
            {
                text = _("Automatic Sync"),
                separator = true,
                sub_item_table = {
                    {
                        text = _("On Close Document"),
                        checked_func = function()
                            return self.settings:getSyncOnCloseDocument()
                        end,
                        callback = function()
                            self.settings:toggleSyncOnCloseDocument()
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("On Suspend"),
                        checked_func = function()
                            return self.settings:getSyncOnSuspend()
                        end,
                        callback = function()
                            self.settings:toggleSyncOnSuspend()
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("On Power Off"),
                        checked_func = function()
                            return self.settings:getSyncOnPowerOff()
                        end,
                        callback = function()
                            self.settings:toggleSyncOnPowerOff()
                        end,
                        keep_menu_open = true,
                        separator = true,
                    },
                    {
                        text = _("Enable WiFi"),
                        checked_func = function()
                            return self.settings:getSyncEnableWifi()
                        end,
                        callback = function()
                            self.settings:toggleSyncEnableWifi()
                        end,
                    },
                },
            },
            {
                text = _("Sync Shelves"),
                checked_func = function()
                    return self.settings:getSyncShelves()
                end,
                callback = function()
                    self.settings:toggleSyncShelves()
                end,
            },
            {
                text_func = function()
                    local targetDescription = "All"

                    local targetShelves = self.settings:getTargetShelves()

                    local count = 0
                    for _, shelf in ipairs(targetShelves) do
                        if count == 0 then
                            targetDescription = shelf.name
                        else
                            targetDescription = targetShelves .. ", " .. shelf.name
                        end
                        count = count + 1
                    end

                    return T(_("Source Shelves: %1"), targetDescription)
                end,
                callback = function()
                    self.settings:showTargetShelvesSettings()
                end,
                separator = true,
            },
            {
                text = _("Sync Reading Sessions"),
                checked_func = function()
                    return self.settings:getSyncReadingSessions()
                end,
                callback = function()
                    self.settings:toggleSyncReadingSessions()
                end,
            },
            {
                text = _("Reading Session Thresholds"),
                callback = function()
                    self.settings:showSessionThresholdSettings()
                end,
            },
        }
    }
end

function Grimmory:init()
    self.settings = GrimmorySettings:new()

    self:onGrimmorySettingsChanged()

    self.ui.menu:registerToMainMenu(self)

    self:onDispatcherRegisterActions()

    logger:dbg("Initialized")
end

function Grimmory:onExit()
    logger:dbg("Exiting")
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")

    if self.settings:getSyncOnSuspend() then
       self:synchronizeOnEvent()
    end
end

function Grimmory:onPowerOff()
    logger:dbg("Device is powering off")

    if self.settings:getSyncOnPowerOff() then
       self:synchronizeOnEvent()
    end
end

function Grimmory:onReaderReady()
    logger:dbg("Document open and ready")
end

function Grimmory:onCloseDocument()
    logger:dbg("Document closing")

    if self.settings:getSyncOnCloseDocument() then
        -- Do not block the UI thread
        UIManager:scheduleIn(0.1, function()
            self:synchronizeOnEvent()
        end)
    end
end

function Grimmory:onGrimmorySync()
    local ok, result = pcall(function()
        self:synchronize(false)
    end)

    if not ok then
        logger:warn("Error when synchronizing:", result)
    end
end

function Grimmory:onGrimmorySettingsChanged()
    GrimmorySynchronize:setThresholds(
        self.settings:getSessionThresholdSeconds(),
        self.settings:getSessionThresholdPages()
    )

    GrimmorySynchronize:setTargetShelves(
        self.settings:getTargetShelves()
    )

    GrimmorySynchronize:setFeaturesEnabled(
        self.settings:getSyncShelves(),
        self.settings:getSyncReadingSessions()
    )

    GrimmorySynchronize:setSynchronizeSessionsSince(
        self.settings:getSynchronizedUntil()
    )

    GrimmoryConnector:setCredentials(
        self.settings:getBaseUri(),
        self.settings:getUsername(),
        self.settings:getPassword()
    )
end

function Grimmory:isWifiOn()
    local ok, result = pcall(function()
        return NetworkManager:isWifiOn()
    end)

    if not ok then
        logger:err("Something went wrong checking wifi state", result)
        return true
    end

    return result
end

function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false
    end

    return true
end

function Grimmory:isConnected()
    if not self:isWifiOn() then
        return false
    end

    local ok, result = pcall(function()
        return NetworkManager:isConnected()
    end)

    if not ok then
        logger:err("Something went wrong checking wifi connectivity", result)
        return true
    end

    return result
end

function Grimmory:enableWifi()
    logger:info("Enabling wifi")

    local ok, result = pcall(function()
        NetworkManager.turnOnWifi()

        -- Wait for 10 seconds for connectivity to come up
        local endTime = os.time() + 30
        while os.time() < endTime do
            if NetworkManager:isConnected() then
                logger:info("Connected!")
                return
            end
            -- Sleep for a little bit so we don't make a busy loop
            Socket.select(nil, nil, 0.25)
        end

        logger:info("Timeout attempting to connect")
    end)

    if not ok then
        logger:err("Unable to turn on wifi", result)
    end
end

function Grimmory:disableWifi()
    logger:info("Disabling wifi")
    local ok, result = pcall(function()
        return NetworkManager.turnOffWifi()
    end)

    if not ok then
        logger:err("Unable to turn off wifi", result)
    end
end

function Grimmory:synchronizeOnEvent()
    if self:isReadyToSync() then
        logger:info("Not ready to sync, skipping on event")
        return false
    end

    local wifiNeedsDisable = false
    if self.settings:getSyncEnableWifi() and not self:isWifiOn() then
        wifiNeedsDisable = true
        self:enableWifi()
    end

    if not self:isConnected() then
        logger:info("Cannot sync without connectivity")
        return
    end

    -- In the future, we should limit what we sync
    -- to current or recent books.  For now, we sync everything.
    local ok, result = pcall(function()
        self:synchronize(false)
    end)

    if not ok then
        logger:warn("Error when synchronizing:", result)
    end

    if wifiNeedsDisable then
        self:disableWifi()
    end
end

function Grimmory:synchronize(verbose)
    logger:info("Synchronizing to Grimmory")

    local progressInfo

    if verbose then
        progressInfo = InfoMessage:new({
            text = _("Starting Grimmory sync..."),
            timeout = 1
        })
        UIManager:show(progressInfo)
    end

    local count = 0
    local errorCount = 0

    local ok, result = pcall(function()
        GrimmorySynchronize:synchronizeAll(
            GrimmoryConnector,
            function(progress)
                if progress.since then
                    -- Update since
                    self.settings:setSynchronizedUntil(progress.since)
                end

                if progress.state == "success" then
                    count = count + 1
                elseif progress.state == "error" then
                    errorCount = errorCount + 1
                end
            end
        )
    end)

    if not ok then
        logger:err("Failed sync", result)

        if verbose then
            UIManager:close(progressInfo)
            progressInfo = InfoMessage:new({
                text = T(_("Failed to Synchronize to Grimmory")),
                timeout = 2,
            })
            UIManager:show(progressInfo)
        end

        return
    end

    if verbose then
        local message
        if errorCount > 0 then
            message = _("Completed Grimmory sync\n%1 session(s) recorded\n%2 session(s) failed")
        else
            message = _("Completed Grimmory sync\n%1 session(s) recorded")
        end

        UIManager:close(progressInfo)
        progressInfo = InfoMessage:new({
            text = T(
                message,
                count,
                errorCount
            ),
            timeout = 2
        })
        UIManager:show(progressInfo)
    end
end

return Grimmory