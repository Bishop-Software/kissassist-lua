-- tests/unit/test_pull_role.lua
-- #61 part 3: PullRoleToggle (mac:10586 PullModeToggle) - a pullerpettank who
-- leads the group with a merc takes the EQ group Puller role for a pull.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_role')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session  = { role = 'pullerpettank', infoFileName = '', zoneName = '' },
        pull     = { pullLocY = {}, pullLocX = {}, pullLocZ = {} },
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
        MockMQ.set('TLO.SpawnCount', function(q) return q == 'group mercenary' and mercs or 0 end)
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

    package.loaded['modules.pull'] = nil
end

return M
