local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local ltn12 = require("ltn12")

local PluginMetadata = require("_meta")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()


---@class GithubAPI
---@field base_uri string
local GithubAPI = {
    base_uri = "https://api.github.com",
}

function GithubAPI:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function GithubAPI:getUserAgent()
    return "grimmory.koplugin/" .. PluginMetadata.version .. " (" .. PluginMetadata.repository .. ")"
end

function GithubAPI:request(method, uri, data, sink)
    local client
    if uri:match("^http:") then
        client = http
    elseif uri:match("^https:") then
        client = https
    else
        return false, 0, "unknown url scheme"
    end

    local headers = {
        ["User-Agent"] = self:getUserAgent(),
        ["Accept"] = "application/vnd.github+json",
    }

    local body = nil
    local source = nil

    if data then
        body = json.encode(data)

        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = string.len(body)

        source = ltn12.source.string(body)
    end

    local response_table = {}
    if sink == nil then
        sink = ltn12.sink.table(response_table)
    end
    local _, code, _ = client.request({
        url = uri,
        method = method,
        headers = headers,
        source = source,
        sink = sink,
    })

    local response_text = table.concat(response_table)
    local response = response_text

    if response_text ~= "" then
        local success, decodedResponse = pcall(json.decode, response_text)
        if success then
            response = decodedResponse
        else
            logger:warn("Failed to parse JSON:", response_text)
        end
    end

    if type(code) ~= "number" then
        logger:err("Non-numeric response code received:", tostring(code))
        return false, 0, "Connection error: " .. tostring(code)
    end

    if code >= 400 then
        logger:dbg("Grimmory Connector Request Error", method, uri, code, response)
        if type(response) == "table" then
            if response.message then
                response = response.message
            elseif response.error then
                response = response.error
            end
        end

        return false, code, response
    end

    return true, code, response
end

---@param repository string
---@return boolean
---@return string | nil
function GithubAPI:getLatestReleaseVersion(repository)
    local ok, _, response = self:request(
        "GET",
        self.base_uri .. "/repos/" .. repository .. "/releases/latest"
    )

    if not ok or not response or type(response) == "string" then
        return false, nil
    end

    return true, response.tag_name
end

---@param repository string
---@param version string
---@return boolean ok
---@return any releaase
function GithubAPI:getRelease(repository, version)
    local ok, _, response = self:request(
        "GET",
        self.base_uri .. "/repos/" .. repository .. "/releases/tags/" .. version
    )

    if not ok or not response or type(response) == "string" then
        return false, nil
    end

    return true, response
end

---@param repository string
---@return boolean ok
---@return string | nil body
function GithubAPI:getReleaseDescription(repository, version)
    local ok, release = self:getRelease(repository, version)

    if not ok or not release then
        return false, nil
    end

    return release.body
end

---@param repository string
---@param version string
---@param name_filter string | nil
---@return boolean ok Success of the request
---@return any | nil asset The asset or nothing
function GithubAPI:getReleaseAsset(repository, version, name_filter)
    local ok, release = self:getRelease(repository, version)

    if not ok or not release then
        return false, nil
    end

    for _, asset in ipairs(release.assets) do
        if asset ~= nil then
            if name_filter == nil then
                return true, asset
            elseif type(asset.name) == "string" and asset.name:match(name_filter) then
                return true, asset
            end
        end
    end

    return false, nil
end

---@return boolean ok success
---@return string filename the filename on success or a message on failure
---@return table asset the asset definition
function GithubAPI:downloadReleaseArchive(repository, version, name_filter, download_path, progress_callback)
    local release_ok, asset = self:getReleaseAsset(repository, version, name_filter)

    if not release_ok then
        return false, tostring(asset), {}
    end

    local download_file, file_error = io.open(download_path, "wb")
    if not download_file then
        return false, file_error or "Unknown error opening file", asset
    end

    local bytes_total = asset.size
    local bytes_downloaded = 0

    local function sink(chunk, _)
        if not chunk then
            download_file:close()
            return 1
        end

        download_file:write(chunk)
        bytes_downloaded = bytes_downloaded + #chunk

        if progress_callback and asset.size > 0 then
            progress_callback(bytes_downloaded, bytes_total)
        end

        return 1
    end

    local download_ok, code, message = self:request("GET", asset.browser_download_url, nil, sink)

    if not download_ok then
        os.remove(download_path)

        if not message then
            message = "HTTP Error: " .. tostring(code)
        end

        return false, message, asset
    end

    return true, download_path, asset
end

return GithubAPI