-- tests/unit/test_pause.lua
-- Soft pause (#353): Pause.set is idempotent, stops everything in progress when
-- pausing, and turns MQ2Melee back on when resuming (unless /backoff is on).
-- /kactl pause on|off|toggle is covered in test_control.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pause')
    MockMQ.reset()

    local Pause = require('modules.pause')

    local resets, medleyStops
    local combat = { combatReset = function() resets = resets + 1 end }
    local bard   = { stopMedley  = function() medleyStops = medleyStops + 1 end }

    local function fresh(over)
        MockMQ.reset()
        resets, medleyStops = 0, 0
        local s = {
            session = { paused = false, iAmABard = false },
            combat  = { combatStart = true, useMQ2Melee = false },
            dps     = { paused = false },
        }
        for k, v in pairs(over or {}) do
            for kk, vv in pairs(v) do s[k][kk] = vv end
        end
        Pause.init(s, combat, bard)
        return s
    end

    -- ── pausing ──────────────────────────────────────────────────────────────
    local s = fresh()
    TH.assert_false(Pause.isPaused(), 'starts unpaused')
    TH.assert_true(Pause.set(true), 'set(true) from unpaused reports a change')
    TH.assert_true(Pause.isPaused(), 'paused after set(true)')
    TH.assert_true(s.session.paused, 'state.session.paused set')
    TH.assert_false(s.combat.combatStart, 'combatStart cleared')
    TH.assert_true(MockMQ.cmdCalled('/squelch /attack off'), 'attack off')
    TH.assert_false(MockMQ.cmdCalled('/squelch /melee off'), 'no MQ2Melee: melee left alone')
    TH.assert_eq(resets, 1, 'combatReset called once')
    TH.assert_eq(medleyStops, 0, 'not a bard: medley left alone')
    TH.assert_false(MockMQ.cmdMatched('/stick off'), 'stick inactive: no /stick off')
    TH.assert_false(MockMQ.cmdMatched('/nav stop'), 'nav inactive: no /nav stop')
    TH.assert_false(MockMQ.cmdMatched('/pet back off'), 'no pet: no /pet back off')

    -- idempotent: a second pause does nothing
    MockMQ.reset()
    TH.assert_false(Pause.set(true), 'set(true) while paused reports no change')
    TH.assert_eq(#MockMQ.calls(), 0, 'second pause sends no commands')
    TH.assert_eq(resets, 1, 'second pause: no second combatReset')

    -- ── pausing with everything in progress ──────────────────────────────────
    fresh({ session = { iAmABard = true }, combat = { useMQ2Melee = true } })
    MockMQ.set('TLO.Stick.Active', true)
    MockMQ.set('TLO.Navigation.Active', true)
    MockMQ.set('TLO.MoveTo.Moving', true)
    MockMQ.set('TLO.AdvPath.State', 1)
    MockMQ.set('TLO.Me.Pet.ID', 77)
    MockMQ.set('TLO.Pet.Combat', true)
    Pause.set(true)
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee off'), 'MQ2Melee: melee off')
    TH.assert_true(MockMQ.cmdCalled('/squelch /stick off'), 'stick active: stick off')
    TH.assert_true(MockMQ.cmdCalled('/squelch /nav stop'), 'nav active: nav stop')
    TH.assert_true(MockMQ.cmdCalled('/squelch /moveto off'), 'moveto active: moveto off')
    TH.assert_true(MockMQ.cmdCalled('/squelch /play off'), 'advpath playing: play off')
    TH.assert_true(MockMQ.cmdCalled('/squelch /pet back off'), 'pet fighting: pet back off')
    TH.assert_eq(medleyStops, 1, 'bard: medley stopped')

    -- pet out of combat is left alone
    fresh()
    MockMQ.set('TLO.Me.Pet.ID', 77)
    MockMQ.set('TLO.Pet.Combat', false)
    Pause.set(true)
    TH.assert_false(MockMQ.cmdMatched('/pet back off'), 'pet not fighting: no /pet back off')

    -- ── resuming ─────────────────────────────────────────────────────────────
    fresh({ combat = { useMQ2Melee = true } })
    Pause.set(true)
    MockMQ.reset()
    TH.assert_true(Pause.set(false), 'set(false) from paused reports a change')
    TH.assert_false(Pause.isPaused(), 'unpaused after set(false)')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee on'), 'MQ2Melee: melee back on')
    TH.assert_eq(resets, 1, 'resume: no extra combatReset')
    TH.assert_false(Pause.set(false), 'set(false) while unpaused reports no change')

    -- resuming while /backoff is on leaves MQ2Melee off
    s = fresh({ combat = { useMQ2Melee = true } })
    Pause.set(true)
    s.dps.paused = true
    MockMQ.reset()
    Pause.set(false)
    TH.assert_false(MockMQ.cmdCalled('/squelch /melee on'), 'backed off: melee stays off on resume')

    -- ── loadSettings: [General] *WhilePaused, default off ───────────────────
    s = fresh()
    local ini = {}
    local config = { get = function(_, key, default) return ini[key] or default end }
    Pause.loadSettings(config)
    TH.assert_false(s.session.healWhilePaused, 'HealWhilePaused default off')
    TH.assert_false(s.session.moveWhilePaused, 'MoveWhilePaused default off')
    TH.assert_false(s.session.warnAggroWhilePaused, 'WarnAggroWhilePaused default off')
    ini = { HealWhilePaused = '1', MoveWhilePaused = '1', WarnAggroWhilePaused = '1' }
    Pause.loadSettings(config)
    TH.assert_true(s.session.healWhilePaused, 'HealWhilePaused=1')
    TH.assert_true(s.session.moveWhilePaused, 'MoveWhilePaused=1')
    TH.assert_true(s.session.warnAggroWhilePaused, 'WarnAggroWhilePaused=1')

    -- ── warnAggro ───────────────────────────────────────────────────────────
    local haters = 1
    local function setHaters()
        MockMQ.set('TLO.SpawnCount', function() return function() return haters end end)
    end
    s = fresh({ session = { warnAggroWhilePaused = true } })
    setHaters()
    TH.assert_false(Pause.warnAggro(100), 'not paused: no warning')
    Pause.set(true)
    MockMQ.reset()
    setHaters()
    TH.assert_true(Pause.warnAggro(100), 'paused with aggro: warns')
    TH.assert_true(MockMQ.cmdCalled('/beep'), 'paused with aggro: beeps')
    TH.assert_false(Pause.warnAggro(105), 'within 10s: no repeat')
    TH.assert_true(Pause.warnAggro(111), 'after 10s: warns again')
    haters = 0
    TH.assert_false(Pause.warnAggro(200), 'no haters: no warning')
    haters = 1
    s.session.warnAggroWhilePaused = false
    TH.assert_false(Pause.warnAggro(300), 'setting off: no warning')
end

return M
