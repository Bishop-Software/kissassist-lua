-- tests/unit/test_healing_med.lua
-- DoWeMed (mac:3836): a puller below MedStart meds, and the medding flag that
-- holds pulls clears when a mob gets on us (mac:4042-4053) or MedOn goes off.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_healing_med')

    local RealConfig = require('modules.config')
    package.loaded['modules.config'] = {
        parseCondArray = RealConfig.parseCondArray,
        get = function(_, _, default) return default end,
    }
    package.loaded['modules.healing'] = nil
    local Heal = require('modules.healing')

    MockMQ.set('TLO.Me.Class.ShortName', 'CLR')
    local state = {
        session = { mainAssist = '' },
        combat  = { aggroTargetID = '', xTSlot = 1, xSlotTotal = 20 },
        cast    = { castReturn = '' },
        pet     = { on = false },
        pull    = { pauseHold = false },
        heal = {
            healsArray = {}, groupHealArray = {}, groupHealTimers = {},
            autoRezOn = 0, autoRezArray = {}, curesArray = {},
            singleHealPoint = 0, singleHealPointMA = 0, singleHealPointRange = 0,
        },
    }
    Heal.init(state, { debug = function() end }, {}, {}, {}, {})
    local h = state.heal
    TH.assert_eq(h.medStat, 'Mana', 'cleric meds on mana')

    local mana = 10
    MockMQ.set('TLO.Me.PctMana', function() return mana end)
    MockMQ.set('TLO.Me.Sitting', false)
    MockMQ.set('TLO.Window', function() return { Open = function() return false end } end)

    -- Below MedStart (default 20): start medding and sit.
    Heal.doWeMed()
    TH.assert_true(h.medding, 'below MedStart: medding (pulls held)')
    TH.assert_true(MockMQ.cmdCalled('/sit'), 'below MedStart: sits')

    -- Still under MedStop: stays medding.
    mana = 60
    Heal.doWeMed()
    TH.assert_true(h.medding, 'under MedStop: still medding')

    -- A mob on us with MedCombat off ends the med.
    state.combat.aggroTargetID = '500'
    Heal.doWeMed()
    TH.assert_false(h.medding, 'mob on us: med ends, pulls no longer held')
    state.combat.aggroTargetID = ''

    -- MedOn turned off mid-med clears the flag.
    mana = 10
    Heal.doWeMed()
    TH.assert_true(h.medding, 'medding again')
    h.medOn = false
    Heal.doWeMed()
    TH.assert_false(h.medding, 'MedOn off: med ends')
    h.medOn = true

    -- Reaching MedStop (default 100) ends the med and stands.
    Heal.doWeMed()
    MockMQ.set('TLO.Me.Sitting', true)
    mana = 100
    Heal.doWeMed()
    TH.assert_false(h.medding, 'at MedStop: done medding')
    TH.assert_true(MockMQ.cmdCalled('/stand'), 'at MedStop: stands')

    -- MeddingInterrupted (mac:3875-3955): a mob ends a med at 60%; after the
    -- fight it resumes, though 60% is above MedStart, until MedStop.
    mana = 10
    Heal.doWeMed()
    mana = 60
    state.combat.aggroTargetID = '500'
    Heal.doWeMed()
    TH.assert_false(h.medding, 'interrupted: not medding during the fight')
    TH.assert_true(h.medInterrupted, 'interrupted: remembered')
    state.combat.aggroTargetID = ''
    Heal.doWeMed()
    TH.assert_true(h.medding, 'after the fight: med resumes at 60% (above MedStart)')
    mana = 100
    Heal.doWeMed()
    TH.assert_false(h.medding, 'resumed med ends at MedStop')
    TH.assert_false(h.medInterrupted, 'resumed med done: no longer interrupted')
    mana = 60
    Heal.doWeMed()
    TH.assert_false(h.medding, 'not interrupted: 60% is above MedStart, no med')

    -- Interrupted, but back at MedStop by the end of the fight: nothing to resume.
    mana = 10
    Heal.doWeMed()
    state.combat.aggroTargetID = '500'
    Heal.doWeMed()
    state.combat.aggroTargetID = ''
    mana = 100
    Heal.doWeMed()
    TH.assert_false(h.medding, 'interrupted, already at MedStop: no med')
    TH.assert_false(h.medInterrupted, 'interrupted, already at MedStop: cleared')

    -- Puller HP med (mac:4102-4139): a puller at or below 50% health meds its
    -- HP up to MedStop; other roles don't.
    local hp = 40
    MockMQ.set('TLO.Me.PctHPs', function() return hp end)
    state.movement = { returnToCamp = false, campX = 0, campY = 0 }
    state.session.role = 'assist'
    Heal.doWeMed()
    TH.assert_false(h.medding, 'assist at 40% HP: no HP med')
    state.session.role = 'puller'
    Heal.doWeMed()
    TH.assert_true(h.medding and h.medHP, 'puller at 40% HP: HP med (pulls held)')
    hp = 80
    Heal.doWeMed()
    TH.assert_true(h.medding, 'puller at 80% HP: still medding (MedStop 100)')
    state.combat.aggroTargetID = '500'
    Heal.doWeMed()
    TH.assert_false(h.medding, 'HP med: a mob ends it')
    TH.assert_false(h.medInterrupted, 'HP med interrupted: no mana resume afterwards')
    state.combat.aggroTargetID = ''
    hp = 100
    Heal.doWeMed()
    TH.assert_false(h.medding, 'puller at full HP: no med')

    package.loaded['modules.healing'] = nil
    package.loaded['modules.config']  = nil
end

return M
