-- tests/unit/test_gothit.lua
-- Event_GotHit's response (mac:11054-11113): GotHit.decideWait (a puller tank hit
-- while waiting in camp), GotHit.decideResponse (the pet tank's steps, MoveWhenHit)
-- and GotHit.respond's gating. The moves themselves are checked in game.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_gothit')
    MockMQ.reset()

    local GotHit = require('modules.gothit')

    local function snap(over)
        local s = {
            role = 'pettank', pulled = false, waitingForMob = false, myTargetID = 0,
            returnToCamp = true, campRadius = 30, campY = 0, campX = 0, myY = 0, myX = 0,
            nearestCampNpc = 0, targetID = 0,
            attackerID = 50, attackerY = 5, attackerX = 0,
            petID = 9, petY = 0, petX = 20, petTaunt = false, petAttackRange = 115,
            tauntOverride = false, moveWhenHit = false, faceMobOn = 0,
        }
        for k, v in pairs(over or {}) do s[k] = v end
        return s
    end
    local function cmds(steps)
        local out = {}
        for _, st in ipairs(steps) do if st.cmd then out[#out + 1] = st.cmd end end
        return table.concat(out, ' ; ')
    end
    local function has(steps, c)
        for _, st in ipairs(steps) do if st.cmd == c then return true end end
        return false
    end
    local function hasWait(steps)
        for _, st in ipairs(steps) do if st.waitAway then return true end end
        return false
    end

    -- ── decideWait ──────────────────────────────────────────────────────────
    local w = GotHit.decideWait(snap({ role = 'pullertank', pulled = true, waitingForMob = true,
        myTargetID = 50, nearestCampNpc = 50 }))
    TH.assert_true(w.endWait, 'wait: pullertank in camp while waiting -> stop waiting')
    TH.assert_false(w.clearTarget, 'wait: nearest NPC is MyTargetID -> target kept')

    w = GotHit.decideWait(snap({ role = 'pullerpettank', pulled = true, waitingForMob = true,
        myTargetID = 50, nearestCampNpc = 77 }))
    TH.assert_true(w.endWait, 'wait: pullerpettank too')
    TH.assert_true(w.clearTarget, 'wait: nearest NPC is another mob -> target cleared')

    w = GotHit.decideWait(snap({ role = 'pullertank', pulled = true, waitingForMob = false }))
    TH.assert_false(w.endWait, 'wait: not in waitForMob (WaitTimer 0) -> nothing')

    w = GotHit.decideWait(snap({ role = 'pullertank', pulled = false, waitingForMob = true }))
    TH.assert_false(w.endWait, 'wait: nothing pulled -> nothing')

    w = GotHit.decideWait(snap({ role = 'pullertank', pulled = true, waitingForMob = true, myY = 40 }))
    TH.assert_false(w.endWait, 'wait: outside CampRadius -> nothing')

    w = GotHit.decideWait(snap({ role = 'pettank', pulled = true, waitingForMob = true }))
    TH.assert_false(w.endWait, 'wait: pettank never waits for a pull')

    -- ── decideResponse ──────────────────────────────────────────────────────
    local st = GotHit.decideResponse(snap(), 'a gnoll')
    TH.assert_eq(cmds(st), '/moveto dist 10 ; /pet attack ; /pet taunt on ; /look 0',
        'response: in camp, pet in range -> pet sent in, taunt on')
    TH.assert_false(hasWait(st), 'response: MoveWhenHit off -> no wait')

    st = GotHit.decideResponse(snap({ petTaunt = true }), 'a gnoll')
    TH.assert_false(has(st, '/pet taunt on'), 'response: taunt already on -> not sent again')

    st = GotHit.decideResponse(snap({ tauntOverride = true }), 'a gnoll')
    TH.assert_true(has(st, '/pet attack'), 'response: Taunt Off still sends the pet')
    TH.assert_false(has(st, '/pet taunt on'), 'response: Taunt Off -> taunt left off')

    st = GotHit.decideResponse(snap({ petX = 200 }), 'a gnoll')
    TH.assert_false(has(st, '/pet attack'), 'response: mob beyond PetAttackRange of the pet -> pet stays')

    st = GotHit.decideResponse(snap({ petID = 0 }), 'a gnoll')
    TH.assert_false(has(st, '/pet attack'), 'response: no pet -> no /pet attack')

    st = GotHit.decideResponse(snap({ moveWhenHit = true }), 'a gnoll')
    TH.assert_true(has(st, '/moveto loc 5 -10'), 'response: MoveWhenHit, mob within 10 -> step 10 away')
    TH.assert_true(hasWait(st), 'response: MoveWhenHit -> wait to get clear')

    st = GotHit.decideResponse(snap({ moveWhenHit = true, attackerY = 15 }), 'a gnoll')
    TH.assert_false(has(st, '/moveto loc 15 -10'), 'response: MoveWhenHit, mob already >10 away -> no step')

    -- Out of camp with ReturnToCamp
    st = GotHit.decideResponse(snap({ myY = 100, attackerY = 105, moveWhenHit = true }), 'a gnoll')
    TH.assert_true(has(st, '/moveto loc 0 0'), 'response: out of camp, MoveWhenHit -> back to camp')
    TH.assert_false(has(st, '/pet attack'), 'response: out of camp -> pet not sent (mac branch)')

    st = GotHit.decideResponse(snap({ myY = 100, attackerY = 105 }), 'a gnoll')
    TH.assert_eq(cmds(st), '/moveto dist 10 ; /look 0', 'response: out of camp, MoveWhenHit off -> nothing moves')

    st = GotHit.decideResponse(snap({ myY = 100, attackerY = 105, petY = 100, returnToCamp = false }), 'a gnoll')
    TH.assert_true(has(st, '/pet attack'), 'response: out of camp without ReturnToCamp -> pet sent')

    st = GotHit.decideResponse(snap({ role = 'hunterpettank', myY = 100, attackerY = 105, petY = 100,
        moveWhenHit = true }), 'a gnoll')
    TH.assert_false(has(st, '/moveto loc 0 0'), 'response: hunterpettank never goes back to camp')
    TH.assert_true(has(st, '/pet attack'), 'response: hunterpettank sends the pet')

    -- Facing
    st = GotHit.decideResponse(snap({ faceMobOn = 1 }), 'a gnoll')
    TH.assert_true(has(st, '/face fast nolook'), 'response: FaceMobOn 1 -> /face fast nolook')
    st = GotHit.decideResponse(snap({ faceMobOn = 2 }), 'a gnoll')
    TH.assert_true(has(st, '/face nolook'), 'response: FaceMobOn 2 -> /face nolook')

    -- No attacker found
    st = GotHit.decideResponse(snap({ attackerID = 0 }), 'a gnoll')
    TH.assert_eq(cmds(st), '/look 0', 'response: attacker not found -> only /look 0')

    st = GotHit.decideResponse(snap({ role = 'pullertank' }), 'a gnoll')
    TH.assert_eq(#st, 0, 'response: pullertank has no pet response')

    -- ── note / respond ──────────────────────────────────────────────────────
    local state = {
        session  = { role = 'assist', iAmDead = false },
        combat   = { myTargetID = 50, myTargetName = 'a gnoll', gotHitToggle = false, gotHitBy = '' },
        pull     = { pulled = true, waitingForMob = true, gotHitEndWait = false },
        movement = { returnToCamp = true, campRadius = 30, campY = 0, campX = 0, faceMobOn = 0 },
        pet      = { attackRange = 115, tauntOverride = false, moveWhenHit = false },
    }
    GotHit.init(state)
    GotHit.note('a gnoll')
    TH.assert_true(state.combat.gotHitToggle, 'note: hit pending')
    TH.assert_eq(state.combat.gotHitBy, 'a gnoll', 'note: attacker name kept')

    MockMQ.reset()
    GotHit.respond()
    TH.assert_false(state.combat.gotHitToggle, 'respond: pending hit cleared')
    TH.assert_eq(#MockMQ.calls(), 0, 'respond: assist role -> no commands')
    TH.assert_false(state.pull.gotHitEndWait, 'respond: assist role -> wait not ended')

    -- pullertank waiting in camp, a different mob nearest in camp
    MockMQ.reset()
    MockMQ.set('TLO.Me.Y', 0)
    MockMQ.set('TLO.Me.X', 0)
    MockMQ.set('TLO.Target.ID', 50)
    -- Both NearestSpawn lookups (nearest NPC in camp, the attacker) find mob 77.
    MockMQ.set('TLO.NearestSpawn', function()
        return { ID = function() return 77 end, Y = function() return 5 end, X = function() return 0 end }
    end)
    state.session.role = 'pullertank'
    GotHit.note('a gnoll')
    GotHit.respond()
    TH.assert_true(state.pull.gotHitEndWait, 'respond: pullertank in camp -> wait ended')
    TH.assert_eq(state.combat.myTargetID, 0, 'respond: other mob nearest -> MyTargetID cleared')
    TH.assert_true(MockMQ.cmdCalled('/squelch /target clear'), 'respond: target cleared')
    TH.assert_false(MockMQ.cmdMatched('^/pet'), 'respond: pullertank sends no pet commands')

    -- Nothing pending -> nothing happens
    MockMQ.reset()
    state.pull.gotHitEndWait = false
    GotHit.respond()
    TH.assert_eq(#MockMQ.calls(), 0, 'respond: no pending hit -> no commands')
    TH.assert_false(state.pull.gotHitEndWait, 'respond: no pending hit -> wait untouched')
end

return M
