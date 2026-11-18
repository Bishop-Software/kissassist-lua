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

    package.loaded['modules.healing'] = nil
    package.loaded['modules.config']  = nil
end

return M
