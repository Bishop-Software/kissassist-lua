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

    -- DPSOn 2: any HP + wait out the spell cooldown (combat.dpsOnOoc) ------------
    local origDpsOn, origDpsOoc = State.combat.dpsOn, State.combat.dpsOnOoc
    mq.cmd('/togglevariable DPSOn 2') ; mq.delay(D)
    TH.assert_true(State.combat.dpsOn, '/togglevariable DPSOn 2 -> dpsOn')
    TH.assert_true(State.combat.dpsOnOoc, '/togglevariable DPSOn 2 -> dpsOnOoc (mode 2)')
    mq.cmd('/togglevariable DPSOn 1') ; mq.delay(D)
    TH.assert_true(State.combat.dpsOn, '/togglevariable DPSOn 1 -> dpsOn')
    TH.assert_false(State.combat.dpsOnOoc, '/togglevariable DPSOn 1 -> mode 1, dpsOnOoc cleared')
    mq.cmd('/changevarint DPSOn 2') ; mq.delay(D)
    TH.assert_true(State.combat.dpsOnOoc, '/changevarint DPSOn 2 (not saved) -> mode 2')
    mq.cmd('/togglevariable DPSOn off') ; mq.delay(D)
    TH.assert_false(State.combat.dpsOn, '/togglevariable DPSOn off -> dpsOn off')
    TH.assert_false(State.combat.dpsOnOoc, '/togglevariable DPSOn off -> dpsOnOoc cleared')
    State.combat.dpsOn, State.combat.dpsOnOoc = origDpsOn, origDpsOoc

    -- Mac name the port spells differently: PetOn -> pet.on -----------------------
    local origPetOn = State.pet.on
    mq.cmd('/togglevariable PetOn on') ; mq.delay(D)
    TH.assert_true(State.pet.on, '/togglevariable PetOn on -> pet.on')
    State.pet.on = origPetOn

    -- MoveWhenHit (pet.moveWhenHit) is supported now (#334); /movewhenhit is the mac alias
    local origMWH = State.pet.moveWhenHit
    mq.cmd('/togglevariable MoveWhenHit on') ; mq.delay(D)
    TH.assert_true(State.pet.moveWhenHit, '/togglevariable MoveWhenHit on -> pet.moveWhenHit')
    mq.cmd('/movewhenhit off') ; mq.delay(D)
    TH.assert_false(State.pet.moveWhenHit, '/movewhenhit off (alias) -> pet.moveWhenHit off')
    State.pet.moveWhenHit = origMWH

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

    -- /kapause soft pause (#353): on/off/1/0, no argument toggles -----------------
    -- Pausing stops attack/stick/nav and resets combat, so run it out of combat.
    local origPaused = State.session.paused
    mq.cmd('/kapause off') ; mq.delay(D)
    TH.assert_false(State.session.paused, '/kapause off')
    mq.cmd('/kapause on') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kapause on')
    mq.cmd('/kapause on') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kapause on twice stays paused')
    mq.cmd('/kapause') ; mq.delay(D)
    TH.assert_false(State.session.paused, '/kapause (no arg) toggles off')
    mq.cmd('/kapause') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kapause (no arg) toggles on')
    mq.cmd('/kapause 0') ; mq.delay(D)
    TH.assert_false(State.session.paused, '/kapause 0')
    mq.cmd('/kapause 1') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kapause 1')
    -- ${KissAssist} TLO reports it
    TH.assert_eq(mq.parse('${KissAssist.Paused}'), 'TRUE', '${KissAssist.Paused} TRUE while paused')
    TH.assert_eq(mq.parse('${KissAssist.State}'), 'Paused', '${KissAssist.State} Paused')
    mq.cmd('/kapause off') ; mq.delay(D)
    TH.assert_eq(mq.parse('${KissAssist.Paused}'), 'FALSE', '${KissAssist.Paused} FALSE after /kapause off')
    TH.assert_eq(mq.parse('${KissAssist}'), 'Running', '${KissAssist} Running')
    mq.cmd(origPaused and '/kapause on' or '/kapause off') ; mq.delay(D)
end

return M
