-- tests/unit/test_pull_wait.lua
-- PullWait respawn wait (#145): Pull.startPullWait / Pull.pullWaiting replace the
-- old blocking mq.delay with a timer the main loop checks (mac Sub PullDelay).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_wait')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session = { role = 'puller', infoFileName = '', zoneName = '' },
        pull    = { pulling = true, pulled = true },
        timers  = { pullDelay = 0 },
        heal    = { medOn = false },
        combat  = { aggroTargetID = '' },
    }
    local utils = { debug = function() end, zoneIniGet = function() return nil end }
    Pull.init(state, utils)

    -- Not waiting until a wait is started.
    TH.assert_false(Pull.pullWaiting(), 'no wait by default')

    -- Starting a wait: pulling flags cleared, waiting true.
    Pull.startPullWait(30)
    TH.assert_true(Pull.pullWaiting(), 'waiting after startPullWait')
    TH.assert_false(state.pull.pulling, 'startPullWait clears pulling')
    TH.assert_false(state.pull.pulled,  'startPullWait clears pulled')
    TH.assert_true(state.timers.pullDelay > os.clock(), 'pullDelay set in the future')

    -- Expiry ends the wait and resets the timer.
    state.timers.pullDelay = os.clock() - 1
    TH.assert_false(Pull.pullWaiting(), 'expired wait -> not waiting')
    TH.assert_eq(state.timers.pullDelay, 0, 'expired wait resets pullDelay')

    -- Aggro ends the wait early.
    Pull.startPullWait(30)
    state.combat.aggroTargetID = '1234'
    TH.assert_false(Pull.pullWaiting(), 'aggro ends the wait')
    TH.assert_eq(state.timers.pullDelay, 0, 'aggro resets pullDelay')
    state.combat.aggroTargetID = ''

    -- MedOn: sits when standing still and not mounted.
    MockMQ.reset()
    MockMQ.set('TLO.Me.Standing', true)
    MockMQ.set('TLO.Me.Moving', false)
    state.heal.medOn = true
    Pull.startPullWait(30)
    TH.assert_true(MockMQ.cmdCalled('/sit'), 'MedOn: sits for the wait')

    MockMQ.reset()
    MockMQ.set('TLO.Me.Standing', true)
    MockMQ.set('TLO.Me.Moving', false)
    MockMQ.set('TLO.Me.Mount.ID', 55)
    Pull.startPullWait(30)
    TH.assert_false(MockMQ.cmdCalled('/sit'), 'mounted: no sit')

    MockMQ.reset()
    MockMQ.set('TLO.Me.Standing', true)
    MockMQ.set('TLO.Me.Moving', false)
    state.heal.medOn = false
    Pull.startPullWait(30)
    TH.assert_false(MockMQ.cmdCalled('/sit'), 'MedOn off: no sit')

    package.loaded['modules.pull'] = nil
end

return M
