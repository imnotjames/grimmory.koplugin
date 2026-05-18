local ffiutil = require("ffi/util")
local ffi = require("ffi")
local json = require("json")
local UIManager = require("ui/uimanager")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

local function readFromFD(fd)
    local ffi_buffer = ffi.new('char[?]', 1, {0})
    local data = {}

    if ffiutil.getNonBlockingReadSize(fd) == 0 then
        return ""
    end

    while true do
        local bytes_read = tonumber(ffi.C.read(fd, ffi.cast('void*', ffi_buffer), 1))
        if bytes_read < 0 then
            local err = ffi.errno()
            logger:err("readFromFD()", ffi.string(ffi.C.strerror(err)))
            break
        elseif bytes_read == 0 then -- EOF, no more data to read
            break
        else
            local bytes_str = ffi.string(ffi_buffer, bytes_read)

            if bytes_str == "\0" then
                break
            end

            table.insert(data, bytes_str)
        end
    end

    return table.concat(data)
end

local function writeToFD(fd, data)
    local size = #data
    local ptr = ffi.cast("uint8_t *", data)

    ffi.C.write(fd, ptr, size)
    ffi.C.write(fd, ffi.cast("uint8_t *", "\0"), 1)
    ffi.C.fdatasync(fd)
end

local function writeObjectToFD(fd, obj)
    local ok, str = pcall(json.encode, obj)

    if not ok then
        logger:err("Could not serialize progress state from subprocess:", str)
        return false, str
    end

    local write_ok, write_result = pcall(writeToFD, fd, str)

    if not write_ok then
        logger:err("Could not write progress state back from subprocess:", write_result)
        return false, write_result
    end

    return true, nil
end

---@class GrimmoryExecutor
---@field private running_subprocesses any[]
local GrimmoryExecutor = {}

function GrimmoryExecutor:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryExecutor:init()
    self.running_subprocesses = self.running_subprocesses or {}
end

function GrimmoryExecutor:clear()
    while true do
        local subprocess_pid = table.remove(self.running_subprocesses)

        if not subprocess_pid then
            break
        end

        ffiutil.terminateSubProcess(subprocess_pid)
    end
end

function GrimmoryExecutor:wrap(func)
    -- Catch and log any error happening in func (an error happening
    -- in a coroutine just aborts silently the coroutine)
    local pcalled_func = function()
        -- we use xpcall as it can give a whole stacktrace, unlike pcall
        local ok, err = xpcall(func, debug.traceback)

        if not ok then
            logger:warn("error in wrapped function:", err)
            return false
        end
        return true
        -- As a coroutine, we will return at first coroutine.yield(),
        -- and the above true/false won't probably be caught by
        -- any code, but let's do it anyway.
    end
    local co = coroutine.create(pcalled_func)
    return coroutine.resume(co)
end

---@alias GrimmoryRunnableProgressCallback function(state: any, terminate: function): bool
---@alias GrimmoryRunnable function(callback: BackgroundRunnableProgressCallback)

---@param runnable GrimmoryRunnable
---@param on_progress GrimmoryRunnableProgressCallback
---@return boolean ok
---@return any result
function GrimmoryExecutor:run(runnable, on_progress)
    local running_coroutine = coroutine.running()

    if not running_coroutine then
        logger:warn("Unwrapped GrimmoryExecutor run command")
        return false, "Unwrapped GrimmoryExecutor run command"
    end

    UIManager:preventStandby()

    local subprocess_pid, parent_read_fd = ffiutil.runInSubProcess(
        function(my_pid, child_write_fd)
            ---@type GrimmoryRunnableProgressCallback
            local function progress_callback(state)
                local write_ok, write_result = writeObjectToFD(child_write_fd, state)

                if not write_ok then
                    logger:err("Could not write progress state back from subprocess:", write_result)
                end

                return true
            end

            local runnable_ok, runnable_result = pcall(runnable, progress_callback)

            local runnable_result = {
                __runnable_ok = runnable_ok,
                __runnable_result = runnable_result,
            }

            local write_ok, write_result = writeObjectToFD(child_write_fd, runnable_result)

            if not write_ok then
                logger:err("Could not write final state back from subprocess:", write_result)
            end

            -- Close the handle manually.
            pcall(ffi.C.close, child_write_fd)

            -- Kill the subprocess because nothing else seems to stop
            -- it when we are using the `runInSubProcess` helper.
            ffi.C.kill(my_pid, 9)
        end,
        true
    )

    local subprocess_ok = false
    local subprocess_result = nil

    if subprocess_pid then
        table.insert(self.running_subprocesses, subprocess_pid)

        local terminate = function()
            ffiutil.terminateSubProcess(subprocess_pid)
        end

        while true do
            local messages_received = 0
            local state_data = readFromFD(parent_read_fd)
            while state_data ~= "" do
                local decode_ok, state = pcall(json.decode, state_data)
                if decode_ok then
                    if state and state.__runnable_ok ~= nil then
                        subprocess_ok = state.__runnable_ok
                        subprocess_result = state.__runnable_result
                    else
                        pcall(on_progress, state, terminate)
                    end
                else
                    logger:err("Failed to decode state data received from subprocess:", state)
                end

                messages_received = messages_received + 1

                if messages_received > 3 then
                    -- If we keep receiving messages we should hand
                    -- back to the UI thread for a bit.
                    break
                end

                state_data = readFromFD(parent_read_fd)
            end

            -- Even if the subprocess is done, if we haven't exhausted
            -- all of the messages we have to keep running.
            local is_subprocess_done = ffiutil.isSubProcessDone(subprocess_pid)
            if is_subprocess_done and messages_received == 0 then
                break
            end

            local continue_func = function() coroutine.resume(running_coroutine) end
            UIManager:scheduleIn(0.1, continue_func)

            -- gives control back to UIManager
            coroutine.yield()
        end

        -- Search for and remove the runnign subprocess PID
        for i, running_subprocess_id in ipairs(self.running_subprocesses) do
            if running_subprocess_id == subprocess_pid then
                table.remove(self.running_subprocesses, i)
                break
            end
        end
    end

    UIManager:allowStandby()

    return subprocess_ok, subprocess_result
end

return GrimmoryExecutor