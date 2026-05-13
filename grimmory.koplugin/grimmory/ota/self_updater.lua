local _ = require("gettext")
local T = require("ffi/util").template

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local NetworkManager = require("ui/network/manager")
local util = require("util")

local PluginMetadata = require("_meta")

local logger = require("grimmory/logger").new("GrimmorySelfUpdater")


local AUTOMATIC_UPDATE_SECONDS = 7200

local function getPluginPath()
    local source = debug.getinfo(1, "S").source
    local path = source:match("@(.*)/")
    if not path or not path:match("%.koplugin$") then
        path = DataStorage:getDataDir() .. "/plugins/grimmory.koplugin"
    end

    return path
end

local function findPluginInArchive(reader)
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local entry_directory, entry_filename = util.splitFilePathName(entry.path)
            if entry_filename == "_meta.lua" then
                return entry_directory
            end
        end
    end

    return ""
end

---@param version string
local function parseVersion(version)
    local major, minor, patch, labels = tostring(version):match("v?(%d+)%.(%d+)%.(%d+)(.*)")

    local prerelease = nil
    local build = nil

    if labels then
        local build_indicator_index = labels:find("+") or (#labels + 1)

        if labels:sub(1, 1) == "-" then
            prerelease = labels:sub(2, build_indicator_index - 1)
            labels = labels:sub(build_indicator_index)
        end

        if labels:sub(1, 1) == "+" then
            build = labels:sub(2)
        end
    end

    return tonumber(major), tonumber(minor), tonumber(patch), prerelease, build
end

---@param version_a string
---@param version_b string
local function isVersionLater(version_a, version_b)
    local major_a, minor_a, patch_a, prerelease_a = parseVersion(version_a)
    local major_b, minor_b, patch_b, prerelease_b = parseVersion(version_b)

    if major_b > major_a then
        return true
    end

    if minor_b > minor_a then
        return true
    end

    if patch_b > patch_a then
        return true
    end

    if prerelease_b ~= prerelease_a then
        return true
    end

    return false
end

---@class GrimmorySelfUpdater
---@field settings GrimmorySettings
---@field scheduler GrimmoryScheduler
---@field github_api GithubAPI
---@field repository string
---@field latest_known_version string | nil
---@field is_pending_restart boolean
---@field cancel_automatic_updates function
local GrimmorySelfUpdater = {
    plugin_path = getPluginPath(),
    release_asset_name = "%a+.koplugin.zip",
    release_cache_path = DataStorage:getDataDir() .. "/cache/grimmory"
}

function GrimmorySelfUpdater:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmorySelfUpdater:init()
    -- If automatic updates is enabled, schedule interval.
    if self.settings:getAutomaticCheckUpdates() then
        self.cancel_automatic_updates = self.scheduler:interval(
            AUTOMATIC_UPDATE_SECONDS,
            self.fetchLatestVersion,
            self
        )

        self:fetchLatestVersion()
    end
end

function GrimmorySelfUpdater:isPendingRestart()
    return self.is_pending_restart
end

function GrimmorySelfUpdater:isUpdateAvailable()
    local current_version = PluginMetadata.version
    local latest_version = self.latest_known_version or current_version

    return isVersionLater(current_version, latest_version)
end

function GrimmorySelfUpdater:getLatestReleaseVersion()
    -- Get the latest release version from github
    local current_version = PluginMetadata.version
    return self.latest_known_version or current_version
end

function GrimmorySelfUpdater:fetchLatestVersion()
    local ok, version = self.github_api:getLatestReleaseVersion(
        PluginMetadata.repository
    )

    if not ok or not version then
        return
    end

    self.latest_known_version = version
end

function GrimmorySelfUpdater:downloadLatestRelease(progress_callback)
    if not self.latest_known_version then
        logger:err("Latest release is not defined")
        return false, _("No latest release")
    end

    local download_path = self.release_cache_path .. "/plugin-" .. self.latest_known_version .. "-" .. os.time() .. ".zip"

    local download_directory, _ = util.splitFilePathName(download_path)

    local directory_exists, directory_error_message = util.makePath(download_directory)
    if not directory_exists then
        return false, directory_error_message
    end

    local ok, result = self.github_api:downloadReleaseArchive(
        PluginMetadata.repository,
        self.latest_known_version,
        self.release_asset_name,
        download_path,
        function(bytes_downloaded, bytes_total)
            if progress_callback then
                progress_callback(
                    "download",
                    math.floor(100 * bytes_downloaded / bytes_total)
                )
            end
        end
    )

    if not ok then
        logger:err("Failed to download release", result)
        return false, result
    end

    return true, download_path
end

function GrimmorySelfUpdater:extractPlugin(source_path, target_path)
    local reader = Archiver.Reader:new()
    if not reader:open(source_path) then
        return false, _("Failed to open downloaded archive.")
    end

    local directory_exists, directory_error_message = util.makePath(self.plugin_path)
    if not directory_exists then
        reader:close()

        return false, directory_error_message
    end

    local plugin_root = findPluginInArchive(reader)

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path:sub(0, #plugin_root) == plugin_root then
            local entry_path = entry.path:sub(#plugin_root + 1)

            local extract_path = target_path .. "/" .. entry_path

            local parent, _ = util.splitFilePathName(extract_path)
            if parent and parent ~= "" then
                util.makePath(parent)
            end

            local ok = reader:extractToPath(entry.path, extract_path)

            if not ok then
                return false, _(T("Failed to extract file: %1", entry.path))
            end

        end
    end
    return true, nil
end

function GrimmorySelfUpdater:update(progress_callback)
    NetworkManager:goOnlineToRun(function()
        local download_ok, download_path = self:downloadLatestRelease(progress_callback)

        if not download_ok then
            if progress_callback then
                progress_callback("failed", 100, download_path)
            end
            return
        end

        local extract_ok, extract_message = self:extractPlugin(download_path, self.plugin_path)

        util.removeFile(download_path)

        if not extract_ok then
            logger:err("Extraction failed:", extract_message)
            if progress_callback then
                progress_callback("failed", 100, extract_message)
            end
            return
        end

        self.is_pending_restart = true

        if progress_callback then
            progress_callback("complete", 100, nil)
        end
    end)
end

return GrimmorySelfUpdater