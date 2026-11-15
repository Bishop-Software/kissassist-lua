-- tests/unit/test_pull_on_return.lua
-- #231: PullOnReturn - after a failed pull, look for another mob on the way
-- back to camp (mac:10609 FindMobOnReturn). Movement.doWeMove does the search
-- and leaves the mob in pull.mob; findMobOnReturn pulls it.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_on_return')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session  = { role = 'hunter', infoFileName = '', zoneName = '' },
        pull     = { mob = 0 },
        timers   = {},
        heal     = { medOn = false },
        combat   = { aggroTargetID = '' },
        pet      = { attackRange = 100 },
        movement = { campX = 0, campY = 0, campRadius = 30, checkOnReturn = false },
    }

    -- doWeMove stub: hands out the next mob from `found` each call.
    local found, moves = {}, {}
    local wired
    local movement = {
        setPull  = function(p) wired = p end,
        doWeMove = function(force)
            moves[#moves + 1] = { force = force, checkOnReturn = state.movement.checkOnReturn }
            state.pull.mob = table.remove(found, 1) or 0
        end,
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end }, nil, movement)
    TH.assert_true(wired == Pull, 'Pull.init hands itself to Movement')

    local pulled = {}
    Pull.pullCheck = function() pulled[#pulled + 1] = state.pull.mob end

    local function run(role, mobs, meDist)
        state.session.role = role
        state.movement.checkOnReturn = false
        found, moves, pulled = mobs, {}, {}
        MockMQ.set('TLO.Me.X', meDist)
        MockMQ.set('TLO.Me.Y', 0)
        Pull.findMobOnReturn()
    end

    run('hunter', {}, 200)
    TH.assert_eq(#moves, 1, 'hunter, nothing found: one move')
    TH.assert_eq(moves[1].force, 1, 'hunter moves with force')
    TH.assert_true(moves[1].checkOnReturn, 'hunter turns on CheckOnReturn before moving')
    TH.assert_eq(#pulled, 0, 'nothing found: no pull')

    run('hunterpettank', { 55, 66 }, 200)
    TH.assert_eq(#pulled, 1, 'hunter pulls one mob then stops')
    TH.assert_eq(pulled[1], 55, 'hunter pulls the mob doWeMove found')

    run('puller', { 55, 66 }, 200)
    TH.assert_eq(moves[1].force, 0, 'puller moves without force')
    TH.assert_false(moves[1].checkOnReturn, 'puller leaves CheckOnReturn to pullCheck')
    TH.assert_eq(#pulled, 2, 'puller keeps pulling until nothing is found')
    TH.assert_eq(#moves, 3, 'puller moves again after each pull')

    run('puller', { 55, 66 }, 10)
    TH.assert_eq(#pulled, 1, 'puller back in camp: stops after one pull')
    TH.assert_eq(state.pull.mob, 0, 'pull.mob cleared on the way out')

    package.loaded['modules.pull'] = nil
end

return M
