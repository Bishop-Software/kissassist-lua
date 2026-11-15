-- tests/unit/test_pull_pause.lua
-- #61 part 2: PullPause (mac:8502 DoMiscStuff) - pull X minutes, rest Y
-- minutes - and its '|condN' hold condition (mac PullHoldCond).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_pause')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session = { role = 'pullertank', infoFileName = '', zoneName = '' },
        pull    = { pullLocY = {}, pullLocX = {}, pullLocZ = {} },
        timers  = {},
        heal    = { medOn = false, medding = false },
        combat  = { aggroTargetID = '' },
        pet     = { attackRange = 100 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local p, t = state.pull, state.timers

    -- ---- parsing ----
    TH.assert_eq(p.pauseRun, 0, 'no PullPause in config: off')
    Pull.setPullPause('30|2')
    TH.assert_eq(p.pauseRun, 30, '30|2: pull 30 minutes')
    TH.assert_eq(p.pauseRest, 2, '30|2: rest 2 minutes')
    TH.assert_eq(p.pauseCond, 0, '30|2: no hold condition')
    Pull.setPullPause('30|2|cond12')
    TH.assert_eq(p.pauseCond, 12, '30|2|cond12: hold condition 12')
    Pull.setPullPause('0|0|cond4')
    TH.assert_eq(p.pauseRun, 0, '0|0|cond4: cycle off')
    TH.assert_eq(p.pauseCond, 4, '0|0|cond4: hold condition still used')
    Pull.setPullPause('0')
    TH.assert_eq(p.pauseRun, 0, '0: off')
    Pull.setPullPause('30|0')
    TH.assert_eq(p.pauseRun, 0, 'rest 0: off')
    state.session.role = 'assist'
    Pull.setPullPause('30|2|cond1')
    TH.assert_eq(p.pauseRun, 0, 'non-puller role: cycle off')
    TH.assert_eq(p.pauseCond, 0, 'non-puller role: no hold condition')
    state.session.role = 'pullertank'

    -- ---- cycle ----
    Pull.setPullPause('30|2')
    Pull.pullPauseCheck()
    local now = os.clock()
    TH.assert_false(p.pauseHold, 'first pass: pulling')
    TH.assert_near(t.pullPause1, now + 1800, 1, 'pull window is 30 minutes')
    TH.assert_near(t.pullPause2, now + 120,  1, 'idle restart after 2 minutes')

    Pull.pullPauseActive()
    TH.assert_near(t.pullPause2, os.clock() + 180, 1, 'a pull pushes the idle restart to rest + 1 minute')

    -- Window over: rest starts and the puller sits to med.
    state.heal.medOn = true
    MockMQ.set('TLO.Me.Standing', true)
    t.pullPause1 = 0
    Pull.pullPauseCheck()
    TH.assert_true(p.pauseHold, 'window over: resting')
    TH.assert_near(t.pullPause1, os.clock() + 120, 1, 'rest lasts 2 minutes')
    Pull.pullPauseCheck()
    TH.assert_true(MockMQ.cmdCalled('/sit'), 'resting with MedOn: sits')

    -- Rest over: pulling resumes with a fresh window.
    MockMQ.reset()
    t.pullPause1 = 0
    Pull.pullPauseCheck()
    TH.assert_false(p.pauseHold, 'rest over: pulling again')
    TH.assert_near(t.pullPause1, os.clock() + 1800, 1, 'new 30 minute window')

    -- Idle: no pull for the rest time restarts the window.
    t.pullPause1, t.pullPause2 = os.clock() + 5, 0
    Pull.pullPauseCheck()
    TH.assert_near(t.pullPause1, os.clock() + 1800, 1, 'idle: window restarted')

    -- Manual pull hold: no rest starts.
    p.hold = true
    t.pullPause1 = 0
    Pull.pullPauseCheck()
    TH.assert_false(p.pauseHold, 'manual hold: no rest')
    p.hold = false

    -- Off: nothing happens.
    Pull.setPullPause('0')
    Pull.pullPauseCheck()
    TH.assert_false(p.pauseHold, 'off: never rests')

    -- ---- hold condition ----
    local condResult = true
    local realCond = package.loaded['modules.cond']
    package.loaded['modules.cond'] = { eval = function() return condResult end }
    Pull.setPullPause('0|0|cond3')
    state.cond = { on = true, expressions = { [3] = '${Me.PctHPs}<50' } }
    TH.assert_true(Pull.heldByCond(), 'condition true: pulls held')
    condResult = false
    TH.assert_false(Pull.heldByCond(), 'condition false: pulls run')
    condResult = true
    state.cond.on = false
    TH.assert_false(Pull.heldByCond(), 'conditions off: not held')
    state.cond = { on = true, expressions = {} }
    TH.assert_false(Pull.heldByCond(), 'condition missing: not held')
    package.loaded['modules.cond'] = realCond

    package.loaded['modules.pull'] = nil
end

return M
