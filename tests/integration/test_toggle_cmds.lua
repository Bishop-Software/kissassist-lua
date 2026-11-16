-- tests/integration/test_toggle_cmds.lua
-- Integration tests for /togglevariable and /changevarint binds.
-- Both take the mac's variable names and value rules (mac:8371, 11237):
-- on/1 = on, off/0/no value = off, a number is used as is.
--
-- Run in-game while kissassist is running: /katest toggle_cmds
local M = {}

local D = 250  -- ms delay after each mq.cmd() to let the deferred bind execute

function M.run(mq, State, TH)
    TH.setSuite('test_toggle_cmds')

    -- /togglevariable on a boolean, mac name (MeleeOn -> combat.meleeOn) ----------
    local origMeleeOn = State.combat.meleeOn
    State.combat.meleeOn = false
    mq.cmd('/togglevariable MeleeOn on') ; mq.delay(D)
    TH.assert_true(State.combat.meleeOn, '/togglevariable MeleeOn on')
    mq.cmd('/togglevariable MeleeOn off') ; mq.delay(D)
    TH.assert_false(State.combat.meleeOn, '/togglevariable MeleeOn off')
    mq.cmd('/togglevariable meleeon 1') ; mq.delay(D)
    TH.assert_true(State.combat.meleeOn, '/togglevariable meleeon 1 (any case)')
    mq.cmd('/togglevariable MeleeOn') ; mq.delay(D)
    TH.assert_false(State.combat.meleeOn, '/togglevariable MeleeOn (no value) turns it off, as in the mac')
    State.combat.meleeOn = origMeleeOn

    -- /togglevariable on a number: HealsOn (heal.healsOn) -------------------------
    local origHealsOn = State.heal.healsOn
    mq.cmd('/togglevariable HealsOn 2') ; mq.delay(D)
    TH.assert_eq(State.heal.healsOn, 2, '/togglevariable HealsOn 2')
    mq.cmd('/togglevariable HealsOn off') ; mq.delay(D)
    TH.assert_eq(State.heal.healsOn, 0, '/togglevariable HealsOn off')
    State.heal.healsOn = origHealsOn

    -- Mac name the port spells differently: PetOn -> pet.on -----------------------
    local origPetOn = State.pet.on
    mq.cmd('/togglevariable PetOn on') ; mq.delay(D)
    TH.assert_true(State.pet.on, '/togglevariable PetOn on -> pet.on')
    State.pet.on = origPetOn

    -- waithere: stop chasing and returning to camp --------------------------------
    local origChase, origRTC = State.session.chaseAssist, State.movement.returnToCamp
    State.session.chaseAssist, State.movement.returnToCamp = true, true
    mq.cmd('/togglevariable waithere') ; mq.delay(D)
    TH.assert_false(State.session.chaseAssist, 'waithere: ChaseAssist off')
    TH.assert_false(State.movement.returnToCamp, 'waithere: ReturnToCamp off')
    State.session.chaseAssist, State.movement.returnToCamp = origChase, origRTC

    -- /changevarint, mac form: <Section> <Name> <value> (saved; restored after) ----
    local origAssistAt = State.combat.assistAt
    mq.cmd('/changevarint Melee AssistAt 80') ; mq.delay(D)
    TH.assert_eq(State.combat.assistAt, 80, '/changevarint Melee AssistAt 80 -> combat.assistAt')
    mq.cmd(string.format('/changevarint Melee AssistAt %d', origAssistAt)) ; mq.delay(D)
    TH.assert_eq(State.combat.assistAt, origAssistAt, 'AssistAt restored')

    -- /changevarint, short form: <name> <value> (not saved) -----------------------
    local origRadius = State.movement.campRadius
    mq.cmd('/changevarint campRadius 75') ; mq.delay(D)
    TH.assert_eq(State.movement.campRadius, 75, '/changevarint campRadius 75')
    State.movement.campRadius = origRadius

    -- Unknown / unsupported variables -> no crash -----------------------------------
    local ok1 = pcall(function() mq.cmd('/changevarint notARealVar 5') mq.delay(D) end)
    TH.assert_true(ok1, '/changevarint unknown var no crash')
    local ok2 = pcall(function() mq.cmd('/togglevariable notARealVar') mq.delay(D) end)
    TH.assert_true(ok2, '/togglevariable unknown var no crash')
    local ok3 = pcall(function() mq.cmd('/togglevariable DPSMeter on') mq.delay(D) end)
    TH.assert_true(ok3, '/togglevariable unsupported mac var no crash')
end

return M
