-- Soft pause (#353). No mac equivalent: the mac is frozen with /mqp, which a Lua
-- script can't use. The script keeps running while paused, so binds, events,
-- comms and the UI still work; init.lua and the blocking loops check
-- Pause.isPaused() and skip the automation.
local mq = require('mq')

local Pause = {}

local _state, _combat, _bard

function Pause.init(state, combat, bard)
    _state  = state
    _combat = combat
    _bard   = bard
end

-- [General] HealWhilePaused / MoveWhilePaused / WarnAggroWhilePaused (Lua port
-- only, default off). config: the Config module (passed in so tests needn't load it).
function Pause.loadSettings(config)
    local s = _state.session
    s.healWhilePaused      = config.get('General', 'HealWhilePaused',      '0') == '1'
    s.moveWhilePaused      = config.get('General', 'MoveWhilePaused',      '0') == '1'
    s.warnAggroWhilePaused = config.get('General', 'WarnAggroWhilePaused', '0') == '1'
end

function Pause.isPaused()
    return _state.session.paused == true
end

-- WarnAggroWhilePaused: while paused with a hater on XTarget, warn and beep,
-- at most once every WARN_EVERY seconds. Returns true when it warned.
local WARN_EVERY = 10
local _nextWarn  = 0
function Pause.warnAggro(now)
    if not (_state.session.paused and _state.session.warnAggroWhilePaused) then return false end
    if (mq.TLO.SpawnCount('xtarhater')() or 0) == 0 then return false end
    now = now or os.clock()
    if now < _nextWarn then return false end
    _nextWarn = now + WARN_EVERY
    printf('\arKissAssist is PAUSED and you have aggro!\aw Use \at/kactl pause off\aw to resume.')
    mq.cmd('/beep')
    return true
end

-- Stop everything already in progress, so a pause is hands off straight away.
-- The same as /backoff (attack, melee, stick, combatReset) plus nav, moveto,
-- advpath, the pet and the bard medley.
local function stopEverything()
    local s, c = _state, _state.combat
    c.combatStart = false
    if c.useMQ2Melee then mq.cmd('/squelch /melee off') end
    mq.cmd('/squelch /attack off')
    if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
    if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
    if mq.TLO.MoveTo.Moving() then mq.cmd('/squelch /moveto off') end
    if (mq.TLO.AdvPath.State() or 0) ~= 0 then mq.cmd('/squelch /play off') end
    if (mq.TLO.Me.Pet.ID() or 0) ~= 0 and mq.TLO.Pet.Combat() then
        mq.cmd('/squelch /pet back off')
    end
    if _combat then _combat.combatReset(0, 'pause') end
    if s.session.iAmABard and _bard then _bard.stopMedley() end
end

-- Set the pause state. Idempotent: returns false when nothing changed, so
-- /kactl pause on twice (or MQ2Boxr re-sending it) does nothing the second time.
function Pause.set(on)
    on = on == true
    if _state.session.paused == on then return false end
    _state.session.paused = on
    if on then
        _nextWarn = 0  -- a fresh pause warns about aggro straight away
        stopEverything()
        printf('\ayKissAssist paused.\aw Use \at/kactl pause off\aw to resume.')
    else
        -- /backoff turns MQ2Melee back on itself when it ends.
        if _state.combat.useMQ2Melee and not _state.dps.paused then
            mq.cmd('/squelch /melee on')
        end
        printf('\agKissAssist resumed.')
    end
    return true
end

return Pause
