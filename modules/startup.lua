-- modules/startup.lua
-- Port of Sub StartupCommands (mac:15946) and Sub WinTitle (mac:15258).
--
-- [StartupCommands] CommandSize / Command1..N are run once at startup, 0.5 s
-- apart. With ConOn, a |condN suffix skips the line while condition N is false.
--
-- The window title is /setwintitle with state.misc.winTitleText, an MQ
-- expression re-parsed each time (mac:16250 sets it with /noparse). It is set
-- at startup and on every zone. Startup lines customize it the mac's way,
--   CommandN=/noparse /varset WinTitleText ${Me.Name} (${Me.Class.ShortName})
-- which can't be passed to MQ as is: /varset only works while a macro runs.
--
-- Deliberate differences from the mac:
--  - |condN is stripped before the command runs (the mac leaves it on the end).
--  - Other /varset lines go to /togglevariable (mac names, session only).
--  - A title set by a startup line is applied straight away, not on the next zone.
local mq     = require('mq')
local Config = require('modules.config')
local Utils  = require('modules.utils')

local Startup = {}

local _state, _cond

function Startup.init(state, cond)
    _state = state
    _cond  = cond
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Turns one Command line into an action:
--   { kind = 'skip' }                                  empty / null
--   { kind = 'title', text = expr, condNo = n }        /varset WinTitleText expr
--   { kind = 'cmd',   cmd  = line, condNo = n }        anything else
-- condNo is 0 when the line has no |condN suffix.
function Startup.parse(line)
    local text = trim(line or '')
    if text == '' or text:lower() == 'null' then return { kind = 'skip' } end

    local condNo = 0
    local body, n = text:match('^(.-)%s*|[Cc][Oo][Nn][Dd](%d+)$')
    if body then
        text, condNo = body, tonumber(n) or 0
        if text == '' then return { kind = 'skip' } end
    end

    -- [/noparse ]/varset <Name> [value]
    local rest = text:match('^/[Nn][Oo][Pp][Aa][Rr][Ss][Ee]%s+(.*)$') or text
    local name, value = rest:match('^/[Vv][Aa][Rr][Ss][Ee][Tt]%s+(%S+)%s*(.-)$')
    if name then
        if name:lower() == 'wintitletext' then
            return { kind = 'title', text = value, condNo = condNo }
        end
        local cmd = '/togglevariable ' .. name
        if value ~= '' then cmd = cmd .. ' ' .. value end
        return { kind = 'cmd', cmd = cmd, condNo = condNo }
    end

    return { kind = 'cmd', cmd = text, condNo = condNo }
end

-- Sets the window title from state.misc.winTitleText. Empty or 'null' leaves the
-- title alone. Returns true if a title was set. cmd is injectable for tests.
function Startup.setWinTitle(cmd)
    if not _state then return false end  -- before Startup.init
    local text = _state.misc.winTitleText
    if not text or text == '' or text:lower() == 'null' then return false end
    local title = mq.parse(text)
    if not title or title == '' or title == 'NULL' then return false end
    local run = cmd or mq.cmd
    run('/setwintitle ' .. title)
    return true
end

-- Runs [StartupCommands]. cmd / delay are injectable for tests (default mq.cmd
-- and mq.delay). Returns the number of commands run.
function Startup.runCommands(cmd, delay)
    cmd   = cmd or mq.cmd
    delay = delay or mq.delay
    local lines = Config.get('StartupCommands', 'Command', {})
    local size  = tonumber(Config.get('StartupCommands', 'CommandSize', '0')) or 0
    local ran, oldTitle = 0, _state.misc.winTitleText

    for i = 1, math.min(size, #lines) do
        local a = Startup.parse(lines[i])
        if a.kind ~= 'skip' then
            if a.condNo > 0 and not _cond.eval(a.condNo) then
                Utils.debug('general', 'StartupCommands: Command%d skipped (cond%d false)', i, a.condNo)
            elseif a.kind == 'title' then
                _state.misc.winTitleText = a.text ~= '' and a.text or 'null'
                Utils.debug('general', 'StartupCommands: WinTitleText = %s', _state.misc.winTitleText)
            else
                Utils.debug('general', 'StartupCommands: Command%d %s', i, a.cmd)
                cmd(a.cmd)
                ran = ran + 1
                delay(500)  -- mac /delay 5
            end
        end
    end

    if _state.misc.winTitleText ~= oldTitle then Startup.setWinTitle(cmd) end
    return ran
end

return Startup
