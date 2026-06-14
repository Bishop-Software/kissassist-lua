-- tests/unit/test_state.lua
-- Verifies State sub-table existence and default values from state.lua.
-- No mq dependency — runs without mock injection.
local M = {}

function M.run(TH, _MockMQ)
    local State = require('modules.state')

    TH.setSuite('test_state')

    -- Top-level flag
    TH.assert_false(State.terminate, 'terminate defaults false')

    -- session
    TH.assert_eq(State.session.role,           'assist', 'session.role')
    TH.assert_eq(State.session.assistAt,       95,       'session.assistAt')
    TH.assert_eq(State.session.mainAssist,     '',       'session.mainAssist')
    TH.assert_false(State.session.iAmABard,              'session.iAmABard')
    TH.assert_false(State.session.iAmARogue,             'session.iAmARogue')
    TH.assert_false(State.session.iAmMA,                 'session.iAmMA')
    TH.assert_false(State.session.iAmDead,               'session.iAmDead')
    TH.assert_eq(State.session.groupEscapeOn,  0,        'session.groupEscapeOn')  -- M18

    -- combat
    TH.assert_true(State.combat.burnOn,                  'combat.burnOn')
    TH.assert_eq(State.combat.assistAt,        95,       'combat.assistAt')
    TH.assert_eq(State.combat.dpsSkip,         20,       'combat.dpsSkip')
    TH.assert_eq(State.combat.dpsInterval,     2,        'combat.dpsInterval')
    TH.assert_eq(State.combat.meleeDistance,   30,       'combat.meleeDistance')
    TH.assert_false(State.combat.combatStart,            'combat.combatStart')
    TH.assert_eq(State.combat.autoFireOn,      0,        'combat.autoFireOn')       -- M16
    TH.assert_false(State.combat.petTargetSwitch,        'combat.petTargetSwitch')  -- M22
    TH.assert_eq(State.combat.xSlotTotal,      20,       'combat.xSlotTotal')
    TH.assert_false(State.combat.dpsOn,                  'combat.dpsOn')
    TH.assert_false(State.combat.meleeOn,                'combat.meleeOn')

    -- cast
    TH.assert_eq(State.cast.status,            'IDLE',   'cast.status')
    TH.assert_eq(State.cast.gemSlots,          8,        'cast.gemSlots')
    TH.assert_eq(State.cast.miscGem,           0,        'cast.miscGem')
    TH.assert_eq(State.cast.failMax,           3,        'cast.failMax')
    TH.assert_false(State.cast.checkStuckGem,            'cast.checkStuckGem')

    -- pull
    TH.assert_eq(State.pull.chainPull,         0,        'pull.chainPull')
    TH.assert_false(State.pull.hold,                     'pull.hold')
    TH.assert_eq(State.pull.mob,               0,        'pull.mob')
    TH.assert_false(State.pull.pulling,                  'pull.pulling')
    TH.assert_false(State.pull.on,                       'pull.on')

    -- movement
    TH.assert_eq(State.movement.campRadius,    50,       'movement.campRadius')
    TH.assert_eq(State.movement.stickDist,     13,       'movement.stickDist')
    TH.assert_false(State.movement.returnToCamp,         'movement.returnToCamp')
    TH.assert_eq(State.movement.faceMobOn,     0,        'movement.faceMobOn')

    -- heal
    TH.assert_eq(State.heal.healsOn,           0,        'heal.healsOn')
    TH.assert_true(State.heal.medOn,                     'heal.medOn')
    TH.assert_eq(State.heal.medStart,          20,       'heal.medStart')
    TH.assert_eq(State.heal.medStop,           100,      'heal.medStop')
    TH.assert_eq(State.heal.autoRezOn,         0,        'heal.autoRezOn')
    TH.assert_eq(State.heal.corpsRecoveryOn,   0,        'heal.corpsRecoveryOn')  -- M18
    TH.assert_eq(State.heal.groupWatchPct,     20,       'heal.groupWatchPct')

    -- buffs
    TH.assert_false(State.buffs.buffsOn,                 'buffs.buffsOn')
    TH.assert_eq(State.buffs.checkBuffsTimer,  15,       'buffs.checkBuffsTimer')
    TH.assert_eq(State.buffs.blockedBuffsCount, 30,      'buffs.blockedBuffsCount')
    -- slotTimers initialized for slots 1..20, members 0..5
    TH.assert_not_nil(State.buffs.slotTimers[1],         'buffs.slotTimers[1] exists')
    TH.assert_eq(State.buffs.slotTimers[1][0],  0,       'buffs.slotTimers[1][0]=0')
    TH.assert_eq(State.buffs.slotTimers[20][5], 0,       'buffs.slotTimers[20][5]=0')

    -- pet
    TH.assert_false(State.pet.on,                        'pet.on')
    TH.assert_eq(State.pet.assistAt,           100,      'pet.assistAt')
    TH.assert_false(State.pet.combatOn,                  'pet.combatOn')

    -- mez (M12)
    TH.assert_eq(State.mez.on,                 0,        'mez.on')
    TH.assert_eq(State.mez.radius,             40,       'mez.radius')
    TH.assert_eq(State.mez.minLevel,           1,        'mez.minLevel')
    TH.assert_eq(State.mez.maxLevel,           115,      'mez.maxLevel')
    TH.assert_eq(State.mez.stopHPs,            50,       'mez.stopHPs')

    -- bard (M8)
    TH.assert_eq(State.bard.burnMedley,        'burn',   'bard.burnMedley')
    TH.assert_eq(State.bard.meleeMedley,       'melee',  'bard.meleeMedley')
    TH.assert_eq(State.bard.oocMedley,         'ooc',    'bard.oocMedley')
    TH.assert_eq(State.bard.meleeTwistOn,      0,        'bard.meleeTwistOn')

    -- loot
    TH.assert_eq(State.loot.on,                1,        'loot.on')
    TH.assert_eq(State.loot.radius,            100,      'loot.radius')
    TH.assert_eq(State.loot.spamInfo,          1,        'loot.spamInfo')

    -- cond (M11)
    TH.assert_false(State.cond.on,                       'cond.on')
    TH.assert_eq(State.cond.size,              5,        'cond.size')
    TH.assert_type(State.cond.expressions,     'table',  'cond.expressions is table')

    -- debuff (M14)
    TH.assert_eq(State.debuff.on,              0,        'debuff.on')
    TH.assert_eq(State.debuff.count,           0,        'debuff.count')
    TH.assert_type(State.debuff.slots,         'table',  'debuff.slots is table')

    -- afk (M19)
    TH.assert_eq(State.afk.on,                 0,        'afk.on')
    TH.assert_eq(State.afk.gmAction,           1,        'afk.gmAction')
    TH.assert_eq(State.afk.pcRadius,           500,      'afk.pcRadius')

    -- merc (M20)
    TH.assert_eq(State.merc.on,                0,        'merc.on')
    TH.assert_eq(State.merc.assistAt,          100,      'merc.assistAt')
    TH.assert_false(State.merc.inGroup,                  'merc.inGroup')

    -- misc
    TH.assert_false(State.misc.autoHide,                 'misc.autoHide')  -- M21
    TH.assert_true(State.misc.mountOn,                   'misc.mountOn')
    TH.assert_false(State.misc.dmz,                      'misc.dmz')

    -- timers
    TH.assert_eq(State.timers.petFollow,       60,       'timers.petFollow')
    TH.assert_eq(State.timers.addSpam,         0,        'timers.addSpam')
    TH.assert_eq(State.timers.writeBuffs,      0,        'timers.writeBuffs')

    -- arrays
    TH.assert_eq(State.arrays.beforeArray[1],  'null',   'arrays.beforeArray[1]')
    TH.assert_eq(#State.arrays.beforeArray,    5,        'arrays.beforeArray length=5')
    TH.assert_eq(State.arrays.weaveArray[1],   'null',   'arrays.weaveArray[1]')
    TH.assert_eq(State.arrays.weaveArray[50],  'null',   'arrays.weaveArray[50]')
    TH.assert_eq(State.arrays.mezArray[1][1],  'NULL',   'arrays.mezArray[1][1]')
    TH.assert_eq(State.arrays.xTarToHeal[1],   0,        'arrays.xTarToHeal[1]')
end

return M
