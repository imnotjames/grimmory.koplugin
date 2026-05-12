local logger = require("logger")

local NamespacedLogger = {
    name = "Grimmory",
}
NamespacedLogger.__index = NamespacedLogger

function NamespacedLogger.new(name)
    local self = setmetatable({}, NamespacedLogger)
    self.name = name
    return self
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