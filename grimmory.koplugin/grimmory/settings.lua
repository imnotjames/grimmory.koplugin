local _ = require("gettext")

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- Contains all of the stored settings and settings UI
-- elements to control Grimmory connections & sync.

---@class GrimmoryTargetShelf
---@field id number
---@field name string

---@class GrimmorySettingsData
---@field automatic_check_updates boolean
---@field base_uri string
---@field username string
---@field password string
---@field session_threshold_seconds number
---@field session_threshold_pages number
---@field sync_on_close_document boolean
---@field sync_on_suspend boolean
---@field sync_on_power_off boolean
---@field sync_enable_wifi boolean
---@field sync_periodically boolean
---@field sync_frequency number
---@field sync_shelves boolean
---@field sync_target_shelves GrimmoryTargetShelf[]
---@field sync_download_directory string
---@field sync_reading_sessions boolean
---@field sync_reading_progress boolean
---@field synchronized_until number

---@type GrimmorySettingsData
local DEFAULTS = {
    automatic_check_updates = false,
    synchronized_until = os.time(), -- plugin init time
    base_uri = "",
    username = "",
    password = "",
    session_threshold_seconds = 60,
    session_threshold_pages = 0,
    sync_on_close_document = true,
    sync_on_suspend = true,
    sync_on_power_off = true,
    sync_enable_wifi = false,
    sync_periodically = false,
    sync_frequency = 120,
    sync_shelves = true,
    sync_target_shelves = {},
    sync_download_directory = "grimmory/",
    sync_reading_sessions = true,
    sync_reading_progress = true,
}

---@class GrimmorySettings
---@field settings any Underlying lua settings interactions
---@field data GrimmorySettingsData In-memory setting values
local GrimmorySettings = {
    data = DEFAULTS,
}

local SETTING_KEY = "grimmory"

local function openSettingsHandle()
  local path = DataStorage:getSettingsDir() .. "/" .. SETTING_KEY .. ".lua"
  return LuaSettings:open(path)
end

function GrimmorySettings:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmorySettings:init()
    self.settings = openSettingsHandle()
    local success, result = pcall(function()
        return self.settings:readSetting(SETTING_KEY, {}) or {}
    end)

    if success then
        self.data = result
    else
        logger:err("Error reading settings, using defaults", result)
        self.data = DEFAULTS
    end
end

function GrimmorySettings:write()
    local success, error_msg = pcall(function()
        if not self.settings then
            logger:err("No settings object available for write")
            return false
        end

        logger:dbg("Saving settings data", self.data)
        self.settings:saveSetting(SETTING_KEY, self.data)
        self.settings:flush()
        logger:dbg("Settings saved and flushed successfully")
        return true
    end)

    if not success then
        logger:err("Error writing settings:", error_msg)
        return false
    end

    return true
end

function GrimmorySettings:getBaseUri()
    return self.data.base_uri or DEFAULTS.base_uri
end

function GrimmorySettings:setBaseUri(uri)
    uri = tostring(uri or ""):gsub("/*$", "")
    self.data.base_uri = uri
    self:write()
end

function GrimmorySettings:getUsername()
    return self.data.username or DEFAULTS.username
end

function GrimmorySettings:setUsername(username)
    self.data.username = username
    self:write()
end

function GrimmorySettings:getPassword()
    return self.data.password or DEFAULTS.password
end

function GrimmorySettings:setPassword(password)
    self.data.password = password
    self:write()
end

function GrimmorySettings:getSessionThresholdSeconds()
    return self.data.session_threshold_seconds or DEFAULTS.session_threshold_seconds
end

---@param seconds integer
function GrimmorySettings:setSessionThresholdSeconds(seconds)
    self.data.session_threshold_seconds = seconds
    self:write()
end

function GrimmorySettings:getSessionThresholdPages()
    return self.data.session_threshold_pages or DEFAULTS.session_threshold_pages
end

---@param pages integer
function GrimmorySettings:setSessionThresholdPages(pages)
    self.data.session_threshold_pages = pages
    self:write()
end

function GrimmorySettings:getSyncShelves()
    if self.data.sync_shelves == nil then
        return DEFAULTS.sync_shelves
    end

    return self.data.sync_shelves
end

function GrimmorySettings:toggleSyncShelves()
    self.data.sync_shelves = not self.data.sync_shelves
    self:write()
end

function GrimmorySettings:getSyncDownloadDirectory()
    return self.data.sync_download_directory or DEFAULTS.sync_download_directory
end

---@param directory string
function GrimmorySettings:setSyncDownloadDirectory(directory)
    self.data.sync_download_directory = directory
    self:write()
end

function GrimmorySettings:getSyncTargetShelves()
    return self.data.sync_target_shelves or DEFAULTS.sync_target_shelves
end

---@param target_shelves GrimmoryTargetShelf
function GrimmorySettings:setSyncTargetShelves(target_shelves)
    self.data.sync_target_shelves = target_shelves
    self:write()
end

function GrimmorySettings:getSyncReadingProgress()
    if self.data.sync_reading_progress == nil then
        return DEFAULTS.sync_reading_progress
    end

    return self.data.sync_reading_progress
end

function GrimmorySettings:toggleSyncReadingProgress()
    self.data.sync_reading_progress = not self.data.sync_reading_progress
    self:write()
end

function GrimmorySettings:getSyncReadingSessions()
    if self.data.sync_reading_sessions == nil then
        return DEFAULTS.sync_reading_sessions
    end

    return self.data.sync_reading_sessions
end

function GrimmorySettings:toggleSyncReadingSessions()
    self.data.sync_reading_sessions = not self.data.sync_reading_sessions
    self:write()
end

function GrimmorySettings:getSyncPeriodically()
    if self.data.sync_periodically == nil then
        return DEFAULTS.sync_periodically
    end

    return self.data.sync_periodically
end

function GrimmorySettings:toggleSyncPeriodically()
    self.data.sync_periodically = not self.data.sync_periodically
    self:write()
end

function GrimmorySettings:getSyncFrequency()
    return self.data.sync_frequency or DEFAULTS.sync_frequency
end

function GrimmorySettings:setSyncFrequency(seconds)
    self.data.sync_frequency = seconds
    self:write()
end

function GrimmorySettings:getSyncOnCloseDocument()
    if self.data.sync_on_close_document == nil then
        return DEFAULTS.sync_on_close_document
    end

    return self.data.sync_on_close_document
end

function GrimmorySettings:toggleSyncOnCloseDocument()
    self.data.sync_on_close_document = not self.data.sync_on_close_document
end

function GrimmorySettings:getSyncOnSuspend()
    if self.data.sync_on_suspend == nil then
        return DEFAULTS.sync_on_suspend
    end

    return self.data.sync_on_suspend
end

function GrimmorySettings:toggleSyncOnSuspend()
    self.data.sync_on_suspend = not self.data.sync_on_suspend
    self:write()
end

function GrimmorySettings:getSyncOnPowerOff()
    if self.data.sync_on_power_off == nil then
        return DEFAULTS.sync_on_power_off
    end

    return self.data.sync_on_power_off
end

function GrimmorySettings:toggleSyncOnPowerOff()
    self.data.sync_on_power_off = not self.data.sync_on_power_off
    self:write()
end

function GrimmorySettings:getSyncEnableWifi()
    if self.data.sync_enable_wifi == nil then
        return DEFAULTS.sync_enable_wifi
    end

    return self.data.sync_enable_wifi
end

function GrimmorySettings:toggleSyncEnableWifi()
    self.data.sync_enable_wifi = not self.data.sync_enable_wifi
    self:write()
end

function GrimmorySettings:getSynchronizedUntil()
    return self.data.synchronized_until or DEFAULTS.synchronized_until
end

---@param timestamp number
function GrimmorySettings:setSynchronizedUntil(timestamp)
    self.data.synchronized_until = timestamp
    self:write()
end

function GrimmorySettings:getAutomaticCheckUpdates()
    if self.data.automatic_check_updates == nil then
        return DEFAULTS.automatic_check_updates
    end

    return self.data.automatic_check_updates
end

function GrimmorySettings:toggleAutomaticCheckUpdates()
    self.data.automatic_check_updates = not self.data.automatic_check_updates
    self:write()
end

return GrimmorySettings
