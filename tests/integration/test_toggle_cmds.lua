-- tests/integration/test_toggle_cmds.lua
-- Integration tests for /togglevariable and /changevarint binds.
-- Both take the mac's variable names and value rules (mac:8371, 11237):
-- on/1 = on, off/0/no value = off, a number is used as is.
--
-- Run in-game while kissassist is running: /kactl test toggle_cmds
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

    -- /kactl pause (#353, was /kapause): on/off/toggle; anything else rejected ----
    -- Pausing stops attack/stick/nav and resets combat, so run it out of combat.
    local origPaused = State.session.paused
    mq.cmd('/kactl pause off') ; mq.delay(D)
    TH.assert_false(State.session.paused, '/kactl pause off')
    mq.cmd('/kactl pause on') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kactl pause on')
    mq.cmd('/kactl pause on') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kactl pause on twice stays paused')
    mq.cmd('/kactl pause toggle') ; mq.delay(D)
    TH.assert_false(State.session.paused, '/kactl pause toggle → off')
    mq.cmd('/kactl pause toggle') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kactl pause toggle → on')
    mq.cmd('/kactl pause') ; mq.delay(D)
    TH.assert_true(State.session.paused, '/kactl pause (no argument) → rejected, unchanged')
    TH.assert_true((mq.TLO.KissAssist.LastResult() or ''):find('^error:') ~= nil,
        '${KissAssist.LastResult} error: after /kactl pause with no argument')
    -- ${KissAssist} TLO reports it
    TH.assert_eq(mq.parse('${KissAssist.Paused}'), 'TRUE', '${KissAssist.Paused} TRUE while paused')
    TH.assert_eq(mq.parse('${KissAssist.State}'), 'Paused', '${KissAssist.State} Paused')
    mq.cmd('/kactl pause off') ; mq.delay(D)
    TH.assert_eq(mq.parse('${KissAssist.Paused}'), 'FALSE', '${KissAssist.Paused} FALSE after /kactl pause off')
    TH.assert_eq(mq.parse('${KissAssist}'), 'Running', '${KissAssist} Running')
    TH.assert_eq(mq.TLO.KissAssist.LastResult(), 'ok', '${KissAssist.LastResult} ok')

    -- /kactl set (#363): explicit values, toggle -------------------------------------
    local origMelee = State.combat.meleeOn
    mq.cmd('/kactl set MeleeOn off') ; mq.delay(D)
    TH.assert_false(State.combat.meleeOn, '/kactl set MeleeOn off')
    mq.cmd('/kactl set MeleeOn toggle') ; mq.delay(D)
    TH.assert_true(State.combat.meleeOn, '/kactl set MeleeOn toggle → on')
    mq.cmd('/kactl set MeleeOn') ; mq.delay(D)
    TH.assert_true(State.combat.meleeOn, '/kactl set MeleeOn (no value) → rejected, unchanged')
    State.combat.meleeOn = origMelee

    -- /kactl replacements for the mac's commands (#363, 3b) -----------------------
    -- /backoff stops the fight and resets combat, so run it out of combat.
    local origBackoff = State.dps.paused
    mq.cmd('/kactl backoff on') ; mq.delay(D)
    TH.assert_true(State.dps.paused, '/kactl backoff on')
    mq.cmd('/kactl backoff off') ; mq.delay(D)
    TH.assert_false(State.dps.paused, '/kactl backoff off')
    State.dps.paused = origBackoff

    local origDebug = State.debug.combat
    mq.cmd('/kactl debug combat on') ; mq.delay(D)
    TH.assert_true(State.debug.combat, '/kactl debug combat on')
    mq.cmd('/kactl debug combat off') ; mq.delay(D)
    TH.assert_false(State.debug.combat, '/kactl debug combat off')
    State.debug.combat = origDebug

    local origIgnore = State.pull.mobsToIgnoreByID
    mq.cmd('/kactl ignore clear') ; mq.delay(D)
    TH.assert_eq(State.pull.mobsToIgnoreByID, 'null', '/kactl ignore clear')
    State.pull.mobsToIgnoreByID = origIgnore

    TH.assert_eq(type(State.session.legacyCmdNotice), 'boolean', 'LegacyCmdNotice loaded')
    mq.cmd(origPaused and '/kactl pause on' or '/kactl pause off') ; mq.delay(D)
end

return M
