local Device = require("device")
local NetworkManager = require("ui/network/manager")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class WifiManager
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

  if not Device:hasWifiToggle() then
    logger:err("Requested with wifi but cannot enable")
    return
  end

  local original_on = NetworkManager.wifi_was_on
  local calling_coroutine = coroutine.running()

  NetworkManager:turnOnWifiAndWaitForConnection(function()
    -- restore original "was on" state to prevent wifi
    -- being restored automatically after suspend
    NetworkManager.wifi_was_on = original_on
    self.connection_pending = false
    if calling_coroutine and coroutine.status(calling_coroutine) == "suspended" then
      -- resume back into the original coroutine so `callback`
      -- (and anything it calls, like GrimmoryExecutor:run)
      -- executes with the correct coroutine context
      local ok, err = coroutine.resume(calling_coroutine, callback)
      if not ok then
          logger:err("Error resuming coroutine after wifi connect:", err)
      end
    end
  end)

  local resumed_callback = coroutine.yield()
  if resumed_callback then
      resumed_callback(false)
  end

  NetworkManager:turnOffWifi()
end

return WifiManager