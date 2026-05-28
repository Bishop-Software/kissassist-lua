-- tests/mock_mq.lua
-- Programmable mock for the MQ Lua 'mq' module.
--
-- Usage in a test file:
--   MockMQ.set('TLO.Me.Level', 85)
--   MockMQ.set('TLO.Target', nil)        -- target not present
--   MockMQ.set('parse:${Me.PctHPs}>1', '1')
--   MockMQ.reset()                        -- clear all state between tests
--   MockMQ.cmdCalled('/echo hello')       -- assert a cmd was issued

local MockMQ = {}

local _returns = {}
local _calls   = {}
local _pickles = {}

-- Build a TLO proxy. path is the dot-path starting at 'TLO' (e.g. 'TLO.Me.Level').
-- Accessing .foo on the proxy appends '.foo' to the path.
-- Calling () on the proxy looks up _returns[path] and returns it (or calls it if fn).
local function makeTLOProxy(path)
    return setmetatable({}, {
        __index = function(_, k)
            return makeTLOProxy(path .. '.' .. k)
        end,
        __call = function(_, ...)
            local v = _returns[path]
            if type(v) == 'function' then return v(...) end
            return v
        end,
    })
end

MockMQ.TLO = makeTLOProxy('TLO')

-- Set a TLO return value. key is the full dot-path, e.g.:
--   MockMQ.set('TLO.Me.Level', 85)
--   MockMQ.set('TLO.Target.Type', 'NPC')
--   MockMQ.set('TLO.Target', 'some_npc')  -- makes tgt() non-nil (TARGETCHECK)
function MockMQ.set(key, value)
    _returns[key] = value
end

-- Override mq.parse for a specific expression string.
-- MockMQ.set('parse:${Me.PctHPs}>1', '1')  → mq.parse('${Me.PctHPs}>1') returns '1'
-- Use MockMQ.set('parse:*default*', '0') to set a blanket default.
function MockMQ.parse(expr)
    local specific = _returns['parse:' .. (expr or '')]
    if specific ~= nil then
        if type(specific) == 'function' then return specific() end
        return tostring(specific)
    end
    local default = _returns['parse:*default*']
    if default ~= nil then return tostring(default) end
    return '0'
end

-- mq.cmd stub — records every call for assertion.
function MockMQ.cmd(str)
    _calls[#_calls + 1] = str
end

-- Returns true if the given cmd string was called (exact match).
function MockMQ.cmdCalled(str)
    for _, c in ipairs(_calls) do
        if c == str then return true end
    end
    return false
end

-- Returns true if any recorded cmd matches the given Lua pattern.
function MockMQ.cmdMatched(pattern)
    for _, c in ipairs(_calls) do
        if c:find(pattern) then return true end
    end
    return false
end

-- Returns the full list of recorded cmd strings (for detailed assertions).
function MockMQ.calls()
    return _calls
end

-- No-ops for lifecycle functions.
function MockMQ.doevents() end
function MockMQ.delay() end
function MockMQ.event() end
function MockMQ.bind() end

-- In-memory pickle/unpickle — avoids touching the filesystem during tests.
function MockMQ.pickle(path, tbl)
    _pickles[path] = tbl
end
function MockMQ.unpickle(path)
    return _pickles[path]
end

-- Reset all programmed returns, recorded calls, and in-memory pickles.
-- Call between tests to ensure isolation.
function MockMQ.reset()
    _returns = {}
    _calls   = {}
    _pickles = {}
end

return MockMQ
