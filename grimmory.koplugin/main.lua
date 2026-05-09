local _ = require("gettext")
local T = require("ffi/util").template

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkManager = require("ui/network/manager")
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
                text = _("Sync Now"),
                callback = function()
                    self:synchronize(true)
                end,
            },
            {
                text = _("Connection Settings"),
                callback = function()
                    self.settings:showConnectionSettings()
                end,
            }
        }
    }
end

function Grimmory:init()
    self.settings = GrimmorySettings:new()

    GrimmoryConnector:setCredentials(
        self.settings:getBaseUri(),
        self.settings:getUsername(),
        self.settings:getPassword()
    )

    self.ui.menu:registerToMainMenu(self)

    self:onDispatcherRegisterActions()

    logger:dbg("Initialized")
end

function Grimmory:onExit()
    logger:dbg("Exiting")
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")
end

function Grimmory:onResume()
    logger:dbg("Device is suspending")
end

function Grimmory:onPowerOff()
    logger:dbg("Device is powering off")
end

function Grimmory:onReboot()
    logger:dbg("Device is rebooting")
end

function Grimmory:onReaderReady()
    logger:dbg("Document open and ready")
end

function Grimmory:onCloseDocument()
    logger:dbg("Document closing")
end

function Grimmory:onGrimmorySync()
    self:synchronize(true)
end

function Grimmory:onGrimmorySettingsChanged()
    GrimmoryConnector:setCredentials(
        self.settings:getBaseUri(),
        self.settings:getUsername(),
        self.settings:getPassword()
    )
end

function Grimmory:synchronize(verbose)
    logger:info("Synchronizing to Grimmory")

    -- TODO: Test connection and stop if it's not ready

    local progressInfo

    if verbose then
        progressInfo = InfoMessage:new({
            text = _("Starting Grimmory sync..."),
            timeout = 1
        })
        UIManager:show(progressInfo)
    end

    local since = self.settings:getSynchronizedUntil()

    NetworkManager:runWhenOnline(function()
        local count = 0
        local errorCount = 0

        local ok, result = pcall(function()
            GrimmorySynchronize:synchronizeAll(
                GrimmoryConnector,
                since,
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

    end)
end

return Grimmory