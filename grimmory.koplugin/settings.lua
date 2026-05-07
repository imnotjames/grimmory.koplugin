local _ = require("gettext")
local T = require("ffi/util").template

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

                ok, version = GrimmoryConnector:getVersion()

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

                UIManager:sendEvent(Event:new("GrimmorySettingsChanged"))

                UIManager:close(self.settingsDialog)
                UIManager:show(InfoMessage:new({ text = _("Grimmory connection saved."), timeout = 2 }))
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

function GrimmorySettings:getSynchronizedUntil()
    return self.data.synchronizedUntil or DEFAULTS.synchronizedUntil
end

function GrimmorySettings:setSynchronizedUntil(synchronizedUntil)
    self:update({ synchronizedUntil = synchronizedUntil })
end

return GrimmorySettings
