-- One cancellable prefetch per reader. Parent drains bounded pipe chunks; it
-- never waits for HTTP, pipe EOF, or waitpid on the UI thread.
local Worker = {}
Worker.__index = Worker
local live = setmetatable({}, {__mode = "k"})
local function failureText(reason)
    return tostring(reason or "fetch failed"):gsub("[\r\n]", " "):sub(1, 240)
end

function Worker:new(options)
    local worker = setmetatable({ options = options }, self)
    live[worker] = true
    return worker
end

function Worker:_reap(job)
    local ffiutil = require("ffi/util")
    local UI = require("ui/uimanager")
    local function collect()
        if not ffiutil.isSubProcessDone(job.pid) then
            UI:scheduleIn(0.2, collect)
        elseif job.standby then
            job.standby = false
            UI:allowStandby()
        end
    end
    collect()
end

function Worker:cancel()
    local job = self.job
    if not job then return end
    self.job = nil
    local UI = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local C = require("ffi").C
    UI:unschedule(job.poll)
    if job.fd then C.close(job.fd); job.fd = nil end
    if not ffiutil.isSubProcessDone(job.pid) then
        -- Kill the owned PID too: cancellation can precede the child's setpgid.
        C.kill(job.pid, 9)
        self:_reap(job)
    elseif job.standby then
        job.standby = false
        UI:allowStandby()
    end
end

function Worker:close()
    self.closed = true
    self:cancel()
    live[self] = nil
end

function Worker.closeAll()
    for worker in pairs(live) do worker:close() end
end

function Worker:start(index, fetch, done)
    if self.closed then return false, "closed" end
    if self.job then return false, "busy" end
    local ffiutil = require("ffi/util")
    if not ffiutil.runInSubProcess then return false, "unsupported" end
    local ffi = require("ffi")
    local C = ffi.C
    local UI = require("ui/uimanager")
    local opts = self.options
    local max_bytes = opts.max_bytes
    local parent_pid
    if ffi.os == "Linux" then
        ffi.cdef[[int prctl(int option, ...);]]
        parent_pid = tonumber(C.getpid())
    end
    -- Own the pipe here: ffi/util's with_pipe path does not close it on fork failure.
    local allocated, pipe, read_buffer = pcall(function()
        return ffi.new("int[2]", {-1, -1}), ffi.new("char[?]", 64 * 1024)
    end)
    if not allocated then return false, "allocation failed: " .. failureText(pipe) end
    if C.pipe(pipe) ~= 0 then return false, "pipe failed: errno " .. ffi.errno() end
    local fd, write_fd = tonumber(pipe[0]), tonumber(pipe[1])
    local started = opts.now()
    local ok, pid, launch_error = pcall(ffiutil.runInSubProcess, function()
        C.close(fd)
        if parent_pid then
            -- UI timers vanish on quit/USBMS. Never leave an orphaned HTTP/DNS
            -- worker holding the device's mounted files after the parent exits.
            if C.prctl(1, ffi.cast("unsigned long", 9), ffi.cast("unsigned long", 0),
                    ffi.cast("unsigned long", 0), ffi.cast("unsigned long", 0)) ~= 0
                or tonumber(C.getppid()) ~= parent_pid then
                C.close(write_fd)
                return
            end
        end
        local fetched, data, reason = pcall(fetch, index, true)
        local kind = "D"
        if not fetched then
            kind, data = "E", "fetch exception: " .. failureText(data)
        elseif type(data) ~= "string" or #data == 0 then
            kind, data = "E", failureText(reason or "empty response")
        elseif #data > max_bytes then
            kind, data = "E", "response byte budget"
        end
        if kind == "E" then data = failureText(data) end
        -- Write the header separately, avoiding a second full image string.
        local function writeAll(value)
            local ptr, offset = ffi.cast("const char *", value), 0
            while offset < #value do
                local n = tonumber(C.write(write_fd, ptr + offset, #value - offset))
                if n > 0 then offset = offset + n
                elseif n < 0 and ffi.errno() == 4 then -- EINTR
                else return false end
            end
            return true
        end
        local fetch_ms = math.max(0, math.floor((opts.now() - started) * 1000))
        if writeAll(string.format("%s %d %d\n", kind, #data, fetch_ms)) then
            writeAll(data)
        end
        C.close(write_fd)
    end)
    C.close(write_fd)
    if not ok or not pid then
        C.close(fd)
        return false, failureText(ok and launch_error or pid)
    end
    local job = {pid = pid, fd = fd, index = index, started = started,
        chunks = {}, bytes = 0, header = "", buffer = read_buffer}
    self.job = job
    UI:preventStandby()
    job.standby = true
    local function finish(data, reason)
        if self.job ~= job then return end
        local total_ms = math.max(0, math.floor((opts.now() - job.started) * 1000))
        self:cancel()
        done(data, reason, {total_ms = total_ms, fetch_ms = job.fetch_ms,
            transfer_ms = job.fetch_ms and math.max(0, total_ms - job.fetch_ms)})
    end
    job.poll = function()
        if self.job ~= job or self.closed then return end
        if opts.now() - job.started >= opts.timeout then finish(nil, "deadline"); return end
        -- A pipe can hold much less than 256 KiB. Drain refills within a small
        -- time/byte budget, then yield so input and painting still get a turn.
        local poll_started, drained, reads = opts.now(), 0, 0
        while drained < 256 * 1024 and reads < 8 and opts.now() - poll_started < 0.002 do
            local available = ffiutil.getNonBlockingReadSize(job.fd)
            if available == nil then finish(nil, "pipe error"); return end
            if available == 0 then break end
            local amount = math.min(available, 64 * 1024, 256 * 1024 - drained)
            local n = tonumber(C.read(job.fd, job.buffer, amount))
            reads = reads + 1
            if n > 0 then
                drained = drained + n
                local chunk = ffi.string(job.buffer, n)
                if not job.expected then
                    local header = job.header .. chunk
                    local newline = header:find("\n", 1, true)
                    if not newline then
                        if #header > 64 then finish(nil, "invalid header"); return end
                        job.header = header
                        chunk = ""
                    else
                        if newline > 64 then finish(nil, "invalid header"); return end
                        local kind, length, fetch_ms = header:sub(1, newline - 1):match("^([DE]) (%d+) (%d+)$")
                        length, fetch_ms = tonumber(length), tonumber(fetch_ms)
                        local limit = kind == "E" and 240 or max_bytes
                        if not length or length < 1 or length > limit or not fetch_ms then
                            finish(nil, "invalid header"); return
                        end
                        job.expected, job.fetch_ms, job.header = length, fetch_ms, nil
                        job.error_response = kind == "E"
                        chunk = header:sub(newline + 1)
                    end
                end
                if #chunk > 0 then
                    job.chunks[#job.chunks + 1] = chunk
                    job.bytes = job.bytes + #chunk
                end
                if job.bytes > (job.expected or max_bytes) then finish(nil, "oversized response"); return end
            elseif n < 0 and ffi.errno() ~= 4 then finish(nil, "read error"); return
            else break end
        end
        -- Do not wait for child exit before draining: a full pipe blocks writes.
        if ffiutil.isSubProcessDone(job.pid) then
            local remaining = ffiutil.getNonBlockingReadSize(job.fd)
            if remaining == 0 then
                if job.expected and job.bytes == job.expected then
                    local body = table.concat(job.chunks)
                    if job.error_response then finish(nil, body) else finish(body) end
                else finish(nil, "incomplete response") end
                return
            end
        end
        UI:scheduleIn(drained > 0 and 0.001 or 0.05, job.poll)
    end
    UI:scheduleIn(0.05, job.poll)
    return true
end

-- Serial, bounded progress reports shared across readers. Session identity
-- invalidates even a deferred report when the same chapter is reopened.
local Queue = {}
Queue.__index = Queue
Worker.Queue = Queue

function Queue:new(options)
    return setmetatable({options = options, pending = {},
        sessions = setmetatable({}, {__mode = "v"})}, self)
end

function Queue:begin(key)
    if self.closed then return {obsolete = true} end
    local previous = self.sessions[key]
    if previous then
        previous.obsolete = true
        for i = #self.pending, 1, -1 do
            if self.pending[i].session == previous then table.remove(self.pending, i) end
        end
        if self.active and self.active.session == previous then
            self.active.worker:close()
            self.active = nil
        end
    end
    local session = {}
    self.sessions[key] = session
    self:_next()
    return session
end

function Queue:_next()
    if self.closed or self.active then return end
    local task = table.remove(self.pending, 1)
    if not task then return end
    self.active = task
    task.worker = Worker:new(self.options)
    local function completed(data, reason, timing)
        if self.active ~= task then return end
        self.active = nil
        task.done(data, reason, timing)
        self:_next()
    end
    local launched, reason = task.worker:start(0, task.fetch, completed)
    if not launched then
        completed(nil, reason or "subprocess unavailable")
    end
end

function Queue:submit(session, fetch, done)
    if self.closed then return false, "queue closed" end
    if session.obsolete then return false, "superseded session" end
    if #self.pending >= (self.options.max_pending or 12) then return false, "queue full" end
    self.pending[#self.pending + 1] = {session = session, fetch = fetch, done = done}
    self:_next()
    return true
end

function Queue:close()
    self.closed = true
    for _, session in pairs(self.sessions) do session.obsolete = true end
    self.sessions, self.pending = {}, {}
    if self.active then
        self.active.worker:close()
        self.active = nil
    end
end

return Worker
