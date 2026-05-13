local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local PathChooser = require("ui/widget/pathchooser")
local ProgressbarDialog = require("ui/widget/progressbardialog")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class DialogManager
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field updater GrimmorySelfUpdater
local DialogManager = {}

function DialogManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function DialogManager:toast(text, timeout)
    if self.info_message then
        UIManager:close(self.info_message)
    end

    if timeout == nil then
        timeout = 2
    elseif timeout <= 0 then
        timeout = nil
    end

    self.info_message = InfoMessage:new({
        text = text,
        timeout = timeout,
    })

    UIManager:show(self.info_message)
end

function DialogManager:showConnectionSettings()
    self.dialog = MultiInputDialog:new({
        title = _("Grimmory Connection"),
        fields = {
            {
                text = self.settings:getBaseUri(),
                description = _("Server URL"),
                hint = _("http://example.com:port"),
            },
            {
                text = self.settings:getUsername(),
                description = _("Username"),
            },
            {
                text = self.settings:getPassword(),
                description = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(self.dialog)
                end,
            },
            {
                text = _("Test"),
                callback = function()
                    local fields = self.dialog:getFields()

                    local ok, version = self.api:testConnection(
                        fields[1],
                        fields[2],
                        fields[3]
                    )

                    if ok then
                        self:toast(T(_("Connection successful\nGrimmory (%1)"), tostring(version)))
                    else
                        self:toast(T(_("Unable to connect to Grimmory\nError: %1"), tostring(version)))
                    end
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = self.dialog:getFields()

                    self.settings:setBaseUri(fields[1])
                    self.settings:setUsername(fields[2])
                    self.settings:setPassword(fields[3])

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(self.dialog)
                end,
            },
            },
        },
    })

    UIManager:show(self.dialog)
    self.dialog:onShowKeyboard()
end

function DialogManager:showTargetShelvesSettings()
    local ok, result = self.api:getShelves()

    if not ok or type(result) == "string" then
        logger:err("Something went wrong loading shelves", result)
        self:toast(T(_("Could not load shelves: %1"), result))
        return
    end

    local buttons = {
        {
            {
                text = _("Cancel Selection"),
                callback = function()
                    UIManager:close(self.dialog)
                end,
            }
        },
        {
            {
                text = _("All Shelves"),
                callback = function()
                    logger:info("Set target shelves to All Shelves")
                    self.settings:setTargetShelves({})

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(self.dialog)
                end,
            }
        }
    }

    local shelfNameToId = {}

    for _, shelf in ipairs(result) do
        local shelfName = shelf.name
        local shelfId = shelf.id

        local uniqueShelfName = shelfName
        local uniqueShelfIndex = 0
        while shelfNameToId[uniqueShelfName] do
            uniqueShelfIndex = uniqueShelfIndex + 1
            uniqueShelfName = shelfName .. " " .. uniqueShelfIndex
        end

        table.insert(
            buttons,
            {
                {
                    text = uniqueShelfName,
                    callback = function()
                        logger:info("Set target shelves to shelf ID", shelfId)
                        self.settings:setTargetShelves({ { id = shelfId, name = uniqueShelfName } })

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(self.dialog)
                    end
                }
            }
        )
    end

    self.dialog = ButtonDialog:new({
        title = _("Target Shelf"),
        buttons = buttons,
    })

    UIManager:show(self.dialog)
end

function DialogManager:showSyncFrequencySettings()
    self.dialog = MultiInputDialog:new({
        title = _("Periodic Sync Frequency"),
        fields = {
            {
                text = self.settings:getSyncFrequency(),
                description = _("Minutes between synchronization"),
                input_type = "number"
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.dialog:getFields()

                        self.settings:setSyncFrequency(math.max(1, fields[1]))

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(self.dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(self.dialog)
end

function DialogManager:showSessionThresholdSettings()
    self.dialog = MultiInputDialog:new({
        title = _("Session Thresholds"),
        fields = {
            {
                text = self.settings:getSessionThresholdSeconds(),
                description = _("Minimum Session Seconds"),
                input_type = "number",
            },
            {
                text = self.settings:getSessionThresholdPages(),
                description = _("Minimum Session Pages"),
                input_type = "number",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(self.dialog)
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = self.dialog:getFields()

                    self.settings:setSessionThresholdSeconds(math.max(0, fields[1]))
                    self.settings:setSessionThresholdPages(math.max(0, fields[2]))

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(self.dialog)
                end,
            },
            },
        },
    })

    UIManager:show(self.dialog)
    self.dialog:onShowKeyboard()
end

function DialogManager:showDownloadDirectorySettings()
    self.dialog = PathChooser:new({
        title = "Download Directory",
        select_file = false,
        show_files = false,
        path = self.settings:getDownloadDirectory(),
        onConfirm = function(newPath)
            self.settings:setDownloadDirectory(newPath)
        end,
    })

    UIManager:show(self.dialog)
end

function DialogManager:showPluginUpdateCheck()
    local latest_version = self.updater:getLatestReleaseVersion()
    local is_update_available = self.updater:isUpdateAvailable()

    local update_button_text = _("No update available")

    if is_update_available then
        update_button_text = T(_("Update to %1"), latest_version)
    end

    self.dialog = ButtonDialog:new({
        title = T(_("Update Grimmory Plugin\nLatest release is %1"), latest_version),
        buttons = {
            {
                {
                    text = update_button_text,
                    callback = function()
                        if is_update_available then
                            UIManager:close(self.dialog)

                            self:showPluginUpdater()
                        end
                    end,
                },
                {
                    text = _("Check for Updates"),
                    callback = function()
                        self.updater:fetchLatestVersion()
                        UIManager:close(self.dialog)
                        self:showPluginUpdateCheck()
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(self.dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(self.dialog)
end

function DialogManager:showPluginUpdater()
    local dialog = ProgressbarDialog:new({
        title = _("Updating Grimmory Plugin"),
        progress_max = 100,
        refresh_time_seconds = 3,
        dismissable = false,
    })

    UIManager:show(dialog)

    UIManager:nextTick(function()
        self.updater:update(
            function(state, progress, message)
                dialog:reportProgress(progress)

                if state == "complete" then
                    UIManager:close(dialog)

                    UIManager:askForRestart(_("Grimmory plugin update will apply on next Restart."))
                elseif state == "failed" then
                    UIManager:close(dialog)

                    self:toast(T(_("Failed to update\n%1"), message), 0)
                end
            end
        )
    end)
end



return DialogManager