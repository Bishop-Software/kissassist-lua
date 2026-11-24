-- tests/unit/test_gap14_small.lua
-- Gap 14 small items: Cast.stopMoving (mac StopMoving, mac:10025) and BeforeAttack
-- command: entries (mac:2045). The pet-hold line in combatReset (mac:2266) is a
-- one-line command and is checked in game.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_gap14_small')
    MockMQ.reset()

    local function callable(v) return function() return v end end

    -- ── Cast.stopMoving ─────────────────────────────────────────────────────
    local Utils = require('modules.utils')
    local Cast  = require('modules.cast')
    Cast.init({ cast = {}, session = {}, combat = {}, buffs = {} }, Utils)

    local function setMove(moveto, stick, nav)
        MockMQ.reset()
        MockMQ.set('TLO.MoveTo.Moving', moveto)
        MockMQ.set('TLO.Stick.Active', stick)
        MockMQ.set('TLO.Navigation.Active', nav)
        MockMQ.set('TLO.Me.Moving', false)
    end

    setMove(true, true, false)
    Cast.stopMoving()
    TH.assert_true(MockMQ.cmdCalled('/squelch /moveto off'), 'stopMoving: moveto active -> /moveto off')
    TH.assert_true(MockMQ.cmdCalled('/squelch /stick off'), 'stopMoving: stick active -> /stick off')
    TH.assert_false(MockMQ.cmdCalled('/squelch /nav stop'), 'stopMoving: nav idle -> no /nav stop')

    setMove(false, false, true)
    Cast.stopMoving()
    TH.assert_true(MockMQ.cmdCalled('/squelch /nav stop'), 'stopMoving: nav active -> /nav stop')
    TH.assert_eq(#MockMQ.calls(), 1, 'stopMoving: only the active mover is stopped')

    -- ── BeforeAttack command: entries ───────────────────────────────────────
    local Abilities = require('modules.combat.abilities')
    local sentCommand
    local castStub = { castCommand = function(name) sentCommand = name; return 'CAST_SUCCESS' end }

    local condStub = { eval = function(n) return n ~= 3 end }   -- cond3 is false

    local function runBefore(entry)
        MockMQ.reset()
        sentCommand = nil
        MockMQ.set('TLO.Target.ID', 123)
        MockMQ.set('TLO.FindItem', function() return { ID = callable(0) } end)
        MockMQ.set('TLO.Me.AltAbility', function() return { ID = callable(0), Type = callable(0) } end)
        MockMQ.set('TLO.Me.CombatAbilityReady', function() return callable(false) end)
        MockMQ.set('TLO.Me.Skill', function() return callable(0) end)
        local state = { arrays = { beforeArray = { entry, 'null' } } }
        Abilities.init(state, Utils, castStub, condStub, nil, {})
        Abilities.beforeAttack(123, 1)
    end

    runBefore('command:/pet attack')
    TH.assert_eq(sentCommand, 'command:/pet attack', 'BeforeAttack: command: entry -> castCommand')

    runBefore('Command:/pet taunt on|cond4')
    TH.assert_eq(sentCommand, 'Command:/pet taunt on', 'BeforeAttack: prefix is case-insensitive, |cond stripped')

    runBefore('command:/pet taunt on|cond3')
    TH.assert_nil(sentCommand, 'BeforeAttack: false |cond -> command not sent')

    runBefore('Some Missing Ability')
    TH.assert_nil(sentCommand, 'BeforeAttack: non-command entry with nothing ready -> no castCommand')

    MockMQ.reset()
end

return M
