-- tests/integration/test_toggle_cmds.lua
-- Integration tests for /togglevariable and /changevarint binds.
-- Covers test plan section S2.2.x.
--
-- Run in-game while kissassist is running: /katest toggle_cmds
local M = {}

local D = 250  -- ms delay after each mq.cmd() to let the deferred bind execute

function M.run(mq, State, TH)
    TH.setSuite('test_toggle_cmds')

    -- /togglevariable on a boolean: dpsOn (combat sub-table, default false) ------
    local origDpsOn = State.combat.dpsOn
    State.combat.dpsOn = false

    mq.cmd('/togglevariable dpsOn') ; mq.delay(D)
    TH.assert_true(State.combat.dpsOn,  '/togglevariable dpsOn false→true')

    mq.cmd('/togglevariable dpsOn') ; mq.delay(D)
    TH.assert_false(State.combat.dpsOn, '/togglevariable dpsOn true→false')

    State.combat.dpsOn = origDpsOn

    -- /togglevariable on a number: healsOn (heal sub-table, 0=off/1=on) ----------
    local origHealsOn = State.heal.healsOn
    State.heal.healsOn = 0

    mq.cmd('/togglevariable healsOn') ; mq.delay(D)
    TH.assert_eq(State.heal.healsOn, 1, '/togglevariable healsOn 0→1')

    mq.cmd('/togglevariable healsOn') ; mq.delay(D)
    TH.assert_eq(State.heal.healsOn, 0, '/togglevariable healsOn 1→0')

    State.heal.healsOn = origHealsOn

    -- /togglevariable on a boolean: meleeOn (combat sub-table) -------------------
    local origMeleeOn = State.combat.meleeOn
    State.combat.meleeOn = false

    mq.cmd('/togglevariable meleeOn') ; mq.delay(D)
    TH.assert_true(State.combat.meleeOn,  '/togglevariable meleeOn false→true')

    mq.cmd('/togglevariable meleeOn') ; mq.delay(D)
    TH.assert_false(State.combat.meleeOn, '/togglevariable meleeOn true→false')

    State.combat.meleeOn = origMeleeOn

    -- /changevarint assistAt: session sub-table is searched first ----------------
    local origAssistAt = State.session.assistAt

    mq.cmd('/changevarint assistAt 80') ; mq.delay(D)
    TH.assert_eq(State.session.assistAt, 80, '/changevarint assistAt 80')

    mq.cmd('/changevarint assistAt 50') ; mq.delay(D)
    TH.assert_eq(State.session.assistAt, 50, '/changevarint assistAt 50')

    State.session.assistAt = origAssistAt

    -- /changevarint campRadius (movement sub-table) ------------------------------
    local origRadius = State.movement.campRadius

    mq.cmd('/changevarint campRadius 75') ; mq.delay(D)
    TH.assert_eq(State.movement.campRadius, 75, '/changevarint campRadius 75')

    State.movement.campRadius = origRadius

    -- Unknown variable → no crash ------------------------------------------------
    local ok1 = pcall(function() mq.cmd('/changevarint notARealVar 5') mq.delay(D) end)
    TH.assert_true(ok1, '/changevarint unknown var no crash')

    local ok2 = pcall(function() mq.cmd('/togglevariable notARealVar') mq.delay(D) end)
    TH.assert_true(ok2, '/togglevariable unknown var no crash')
end

return M
