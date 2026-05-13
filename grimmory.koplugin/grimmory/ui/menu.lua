local _ = require("gettext")
local T = require("ffi/util").template

local Event = require("ui/event")
local UIManager = require("ui/uimanager")

local PluginMetadata = require("_meta")

local logger = require("grimmory/logger").new("GrimmoryMenu")

---@class GrimmoryMenu
---@field settings GrimmorySettings
---@field dialog_manager DialogManager
---@field updater GrimmorySelfUpdater
local GrimmoryMenu = {}

function GrimmoryMenu:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function GrimmoryMenu:getAboutMenu()
    -- These won't change after the plugin starts up
    local repository = PluginMetadata.repository
    local version = PluginMetadata.version

    return {
        {
            text = repository,
            keep_menu_open = true,
        },
        {
            text = T(_("Version %1"), version),
            keep_menu_open = true,
            separator = true,
        },
        {
            text_func = function()
                return _("Automatically Check for Updates")
            end,
            checked_func = function()
                return self.settings:getAutomaticCheckUpdates()
            end,
            callback = function()
                self.settings:toggleAutomaticCheckUpdates()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                if self.updater:isPendingRestart() then
                    return _("Update Pending Restart")
                end

                if self.updater:isUpdateAvailable() then
                    local latest_version = self.updater:getLatestReleaseVersion()
                    return T(_("Update to %1"), latest_version)
                end

                return _("Check for Updates")
            end,
            callback = function()
                if self.updater:isPendingRestart() then
                    UIManager:askForRestart(_("Grimmory plugin update will apply on next Restart."))
                else
                    self.dialog_manager:showPluginUpdateCheck()
                end
            end,
        },
    }
end

function GrimmoryMenu:getSyncOptionsMenu()
    return {
        {
            text = _("On Close Document"),
            checked_func = function()
                return self.settings:getSyncOnCloseDocument()
            end,
            callback = function()
                self.settings:toggleSyncOnCloseDocument()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
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
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
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
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            keep_menu_open = true,
            separator = true,
        },
        {
            text = _("Periodically Sync"),
            checked_func = function()
                return self.settings:getSyncPeriodically()
            end,
            callback = function()
                self.settings:toggleSyncPeriodically()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                local frequency = self.settings:getSyncFrequency()
                return T(_("Frequency: %1 minutes"), frequency)
            end,
            callback = function()
                self.dialog_manager:showSyncFrequencySettings()
            end,
            separator = true,
        },
        {
            text = _("Enable WiFi"),
            checked_func = function()
                return self.settings:getSyncEnableWifi()
            end,
            callback = function()
                self.settings:toggleSyncEnableWifi()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
    }
end

function GrimmoryMenu:getTopMenu()
    return  {
        {
            text = _("Force Sync Now"),
            enabled_func = function()
                if self.settings:getBaseUri() == "" then
                    logger:info("BaseURI is not configured, cannot sync")
                    return false
                end

                return true
            end,
            callback = function()
                UIManager:broadcastEvent(Event:new("GrimmorySync", true))
            end,
            separator = true,
        },
        {
            text = _("Connection Settings"),
            callback = function()
                self.dialog_manager:showConnectionSettings()
            end,
        },
        {
            text = _("Automatic Sync"),
            separator = true,
            sub_item_table = self:getSyncOptionsMenu()
        },
        {
            text = _("Download Books"),
            checked_func = function()
                return self.settings:getSyncShelves()
            end,
            callback = function()
                self.settings:toggleSyncShelves()
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
        {
            text = _("Set Download Directory"),
            callback = function()
                self.dialog_manager:showDownloadDirectorySettings()
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
            enabled_func = function()
                if self.settings:getBaseUri() == "" then
                    logger:info("BaseURI is not configured, cannot fetch shelves")
                    return false
                end

                return true
            end,
            callback = function()
                self.dialog_manager:showTargetShelvesSettings()
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
                UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))
            end,
        },
        {
            text = _("Reading Session Thresholds"),
            callback = function()
                self.dialog_manager:showSessionThresholdSettings()
            end,
            separator = true,
        },
        {
            text = _("About Grimmory Sync"),
            sub_item_table = self:getAboutMenu(),
        },
    }
end

function GrimmoryMenu:addToMainMenu(menu_items)
    menu_items.grimmory = {
        text = "Grimmory",
        sorting_hint = "tools",
        sub_item_table = self:getTopMenu()
    }
end

return GrimmoryMenu