-- modules/gothit.lua
-- Port of the response in Sub Event_GotHit (mac:11054-11113).
--
-- The mac does all of it inside the event handler. Here the handler (events.lua
-- onGotHit) only records who hit us; respond() acts on it from the places the
-- mac's /doevents would have run the handler: the top of the main loop, each
-- fight() tick and the pull's wait-in-camp loop.
--
--   pullertank / pullerpettank waiting in camp for the pull: stop waiting, and
--     clear the target if the nearest NPC in camp isn't MyTargetID (mac:11069).
--   pettank / pullerpettank / hunterpettank: target the attacker, then either
--     go back to camp (out of camp with ReturnToCamp, MoveWhenHit) or send the
--     pet in and, with MoveWhenHit, step 10 away from the mob (mac:11079-11109).
--
-- The mac's first block (aggro, no target, ReturnToCamp off -> CheckForCombat,
-- mac:11060) is the main loop's own combat pass here: respond() runs at the top
-- of the loop and the combat phase follows it.
--
-- Split for testing: snapshot() reads the TLOs, decideWait() and
-- decideResponse() are pure, respond() sends the commands.
local mq = require('mq')

local GotHit = {}

local _state

-- Roles with a response (mac:11068, 11069, 11079).
GotHit.WAIT_ROLES    = { pullertank = true, pullerpettank = true }
GotHit.PETTANK_ROLES = { pettank = true, pullerpettank = true, hunterpettank = true }
-- mac GotHitDistChk: how far from the mob MoveWhenHit steps.
GotHit.DIST = 10

function GotHit.init(state)
    _state = state
end

-- Called by the GotHit event handler with the attacker's name.
function GotHit.note(mob)
    _state.combat.gotHitToggle = true
    _state.combat.gotHitBy     = mob or ''
end

local function dist2D(y1, x1, y2, x2)
    return math.sqrt((y1 - y2) ^ 2 + (x1 - x2) ^ 2)
end

-- Reads everything the decide functions need from the game, once.
function GotHit.snapshot(mob)
    local s  = _state
    local me = mq.TLO.Me
    local attacker = mq.TLO.NearestSpawn(string.format('npc radius 39 targetable "%s"', mob or ''))
    local pet = me.Pet
    return {
        role           = s.session.role or '',
        pulled         = s.pull.pulled and true or false,
        waitingForMob  = s.pull.waitingForMob and true or false,
        myTargetID     = s.combat.myTargetID or 0,
        returnToCamp   = s.movement.returnToCamp and true or false,
        campRadius     = s.movement.campRadius or 30,
        campY          = s.movement.campY or 0,
        campX          = s.movement.campX or 0,
        myY            = me.Y() or 0,
        myX            = me.X() or 0,
        nearestCampNpc = mq.TLO.NearestSpawn(string.format('npc los radius %d targetable',
                             s.movement.campRadius or 30)).ID() or 0,
        targetID       = mq.TLO.Target.ID() or 0,
        attackerID     = attacker.ID() or 0,
        attackerY      = attacker.Y() or 0,
        attackerX      = attacker.X() or 0,
        petID          = pet.ID() or 0,
        petY           = pet.Y() or 0,
        petX           = pet.X() or 0,
        petTaunt       = mq.TLO.Pet.Taunt() and true or false,
        petAttackRange = s.pet.attackRange or 115,
        tauntOverride  = s.pet.tauntOverride and true or false,
        moveWhenHit    = s.pet.moveWhenHit and true or false,
        faceMobOn      = s.movement.faceMobOn or 0,
    }
end

-- A puller tank hit while waiting in camp for its pull (mac:11069-11078).
-- Returns { endWait = bool, clearTarget = bool }.
function GotHit.decideWait(snap)
    local out = { endWait = false, clearTarget = false }
    if not GotHit.WAIT_ROLES[snap.role] then return out end
    if not (snap.pulled and snap.waitingForMob) then return out end
    if dist2D(snap.myY, snap.myX, snap.campY, snap.campX) > snap.campRadius then return out end
    out.endWait     = true
    out.clearTarget = snap.nearestCampNpc ~= snap.myTargetID
    return out
end

-- The pet tank's response, once the attacker is targeted (mac:11085-11109).
-- Returns a list of steps: { cmd = '...' }, { echo = '...' } or
-- { waitAway = true } (wait up to 1.5 s to be more than DIST from the mob).
function GotHit.decideResponse(snap, mob)
    local steps = {}
    if not GotHit.PETTANK_ROLES[snap.role] then return steps end
    local function cmd(c)  steps[#steps + 1] = { cmd = c }  end
    local function echo(e) steps[#steps + 1] = { echo = e } end

    if snap.attackerID > 0 then
        echo(string.format('I got hit by >>%s<< ID:%d!', mob, snap.attackerID))
        cmd('/moveto dist ' .. GotHit.DIST)
        local myCampDist = dist2D(snap.myY, snap.myX, snap.campY, snap.campX)
        if myCampDist > snap.campRadius and snap.role ~= 'hunterpettank' and snap.returnToCamp then
            if snap.moveWhenHit then
                echo('Moving back to camp!')
                cmd(string.format('/moveto loc %s %s', snap.campY, snap.campX))
            end
        else
            if snap.petID > 0 and dist2D(snap.attackerY, snap.attackerX, snap.petY, snap.petX)
                    <= snap.petAttackRange then
                cmd('/pet attack')
                -- The mac always turns taunt on here; the port leaves it off when
                -- the Pet tab's Taunt Off (PetTauntOverride) is set.
                if not snap.petTaunt and not snap.tauntOverride then cmd('/pet taunt on') end
            end
            if snap.moveWhenHit then
                echo(string.format('Trying to get away from >>%s<<.', mob))
                if dist2D(snap.myY, snap.myX, snap.attackerY, snap.attackerX) <= GotHit.DIST then
                    cmd(string.format('/moveto loc %s %s', snap.attackerY, snap.attackerX - GotHit.DIST))
                end
            end
        end
    end
    if snap.moveWhenHit then steps[#steps + 1] = { waitAway = true } end
    if snap.faceMobOn ~= 0 and (snap.attackerID > 0 or snap.targetID > 0) then
        cmd(snap.faceMobOn == 2 and '/face nolook' or '/face fast nolook')
    end
    cmd('/look 0')
    return steps
end

-- Acts on a pending hit, if any. Safe to call every pass.
function GotHit.respond()
    local s = _state
    if not s.combat.gotHitToggle then return end
    local mob = s.combat.gotHitBy or ''
    s.combat.gotHitToggle = false
    s.combat.gotHitBy     = ''
    if s.session.iAmDead or mq.TLO.Me.Hovering() then return end
    local role = s.session.role or ''
    if not (GotHit.WAIT_ROLES[role] or GotHit.PETTANK_ROLES[role]) then return end

    local snap = GotHit.snapshot(mob)
    local w = GotHit.decideWait(snap)
    if w.endWait then
        if w.clearTarget then
            s.combat.myTargetID   = 0
            s.combat.myTargetName = ''
            if (mq.TLO.Target.ID() or 0) > 0 then mq.cmd('/squelch /target clear') end
        end
        s.pull.gotHitEndWait = true
        printf('\awI got hit by >>\at%s\aw<< ID: \at%d\aw while waiting for mob.', mob, snap.attackerID)
    end

    if not GotHit.PETTANK_ROLES[role] then return end
    if snap.attackerID > 0 then
        mq.cmdf('/squelch /target id %d', snap.attackerID)
        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == snap.attackerID end)
        snap.targetID = mq.TLO.Target.ID() or 0
    end
    for _, step in ipairs(GotHit.decideResponse(snap, mob)) do
        if step.cmd then
            mq.cmd(step.cmd)
        elseif step.echo then
            printf('\aw%s', step.echo)
        elseif step.waitAway then
            mq.delay(1500, function()
                local t = mq.TLO.Target
                if not t() then return true end
                return dist2D(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, t.Y() or 0, t.X() or 0) > GotHit.DIST
            end)
        end
    end
end

return GotHit
