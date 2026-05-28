-- tests/integration/test_toggle_cmds.lua
-- Integration tests for /togglevariable and /changevarint binds.
-- Covers test plan section S2.2.x.
--
-- REQUIRES: kissassist running on a live character.
-- INVOKE via mq_eval (MQ MCP tool) while the bot is running:
--
--   local TH = require('tests.test_helpers')
--   require('tests.integration.test_toggle_cmds').run(mq, KAState, TH)
--   TH.printSummary()

local M = {}

function M.run(mq, State, TH)
    TH.setSuite('test_toggle_cmds')

    -- /togglevariable on a boolean: dpsOn (combat sub-table, default false) ------
    local origDpsOn = State.combat.dpsOn
    State.combat.dpsOn = false   -- ensure known starting value

    mq.cmd('/togglevariable dpsOn')
    TH.assert_true(State.combat.dpsOn,  '/togglevariable dpsOn false→true')

    mq.cmd('/togglevariable dpsOn')
    TH.assert_false(State.combat.dpsOn, '/togglevariable dpsOn true→false')

    State.combat.dpsOn = origDpsOn

    -- /togglevariable on a number: healsOn (heal sub-table, 0=off/1=on) ----------
    local origHealsOn = State.heal.healsOn
    State.heal.healsOn = 0   -- known starting value

    mq.cmd('/togglevariable healsOn')
    TH.assert_eq(State.heal.healsOn, 1, '/togglevariable healsOn 0→1')

    mq.cmd('/togglevariable healsOn')
    TH.assert_eq(State.heal.healsOn, 0, '/togglevariable healsOn 1→0')

    State.heal.healsOn = origHealsOn

    -- /togglevariable on a boolean: meleeOn (combat sub-table) -------------------
    local origMeleeOn = State.combat.meleeOn
    State.combat.meleeOn = false

    mq.cmd('/togglevariable meleeOn')
    TH.assert_true(State.combat.meleeOn,  '/togglevariable meleeOn false→true')

    mq.cmd('/togglevariable meleeOn')
    TH.assert_false(State.combat.meleeOn, '/togglevariable meleeOn true→false')

    State.combat.meleeOn = origMeleeOn

    -- /changevarint <varName> <value>: assistAt (session sub-table) ---------------
    -- session sub-table is searched first in stateSubtables(), so session.assistAt wins.
    local origAssistAt = State.session.assistAt

    mq.cmd('/changevarint assistAt 80')
    TH.assert_eq(State.session.assistAt, 80, '/changevarint assistAt 80')

    mq.cmd('/changevarint assistAt 50')
    TH.assert_eq(State.session.assistAt, 50, '/changevarint assistAt 50')

    State.session.assistAt = origAssistAt

    -- /changevarint: campRadius (movement sub-table) ------------------------------
    local origRadius = State.movement.campRadius

    mq.cmd('/changevarint campRadius 75')
    TH.assert_eq(State.movement.campRadius, 75, '/changevarint campRadius 75')

    State.movement.campRadius = origRadius

    -- /changevarint: unknown variable → no crash (pcall success) -----------------
    local ok = pcall(function() mq.cmd('/changevarint notARealVar 5') end)
    TH.assert_true(ok, '/changevarint unknown var no crash')

    -- /togglevariable: unknown variable → no crash --------------------------------
    local ok2 = pcall(function() mq.cmd('/togglevariable notARealVar') end)
    TH.assert_true(ok2, '/togglevariable unknown var no crash')
end

return M
