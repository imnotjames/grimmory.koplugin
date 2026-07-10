local DataStorage = require("datastorage")
local PluginLoader = require("pluginloader")
local util = require("util")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

local function get_plugin_path()
        -- local source = debug.getinfo(1, "S").source
        -- local path = source:match("@(.*%.koplugin)/")
        if path and util.directoryExists(path) then
            return path
        end

        if not path then
            -- If for some reason the debug.getinfo won't get us our plugin
            -- path, we need to fall back to the plugin loader.  This is because
            -- in some cases (like with the MultiUser plugin) our data dir may
            -- not actually have our plugin!
            local all_plugins = PluginLoader._discover()

            for _, plugin in ipairs(all_plugins) do
                if plugin.name == "grimmory.koplugin" then
                    return plugin.path
                end
            end
        end

        -- Fall back to DataStorage:getDataDir()`
        return DataStorage:getDataDir() .. "/plugins/grimmory.koplugin"
end

---@class GrimmoryPluginMetadata
local PluginMetadata = {
    plugin_path = nil,
    meta = nil,
}

function PluginMetadata.getPluginPath()
    if PluginMetadata.plugin_path == nil then
        PluginMetadata.plugin_path = get_plugin_path()
        logger:dbg("Resolved plugin path:", PluginMetadata.plugin_path)
    end

    return PluginMetadata.plugin_path
end

function PluginMetadata.getMeta()
    if PluginMetadata.meta == nil then
        local plugin_path = PluginMetadata.getPluginPath()
        local meta_path = plugin_path .. "/_meta.lua"

        local load_ok, meta = pcall(dofile, meta_path)

        if load_ok and type(meta) == "table" then
            PluginMetadata.meta = meta
        else
            logger:err("Failed to load meta:", meta or "Unknown error")
            PluginMetadata.meta = false
        end
    end

    return PluginMetadata.meta or {}
end

---@return boolean has_repository
function PluginMetadata.hasRepository()
    local meta = PluginMetadata.getMeta()

    return type(meta.repository) == "string"
end

---@return string version
function PluginMetadata.getVersion()
    local meta = PluginMetadata.getMeta()

    if type(meta.version) ~= "string" then
        return "0.0.0-snapshot"
    end

    return meta.version
end

---@return string repository
function PluginMetadata.getRepository()
    local meta = PluginMetadata.getMeta()

    if type(meta.repository) ~= "string" then
        return "unknown repository"
    end

    return meta.repository
end

return PluginMetadata