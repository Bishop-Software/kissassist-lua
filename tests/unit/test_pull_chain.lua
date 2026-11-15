-- tests/unit/test_pull_chain.lua
-- #257: Pull.chainPullNextMob (the .mac's ChainPullNextMob, mac:15751) - the
-- mid-fight hand-off to the next pull - and chain pulling being puller-only
-- (mac:8841).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_chain')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local named = false
    local state = {
        session  = { role = 'pullertank', infoFileName = '', zoneName = '', mainAssist = 'Tank' },
        pull     = { pullLocY = {}, pullLocX = {}, pullLocZ = {} },
        timers   = {},
        heal     = { medOn = false },
        combat   = { aggroTargetID = '', xTSlot = 1, xTSlot2 = 2, mobCount = 1,
                     myTargetID = 500, attacking = true, combatStart = true },
        pet      = { attackRange = 100 },
        movement = { campX = 0, campY = 0, campRadius = 30 },
        dps      = { paused = false },
    }
    local combat = { isSpawnNamed = function() return named end }
    MockMQ.set('parse:*default*', '0')
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end },
        nil, nil, combat)
    local p = state.pull

    -- Only the puller role chain pulls.
    TH.assert_eq(p.chainPull, 0, 'pullertank: chain pull forced off')

    -- Stub the search: found = next mob ID (0 = none), at nextDist.
    local found, searched = 0, false
    local realFind = Pull.findMobToPull
    Pull.findMobToPull = function(flag)
        searched = true
        TH.assert_eq(flag, 0, 'searches with readyFlag 0')
        p.mob, p.chainPullTemp = found, found
        return found > 0 and 1 or 0
    end

    -- maX: MA distance from camp; tgtHP: current mob HP; xt2: second XTarget mob
    local function setFight(maX, tgtHP, xt2, nextDist, tot, aggro)
        MockMQ.reset()
        searched = false
        MockMQ.set('TLO.Spawn', function(q)
            if q:sub(1, 1) == '=' then
                return setmetatable({ X = function() return maX end, Y = function() return 0 end },
                    { __call = function() return 'ma' end })
            end
            return { Distance = function() return nextDist end }
        end)
        MockMQ.set('TLO.Target.ID', 500)
        MockMQ.set('TLO.Target.PctHPs', tgtHP)
        MockMQ.set('TLO.Me.XTarget', function(n)
            return { ID = function() return n == 2 and xt2 or 500 end }
        end)
        MockMQ.set('TLO.Me.TargetOfTarget.Name', tot or 'Tank')
        MockMQ.set('TLO.Me.CleanName', 'Puller')
        MockMQ.set('TLO.Me.PctAggro', aggro or 10)
        state.combat.myTargetID, state.combat.attacking, state.combat.combatStart = 500, true, true
        p.chainPull, p.mob = 1, 0
    end
    state.session.role = 'puller'
    p.chainPullHP, p.range = 80, 200
    found = 600

    setFight(10, 50, 0, 300)
    TH.assert_eq(Pull.chainPullNextMob(true), 1, 'mob below ChainPullHP, next mob found: go pull')
    TH.assert_eq(p.chainPull, 2, 'chainPull = 2 (just handed off)')
    TH.assert_eq(p.mob, 600, 'next mob left for Phase 9')
    TH.assert_eq(state.combat.myTargetID, 0, 'MyTargetID cleared')
    TH.assert_false(state.combat.combatStart, 'combatStart cleared')
    TH.assert_true(MockMQ.cmdCalled('/squelch /attack off'), 'attack off')

    setFight(10, 90, 0, 300)
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'mob above ChainPullHP: keep fighting')
    TH.assert_false(searched, 'no search above ChainPullHP')
    TH.assert_eq(p.chainPull, 1, 'chainPull unchanged')

    setFight(100, 50, 0, 300)
    TH.assert_eq(Pull.chainPullNextMob(true), 'W', 'MA > 75 from camp: hold, with message')
    TH.assert_eq(Pull.chainPullNextMob(false), 0, 'MA far, message already shown: 0')

    setFight(10, 50, 700, 300)
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'second mob on XTarget: no hand-off')

    state.combat.mobCount = 2
    setFight(10, 50, 0, 300)
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'two mobs in camp: no hand-off')
    state.combat.mobCount = 1

    named = true
    setFight(10, 50, 0, 300)
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'named mob: no hand-off')
    named = false

    setFight(10, 50, 0, 650)
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'next mob beyond pull range + 400: no hand-off')
    TH.assert_eq(p.mob, 0, 'rejected mob cleared')

    setFight(10, 50, 0, 300, 'Puller')
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'mob is on the puller: no hand-off')

    setFight(10, 50, 0, 300, nil, 60)
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'puller aggro >= 50%: no hand-off')

    found = 0
    setFight(10, 50, 0, 300)
    TH.assert_eq(Pull.chainPullNextMob(true), 0, 'nothing to pull: keep fighting')

    Pull.findMobToPull = realFind
    package.loaded['modules.pull'] = nil
end

return M
