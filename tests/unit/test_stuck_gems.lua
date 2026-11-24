-- tests/unit/test_stuck_gems.lua
-- Cast.checkStuckGems (mac CheckStuckGems, mac:16017): when the client thinks it is
-- casting (Me.Casting.ID) with no casting window, fire the Origin AA and /stopcast.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_stuck_gems')
    MockMQ.reset()

    local Utils = require('modules.utils')
    local Cast  = require('modules.cast')
    local state = { cast = {}, session = {}, combat = {}, buffs = {} }
    Cast.init(state, Utils)

    local function callable(v) return function() return v end end

    -- env: casting (Casting.ID), window (CastingWindow open), invis, originReady
    local function setEnv(env)
        MockMQ.reset()
        MockMQ.set('TLO.Me.Casting.ID', env.casting or 0)
        MockMQ.set('TLO.Window', function() return { Open = callable(env.window or false) } end)
        MockMQ.set('TLO.Me.Invis', env.invis or false)
        MockMQ.set('TLO.Me.AltAbilityReady', function() return callable(env.originReady or false) end)
        MockMQ.set('TLO.Me.AltAbility', function() return { ID = callable(331) } end)
        MockMQ.set('TLO.Me.SpellInCooldown', false)
        state.cast.checkStuckGem = env.setting ~= false
        state.session.iAmABard   = env.bard or false
    end

    -- Stuck: casting, no window, Origin ready -> /alt act Origin, then /stopcast.
    setEnv({ casting = 1234, originReady = true })
    TH.assert_true(Cast.checkStuckGems(), 'stuck + Origin ready: returns true')
    TH.assert_true(MockMQ.cmdCalled('/alt act 331'), 'stuck: Origin AA activated')
    TH.assert_true(MockMQ.cmdCalled('/stopcast'), 'stuck: /stopcast sent')

    -- Stuck but Origin not ready: nothing sent.
    setEnv({ casting = 1234, originReady = false })
    TH.assert_false(Cast.checkStuckGems(), 'Origin not ready: returns false')
    TH.assert_eq(#MockMQ.calls(), 0, 'Origin not ready: no commands')

    -- Guards: each leaves things alone.
    local guards = {
        { { casting = 0,    originReady = true },                  'not casting' },
        { { casting = 1234, originReady = true, window = true },   'casting window open (a real cast)' },
        { { casting = 1234, originReady = true, invis = true },    'invisible' },
        { { casting = 1234, originReady = true, bard = true },     'bard (songs always "casting")' },
        { { casting = 1234, originReady = true, setting = false }, 'CheckStuckGem off' },
    }
    for _, g in ipairs(guards) do
        setEnv(g[1])
        TH.assert_false(Cast.checkStuckGems(), 'guard: ' .. g[2] .. ' -> returns false')
        TH.assert_false(MockMQ.cmdCalled('/stopcast'), 'guard: ' .. g[2] .. ' -> no /stopcast')
    end

    MockMQ.reset()
end

return M
