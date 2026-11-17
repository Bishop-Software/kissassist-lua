-- tests/unit/test_groupwatch.lua
-- GroupWatch (mac:10633) / CheckStats (mac:10703): hold pulls while a group
-- member meds, pause while the main assist is missing, GroupWatchCheck cond.
local M = {}

-- A fake group member / spawn: every field is a callable like the real TLO.
local function member(id, name, cls, mana, endu, typ)
    local m = { mana = mana, endu = endu }
    m.ID               = function() return id end
    m.CleanName        = function() return name end
    m.Type             = function() return typ or 'PC' end
    m.OtherZone        = function() return false end
    m.CurrentMana      = function() return m.mana end
    m.CurrentEndurance = function() return m.endu end
    m.Class            = { ShortName = function() return cls end }
    return m
end

function M.run(TH, MockMQ)
    TH.setSuite('test_groupwatch')
    MockMQ.reset()
    local GroupWatch = require('modules.groupwatch')

    local announced = {}
    local comms = { announce = function(msg) announced[#announced + 1] = msg end }
    local radarCount = 0
    local state
    local combat = { mobRadar = function() state.combat.mobCount = radarCount end }
    local condResult = false
    local cond = { eval = function() return condResult end }

    state = {
        session  = { role = 'assist', mainAssist = 'Tank' },
        movement = { campZone = 1 },
        pull     = { chainPull = 0, pauseRun = 0 },
        timers   = {},
        heal     = { medding = false, medCombat = false },
        combat   = { aggroTargetID = '', mobCount = 0, meleeDistance = 75 },
        cond     = { on = false, expressions = {} },
    }
    GroupWatch.init(state, { debug = function() end }, cond, comms, combat)
    local h, p = state.heal, state.pull

    -- ---- config parsing (mac:14569-14587) ----
    TH.assert_eq(h.groupWatchOn, 0, 'no GroupWatchOn in config: off')
    GroupWatch.setConfig('1', 'FALSE')
    TH.assert_eq(h.groupWatchOn, 1, '1: on')
    TH.assert_eq(h.groupWatchPct, 20, '1: default 20%')
    GroupWatch.setConfig('2|35', 'cond7')
    TH.assert_eq(h.groupWatchOn, 2, '2|35: healers only')
    TH.assert_eq(h.groupWatchPct, 35, '2|35: 35%')
    TH.assert_eq(h.groupWatchCond, 7, 'cond7: condition 7')
    GroupWatch.setConfig('1|20', 'FALSE')
    TH.assert_eq(h.groupWatchCond, 0, 'FALSE: no condition')

    -- ---- /changevarint values ----
    TH.assert_true(GroupWatch.isVar('GroupWatchOn'), 'GroupWatchOn handled here')
    TH.assert_true(GroupWatch.isVar('groupwatchcheck'), 'names are case-insensitive')
    TH.assert_false(GroupWatch.isVar('MedOn'), 'other names are not')
    TH.assert_eq(GroupWatch.setVar('GroupWatchOn', '2|30'), '2|30', 'on|pct sets both')
    TH.assert_eq(h.groupWatchPct, 30, 'on|pct: percent updated live')
    TH.assert_eq(GroupWatch.setVar('GroupWatchOn', '1'), '1|30', 'on alone keeps the percent')
    TH.assert_eq(GroupWatch.setVar('GroupWatchOn', 'off'), '0|30', 'off')
    TH.assert_eq(GroupWatch.setVar('GroupWatchOn', '3'), nil, 'out of range rejected')
    TH.assert_eq(GroupWatch.setVar('GroupWatchOn', 'x|20'), nil, 'junk rejected')
    TH.assert_eq(GroupWatch.setVar('GroupWatchPct', '150'), '100', 'percent clamped')
    TH.assert_eq(GroupWatch.setVar('GroupWatchCheck', 'cond4'), 'cond4', 'condN')
    TH.assert_eq(h.groupWatchCond, 4, 'condN: condition 4')
    TH.assert_eq(GroupWatch.setVar('GroupWatchCheck', 'FALSE'), 'FALSE', 'FALSE clears it')
    TH.assert_eq(h.groupWatchCond, 0, 'FALSE: no condition')
    GroupWatch.setConfig('1|20', 'FALSE')

    -- World: MA present, in camp zone, one cleric and one warrior.
    local members = {}
    local spawns  = {}
    MockMQ.set('TLO.Zone.ID', 1)
    MockMQ.set('TLO.Group.Member', function(i) return members[i] end)
    MockMQ.set('TLO.Spawn', function(q)
        return spawns[q] or member(0, '', '', nil, nil)
    end)
    MockMQ.set('TLO.Me.Standing', true)
    local clr = member(11, 'Cleric', 'CLR', 80, 100)
    local war = member(12, 'Warrior', 'WAR', 0, 80)
    members[1], members[2] = clr, war
    spawns['=Tank'] = member(99, 'Tank', 'WAR', 0, 100)
    spawns['id 11'] = clr
    spawns['id 12'] = war

    -- ---- nobody low: no hold ----
    TH.assert_false(GroupWatch.check(), 'all fine: not paused')
    TH.assert_false(p.watchHold, 'all fine: pulls not held')

    -- ---- a low cleric holds pulls until 90% ----
    clr.mana = 15
    GroupWatch.check()
    TH.assert_true(p.watchHold, 'cleric at 15% mana: pulls held')
    TH.assert_eq(h.gwWatchID, 11, 'waiting on the cleric')
    TH.assert_eq(h.gwWatchStat, 'Mana', 'casters are watched on mana')
    TH.assert_true(MockMQ.cmdCalled('/target id 11'), 'targets the member to refresh stats')
    TH.assert_true(MockMQ.cmdCalled('/sit'), 'sits to med while waiting')

    clr.mana = 60
    GroupWatch.check()
    TH.assert_true(p.watchHold, 'cleric at 60%: still held')

    MockMQ.set('TLO.Me.Sitting', true)
    state.pull.pauseRun = 30
    clr.mana = 90
    GroupWatch.check()
    TH.assert_false(p.watchHold, 'cleric at 90%: pulls resume')
    TH.assert_eq(h.gwWatchID, 0, 'wait over')
    TH.assert_true(MockMQ.cmdCalled('/stand'), 'stands when the wait ends')
    TH.assert_near(state.timers.pullPause1, os.clock() + 1800, 1, 'PullPause window restarts (mac:10755)')
    state.pull.pauseRun = 0
    MockMQ.set('TLO.Me.Sitting', false)

    -- ---- warriors are watched on endurance; at exactly the percent counts ----
    war.endu = 20
    GroupWatch.check()
    TH.assert_eq(h.gwWatchStat, 'Endurance', 'warrior at 20% endurance: watched')
    -- Member leaves the zone: wait ends.
    spawns['id 12'] = nil
    GroupWatch.check()
    TH.assert_eq(h.gwWatchID, 0, 'member gone: wait ends')
    TH.assert_false(p.watchHold, 'member gone: pulls resume')
    spawns['id 12'] = war
    war.endu = 100

    -- ---- GroupWatchOn=2 ignores non-healers ----
    h.groupWatchOn = 2
    war.endu = 5
    GroupWatch.check()
    TH.assert_false(p.watchHold, 'healers only: low warrior ignored')
    war.endu = 100
    h.groupWatchOn = 1

    -- ---- hybrids are checked on both stats ----
    local shd = member(13, 'Knight', 'SHD', 100, 10)
    members[3] = shd
    spawns['id 13'] = shd
    GroupWatch.check()
    TH.assert_eq(h.gwWatchID, 13, 'SHD low on endurance: watched')
    TH.assert_eq(h.gwWatchStat, 'Endurance', 'SHD watched on endurance')
    shd.endu = 100
    GroupWatch.check()
    members[3] = nil

    -- ---- aggro without chain pulling: no new wait ----
    state.combat.aggroTargetID = '500'
    clr.mana = 10
    GroupWatch.check()
    TH.assert_eq(h.gwWatchID, 0, 'in combat: no wait started (mac:10635)')
    state.combat.aggroTargetID = ''
    clr.mana = 100

    -- ---- chain-pulling puller with mobs close: hold, no wait ----
    state.session.role = 'puller'
    p.chainPull = 1
    radarCount = 2
    clr.mana = 10
    GroupWatch.check()
    TH.assert_true(p.watchHold, 'chain puller with mobs near: pulls held')
    TH.assert_eq(h.gwWatchID, 0, 'chain puller with mobs near: no med wait')
    TH.assert_eq(#announced, 0, 'nothing announced yet')
    radarCount = 0
    GroupWatch.check()
    TH.assert_eq(h.gwWatchID, 11, 'chain puller, no mobs near: waits')
    TH.assert_true(#announced > 0, 'puller roles announce the wait to the group')
    clr.mana = 100
    GroupWatch.check()

    -- A dead member stops chain pulling.
    members[2] = member(12, 'Warrior', 'WAR', 0, 0, 'Corpse')
    GroupWatch.check()
    TH.assert_true(p.watchHold, 'chain pulling with a corpse in group: held')
    members[2] = war
    GroupWatch.check()
    TH.assert_false(p.watchHold, 'corpse gone: released')
    p.chainPull = 0
    state.session.role = 'assist'

    -- ---- main assist missing: pause ----
    spawns['=Tank'] = nil
    TH.assert_true(GroupWatch.check(), 'MA missing: paused')
    TH.assert_true(p.watchHold, 'MA missing: pulls held')
    state.combat.aggroTargetID = '500'
    TH.assert_true(GroupWatch.check(), 'MA missing: stays paused through combat')
    state.combat.aggroTargetID = ''
    spawns['=Tank'] = member(99, 'Tank', 'WAR', 0, 100)
    TH.assert_false(GroupWatch.check(), 'MA back: resumes')
    TH.assert_false(h.gwWaitMA, 'MA back: wait cleared')
    -- Tank roles never wait for an MA.
    state.session.role = 'tank'
    spawns['=Tank'] = nil
    TH.assert_false(GroupWatch.check(), 'tank role: no MA pause')
    -- Out of the camp zone: no MA pause.
    state.session.role = 'assist'
    MockMQ.set('TLO.Zone.ID', 2)
    TH.assert_false(GroupWatch.check(), 'outside camp zone: no MA pause')
    MockMQ.set('TLO.Zone.ID', 1)
    spawns['=Tank'] = member(99, 'Tank', 'WAR', 0, 100)

    -- ---- GroupWatchCheck condition ----
    h.groupWatchCond = 3
    condResult = true
    GroupWatch.check()
    TH.assert_false(p.watchHold, 'conditions off: condition ignored')
    state.cond.on = true
    state.cond.expressions[3] = '${Me.PctHPs}<50'
    GroupWatch.check()
    TH.assert_true(p.watchHold, 'condition true: pulls held')
    state.combat.aggroTargetID = '500'
    p.chainPull = 1
    GroupWatch.check()
    TH.assert_false(p.watchHold, 'condition true but mob on us and MedCombat off: released')
    p.chainPull = 0
    state.combat.aggroTargetID = ''
    condResult = false
    GroupWatch.check()
    TH.assert_false(p.watchHold, 'condition false: released')

    -- ---- turning it off clears any wait ----
    clr.mana = 10
    GroupWatch.check()
    TH.assert_true(p.watchHold, 'held before turning off')
    h.groupWatchOn = 0
    GroupWatch.check()
    TH.assert_false(p.watchHold, 'GroupWatchOn 0: hold cleared')
    TH.assert_eq(h.gwWatchID, 0, 'GroupWatchOn 0: wait cleared')
end

return M
