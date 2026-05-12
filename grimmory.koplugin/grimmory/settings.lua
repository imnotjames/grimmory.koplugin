local _ = require("gettext")

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local logger = require("grimmory/logger").new("GrimmorySettings")

-- Contains all of the stored settings and settings UI
-- elements to control Grimmory connections & sync.

local DEFAULTS = {
    synchronizedUntil = os.time(), -- plugin init time
    baseUri = "",
    username = "",
    password = "",
    sessionThresholdSeconds = 60,
    sessionThresholdPages = 0,
    syncOnCloseDocument = true,
    syncOnSuspend = true,
    syncOnPowerOff = true,
    syncEnableWifi = false,
    syncPeriodically = false,
    syncFrequency = 120,
    syncShelves = true,
    syncReadingSessions = true,
    targetShelves = {},
    downloadDirectory = "grimmory/"
}

---@class GrimmorySettings
---@field settings any Underlying lua settings interactions
---@field data any In-memory setting values
local GrimmorySettings = {
    data = DEFAULTS,
}

local SETTING_KEY = "grimmory"

local function openSettingsHandle()
  local path = DataStorage:getSettingsDir() .. "/" .. SETTING_KEY .. ".lua"
  return LuaSettings:open(path)
end

function GrimmorySettings:new(o)
    o = o or {}
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
        self.data = {}
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

function GrimmorySettings:update(patch)
    for k, v in pairs(patch or {}) do
        logger:dbg("Updating setting:", k, "=", v)
        self.data[k] = v
    end

    return self:write()
end

function GrimmorySettings:getDownloadDirectory()
    return self.data.downloadDirectory or DEFAULTS.downloadDirectory
end

function GrimmorySettings:setDownloadDirectory(downloadDirectory)
    self:update({ downloadDirectory = downloadDirectory })
end

function GrimmorySettings:getBaseUri()
    return self.data.baseUri or DEFAULTS.baseUri
end

function GrimmorySettings:setBaseUri(uri)
    uri = tostring(uri or ""):gsub("/*$", "")
    self:update({ baseUri = uri })
end

function GrimmorySettings:getUsername()
    return self.data.username or DEFAULTS.username
end

function GrimmorySettings:setUsername(username)
    self:update({ username = username })
end

function GrimmorySettings:getPassword()
    return self.data.password or DEFAULTS.password
end

function GrimmorySettings:setPassword(password)
    self:update({ password = password })
end

function GrimmorySettings:getTargetShelves()
    return self.data.targetShelves or DEFAULTS.targetShelves
end

function GrimmorySettings:setTargetShelves(targetShelves)
    self:update({ targetShelves = targetShelves })
end

function GrimmorySettings:getSessionThresholdSeconds()
    return self.data.sessionThresholdSeconds or DEFAULTS.sessionThresholdSeconds
end

function GrimmorySettings:setSessionThresholdSeconds(sessionThresholdSeconds)
    self:update({ sessionThresholdSeconds = sessionThresholdSeconds })
end

function GrimmorySettings:getSessionThresholdPages()
    return self.data.sessionThresholdPages or DEFAULTS.sessionThresholdPages
end

function GrimmorySettings:setSessionThresholdPages(sessionThresholdPages)
    self:update({ sessionThresholdPages = sessionThresholdPages })
end

function GrimmorySettings:toggleSyncShelves()
    self:update({ syncShelves = not self:getSyncShelves() })
end

function GrimmorySettings:getSyncShelves()
    if self.data.syncShelves == nil then
        return DEFAULTS.syncShelves
    end

    return self.data.syncShelves
end

function GrimmorySettings:toggleSyncReadingSessions()
    self:update({ syncReadingSessions = not self:getSyncReadingSessions() })
end

function GrimmorySettings:getSyncReadingSessions()
    if self.data.syncReadingSessions == nil then
        return DEFAULTS.syncReadingSessions
    end

    return self.data.syncReadingSessions
end

function GrimmorySettings:toggleSyncPeriodically()
    self:update({ syncPeriodically = not self:getSyncPeriodically()})
end

function GrimmorySettings:getSyncPeriodically()
    if self.data.syncPeriodically == nil then
        return DEFAULTS.syncPeriodically
    end

    return self.data.syncPeriodically
end


function GrimmorySettings:setSyncFrequency(syncFrequency)
    self:update({ syncFrequency = syncFrequency })
end

function GrimmorySettings:getSyncFrequency()
    return self.data.syncFrequency or DEFAULTS.syncFrequency
end

function GrimmorySettings:toggleSyncOnCloseDocument()
    self:update({ syncOnCloseDocument = not self:getSyncOnCloseDocument() })
end

function GrimmorySettings:getSyncOnCloseDocument()
    if self.data.syncOnCloseDocument == nil then
        return DEFAULTS.syncOnCloseDocument
    end

    return self.data.syncOnCloseDocument
end

function GrimmorySettings:toggleSyncOnSuspend()
    self:update({ syncOnSuspend = not self:getSyncOnSuspend() })
end

function GrimmorySettings:getSyncOnSuspend()
    if self.data.syncOnSuspend == nil then
        return DEFAULTS.syncOnSuspend
    end

    return self.data.syncOnSuspend
end

function GrimmorySettings:toggleSyncOnPowerOff()
    self:update({ syncOnPowerOff = not self:getSyncOnPowerOff() })
end

function GrimmorySettings:getSyncOnPowerOff()
    if self.data.syncOnPowerOff == nil then
        return DEFAULTS.syncOnPowerOff
    end

    return self.data.syncOnPowerOff
end

function GrimmorySettings:toggleSyncEnableWifi()
    self:update({ syncEnableWifi = not self:getSyncEnableWifi() })
end

function GrimmorySettings:getSyncEnableWifi()
    if self.data.syncEnableWifi == nil then
        return DEFAULTS.syncEnableWifi
    end

    return self.data.syncEnableWifi
end

function GrimmorySettings:getSynchronizedUntil()
    return self.data.synchronizedUntil or DEFAULTS.synchronizedUntil
end

function GrimmorySettings:setSynchronizedUntil(synchronizedUntil)
    self:update({ synchronizedUntil = synchronizedUntil })
end

return GrimmorySettings
