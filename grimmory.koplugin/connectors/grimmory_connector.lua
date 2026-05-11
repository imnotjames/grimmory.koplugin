local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local ltn12 = require("ltn12")

local Device = require("device")
local Version = require("version")

local logger = require("namespaced_logger").new("GrimmoryConnector")


function toISO8601(timestamp)
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

local GrimmoryConnector = {
    id = "KOReader",
    model = Device.model,
    version = Version:getCurrentRevision(),
    baseUri = nil,
    username = nil,
    password = nil,
    __accessToken = nil,
}

function GrimmoryConnector:setCredentials(baseUri, username, password)
    baseUri = baseUri:gsub("/+$", "")

    if baseUri == self.baseUri and username == self.username and password == self.password then
        -- No change, don't do anything
        return
    end

    self.baseUri = baseUri
    self.username = username
    self.password = password
    self.__accessToken = nil
end

function GrimmoryConnector:__refreshAccessToken()
    local credentials = {
        username = self.username,
        password = self.password,
    }

    local ok, _, body = self:request("POST", "/api/v1/auth/login", credentials)

    if ok and body then
        self.__accessToken = body["accessToken"]
    end

    return self.__accessToken
end

function GrimmoryConnector:__getAccessToken()
    if self.__accessToken then
        return self.__accessToken
    end

    return self:__refreshAccessToken()
end

function GrimmoryConnector:request(method, path, data, accessToken, sink)
    local url = self.baseUri .. path

    local headers = {}

    if accessToken then
        headers["Authorization"] = "Bearer " .. accessToken
    end

    local client
    if url:match("^http:") then
        client = http
    elseif url:match("^https:") then
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

    local responseTable = {}
    if sink == nil then
        sink = ltn12.sink.table(responseTable)
    end
    local _, code, _ = client.request({
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = sink,
    })

    local responseText = table.concat(responseTable)
    local response = responseText

    if responseText ~= "" then
        local success, decodedResponse = pcall(json.decode, responseText)
        if success then
            response = decodedResponse
        else
            logger:warn("Failed to parse JSON:", responseText)
        end
    end

    if type(code) ~= "number" then
        logger:err("Non-numeric response code received:", tostring(code))
        return false, 0, "Connection error: " .. tostring(code)
    end

    if code >= 400 then
        logger:dbg("Grimmory Connector Request Error", method, path, code, response)
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

function GrimmoryConnector:testConnection()
    local hasOldToken = false

    if self.__accessToken then
        hasOldToken = true
    end

    -- Check current user
    local ok, _ = self:getCurrentUser()

    -- Second attempt if we had an old token to refresh it
    if not ok and hasOldToken then
        self.__accessToken = nil

        ok, _ = self:getCurrentUser()
    end

    return ok
end

function GrimmoryConnector:getCurrentUser()
    -- Check current user
    local ok, code, body = self:request(
        "GET",
        "/api/v1/users/me",
        nil,
        self:__getAccessToken()
    )

    return ok, body
end

function GrimmoryConnector:getVersion()
    local ok, code, payload = self:request(
        "GET",
        "/api/v1/version",
        nil,
        self:__getAccessToken()
    )

    if not ok then
        local message = nil

        if type(payload) == "string" then
            message = payload
        elseif payload and payload.error then
            message = payload.error
        end

        return ok, message
    end

    return ok, payload["current"]
end

function GrimmoryConnector:getBooks()
    local ok, _, payload = self:request(
        "GET",
        "/api/v1/books?stripForListView=false",
        nil,
        self:__getAccessToken()
    )

    return ok, payload or {}
end

function GrimmoryConnector:downloadBook(bookId, destinationPath)
    local path = "/api/v1/books/" .. tonumber(bookId) .. "/download"

    local destinationFile, fileError = io.open(destinationPath, "wb")
    if not destinationFile then
        return false, fileError or "Unknown error opening file"
    end

    local sink = ltn12.sink.file(destinationFile)

    local ok, code, message = self:request("GET", path, nil, self:__getAccessToken(), sink)

    if not ok then
        os.remove(destinationPath)

        if not message then
            message = "HTTP Error: " .. tostring(code)
        end

        return false, message
    end

    return true, destinationPath
end

function GrimmoryConnector:getShelves()
    local ok, _, body = self:request(
        "GET",
        "/api/v1/shelves",
        nil,
        self:__getAccessToken()
    )

    if not ok then
        return false, body
    end

    return ok, body
end

function GrimmoryConnector:recordSession(bookId, startTime, endTime, startProgress, endProgress)
    local durationSeconds = endTime - startTime
    local progressDelta = math.max(0, endProgress - startProgress)
    local bookType = "EPUB"

    local readingSessionRequest = {
        bookId = bookId,
        bookType = bookType,
        startTime = toISO8601(startTime),
        endTime = toISO8601(endTime),
        durationSeconds = durationSeconds,
        durationFormatted = nil,
        startProgress = startProgress,
        endProgress = endProgress,
        progressDelta = progressDelta,
        startLocation = nil,
        endLocation = nil,
    }

    local ok, _, body = self:request(
        "POST",
        "/api/v1/reading-sessions",
        readingSessionRequest,
        self:__getAccessToken()
    )

    return ok, body
end

return GrimmoryConnector
