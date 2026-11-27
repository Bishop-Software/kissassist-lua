-- tests/unit/test_cantsee.lua
-- Event_CantSee (mac:10820-10900): CantSee.note (pulling vs not), CantSee.decide
-- (not attacking / attacking with and without MQ2Melee, out of sight with and
-- without nav, the re-stick per StickHow x MA x underwater) and respond()'s gating.
-- The moves themselves are checked in game.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_cantsee')
    MockMQ.reset()

    local CantSee = require('modules.cantsee')

    local function snap(over)
        local s = {
            attacking = true, useMQ2Melee = false, meleeOn = true, iAmMA = false,
            sitting = false, feetWet = false, stickActive = false, faceMobOn = 1,
            targetID = 42, los = true, maxRangeTo = 15, moveUse = 'nav', navPath = true,
            meleeDistance = 20, stickHow = 'behind', stickDist = 13, stickDistUW = 10,
            myTargetID = 42,
        }
        for k, v in pairs(over or {}) do s[k] = v end
        return s
    end
    local function cmds(steps)
        local out = {}
        for _, st in ipairs(steps) do
            if st.cmd then out[#out + 1] = st.cmd
            elseif st.nav then out[#out + 1] = '<nav>'
            elseif st.wait then out[#out + 1] = '<wait ' .. st.wait .. '>' end
        end
        return table.concat(out, ' ; ')
    end
    local function has(steps, c)
        for _, st in ipairs(steps) do if st.cmd == c then return true end end
        return false
    end
    local function hasNav(steps)
        for _, st in ipairs(steps) do if st.nav then return true end end
        return false
    end

    -- ── not attacking ───────────────────────────────────────────────────────
    TH.assert_eq(cmds(CantSee.decide(snap({ attacking = false }))), '/squelch /face fast nolook',
        'not attacking: face only')
    TH.assert_eq(cmds(CantSee.decide(snap({ attacking = false, faceMobOn = 2 }))), '/squelch /face nolook',
        'not attacking: FaceMobOn 2 -> nolook')
    TH.assert_eq(#CantSee.decide(snap({ attacking = false, faceMobOn = 0 })), 0,
        'not attacking, FaceMobOn off: nothing')

    -- ── attacking with MQ2Melee ─────────────────────────────────────────────
    TH.assert_eq(cmds(CantSee.decide(snap({ useMQ2Melee = true, sitting = true, los = false }))),
        '/stand ; /squelch /face fast nolook ; /look 0', 'MQ2Melee: stand, face, look only')

    -- ── attacking without MQ2Melee: getting back in sight ───────────────────
    local st = CantSee.decide(snap({ los = false }))
    TH.assert_true(hasNav(st), 'out of sight with a nav path -> nav')
    TH.assert_false(has(st, '/squelch /moveto id 42 dist 18'), 'out of sight -> no moveto into melee')

    st = CantSee.decide(snap({ los = false, navPath = false }))
    TH.assert_false(hasNav(st), 'out of sight, no nav path -> no nav')
    st = CantSee.decide(snap({ los = false, moveUse = 'los' }))
    TH.assert_false(hasNav(st), 'out of sight, no nav mesh (moveUse los) -> no nav')

    st = CantSee.decide(snap())
    TH.assert_true(has(st, '/squelch /moveto id 42 dist 18'), 'in sight -> moveto MeleeDistance-2')
    TH.assert_false(hasNav(st), 'in sight -> no nav')

    -- ── re-stick: StickHow set (not 0 / I) ──────────────────────────────────
    TH.assert_eq(cmds(CantSee.decide(snap())),
        '/squelch /face fast nolook ; /look 0 ; /squelch /moveto id 42 dist 18 ; /squelch /moveto 15 id 42 ; <wait 1000> ; /squelch /stick 13 id 42 behindonce moveback',
        'StickHow set, not MA, dry: moveto MaxRangeTo, wait, stick behindonce moveback')
    st = CantSee.decide(snap({ iAmMA = true }))
    TH.assert_true(has(st, '/squelch /stick 13 id 42 moveback'), 'StickHow set, MA: no behindonce')
    st = CantSee.decide(snap({ feetWet = true, stickActive = true }))
    TH.assert_true(has(st, '/squelch /stick off'), 'underwater, stick active: stick off first')
    TH.assert_true(has(st, '/squelch /face'), 'underwater: plain /face')
    TH.assert_true(has(st, '/squelch /moveto 15 id 42 uw'), 'underwater: moveto ... uw')
    TH.assert_true(has(st, '/squelch /stick 10 id 42 behindonce moveback uw'), 'underwater: StickDistUW ... uw')
    st = CantSee.decide(snap({ feetWet = true, stickActive = false }))
    TH.assert_false(has(st, '/squelch /stick off'), 'underwater, no stick: no stick off')

    -- ── re-stick: StickHow 0 ────────────────────────────────────────────────
    st = CantSee.decide(snap({ stickHow = '0' }))
    TH.assert_true(has(st, '/squelch /stick 13 id 42 !front moveback'), 'StickHow 0, not MA: !front moveback')
    TH.assert_false(has(st, '/squelch /moveto 15 id 42'), 'StickHow 0: no MaxRangeTo moveto')
    st = CantSee.decide(snap({ stickHow = '0', iAmMA = true }))
    TH.assert_true(has(st, '/squelch /stick 13 id 42 moveback'), 'StickHow 0, MA: moveback')
    st = CantSee.decide(snap({ stickHow = '0', feetWet = true }))
    TH.assert_true(has(st, '/squelch /stick 10 id 42 moveback uw'), 'StickHow 0 underwater: no !front, uw')
    st = CantSee.decide(snap({ stickHow = '0', meleeOn = false }))
    TH.assert_false(has(st, '/squelch /stick 13 id 42 !front moveback'), 'StickHow 0, MeleeOn off: no stick')

    -- ── re-stick: StickHow I ────────────────────────────────────────────────
    st = CantSee.decide(snap({ stickHow = 'I' }))
    TH.assert_eq(cmds(st), '/squelch /face fast nolook ; /look 0 ; /squelch /moveto id 42 dist 18',
        'StickHow I: no re-stick')

    -- ── note / respond ──────────────────────────────────────────────────────
    local state = {
        session  = { iAmDead = false, iAmMA = false },
        combat   = { attacking = false, useMQ2Melee = false, meleeOn = true, myTargetID = 0, meleeDistance = 20 },
        movement = { cantSee = false, cantSeePending = false, faceMobOn = 1, stickHow = '0' },
        pull     = { pulling = true, moveUse = 'los' },
    }
    CantSee.init(state)
    CantSee.note()
    TH.assert_true(state.movement.cantSee, 'note while pulling: cantSee set for the pull retry')
    TH.assert_false(state.movement.cantSeePending, 'note while pulling: no response queued')

    state.movement.cantSee = false
    state.pull.pulling = false
    CantSee.note()
    TH.assert_false(state.movement.cantSee, 'note outside a pull: cantSee left alone')
    TH.assert_true(state.movement.cantSeePending, 'note outside a pull: response queued')

    MockMQ.reset()
    MockMQ.set('TLO.Target.ID', 42)
    MockMQ.set('TLO.Navigation.PathExists', function() return function() return false end end)
    CantSee.respond()
    TH.assert_false(state.movement.cantSeePending, 'respond: pending cleared')
    TH.assert_true(MockMQ.cmdCalled('/squelch /face fast nolook'), 'respond, not attacking: faces')
    TH.assert_eq(#MockMQ.calls(), 1, 'respond, not attacking: only the face')

    MockMQ.reset()
    CantSee.respond()
    TH.assert_eq(#MockMQ.calls(), 0, 'respond: nothing pending -> no commands')

    -- Holding (/kactl hold, #364): no moving back into sight; the pending flag clears.
    state.movement.cantSeePending = true
    state.session.hold = true
    MockMQ.reset()
    MockMQ.set('TLO.Target.ID', 42)
    CantSee.respond()
    TH.assert_eq(#MockMQ.calls(), 0, 'respond while holding: no commands')
    TH.assert_false(state.movement.cantSeePending, 'respond while holding: pending cleared')
    state.session.hold = false
end

return M
