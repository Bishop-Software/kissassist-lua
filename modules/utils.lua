local Utils = {}

local mq      = require('mq')
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
    bard      = false, charm     = false,
    comms     = false, debuff    = false,
    merc      = false,
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
    bard      = '\amBARD',      charm     = '\ayCHARM',
    comms     = '\atCOMMS',     debuff    = '\aoDEBUFF',
    merc      = '\agMERC',
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

-- Section name for this zone in KissAssist_Info.ini, matching the mac so lists are
-- shared with .mac characters (mac:219-224, 11126-11130): the long zone name, or
-- the short name when the long one has a comma or apostrophe, plus _I in instances.
function Utils.zoneKey()
    local short = mq.TLO.Zone.ShortName() or ''
    local long  = mq.TLO.Zone.Name() or ''
    local key   = long
    if long == '' or long:find(',', 1, true) or long:find("'", 1, true) then key = short end
    if mq.TLO.Me.InInstance() then key = key .. '_I' end
    return key
end

-- Read a zone list (MobsToPull, MobsToIgnore, MobsToBurn, CharmImmune, ...) from
-- KissAssist_Info.ini. Uses the mac-style section first, then falls back to the
-- short-name section that older Lua builds wrote to, so those lists aren't lost.
-- Returns nil when neither section has the key.
function Utils.zoneIniGet(infoFile, zoneKey, key)
    if not infoFile or infoFile == '' or not zoneKey or zoneKey == '' then return nil end
    local v = mq.TLO.Ini(infoFile, zoneKey, key)()
    if v ~= nil and v ~= '' then return v end
    local legacy = (mq.TLO.Zone.ShortName() or '') .. (mq.TLO.Me.InInstance() and '_I' or '')
    if legacy ~= '' and legacy ~= zoneKey then
        v = mq.TLO.Ini(infoFile, legacy, key)()
        if v ~= nil and v ~= '' then return v end
    end
    return nil
end
function Utils.setTimer(seconds) return os.clock() + seconds end

-- Resolve a spell name to the highest rank in the character's spellbook.
-- Handles INI entries like 'Foo|Aura' where only 'Foo Rk. II' is in the book.
-- Returns name unchanged for AAs, items, discs, or spells already at base rank.
function Utils.resolveSpellRank(name)
    if (mq.TLO.Me.Book(name)() or 0) ~= 0 then return name end
    local rk2 = name .. ' Rk. II'
    if (mq.TLO.Me.Book(rk2)() or 0) ~= 0 then return rk2 end
    local rk3 = name .. ' Rk. III'
    if (mq.TLO.Me.Book(rk3)() or 0) ~= 0 then return rk3 end
    return name
end

return Utils
