local Device = require("device")
local NetworkManager = require("ui/network/manager")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

local WifiManager = {}

function WifiManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function WifiManager:isConnected()
    local ok, result = pcall(function()
        return NetworkManager:isConnected()
    end)

    if not ok then
        logger:err("Something went wrong checking wifi connectivity", result)
        return true
    end

    return result
end

function WifiManager:withWifi(callback)
  if NetworkManager:isWifiOn() and NetworkManager:isConnected() then
    callback(false)
    return
  end

  if not Device:hasWifiRestore() then
    logger:err("Requested with wifi but cannot enable")
    return
  end

  local original_on = NetworkManager.wifi_was_on

  NetworkManager:turnOnWifiAndWaitForConnection(function()
    -- restore original "was on" state to prevent wifi
    -- being restored automatically after suspend
    NetworkManager.wifi_was_on = original_on

    self.connection_pending = false

    callback(true)

    NetworkManager:turnOffWifi()
  end)
end

return WifiManager