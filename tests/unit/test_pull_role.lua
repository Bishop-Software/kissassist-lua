-- tests/unit/test_pull_role.lua
-- #61 part 3: PullRoleToggle (mac:10586 PullModeToggle) - a pullerpettank who
-- leads the group with a merc takes the EQ group Puller role for a pull.
-- Gap 11: a solo puller whose MA is its merc does the same (mac:9692, 10555).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_role')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session  = { role = 'pullerpettank', infoFileName = '', zoneName = '' },
        pull     = {},
        timers   = {},
        heal     = { medOn = false },
        combat   = { aggroTargetID = '' },
        pet      = { attackRange = 100 },
        movement = { campX = 0, campY = 0, campRadius = 30 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local p = state.pull
    TH.assert_false(p.roleToggle, 'PullRoleToggle defaults off')

    -- leader: I lead the group; mercs: mercs in group; puller: current Puller ID
    local function setGroup(leader, mercs, puller, mobDist)
        MockMQ.reset()
        MockMQ.set('TLO.Me.ID', 10)
        MockMQ.set('TLO.Me.CleanName', 'Me')
        MockMQ.set('TLO.Group.Leader.ID', leader and 10 or 20)
        MockMQ.set('TLO.Group.Puller.ID', puller)
        MockMQ.set('TLO.SpawnCount', function(q)
            return function() return q == 'group mercenary' and mercs or 0 end
        end)
        MockMQ.set('TLO.Spawn', function()
            return setmetatable({ X = function() return mobDist end, Y = function() return 0 end },
                { __call = function() return 'mob' end })
        end)
    end

    p.roleToggle = true
    setGroup(true, 1, 0, 200)
    Pull.roleToggle(true, 99)
    TH.assert_true(MockMQ.cmdCalled('/grouproles set Me 3'), 'leader + merc, mob outside camp: take Puller role')

    setGroup(true, 1, 0, 20)
    Pull.roleToggle(true, 99)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'mob inside camp radius: no role change')

    setGroup(true, 1, 10, 200)
    Pull.roleToggle(true, 99)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'already Puller: no change')

    setGroup(false, 1, 0, 200)
    Pull.roleToggle(true, 99)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'not group leader: no change')

    setGroup(true, 0, 0, 200)
    Pull.roleToggle(true, 99)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'no merc in group: no change')

    setGroup(true, 1, 10, 200)
    Pull.roleToggle(false)
    TH.assert_true(MockMQ.cmdCalled('/grouproles unset Me 3'), 'back in camp as Puller: drop the role')

    setGroup(true, 1, 0, 200)
    Pull.roleToggle(false)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'not Puller: nothing to drop')

    state.session.role = 'pullertank'
    setGroup(true, 1, 0, 200)
    Pull.roleToggle(true, 99)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'other puller roles: no change')
    state.session.role = 'pullerpettank'

    p.roleToggle = false
    setGroup(true, 1, 0, 200)
    Pull.roleToggle(true, 99)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'option off: no change')

    -- ── Solo puller with a merc tank (mac:9692, 10555) ──────────────────────
    -- members: Group.Members; maType: the MA spawn's Type; puller: Group.Puller.ID;
    -- mobDist: distance to myTargetID
    local function setMerc(members, maType, puller, mobDist)
        MockMQ.reset()
        MockMQ.set('TLO.Me.ID', 10)
        MockMQ.set('TLO.Me.CleanName', 'Me')
        MockMQ.set('TLO.Group.Members', members)
        MockMQ.set('TLO.Group.Puller.ID', puller)
        MockMQ.set('TLO.Spawn', function(q)
            if q:sub(1, 1) == '=' then return { Type = function() return maType end } end
            return { Distance = function() return mobDist end }
        end)
    end
    state.session.role       = 'puller'
    state.session.mainAssist = 'MercName'
    state.combat.myTargetID  = 99
    state.combat.meleeDistance = 75

    setMerc(1, 'Mercenary', 0, 300)
    Pull.mercPullerRole(true)
    TH.assert_true(MockMQ.cmdCalled('/grouproles set Me 3'), 'merc tank: take Puller role at pull start')

    setMerc(1, 'Mercenary', 10, 300)
    Pull.mercPullerRole(true)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'merc tank: already Puller, no change')

    setMerc(2, 'Mercenary', 0, 300)
    Pull.mercPullerRole(true)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'merc tank: more than one group member, no change')

    setMerc(1, 'PC', 0, 300)
    Pull.mercPullerRole(true)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'MA is not a merc: no change')

    setMerc(1, 'Mercenary', 10, 50)
    Pull.mercPullerRole(false)
    TH.assert_true(MockMQ.cmdCalled('/grouproles unset Me 3'), 'merc tank: mob within MeleeDistance, drop the role')

    setMerc(1, 'Mercenary', 10, 300)
    Pull.mercPullerRole(false)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'merc tank: mob still far, keep the role')

    setMerc(1, 'Mercenary', 0, 50)
    Pull.mercPullerRole(false)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'merc tank: not Puller, nothing to drop')

    state.session.role = 'pullertank'
    setMerc(1, 'Mercenary', 0, 300)
    Pull.mercPullerRole(true)
    TH.assert_false(MockMQ.cmdMatched('grouproles'), 'merc tank: only the puller role')

    package.loaded['modules.pull'] = nil
end

return M
