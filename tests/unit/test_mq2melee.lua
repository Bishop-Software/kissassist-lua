-- tests/unit/test_mq2melee.lua
-- #237: MQ2Melee gaps vs the mac.
--   * Settings.setMQ2Melee: UseMQ2Melee 1 -> stickmode=0, 2 -> stickmode=1
--     (mac:16356-16361); off with the plugin loaded -> melee=0 + off; refuses
--     to turn on without the plugin.
--   * /backoff (Bind_BackOff, mac:13717-13767): on/1 backs off, off/0 resumes,
--     bare toggles; backing off sends /melee off, /attack off, /stick off and
--     CombatReset; resuming sends /melee on; waitFlag gives the MA a moment to
--     pick a new target (CombatTargetCheck 2 with target switching forced on);
--     ReturnToCamp heads back to camp.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_mq2melee')

    local function clearCalls()
        local calls = MockMQ.calls()
        for i = #calls, 1, -1 do calls[i] = nil end
    end

    -- ── Settings.setMQ2Melee ────────────────────────────────────────────────
    package.loaded['modules.combat.settings'] = nil
    local Settings = require('modules.combat.settings')
    local loaded = false
    MockMQ.set('TLO.Plugin', function()
        return { IsLoaded = function() return loaded end }
    end)
    local st = { combat = { useMQ2Melee = false, mq2MeleeMode = 1 } }

    TH.assert_false(Settings.setMQ2Melee(st, true), 'plugin not loaded: refuses to turn on')
    TH.assert_false(st.combat.useMQ2Melee, 'plugin not loaded: stays off')

    loaded = true
    clearCalls()
    TH.assert_true(Settings.setMQ2Melee(st, true), 'plugin loaded: turns on')
    TH.assert_true(st.combat.useMQ2Melee, 'plugin loaded: useMQ2Melee on')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee on'), 'on: /melee on')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee stickmode=0'), 'UseMQ2Melee=1: stickmode=0 (MQ2Melee sticks)')

    clearCalls()
    st.combat.mq2MeleeMode = 2
    Settings.setMQ2Melee(st, true)
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee stickmode=1'), 'UseMQ2Melee=2: stickmode=1 (INI stickcmd)')
    TH.assert_false(MockMQ.cmdCalled('/squelch /melee stickmode=0'), 'UseMQ2Melee=2: not stickmode=0')

    clearCalls()
    Settings.setMQ2Melee(st, false)
    TH.assert_false(st.combat.useMQ2Melee, 'off: useMQ2Melee off')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee melee=0'), 'off, plugin loaded: melee=0')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee off'), 'off, plugin loaded: /melee off')
    TH.assert_false(MockMQ.cmdMatched('/plugin'), 'off: the plugin is not unloaded')

    -- ── /backoff ────────────────────────────────────────────────────────────
    local savedAliases, savedMovement = package.loaded['modules.aliases'], package.loaded['modules.movement']
    local savedBind, savedDelay = MockMQ.bind, MockMQ.delay
    local moves = 0
    package.loaded['modules.aliases']  = { sync = function() return 0, 0 end }
    package.loaded['modules.movement'] = { doWeMove = function() moves = moves + 1 end }
    package.loaded['modules.binds']    = nil
    local bound = {}
    MockMQ.bind = function(cmd, fn) bound[cmd] = fn end
    local Binds = require('modules.binds')

    local state = {
        dps      = { paused = false },
        combat   = { useMQ2Melee = true, combatStart = true, targetSwitchingOn = false },
        session  = { iAmMA = true },
        cast     = {},
        movement = { returnToCamp = false, campX = 0, campY = 0 },
    }
    local resets, checks = {}, {}
    local combat = {
        combatReset = function(_, from) resets[#resets + 1] = from end,
        combatTargetCheck = function(n)
            checks[#checks + 1] = { n = n, switching = state.combat.targetSwitchingOn,
                                    paused = state.dps.paused }
        end,
    }
    Binds.register(state, {}, {}, combat, { set = function() end, save = function() end }, {})
    local backoff = bound['/backoff']
    TH.assert_true(backoff ~= nil, '/backoff is bound')

    local stick = true
    MockMQ.set('TLO.Stick.Active', function() return stick end)

    -- /backoff on: back off.
    clearCalls()
    backoff('on')
    TH.assert_true(state.dps.paused, '/backoff on: paused')
    TH.assert_false(state.combat.combatStart, '/backoff on: combat stopped')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee off'), '/backoff on: /melee off')
    TH.assert_true(MockMQ.cmdCalled('/squelch /attack off'), '/backoff on: /attack off')
    TH.assert_true(MockMQ.cmdCalled('/stick off'), '/backoff on: /stick off')
    TH.assert_eq(resets[#resets], 'backoff', '/backoff on: CombatReset')

    -- /backoff on again: stays backed off (not a toggle).
    backoff('on')
    TH.assert_true(state.dps.paused, '/backoff on twice: still paused')

    -- /backoff off: resume.
    clearCalls()
    backoff('off')
    TH.assert_false(state.dps.paused, '/backoff off: resumed')
    TH.assert_true(MockMQ.cmdCalled('/squelch /melee on'), '/backoff off: /melee on')

    -- 1 / 0 work like on / off; bare /backoff toggles.
    backoff('1')
    TH.assert_true(state.dps.paused, '/backoff 1: paused')
    backoff('0')
    TH.assert_false(state.dps.paused, '/backoff 0: resumed')
    backoff()
    TH.assert_true(state.dps.paused, 'bare /backoff: toggles to paused')
    backoff()
    TH.assert_false(state.dps.paused, 'bare /backoff: toggles back')

    -- Without MQ2Melee no /melee commands are sent.
    state.combat.useMQ2Melee = false
    clearCalls()
    backoff('on')
    backoff('off')
    TH.assert_false(MockMQ.cmdMatched('/melee'), 'no MQ2Melee: no /melee commands')
    state.combat.useMQ2Melee = true

    -- waitFlag: the MA switches target during the wait -> CombatTargetCheck 2.
    local tid = 100
    MockMQ.set('TLO.Target.ID', function() return tid end)
    MockMQ.delay = function() tid = 200 end
    backoff('on')
    backoff('off', '1')
    TH.assert_eq(#checks, 1, 'waitFlag, new target: CombatTargetCheck runs')
    TH.assert_eq(checks[1].n, 2, 'waitFlag: CombatTargetCheck 2')
    TH.assert_true(checks[1].switching, 'waitFlag: target switching forced on during the check')
    TH.assert_true(checks[1].paused, 'waitFlag: check runs before DPS resumes')
    TH.assert_false(state.combat.targetSwitchingOn, 'waitFlag: TargetSwitchingOn restored')
    TH.assert_false(state.dps.paused, 'waitFlag: resumed afterwards')

    -- waitFlag, no new target: no check.
    MockMQ.delay = function() end
    backoff('on')
    backoff('off', '1')
    TH.assert_eq(#checks, 1, 'waitFlag, same target: no CombatTargetCheck')

    -- ReturnToCamp: heads back to camp when more than 15 away (not with waitFlag).
    MockMQ.set('TLO.Me.X', 0)
    MockMQ.set('TLO.Me.Y', 0)
    state.movement = { returnToCamp = true, campX = 100, campY = 0 }
    backoff('on')
    TH.assert_eq(moves, 1, 'ReturnToCamp, away from camp: moves back')
    backoff('off', '1')
    TH.assert_eq(moves, 1, 'ReturnToCamp with waitFlag: stays put')
    state.movement.campX = 10
    backoff('on')
    TH.assert_eq(moves, 1, 'ReturnToCamp, within 15 of camp: stays put')

    MockMQ.bind, MockMQ.delay = savedBind, savedDelay
    package.loaded['modules.aliases']  = savedAliases
    package.loaded['modules.movement'] = savedMovement
    package.loaded['modules.binds']    = nil
    package.loaded['modules.combat.settings'] = nil
end

return M
