-- tests/unit/test_afk_camp_on_death.lua
-- #243: CampOnDeath — camp out when not in the camp zone (DoICampA mac:6199,
-- called from AFKTools mac:11668-11671; CampOnDeathTimer 10m set on zoning mac:11125).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_afk_camp_on_death')
    MockMQ.reset()
    local Afk = require('modules.afk')

    local cfg = { CampOnDeath = '1', AFKToolsOn = '0' }
    local config = { get = function(_, key, default) return cfg[key] or default end }
    local state = {
        afk      = {},
        timers   = {},
        session  = { iAmABard = false },
        heal     = { healsOn = 0 },
        combat   = { aggroTargetID = '' },
        movement = { campZone = 100 },
    }
    local comms = { announce = function() end }
    Afk.init(state, {}, {}, comms, config)
    TH.assert_eq(state.afk.campOnDeath, 1, 'CampOnDeath loaded from [AFKTools]')

    local function reset(mode, zone, timerLeft)
        MockMQ.reset()
        MockMQ.set('TLO.Zone.ID', zone)
        state.afk.campOnDeath   = mode
        state.afk.waitingToCamp = false
        state.terminate         = nil
        state.timers.campOnDeath = timerLeft and (os.clock() + timerLeft) or 0
    end

    -- In the camp zone: nothing happens
    reset(2, 100)
    Afk.check()
    TH.assert_false(MockMQ.cmdCalled('/camp desktop'), 'in camp zone: no camp')
    TH.assert_true(state.terminate == nil, 'in camp zone: keeps running')

    -- Off: out of zone, nothing happens
    reset(0, 200)
    Afk.check()
    TH.assert_false(MockMQ.cmdCalled('/camp desktop'), 'CampOnDeath 0: no camp')

    -- Mode 2: camps at once
    reset(2, 200, 600)
    Afk.check()
    TH.assert_true(MockMQ.cmdCalled('/camp desktop'), 'CampOnDeath 2: camps at once')
    TH.assert_true(state.terminate == true, 'CampOnDeath 2: ends kissassist')

    -- Mode 1: waits while the timer runs, without blocking
    reset(1, 200, 600)
    Afk.check()
    TH.assert_false(MockMQ.cmdCalled('/camp desktop'), 'CampOnDeath 1: waits for the timer')
    TH.assert_true(state.afk.waitingToCamp, 'CampOnDeath 1: waiting flag set')
    TH.assert_true(state.terminate == nil, 'CampOnDeath 1: keeps running while waiting')

    -- Back in the camp zone while waiting: aborts
    MockMQ.set('TLO.Zone.ID', 100)
    Afk.check()
    TH.assert_false(state.afk.waitingToCamp, 'back in camp zone: wait aborted')
    TH.assert_false(MockMQ.cmdCalled('/camp desktop'), 'back in camp zone: no camp')

    -- Mode 1: camps once the timer expires
    reset(1, 200, 600)
    Afk.check()
    state.timers.campOnDeath = os.clock() - 1
    Afk.check()
    TH.assert_true(MockMQ.cmdCalled('/camp desktop'), 'CampOnDeath 1: camps when the timer expires')
    TH.assert_true(state.terminate == true, 'CampOnDeath 1: ends kissassist')

    -- Bard stops singing first
    reset(2, 200)
    state.session.iAmABard = true
    Afk.check()
    TH.assert_true(MockMQ.cmdCalled('/medley stop'), 'bard: medley stopped before camping')
    state.session.iAmABard = false

    -- Out of the camp zone, GM/stranger checks are skipped (mac:11668-11671)
    reset(0, 200)
    state.afk.on = 1
    state.afk.gmAction = 2
    MockMQ.set('TLO.SpawnCount', function() return function() return 1 end end)
    Afk.check()
    TH.assert_true(state.terminate == nil, 'out of camp zone: GM check skipped')
    state.afk.on = 0

    -- ── Soft pause (#353): the stranger and GM holds are skipped ──────────────
    local fights = 0
    local combat = { checkForCombat = function() fights = fights + 1 end }
    Afk.init(state, {}, combat, comms, config)
    -- Strangers in camp for the first 2 checks, then gone (so a hold ends)
    local function strangers()
        local n = 0
        return function() n = n + 1; return n <= 2 and 1 or 0 end
    end
    local function strangerSetup(paused)
        reset(0, 100)
        fights = 0
        state.session.paused = paused
        state.afk.on = 2
        MockMQ.set('TLO.Plugin', function() return { IsLoaded = function() return true end } end)
        MockMQ.set('TLO.Posse.Strangers', strangers())
    end

    strangerSetup(false)
    Afk.check()
    TH.assert_true(fights > 0, 'not paused: stranger hold keeps fighting')
    TH.assert_true(MockMQ.cmdCalled('/beep'), 'not paused: stranger hold beeps')

    strangerSetup(true)
    Afk.check()
    TH.assert_eq(fights, 0, 'paused: stranger hold skipped, no fighting')
    TH.assert_false(MockMQ.cmdCalled('/beep'), 'paused: no stranger hold beep')

    -- GM in zone the whole time: hold (action 1) is skipped, end (action 2) still runs
    reset(0, 100)
    state.session.paused = true
    state.afk.on = 3
    state.afk.gmAction = 1
    MockMQ.set('TLO.SpawnCount', function() return function() return 1 end end)
    Afk.check()
    TH.assert_false(MockMQ.cmdCalled('/beep'), 'paused: GM hold skipped (returns, no beep)')
    TH.assert_true(state.terminate == nil, 'paused: GM hold keeps running')
    state.afk.gmAction = 2
    Afk.check()
    TH.assert_true(state.terminate == true, 'paused: GM action 2 still ends kissassist')

    state.session.paused = nil
    state.afk.on = 0
end

return M
