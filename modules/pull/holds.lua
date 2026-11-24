-- pull/holds.lua — whether pulling may go ahead: the pull-ability ready check,
-- the PullWait respawn wait, the PullPause cycle and its hold condition, and
-- holdReasons (the Pull tab's "Pulls held:" line).
-- Step 4 of the pull module split (see the pull_module_split_plan).
--
-- Calls to other pull functions go through the facade table (Pull.*).

local mq   = require('mq')
local Util = require('modules.pull.util')

local Holds = {}
local _state
local Pull  -- the facade (modules/pull.lua), set by Holds.init

function Holds.init(state, pull)
    _state = state
    Pull   = pull
end

-- True when the PullWith method can be used right now (mac:418): Melee and Pet
-- always; Ranged when the ranged attack is ready; otherwise the named spell, AA,
-- combat ability or item must be ready. Checked before searching so the puller
-- doesn't run to a mob with the pull on cooldown.
function Holds.pullAbilityReady(withAlt)
    withAlt = withAlt or (_state and _state.pull.withAlt) or 'Melee'
    local lw = withAlt:lower()
    if lw == 'melee' or lw == 'pet' then return true end
    local me = mq.TLO.Me
    if lw == 'ranged' then return me.RangedReady() == true end
    return me.SpellReady(withAlt)() == true
        or me.AltAbilityReady(withAlt)() == true
        or me.CombatAbilityReady(withAlt)() == true
        or me.ItemReady(withAlt)() == true
end

-- Start the PullWait respawn wait (mac:9421-9439 Sub PullDelay). The .mac blocks
-- in a /doevents loop; here the main loop keeps running (heals, buffs, combat)
-- and Phase 9 skips pulling until Pull.pullWaiting() turns false.
function Holds.startPullWait(seconds)
    local s = _state
    s.timers.pullDelay = os.clock() + seconds
    s.pull.pulling = false
    s.pull.pulled  = false
    local me = mq.TLO.Me
    if s.heal.medOn and not me.Mount.ID() and me.Standing() and not me.Moving() then
        mq.cmd('/sit')
    end
end

-- True while the PullWait respawn wait is running. Aggro ends it early, as in
-- the .mac (the fight itself runs through the normal combat phases).
function Holds.pullWaiting()
    local s = _state
    if (s.timers.pullDelay or 0) == 0 then return false end
    if os.clock() >= s.timers.pullDelay or (s.combat.aggroTargetID or '') ~= '' then
        s.timers.pullDelay = 0
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- PullPause (mac:8502 DoMiscStuff): pull for X minutes, then hold pulls and
-- med for Y minutes. [Pull] PullPause = 'X|Y' or 'X|Y|condN'; X = 0 turns the
-- cycle off. The X-minute window restarts if no pull happens for Y minutes.
-- '|condN' holds pulls while condition N is true (mac PullHoldCond).
-- ---------------------------------------------------------------------------

function Holds.setPullPause(value)
    local p    = _state.pull
    local v    = tostring(value or '0')
    local role = _state.session.role or ''
    local a, b = v:match('^%s*([^|]*)|?([^|]*)')
    p.pauseSetting = v
    p.pauseRun  = math.floor(tonumber(a) or 0)
    p.pauseRest = math.floor(tonumber(b) or 0)
    p.pauseCond = tonumber(v:lower():match('|cond(%d+)')) or 0
    -- Only pullers and hunters pause (mac:8842).
    if not role:find('puller', 1, true) and not role:find('hunter', 1, true) then
        p.pauseRun, p.pauseCond = 0, 0
    end
    if p.pauseRest <= 0 then p.pauseRun = 0 end
    p.pauseHold = false
    _state.timers.pullPause1, _state.timers.pullPause2 = 0, 0
end

-- Run each main-loop pass. Starts and ends the pause.
function Holds.pullPauseCheck()
    local p, t = _state.pull, _state.timers
    if (p.pauseRun or 0) == 0 then return end
    local now = os.clock()
    if not p.hold and not p.pauseHold and (t.pullPause2 or 0) <= now then
        t.pullPause1 = now + p.pauseRun  * 60
        t.pullPause2 = now + p.pauseRest * 60
    end
    if (t.pullPause1 or 0) > now then
        -- Med through the pause, as the .mac's DoWeMed 1 does.
        local me = mq.TLO.Me
        if p.pauseHold and _state.heal.medOn and (_state.combat.aggroTargetID or '') == ''
           and not me.Mount.ID() and me.Standing() and not me.Moving() then
            mq.cmd('/sit')
        end
        return
    end
    if not p.hold and not p.pauseHold then
        printf('\ayPausing Pulls for %d Minutes.', p.pauseRest)
        p.pauseHold  = true
        t.pullPause1 = now + p.pauseRest * 60
    elseif p.pauseHold then
        printf('\ayResetting Pull Timer for %d Minutes.', p.pauseRun)
        p.pauseHold  = false
        t.pullPause1 = now + p.pauseRun  * 60
        t.pullPause2 = now + p.pauseRest * 60
        if mq.TLO.Me.Sitting() and not _state.heal.medding
           and (_state.heal.gwWatchID or 0) == 0 then mq.cmd('/stand') end
    end
end

-- A pull happened: keep the X-minute window running (mac:9368).
function Holds.pullPauseActive()
    local p = _state.pull
    if (p.pauseRun or 0) > 0 then
        _state.timers.pullPause2 = os.clock() + (p.pauseRest + 1) * 60
    end
end

-- True while the PullPause '|condN' hold condition is true (mac:9595).
local holdSpam = 0
-- quiet: just check, without the chat message (for the UI).
function Holds.heldByCond(quiet)
    local n = _state.pull.pauseCond or 0
    if n == 0 then return false end
    -- Cond.eval treats "conditions off" and missing entries as true; a hold
    -- condition only applies when it exists.
    local c = _state.cond
    if not c or not c.on or not c.expressions or (c.expressions[n] or '') == '' then return false end
    if not require('modules.cond').eval(n) then return false end
    if not quiet and os.clock() >= holdSpam then
        printf('\ayHolding Pulls Due to Pull Hold Condition.')
        holdSpam = os.clock() + 5
    end
    return true
end

local function pctText(stat, cur, target)
    return string.format('%s %d%% -> %d%%', stat, math.floor(cur or 0), math.floor(target or 0))
end

-- Why pulls are held right now, for the Pull tab's status line. Mirrors the
-- checks in front of the main loop's pull step (init.lua Phase 9) and
-- findMobToPull. Returns a list of short reasons; empty = free to pull.
function Holds.holdReasons()
    local s, out = _state, {}
    local function add(t) out[#out + 1] = t end
    local h  = s.heal or {}
    local me = mq.TLO.Me

    if not Util.isPullerRole(s.session.role) then
        add(string.format('%s role does not pull', s.session.role or '?'))
    end
    if (s.movement.campX or 0) == 0 and (s.movement.campY or 0) == 0 then
        add('no camp set (/makecamphere)')
    end
    if s.pull.hold then add('Pull is switched off') end
    if s.dps and s.dps.paused then add('paused (/backoff)') end
    if h.gwWaitMA then add('main assist not found') end
    if (h.gwWatchID or 0) ~= 0 then
        local sp  = mq.TLO.Spawn('id ' .. h.gwWatchID)
        local cur = h.gwWatchStat == 'Endurance' and sp.CurrentEndurance() or sp.CurrentMana()
        add(string.format('waiting for %s to med (%s)', h.gwWatchName or '?',
            pctText(h.gwWatchStat or 'Mana', cur, 90)))
    end
    if h.gwCondWait then add(string.format('Group Watch condition %d is true', h.groupWatchCond or 0)) end
    if s.pull.watchHold and not h.gwWaitMA and (h.gwWatchID or 0) == 0 and not h.gwCondWait then
        add('Group Watch: dead group member or mobs close while chain pulling')
    end
    if h.medding then
        if h.medHP then
            add('medding (' .. pctText('HP', me.PctHPs(), h.medStop or 100) .. ')')
        else
            local cur = h.medStat == 'Endurance' and me.PctEndurance() or me.PctMana()
            add('medding (' .. pctText(h.medStat or 'Mana', cur, h.medStop or 100) .. ')')
        end
    end
    if h.petMedding then
        add(string.format('healing pet (%d%% of %d%%)', me.Pet.PctHPs() or 0, h.medStop or 100))
    end
    if s.pull.pauseHold then add('Pull Pause rest') end
    if Pull.heldByCond(true) then add(string.format('Pull Pause condition %d is true', s.pull.pauseCond or 0)) end
    if s.misc and s.misc.dragCorpse then add('dragging a corpse') end
    if Pull.pullWaiting() then add('waiting for respawns') end
    return out
end

return Holds
