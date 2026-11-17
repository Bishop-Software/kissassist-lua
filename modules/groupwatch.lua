-- modules/groupwatch.lua
-- Port of Sub GroupWatch (mac:10633) and Sub CheckStats (mac:10703).
--
-- GroupWatchOn=1 watches every group member's mana/endurance, =2 only
-- CLR/DRU/SHM; the percent rides along as "1|20" (GroupWatchPct, default 20).
-- A member at or below the percent holds pulls until they are back to 90%.
-- Non-tank roles also pause while the main assist can't be found, and
-- GroupWatchCheck=condN holds pulls while condition N is true.
--
-- The mac blocks inside these subs (/while loops, DoWeMed 2). Here each wait
-- is a state checked once per pass: GroupWatch.check() runs from the main
-- loop and from Pull.findMobToPull (mac:411, 8986, 9625), and pulling stops
-- while State.pull.watchHold is set. It is a separate flag from pull.hold,
-- which in the port is the user's PullHold setting.
local mq     = require('mq')
local Config = require('modules.config')

local GroupWatch = {}

local _state, _utils, _cond, _comms, _combat

local RESUME_PCT = 90  -- CheckStats resume level (mac:10679)

local TANK_ROLES = {
    tank = true, pullertank = true, pettank = true, pullerpettank = true,
    hunter = true, hunterpettank = true,
}
local ANNOUNCE_ROLES = {
    puller = true, pullertank = true, pullerpettank = true,
    hunter = true, hunterpettank = true,
}
local ENDURANCE_CLASSES = { BER = true, MNK = true, ROG = true, WAR = true }
local HYBRID_CLASSES    = { BST = true, PAL = true, RNG = true, SHD = true }
local HEALER_CLASSES    = { CLR = true, DRU = true, SHM = true }

function GroupWatch.init(state, utils, cond, comms, combat)
    _state  = state
    _utils  = utils
    _cond   = cond
    _comms  = comms
    _combat = combat
    local h = _state.heal
    h.gwWaitMA     = false
    h.gwWatchID    = 0
    h.gwWatchName  = ''
    h.gwWatchStat  = ''
    h.gwCondWait   = false
    _state.pull.watchHold = false
    GroupWatch.setConfig(Config.get('General', 'GroupWatchOn', '0'),
                         Config.get('General', 'GroupWatchCheck', 'FALSE'))
end

-- [General] GroupWatchOn ("0", "1", "2", or with a percent "1|20") and
-- GroupWatchCheck ("condN"), mac:14569-14587.
function GroupWatch.setConfig(onRaw, checkRaw)
    local h = _state.heal
    local on, pct = tostring(onRaw or '0'):match('^%s*([^|]*)|?([^|]*)')
    h.groupWatchOn   = math.floor(tonumber(on) or 0)
    h.groupWatchPct  = tonumber(pct) or h.groupWatchPct or 20
    h.groupWatchCond = tonumber(tostring(checkRaw or ''):lower():match('cond(%d+)')) or 0
end

-- Write the settings back as the mac stores them: GroupWatchOn "1|20",
-- GroupWatchCheck "condN" or "FALSE".
function GroupWatch.save()
    local h = _state.heal
    Config.set('General', 'GroupWatchOn', string.format('%d|%d', h.groupWatchOn or 0, h.groupWatchPct or 20))
    Config.set('General', 'GroupWatchCheck',
        (h.groupWatchCond or 0) > 0 and ('cond' .. h.groupWatchCond) or 'FALSE')
    Config.save()
end

-- Names /changevarint handles here, since GroupWatchOn carries the percent
-- and GroupWatchCheck has no state field of that name.
local VAR_NAMES = { groupwatchon = true, groupwatchpct = true, groupwatchcheck = true }

function GroupWatch.isVar(name)
    return VAR_NAMES[tostring(name or ''):lower()] == true
end

-- Set one setting from a command value. Returns the new value as text, or
-- nil when the value is not valid.
function GroupWatch.setVar(name, value)
    local h, key, v = _state.heal, tostring(name):lower(), tostring(value or '')
    if key == 'groupwatchon' then
        local on, pct = v:match('^%s*([^|]*)|?([^|]*)')
        local lon = on:lower()
        local n = (lon == 'on' and 1) or ((lon == 'off' or lon == '') and 0) or tonumber(on)
        if not n or n < 0 or n > 2 then return nil end
        h.groupWatchOn = math.floor(n)
        if pct ~= '' then
            local p = tonumber(pct)
            if not p then return nil end
            h.groupWatchPct = math.max(1, math.min(100, math.floor(p)))
        end
        return string.format('%d|%d', h.groupWatchOn, h.groupWatchPct or 20)
    elseif key == 'groupwatchpct' then
        local p = tonumber(v)
        if not p then return nil end
        h.groupWatchPct = math.max(1, math.min(100, math.floor(p)))
        return tostring(h.groupWatchPct)
    elseif key == 'groupwatchcheck' then
        local lv = v:lower()
        local n = tonumber(lv:match('^cond(%d+)$') or lv)
        if lv == 'false' or lv == 'off' then n = 0 end
        if not n or n < 0 then return nil end
        h.groupWatchCond = math.floor(n)
        return h.groupWatchCond > 0 and ('cond' .. h.groupWatchCond) or 'FALSE'
    end
    return nil
end

local function debug(fmt, ...)
    if _utils and _utils.debug then _utils.debug('heals', fmt, ...) end
end

local function hasAggro()
    local a = _state.combat.aggroTargetID
    return a ~= nil and a ~= '' and a ~= 0
end

-- Puller roles tell the group; everyone else echoes (mac:10733-10737).
local function say(msg)
    if ANNOUNCE_ROLES[_state.session.role or ''] and _comms then
        _comms.announce(msg, 't')
    else
        printf('%s', msg)
    end
end

local function statOf(spawn, stat)
    if stat == 'Endurance' then return spawn.CurrentEndurance() end
    return spawn.CurrentMana()
end

-- Sit to med while waiting (the mac turns MedOn on for the wait, mac:10676-10677).
local function sitToMed()
    if hasAggro() and not _state.heal.medCombat then return end
    local me = mq.TLO.Me
    if (me.Mount.ID() or 0) == 0 and me.Standing() and not me.Moving()
       and (me.Casting.ID() or 0) == 0 then
        mq.cmd('/sit')
    end
end

function GroupWatch.reset()
    local h = _state.heal
    h.gwWaitMA, h.gwCondWait = false, false
    h.gwWatchID, h.gwWatchName, h.gwWatchStat = 0, '', ''
    _state.pull.watchHold = false
end

-- Main assist gone (mac:10644). Tank roles are their own MA.
local function maMissing()
    local s = _state
    if TANK_ROLES[s.session.role or ''] then return false end
    local ma = s.session.mainAssist or ''
    if ma == '' then return false end
    if (s.movement.campZone or 0) ~= (mq.TLO.Zone.ID() or 0) then return false end
    return (mq.TLO.Spawn('=' .. ma).ID() or 0) == 0
end

-- The member is back up, or gone: resume (mac:10743-10755).
local function endMemberWait(msg)
    local h = _state.heal
    if msg then say(msg) end
    h.gwWatchID, h.gwWatchName, h.gwWatchStat = 0, '', ''
    _state.pull.watchHold = false
    local me = mq.TLO.Me
    if (me.Mount.ID() or 0) == 0 and me.Sitting() and not h.medding then mq.cmd('/stand') end
    -- Restart the PullPause pull window (mac:10755).
    local run = _state.pull.pauseRun or 0
    if run > 0 then _state.timers.pullPause1 = os.clock() + run * 60 end
end

local function waitForMember()
    local h = _state.heal
    local spawn = mq.TLO.Spawn('id ' .. h.gwWatchID)
    if (spawn.ID() or 0) == 0 then
        printf('Character %s Left the zone. Leaving Med Routine.', h.gwWatchName)  -- mac:4080
        endMemberWait(nil)
        return
    end
    if (statOf(spawn, h.gwWatchStat) or 0) >= RESUME_PCT then
        endMemberWait(string.format('%s is now above %d%% %s resuming activity.',
            h.gwWatchName, RESUME_PCT, h.gwWatchStat))
        return
    end
    _state.pull.watchHold = true
    sitToMed()
end

-- Sub CheckStats (mac:10703). True when the scan should stop: a wait started
-- or a chain-pulling puller held pulls.
local function checkStats(member, stat, pct)
    local val = statOf(member, stat)
    if val == nil or val > pct then return false end
    local s = _state
    if s.session.role == 'puller' and (s.pull.chainPull or 0) ~= 0 and _combat then
        _combat.mobRadar('los', s.combat.meleeDistance or 75)
        if (s.combat.mobCount or 0) > 0 then
            s.pull.watchHold = true
            return true
        end
    end
    local h = s.heal
    h.gwWatchID   = member.ID() or 0
    h.gwWatchName = member.CleanName() or ''
    h.gwWatchStat = stat
    s.pull.watchHold = true
    s.pull.pulling   = false
    say(string.format('Waiting for >> %s << to med up to %d%% %s.', h.gwWatchName, RESUME_PCT, stat))
    -- Target them so their stats are current (mac:10738-10739).
    mq.cmdf('/target id %d', h.gwWatchID)
    sitToMed()
    return true
end

-- GroupWatchCheck=condN (mac:10683-10697). Holds while the condition is
-- true; the mac also lets go once a mob is on us and MedCombat is off.
local function condHold()
    local h = _state.heal
    local n = h.groupWatchCond or 0
    local active = n > 0 and _state.cond and _state.cond.on
        and (_state.cond.expressions[n] or '') ~= ''
        and _cond and _cond.eval(n)
        and not (hasAggro() and not h.medCombat)
    if active and not h.gwCondWait then
        printf('Pausing due to GroupWatchCheck..')
    elseif not active and h.gwCondWait then
        printf('Continuing from GroupWatchCheck condition.')
    end
    h.gwCondWait = active and true or false
    return h.gwCondWait
end

-- Run once per pass. Returns true while waiting for the main assist, so the
-- main loop can skip everything but combat (the mac's wait loop only runs
-- events and CheckForCombat, mac:10646-10659).
function GroupWatch.check()
    local s, h = _state, _state.heal
    if (h.groupWatchOn or 0) == 0 then
        if s.pull.watchHold or h.gwWaitMA or h.gwWatchID ~= 0 or h.gwCondWait then GroupWatch.reset() end
        return false
    end

    if h.gwWaitMA then
        if maMissing() then return true end
        printf('Main Assist is back resuming action.')
        h.gwWaitMA = false
        s.pull.watchHold = false
    end

    if hasAggro() and (s.pull.chainPull or 0) == 0 then return false end  -- mac:10635

    if maMissing() then
        printf('I am not detecting Main Assist. Pausing.')
        h.gwWaitMA = true
        s.pull.watchHold = true
        return true
    end

    if h.gwWatchID ~= 0 then
        waitForMember()
        return false
    end

    -- Scan the group (mac:10661-10682).
    s.pull.watchHold = false
    local pct  = h.groupWatchPct or 20
    local only = (h.groupWatchOn == 2)
    for i = 1, 5 do
        local m = mq.TLO.Group.Member(i)
        if m and (m.ID() or 0) ~= 0 and not m.OtherZone() then
            if (m.Type() or ''):lower() == 'corpse' then
                -- A dead member stops chain pulling (mac:10664).
                if (s.pull.chainPull or 0) ~= 0 then s.pull.watchHold = true end
            else
                local cls = m.Class.ShortName() or ''
                if not only or HEALER_CLASSES[cls] then
                    local stat = ENDURANCE_CLASSES[cls] and 'Endurance' or 'Mana'
                    if checkStats(m, stat, pct) then return false end
                    if HYBRID_CLASSES[cls] and checkStats(m, 'Endurance', pct) then return false end
                end
            end
        end
    end

    if condHold() then s.pull.watchHold = true end
    debug('groupWatch: hold=%s', tostring(s.pull.watchHold))
    return false
end

-- True while GroupWatch is waiting on a member (doWeMed and PullPause leave
-- us seated).
function GroupWatch.waiting()
    return _state and (_state.heal.gwWatchID or 0) ~= 0
end

return GroupWatch
