local logger = require("logger")
local util = require("util")

local function getPluginPath()
    local source = debug.getinfo(3, "S").source
    local path, _ = util.splitFileNameSuffix(source)
    local plugin_path = path:sub(path:find(".koplugin/") + 10)
    return "grimmory.koplugin/" .. plugin_path
end

local NamespacedLogger = {}

function NamespacedLogger:new()
    local obj = {
        name = getPluginPath()
    }
    setmetatable(obj, self)
    self.__index = self
    return obj
end

function NamespacedLogger:dbg(...)
    return logger.dbg(self.name, ...)
end

function NamespacedLogger:info(...)
    return logger.info(self.name, ...)
end

function NamespacedLogger:warn(...)
    return logger.warn(self.name, ...)
end

function NamespacedLogger:err(...)
    return logger.err(self.name, ...)
end

return NamespacedLogger