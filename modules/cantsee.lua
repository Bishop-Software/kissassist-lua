-- modules/cantsee.lua
-- Port of Sub Event_CantSee (mac:10820-10900): "You cannot see your target."
--
-- While pulling, the event handler (events.lua onCantSee) only sets
-- movement.cantSee, and the ranged pull faces and tries again (mac:10113).
-- Otherwise it marks a response pending, and respond() runs it from the top of
-- the main loop and each fight() tick, so the up-to-5 s nav doesn't run inside
-- mq.doevents().
--
-- Attacking: stand, face, /look 0. Without MQ2Melee: out of line of sight, nav
-- to the mob (with a nav mesh, up to 5 s, until in range and in sight); in
-- sight, /moveto to MeleeDistance-2. Then re-stick by StickHow. With MQ2Melee,
-- MQ2Melee repositions itself. Not attacking: face only.
--
-- Split for testing: snapshot() reads the TLOs, decide() is pure, respond()
-- sends the commands.
local mq = require('mq')

local CantSee = {}

local _state

CantSee.NAV_MS = 5000   -- mac navTimer 50 (tenths)

function CantSee.init(state)
    _state = state
end

-- Called by the CantSee event handler.
function CantSee.note()
    local s = _state
    if s.pull.pulling then
        s.movement.cantSee = true   -- read by the ranged pull's retry (mac:10826)
        return
    end
    s.movement.cantSeePending = true
end

local function faceCmd(faceMobOn)
    return faceMobOn == 2 and '/squelch /face nolook' or '/squelch /face fast nolook'
end

-- Reads everything decide() needs from the game, once.
function CantSee.snapshot()
    local s  = _state
    local t  = mq.TLO.Target
    local tID = t.ID() or 0
    return {
        attacking   = s.combat.attacking and true or false,
        useMQ2Melee = s.combat.useMQ2Melee and true or false,
        meleeOn     = s.combat.meleeOn and true or false,
        iAmMA       = s.session.iAmMA and true or false,
        sitting     = mq.TLO.Me.Sitting() == true,
        feetWet     = mq.TLO.Me.FeetWet() == true,
        stickActive = mq.TLO.Stick.Active() == true,
        faceMobOn   = s.movement.faceMobOn or 0,
        targetID    = tID,
        los         = tID > 0 and t.LineOfSight() == true,
        maxRangeTo  = math.floor(t.MaxRangeTo() or 0),
        moveUse     = s.pull.moveUse or '',
        navPath     = tID > 0 and mq.TLO.Navigation.PathExists('id ' .. tID)() == true,
        meleeDistance = s.combat.meleeDistance or 75,
        stickHow    = tostring(s.movement.stickHow or s.movement.dStickHow or '0'),
        stickDist   = s.movement.stickDist or 13,
        stickDistUW = s.movement.stickDistUW or 10,
        myTargetID  = s.combat.myTargetID or 0,
    }
end

-- Pure. Returns a list of steps: { cmd = '...' }, { nav = true } (nav to the
-- target for up to NAV_MS) or { wait = ms }.
function CantSee.decide(snap)
    local steps = {}
    local function cmd(c) steps[#steps + 1] = { cmd = c } end
    local canFace = snap.faceMobOn ~= 0 and snap.targetID > 0

    if not snap.attacking then
        if canFace then cmd(faceCmd(snap.faceMobOn)) end
        return steps
    end

    if snap.sitting then cmd('/stand') end
    if canFace then cmd(faceCmd(snap.faceMobOn)) end
    cmd('/look 0')
    if snap.useMQ2Melee then return steps end

    -- Get back in sight (mac:10842-10859).
    if not snap.los then
        if snap.moveUse == 'nav' and snap.navPath then steps[#steps + 1] = { nav = true } end
    elseif snap.targetID > 0 then
        cmd(string.format('/squelch /moveto id %d dist %d', snap.targetID, snap.meleeDistance - 2))
    end

    -- Re-stick (mac:10861-10893).
    local uw = snap.feetWet and ' uw' or ''
    local dist = snap.feetWet and snap.stickDistUW or snap.stickDist
    if snap.stickHow ~= '0' and snap.stickHow ~= 'I' then
        if snap.feetWet then
            if snap.stickActive then cmd('/squelch /stick off') end
            if canFace then cmd('/squelch /face') end
        end
        cmd(string.format('/squelch /moveto %d id %d%s', snap.maxRangeTo, snap.targetID, uw))
        steps[#steps + 1] = { wait = 1000 }
        cmd(string.format('/squelch /stick %d id %d %smoveback%s', dist, snap.myTargetID,
            snap.iAmMA and '' or 'behindonce ', uw))
    elseif snap.stickHow == '0' and snap.meleeOn then
        local front = (not snap.feetWet and not snap.iAmMA) and '!front ' or ''
        cmd(string.format('/squelch /stick %d id %d %smoveback%s', dist, snap.myTargetID, front, uw))
    end
    return steps
end

-- Nav to the target until in range and in sight, for up to NAV_MS (mac:10846-10852).
local function navToTarget(tID)
    local deadline = mq.gettime() + CantSee.NAV_MS
    while mq.gettime() < deadline do
        if not mq.TLO.Navigation.Active() then mq.cmdf('/squelch /nav id %d', tID) end
        local t = mq.TLO.Target
        if (t.MaxRangeTo() or 0) >= (t.Distance() or 999) and t.LineOfSight() then break end
        mq.delay(500)
    end
    if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
end

-- Acts on a pending CantSee, if any. Safe to call every pass.
function CantSee.respond()
    local s = _state
    if not s.movement.cantSeePending then return end
    s.movement.cantSeePending = false
    if s.session.iAmDead or mq.TLO.Me.Hovering() then return end

    local snap = CantSee.snapshot()
    for _, step in ipairs(CantSee.decide(snap)) do
        if step.cmd then
            mq.cmd(step.cmd)
        elseif step.nav then
            navToTarget(snap.targetID)
        elseif step.wait then
            mq.delay(step.wait)
        end
    end
    -- Messages that came in while we moved are handled (mac /doevents flush CantSee).
    if mq.flushevents then mq.flushevents('CantSee') end
    s.movement.cantSeePending = false
end

return CantSee
