local _meta = require("_meta")

---@class GrimmoryPluginMetadata
local PluginMetadata = {}


---@return boolean has_repository
function PluginMetadata.hasRepository()
    return type(_meta.repository) == "string"
end

---@return string version
function PluginMetadata.getVersion()
    if type(_meta.version) ~= "string" then
        return "0.0.0-snapshot"
    end

    return _meta.version
end

---@return string repository
function PluginMetadata.getRepository()
    if type(_meta.repository) ~= "string" then
        return "unknown repository"
    end

    return _meta.repository
end

return PluginMetadata