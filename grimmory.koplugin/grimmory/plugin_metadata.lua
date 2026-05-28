local _meta = require("_meta")

local PluginMetadata = {}


---@return boolean has_repository
function PluginMetadata.hasRepository()
    return _meta.repository ~= nil
end

---@return string version
function PluginMetadata.getVersion()
    if _meta.version == nil then
        return "0.0.0-snapshot"
    end

    return tostring(_meta.version)
end

---@return string repository
function PluginMetadata.getRepository()
    if _meta.version == nil then
        return "unknown repository"
    end

    return tostring(_meta.repository)
end

return PluginMetadata