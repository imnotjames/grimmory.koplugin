local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local ltn12 = require("ltn12")
local Device = require("device")
local Version = require("version")

local logger = require("grimmory/logger").new("GrimmoryAPI")


---@param timestamp number
local function toISO8601(timestamp)
    local parsed = os.date("!*t", timestamp)
    return string.format(
        "%04d-%02d-%02dT%02d:%02d:%02dZ",
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.min,
        parsed.sec
    )
end

---@param value string
local function fromISO8601(value)
    local year, month, day, hour, min, sec = value:match(
        "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
    )

    return os.time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        ec = sec
    })
end

---@param api GrimmoryAPI
---@param base_uri string
---@param username string
---@param password string
local function getAccessToken(api, base_uri, username, password)
    local uri = base_uri .. "/api/v1/auth/login"

    local credentials = {
        username = username,
        password = password,
    }

    local ok, _, body = api:rawRequest("POST", uri, credentials)

    if ok and body then
        return body["accessToken"]
    end

    return nil
end

---@class BookMetadata
---@field isbn13 string | nil
---@field isbn10 string | nil
---@field asin string | nil
---@field title string | nil
---@field authors string[] | nil

---@class BookFile
---@field filename string

---@class Book
---@field id number
---@field added_on number
---@field shelves number[]
---@field metadata BookMetadata
---@field primary_file BookFile | nil

local function parseBook(book)
    local shelves = {}

    if book["shelves"] then
        for _, shelf in ipairs(book["shelves"]) do
            table.insert(shelves, shelf.id)
        end
    end

    ---@type BookMetadata
    local metadata = {
        isbn10 = book["metadata"]["isbn10"],
        isbn13 = book["metadata"]["isbn13"],
        asin = book["metadata"]["asin"],
        title = book["metadata"]["title"],
        authors = book["metadata"]["authors"],
    }

    local primary_file = nil
    
    if book["primaryFile"] and book["primaryFile"]["fileName"] then
        primary_file = {
            filename = book["primaryFile"]["fileName"]
        }
    end

    return {
        id = book.id,
        added_on = fromISO8601(book["addedOn"]),
        shelves = shelves,
        metadata = metadata,
        primary_file = primary_file
    }
end

---@class GrimmoryAPI
local GrimmoryAPI = {
    ---@type GrimmorySettings
    settings = nil,
    id = "KOReader",
    model = Device.model,
    version = Version:getCurrentRevision(),
    cached_access_token = nil,
}
GrimmoryAPI.__index = GrimmoryAPI

function GrimmoryAPI:new(o)
  local new_self = setmetatable(o, self)
  new_self:init()
  return new_self
end

function GrimmoryAPI:init()
    -- TODO: Watch base URI / username / password fields to reset access token

end

function GrimmoryAPI:getUri(path)
    local base_uri = self.settings:getBaseUri():gsub("/+$", "")

    return base_uri .. path
end

function GrimmoryAPI:rawRequest(method, uri, data, headers, sink)
    headers = headers or {}

    local client
    if uri:match("^http:") then
        client = http
    elseif uri:match("^https:") then
        client = https
    else
        return false, 0, "unknown url scheme"
    end

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

function GrimmoryAPI:request(method, path, data, headers, sink)
    headers = headers or {}

    local uri = self:getUri(path)

    local access_token = self.cached_access_token

    if access_token == nil then
        access_token = getAccessToken(
            self,
            self.settings:getBaseUri(),
            self.settings:getUsername(),
            self.settings:getPassword()
        )
        self.cached_access_token = access_token
    end

    if access_token then
        headers["Authorization"] = "Bearer " .. access_token
    end

    return self:rawRequest(method, uri, data, headers, sink)
end

function GrimmoryAPI:testConnection(base_uri, username, password)
    base_uri = base_uri:gsub("/+$", "") 

    local access_token = getAccessToken(
        self,
        base_uri,
        username,
        password
    )

    local headers = {}

    if access_token then
        headers["Authorization"] = "Bearer " .. access_token
    end

    local ok, _, body = self:rawRequest(
        "GET",
        base_uri .. "/api/v1/version",
        nil,
        headers
    )

    if not ok then
        return false, body
    end

    return ok, body["current"]
end

---@return boolean ok
---@return Book[] | string
function GrimmoryAPI:getBooks()
    local ok, _, body = self:request(
        "GET",
        "/api/v1/books?stripForListView=false"
    )

    if not ok or type(body) == "string" then
        return ok, body
    end

    local books = {}

    for _, raw_book in ipairs(body) do
        table.insert(books, parseBook(raw_book))
    end

    return ok, books
end

function GrimmoryAPI:downloadBook(book_id, destination_path)
    local path = "/api/v1/books/" .. tonumber(book_id) .. "/download"

    local destination_file, file_error = io.open(destination_path, "wb")
    if not destination_file then
        return false, file_error or "Unknown error opening file"
    end

    local sink = ltn12.sink.file(destination_file)

    local ok, code, message = self:request("GET", path, nil, nil, sink)

    if not ok then
        os.remove(destination_path)

        if not message then
            message = "HTTP Error: " .. tostring(code)
        end

        return false, message
    end

    return true, destination_path
end

function GrimmoryAPI:getShelves()
    local ok, _, body = self:request(
        "GET",
        "/api/v1/shelves"
    )

    if not ok then
        return false, body
    end

    return ok, body
end

function GrimmoryAPI:recordSession(book_id, start_time, end_time, start_progress, end_progress)
    local duration_seconds = end_time - start_time
    local progress_delta = math.max(0, end_progress - start_progress)

    local book_type = "EPUB"

    local request = {
        bookId = book_id,
        bookType = book_type,
        startTime = toISO8601(start_time),
        endTime = toISO8601(end_time),
        durationSeconds = duration_seconds,
        durationFormatted = nil,
        startProgress = start_progress,
        endProgress = end_progress,
        progressDelta = progress_delta,
        startLocation = nil,
        endLocation = nil,
    }

    local ok, _, body = self:request(
        "POST",
        "/api/v1/reading-sessions",
        request
    )

    return ok, body
end

return GrimmoryAPI
