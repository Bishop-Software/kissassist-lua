-- tests/unit/test_pull_hold.lua
-- Pull.holdReasons(): the Pull tab's "why aren't we pulling" line.
local M = {}

local function has(list, pattern)
    for _, r in ipairs(list) do
        if r:find(pattern) then return true end
    end
    return false
end

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_hold')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session  = { role = 'pullertank', infoFileName = '', zoneName = '' },
        pull     = {},
        timers   = {},
        heal     = { medOn = true, medding = false, medStat = 'Mana', medStop = 100 },
        combat   = { aggroTargetID = '' },
        pet      = { attackRange = 100 },
        movement = { campX = 10, campY = 20 },
        dps      = { paused = false },
        misc     = { dragCorpse = false },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    Pull.setPullPause('0')
    local p, h = state.pull, state.heal
    p.hold, p.pauseHold, p.watchHold = false, false, false

    TH.assert_eq(#Pull.holdReasons(), 0, 'nothing set: free to pull')

    p.hold = true
    TH.assert_true(has(Pull.holdReasons(), 'Pull is switched off'), 'Pull toggle off')
    p.hold = false

    MockMQ.set('TLO.Me.PctMana', 34)
    h.medding = true
    local r = Pull.holdReasons()
    TH.assert_eq(#r, 1, 'medding: one reason')
    TH.assert_true(has(r, 'medding %(Mana 34%% %-> 100%%%)'), 'medding shows stat and levels')
    h.medding = false

    h.gwWatchID, h.gwWatchName, h.gwWatchStat = 11, 'Cleric', 'Mana'
    MockMQ.set('TLO.Spawn', function()
        return { CurrentMana = function() return 18 end, CurrentEndurance = function() return 100 end }
    end)
    p.watchHold = true
    r = Pull.holdReasons()
    TH.assert_true(has(r, 'waiting for Cleric to med %(Mana 18%% %-> 90%%%)'), 'Group Watch member wait')
    TH.assert_eq(#r, 1, 'member wait is not also reported as the chain-pull hold')
    h.gwWatchID = 0

    TH.assert_true(has(Pull.holdReasons(), 'dead group member or mobs close'), 'watchHold alone: chain-pull hold')
    h.gwWaitMA = true
    r = Pull.holdReasons()
    TH.assert_true(has(r, 'main assist not found'), 'main assist missing')
    TH.assert_eq(#r, 1, 'MA wait is not also reported as the chain-pull hold')
    h.gwWaitMA = false
    h.gwCondWait, h.groupWatchCond = true, 3
    TH.assert_true(has(Pull.holdReasons(), 'Group Watch condition 3'), 'Group Watch condition')
    h.gwCondWait, p.watchHold = false, false

    p.pauseHold = true
    TH.assert_true(has(Pull.holdReasons(), 'Pull Pause rest'), 'PullPause rest')
    p.pauseHold = false

    state.misc.dragCorpse = true
    TH.assert_true(has(Pull.holdReasons(), 'dragging a corpse'), 'dragging a corpse')
    state.misc.dragCorpse = false

    state.timers.pullDelay = os.clock() + 60
    TH.assert_true(has(Pull.holdReasons(), 'waiting for respawns'), 'PullWait respawn wait')
    state.timers.pullDelay = 0

    state.movement.campX, state.movement.campY = 0, 0
    TH.assert_true(has(Pull.holdReasons(), 'no camp set'), 'no camp')
    state.movement.campX, state.movement.campY = 10, 20

    state.session.role = 'assist'
    TH.assert_true(has(Pull.holdReasons(), 'assist role does not pull'), 'non-puller role')
    state.session.role = 'pullertank'

    -- Several at once are all listed.
    p.hold, h.medding = true, true
    TH.assert_eq(#Pull.holdReasons(), 2, 'two holds: two reasons')
    p.hold, h.medding = false, false
end

return M
