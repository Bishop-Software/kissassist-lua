local Utils = {}

local Config  = require('modules.config')
local VERSION = Config.VERSION

-- Internal debug flags. Wired to State.debug in Step 1.5 via Utils.init().
local _flags = {
    general   = false, all       = false,
    buffs     = false, cast      = false,
    chainpull = false, combat    = false,
    heals     = false, logging   = false,
    mez       = false, move      = false,
    pet       = false, pull      = false,
    rk        = false, time      = false,
}

-- MQ color codes mirror the .mac DEBUGX macros (\at=teal \ar=red \am=magenta etc.)
local _prefix = {
    general   = '\atDEBUG',     all       = '\atDEBUG',
    buffs     = '\awBUFFS',     cast      = '\atCAST',
    combat    = '\arCOMBAT',    heals     = '\amHEALS',
    move      = '\ayMOVE',      mez       = '\ayMEZ',
    pet       = '\aoPET',       pull      = '\ayPULL',
    chainpull = '\ayPULL',      time      = '\atDEBUGTIME',
    rk        = '\atRK',        logging   = '\atLOG',
}

function Utils.init(state)
    _flags = state.debug
end

function Utils.setFlag(cat, val)
    if _flags[cat] ~= nil then _flags[cat] = val end
end

function Utils.setAll(val)
    for k in pairs(_flags) do _flags[k] = val end
end

function Utils.debug(cat, msg, ...)
    if not (_flags[cat] or _flags.all) then return end
    local prefix = _prefix[cat] or '\atDEBUG'
    printf('%s-%s \aw%s', prefix, VERSION, string.format(msg, ...))
end

-- Replacements for .mac timer variables. Timers are stored as os.clock() expiry timestamps.
function Utils.timerExpired(t) return os.clock() >= t end
function Utils.setTimer(seconds) return os.clock() + seconds end

return Utils
