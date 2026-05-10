local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local Event = require("ui/event")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")

local logger = require("namespaced_logger").new("GrimmorySettings")
local GrimmoryConnector = require("connectors/grimmory_connector")

-- Contains all of the stored settings and settings UI
-- elements to control Grimmory connections & sync.

local GrimmorySettings = {
  settings = nil, -- LuaSettings handle
  data = nil, -- in-memory normalized table
}
GrimmorySettings.__index = GrimmorySettings

local SETTING_KEY = "grimmory"
local DEFAULTS = {
    synchronizedUntil = os.time(), -- plugin init time
    baseUri = "",
    username = "",
    password = "",
    sessionThresholdSeconds = 30,
    sessionThresholdPages = 0,
    syncOnCloseDocument = true,
    syncOnSuspend = true,
    syncOnPowerOff = true,
    syncEnableWifi = false,
    syncShelves = true,
    syncReadingSessions = true,
    targetShelves = {},
}

local function openSettingsHandle()
  local path = DataStorage:getSettingsDir() .. "/" .. SETTING_KEY .. ".lua"
  return LuaSettings:open(path)
end

function GrimmorySettings:new()
  local obj = setmetatable({}, self)
  obj.settings = openSettingsHandle()
  local success, result = pcall(function()
    return obj.settings:readSetting(SETTING_KEY, {}) or {}
  end)
  if success then
    obj.data = result
  else
    logger:err("Error reading settings, using defaults", result)
    obj.data = {}
  end
  return obj
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

function GrimmorySettings:showConnectionSettings()
    self.settingsDialog = MultiInputDialog:new({
        title = _("Grimmory Connection"),
        fields = {
            {
                text = self:getBaseUri(),
                description = _("Server URL"),
                hint = _("http://example.com:port"),
            },
            {
                text = self:getUsername(),
                description = _("Username"),
            },
            {
                text = self:getPassword(),
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
                    UIManager:close(self.settingsDialog)
                end,
            },
            {
                text = _("Test"),
                callback = function()
                    local fields = self.settingsDialog:getFields()

                    GrimmoryConnector:setCredentials(
                        fields[1],
                        fields[2],
                        fields[3]
                    )

                    local ok, version = GrimmoryConnector:getVersion()

                    -- Reset the credentials after the test
                    GrimmoryConnector:setCredentials(
                        self:getBaseUri(),
                        self:getUsername(),
                        self:getPassword()
                    )

                    if ok then
                        UIManager:show(InfoMessage:new({
                            text = T(_("Connection successful\nGrimmory (%1)"), tostring(version)),
                            timeout = 2,
                        }))
                    else
                        UIManager:show(InfoMessage:new({
                            text = T(_("Unable to connect to Grimmory\nError: %1"), tostring(version)),
                            timeout = 2,
                        }))
                    end

                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = self.settingsDialog:getFields()

                    self:setBaseUri(fields[1])
                    self:setUsername(fields[2])
                    self:setPassword(fields[3])

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(self.settingsDialog)
                end,
            },
            },
        },
    })

    UIManager:show(self.settingsDialog)
    self.settingsDialog:onShowKeyboard()
end

function GrimmorySettings:showTargetShelvesSettings()
    local ok, result = GrimmoryConnector:getShelves()

    if not ok then
        logger:err("Something went wrong loading shelves", result)
        return
    end

    local buttons = {
        {
            {
                text = _("Cancel Selection"),
                callback = function()
                    UIManager:close(self.settingsDialog)
                end,
            }
        },
        {
            {
                text = _("All Shelves"),
                callback = function()
                    logger:info("Set target shelves to All Shelves")
                    self:setTargetShelves({})

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(self.settingsDialog)
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
                        self:setTargetShelves({ { id = shelfId, name = uniqueShelfName } })

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(self.settingsDialog)
                    end
                }
            }
        )
    end

    self.settingsDialog = ButtonDialog:new({
        title = _("Target Shelf"),
        buttons = buttons,
    })

    UIManager:show(self.settingsDialog)
end

function GrimmorySettings:showSessionThresholdSettings()
    self.settingsDialog = MultiInputDialog:new({
        title = _("Session Thresholds"),
        fields = {
            {
                text = self:getSessionThresholdSeconds(),
                description = _("Seconds to create a session"),
                input_type = "number"
            },
            {
                text = self:getSessionThresholdPages(),
                description = _("Pages to create a session"),
                input_type = "number"
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(self.settingsDialog)
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = self.settingsDialog:getFields()

                    self:setSessionThresholdSeconds(math.max(0, fields[1]))
                    self:setSessionThresholdPages(math.max(0, fields[2]))

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(self.settingsDialog)
                end,
            },
            },
        },
    })

    UIManager:show(self.settingsDialog)
    self.settingsDialog:onShowKeyboard()
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
