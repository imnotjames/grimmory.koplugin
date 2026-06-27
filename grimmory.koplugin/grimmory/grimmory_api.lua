local _ = require("gettext")
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local ltn12 = require("ltn12")

local PluginMetadata = require("grimmory/plugin_metadata")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()



local function from_json_nullable(value)
    if type(value) == "function" then
        -- Handle JSON encoded null wonk.  Since the
        -- LUA `nil` cannot be stored in a table,
        -- the JSON encoder will use a special `null`
        -- function instead.
        value = value()
    end


    return value
end

---@param value any
---@param converter function
local function from_json_value(value, converter, default_value)
    value = from_json_nullable(value)

    if value == nil then
        return default_value
    end

    return converter(value)
end

local function from_json_string(value, default_value)
    return from_json_value(value, tostring, default_value)
end

local function from_json_number(value, default_value)
    return from_json_value(value, tonumber, default_value)
end

local function from_json_bool(value, default_value)
        if type(value) == "function" then
        -- Handle JSON encoded null wonk.  Since the
        -- LUA `nil` cannot be stored in a table,
        -- the JSON encoder will use a special `null`
        -- function instead.
        value = value()
    end

    if value == nil then
        return default_value == true
    end

    return value == true
end

---@param timestamp number
local function to_iso8601(timestamp)
    if timestamp == nil then
        return nil
    end

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
local function from_iso8601(value)
    local year, month, day, hour, min, sec = value:match(
        "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
    )

    return os.time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec
    })
end

local function from_json_iso8601(value)
    value = from_json_string(value)

    if value == nil then
        return nil
    end

    return from_iso8601(value)
end

---@class BookMetadata
---@field isbn13 string | nil
---@field isbn10 string | nil
---@field asin string | nil
---@field title string | nil

---@class BookFile
---@field filename string

---@class Book
---@field id number
---@field added_on number
---@field shelves number[]
---@field metadata BookMetadata
---@field primary_file BookFile | nil

local function parse_book(book)
    local shelves = {}

    local book_shelves = from_json_nullable(book["shelves"])
    if book_shelves then
        for _, shelf in ipairs(book_shelves) do
            table.insert(shelves, from_json_number(shelf.id))
        end
    end

    local book_metadata = from_json_nullable(book["metadata"]) or {}
    ---@type BookMetadata
    local metadata = {
        isbn10 = from_json_string(book_metadata["isbn10"]),
        isbn13 = from_json_string(book_metadata["isbn13"]),
        asin = from_json_string(book_metadata["asin"]),
        title = from_json_string(book_metadata["title"]),
    }

    local primary_file = nil

    local book_primary_file = from_json_nullable(book["primaryFile"])

    if book_primary_file ~= nil then
        primary_file = {
            filename = from_json_string(book_primary_file["fileName"])
        }
    end

    return {
        id = from_json_number(book.id),
        added_on = from_json_iso8601(book["addedOn"]),
        shelves = shelves,
        metadata = metadata,
        primary_file = primary_file
    }
end

local function getUserAgent()
    return "grimmory.koplugin/" .. PluginMetadata.getVersion() .. " (" .. PluginMetadata.getRepository() .. ")"
end

---@class GrimmoryAPI
---@field settings GrimmorySettings
---@field private cached_access_token string
---@field private cached_refresh_token string
---@field private cached_token_expiry number
local GrimmoryAPI = {}

function GrimmoryAPI:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryAPI:init()
    -- TODO: Watch base URI / username / password fields to reset access token

end

function GrimmoryAPI:getUri(path)
    local base_uri = self.settings:getBaseUri():gsub("/+$", "")

    return base_uri .. path
end

function GrimmoryAPI:refreshToken(refresh_token)
    local uri = self:getUri("/api/v1/auth/refresh")

    local credentials = {
        refreshToken = refresh_token,
    }

    local ok, _, body = self:rawRequest("POST", uri, credentials)

    if not ok or not body then
        return false, nil, nil, 0
    end

    local access_token = from_json_string(body["accessToken"])
    local new_refresh_token = from_json_string(body["refreshToken"])
    local expires = from_json_number(body["expires"])

    return ok, access_token, new_refresh_token, expires
end

---@param base_uri string
---@param username string
---@param password string
---@return boolean ok
---@return string | nil access_token
---@return string | nil refresh_token
---@return number expiry
function GrimmoryAPI:getToken(base_uri, username, password)
    local uri = base_uri .. "/api/v1/auth/login"

    local credentials = {
        username = username,
        password = password,
    }

    local ok, _, body = self:rawRequest("POST", uri, credentials)

    if not ok or not body then
        if type(body) == "string" then
            logger:err("Unable to get refresh token:", body)
            return false, body, body, 0
        else
            logger:err("Unable to get refresh token:", "Unknown Error")
            return false, nil, nil, 0
        end
    end

    local access_token = from_json_string(body["accessToken"])
    local refresh_token = from_json_string(body["refreshToken"])
    local expires = from_json_number(body["expires"])

    return ok, access_token, refresh_token, expires
end


function GrimmoryAPI:rawRequest(method, uri, data, headers, sink)
    headers = headers or {}

    headers["User-Agent"] = getUserAgent()

    for key, value in pairs(self.settings:getExtraHeaders()) do
        headers[key] = value
    end

    local client
    if uri:match("^http:") then
        client = http
    elseif uri:match("^https:") then
        client = https
    else
        return false, 0, "unknown url scheme"
    end

    local source = nil

    if data then
        local body = json.encode(data)

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
        return false, 0, tostring(code)
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

    if self.cached_refresh_token ~= nil and self.cached_token_expiry <= os.time() then
        -- If token exists but is expired, try to refresh

        local refresk_token_ok, access_token, refresh_token, expiration = self:refreshToken(
            self.cached_refresh_token
        )

        if refresk_token_ok and access_token and refresh_token then
            self.cached_token_expiry = os.time() + (expiration or 3600)
            self.cached_refresh_token = refresh_token
            self.cached_access_token = access_token
        else
            -- We're expired and can't refresh.  Toss out the cached
            -- token data and let the block below do its deal.
            self.cached_token_expiry = 0
            self.cached_refresh_token = nil
            self.cached_access_token = nil
        end
    end

    if self.cached_access_token == nil then
        local access_token_ok, access_token, refresh_token, expiration = self:getToken(
            self.settings:getBaseUri(),
            self.settings:getUsername(),
            self.settings:getPassword()
        )

        if not access_token_ok or not access_token or not refresh_token then
            return false, 0, "Could not get access token"
        end

        -- Default expiration to 2 minutes if it's not defined.
        -- For Grimmory this is "safe" as we usually default to 7200
        self.cached_token_expiry = os.time() + (expiration or 3600)
        self.cached_refresh_token = refresh_token
        self.cached_access_token = access_token
    end

    if self.cached_access_token then
        headers["Authorization"] = "Bearer " .. self.cached_access_token
    end

    local ok, code, response = self:rawRequest(method, uri, data, headers, sink)

    if code == 401 then
        logger:warn("Token expired or was otherwise invalid")
        self.cached_token_expiry = nil
        self.cached_refresh_token = nil
        self.cached_access_token = nil
    end


    return ok, code, response
end

function GrimmoryAPI:testConnection(base_uri, username, password)
    base_uri = base_uri:gsub("/+$", "")

    local access_token_ok, access_token = self:getToken(
        base_uri,
        username,
        password
    )

    if not access_token_ok then
        return false, access_token
    end

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

    return ok, from_json_string(body["current"])
end

---@return boolean ok
---@return string | nil currnet_version
function GrimmoryAPI:getServerVersion()
    local ok, _, body = self:request(
        "GET",
        "/api/v1/version"
    )

    if not ok then
        if body then
            return false, tostring(body)
        else
            return false, nil
        end
    end

    return ok, from_json_string(body["current"])
end

---@return boolean ok
---@return Book[] | string page_books
---@return number total_count
function GrimmoryAPI:getBooksPage(page_number)
    local ok, _, body = self:request(
        "GET",
        "/api/v1/books/page?sort=addedOn,asc&page=" .. tostring(page_number or 0)
    )

    if not ok or type(body) == "string" then
        logger:err("Could not get books", body)
        return ok, body, 0
    end

    local books = {}

    if type(body.content) == "table" then
        for _, raw_book in ipairs(body.content) do
            table.insert(books, parse_book(raw_book))
        end
    end

    local total_count = 0
    if type(body.page) == "table" and type(body.page.totalElements) == "number" then
        total_count = body.page.totalElements
    end

    return ok, books, total_count
end

---@return (fun(): (Book | nil, integer, integer))
function GrimmoryAPI:getBooks()
    local page = 0
    local batch_index = 0
    local book_index = 0

    local books_ok, books_batch, total_books = self:getBooksPage(page)

    if not books_ok then
        logger:err("Unable to read books:", books_batch)
        return function()
            return nil, 0, 0
        end
    end

    return function ()
        if type(books_batch) ~= "table" or #books_batch == 0 then
            return nil, book_index, total_books
        end

        if batch_index >= #books_batch then
            -- If current_index is past the current batch
            page = page + 1

            local new_books_ok, new_books_batch, new_total_books = self:getBooksPage(page)
            batch_index = 0

            if not new_books_ok or type(new_books_batch) ~= "table" then
                logger:err("Unable to read books:", new_books_batch)

                -- Set the books batch to empty so we basically stop iteration
                books_batch = {}

                return nil, book_index, total_books
            end

            books_batch = new_books_batch
            total_books = new_total_books
        end

        batch_index = batch_index + 1
        book_index = book_index + 1

        return books_batch[batch_index], book_index, total_books
    end

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
        logger:err("Could not get shelves", body)
        return false, body
    end

    local shelves = {}
    for _, body_shelf in ipairs(body) do
        local shelf = {
            id = from_json_number(body_shelf.id),
            name = from_json_string(body_shelf.name),
        }

        table.insert(shelves, shelf)
    end

    return ok, shelves
end

---@param book_id number
---@param start_time number
---@param end_time number
---@param start_progress number
---@param end_progress number
---@param start_location string
---@param end_location string
function GrimmoryAPI:recordSession(
    book_id,
    start_time,
    end_time,
    start_progress,
    end_progress,
    start_location,
    end_location
)
    local duration_seconds = end_time - start_time
    local progress_delta = math.max(0, end_progress - start_progress)

    local book_type = "EPUB"

    local request = {
        bookId = book_id,
        bookType = book_type,
        startTime = to_iso8601(start_time),
        endTime = to_iso8601(end_time),
        durationSeconds = duration_seconds,
        durationFormatted = nil,
        startProgress = start_progress,
        endProgress = end_progress,
        progressDelta = progress_delta,
        startLocation = start_location,
        endLocation = end_location,
    }

    local ok, _, body = self:request(
        "POST",
        "/api/v1/reading-sessions",
        request
    )

    if not ok then
        logger:err("Unable to record session", body)
    end

    return ok, body
end

function GrimmoryAPI:getKoreaderSync()
    local ok, _, body = self:request(
        "GET",
        "/api/v1/koreader-users/me"
    )

    if not ok or not body then
        logger:err("Could not get koreader sync status", body)
        return false, nil
    end

    return true, from_json_bool(body["syncEnabled"])
end

---@param enabled boolean
function GrimmoryAPI:setKoreaderSync(enabled)
    local ok, _, body = self:request(
        "PATCH",
        "/api/v1/koreader-users/me/sync?enabled=" .. tostring(enabled)
    )

    if not ok then
        logger:err("Could not set koreader sync status", body)
        return false, body
    end

    return true, nil
end

---@return boolean ok
---@return string | nil auth_id
---@return string | nil auth_secret
function GrimmoryAPI:getKoreaderCredentials()
    local ok, _, body = self:request(
        "GET",
        "/api/v1/koreader-users/me"
    )

    if not ok or not body then
        logger:err("Could not get koreader credentials", body)
        return false, nil, nil
    end

    return true, from_json_string(body["username"]), from_json_string(body["password"])
end

function GrimmoryAPI:setKoreaderCredentials(auth_key, auth_secret)
    local request = {
        username = auth_key,
        password = auth_secret,
    }

    local ok, _, body = self:request(
        "PUT",
        "/api/v1/koreader-users/me",
        request
    )

    if not ok or not body then
        return false
    end

    return true
end

function GrimmoryAPI:pushReadingProgress(
    username,
    auth_key,
    device,
    device_id,
    book_md5,
    timestamp,
    percentage,
    location
)
    local request = {
        document = book_md5,
        timestamp = timestamp,
        percentage = percentage,
        progress = location,
        device = device,
        device_id = device_id,
    }

    local headers = {
        ["x-auth-user"] = username,
        ["x-auth-key"] = auth_key,
    }

    local ok, _, body = self:request(
        "PUT",
        "/api/koreader/syncs/progress",
        request,
        headers
    )

    if not ok then
        logger:err("Unable to push progress for book:", book_md5, "-", body)
        return false, body
    end

    return ok, nil
end

---@param username string
---@param auth_key string
---@param book_md5 string
function GrimmoryAPI:getReadingProgress(username, auth_key, book_md5)
    local headers = {
        ["x-auth-user"] = username,
        ["x-auth-key"] = auth_key,
    }

    local ok, code, body = self:request(
        "GET",
        "/api/koreader/syncs/progress/" .. book_md5,
        nil,
        headers
    )

    if code == 404 then
        -- With a 404 we can just say there's no progress
        return true, nil
    end

    if not ok or not body or type(body) == "string" then
        logger:err("Unable to read progress for book:", book_md5, "-", body)
        return false, nil
    end

    local progress = {
        timestamp = from_json_number(body.timestamp),
        document = from_json_string(body.document),
        percentage = from_json_number(body.percentage),
        progress = from_json_string(body.progress),
        device = from_json_string(body.device),
        device_id = from_json_string(body.device_id),
    }

    return ok, progress
end

return GrimmoryAPI
