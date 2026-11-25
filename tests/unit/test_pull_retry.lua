-- tests/unit/test_pull_retry.lua
-- #351: a pull attempt that doesn't land keeps the puller trying from where it
-- stands (mac:9921) instead of walking back to camp without ignoring the mob;
-- PullWithCast shrinks the pull distance when the mob is out of sight (mac:10299).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_retry')
    MockMQ.reset()
    local Util    = require('modules.pull.util')
    local Execute = require('modules.pull.execute')

    -- ── dispatchDone ────────────────────────────────────────────────────────
    local D = Execute.dispatchDone
    TH.assert_false(D(false, false, ''), 'not pulled, no aggro: keep trying (no walk back)')
    TH.assert_true(D(true, false, ''), 'pulled: done')
    TH.assert_true(D(false, true, ''), 'aggro without the pulled flag: done')
    TH.assert_true(D(false, false, 'btcr'), 'aborted (btcr): done, so finishPull ignores the mob')

    -- ── pullWithCast ────────────────────────────────────────────────────────
    local aggro = 0
    local state = { pull = { pulled = false, withAlt = 'Snare' } }
    local castResult, casts = 'CAST_SUCCESS', 0
    local cast = { castWhat = function() casts = casts + 1; return castResult end }
    Util.init(state, { pullAggroID = function() return aggro end })
    Execute.init(state, { debug = function() end }, cast, nil, nil, {})

    local los = false
    local function setMob()
        MockMQ.set('TLO.Spawn', function()
            return setmetatable({ LineOfSight = function() return los end },
                { __call = function() return true end })
        end)
        MockMQ.set('TLO.Target.ID', 42)
        MockMQ.set('TLO.Me.Moving', false)
    end

    -- Out of sight: no cast, pull distance back to 80%.
    setMob()
    local closer = Execute._pullWithCast(42, 100)
    TH.assert_eq(closer, 80, 'out of sight: pull distance shrinks to 80%')
    TH.assert_eq(casts, 0, 'out of sight: no cast')
    TH.assert_false(state.pull.pulled, 'out of sight: not pulled')

    -- In sight, the cast lands.
    los = true
    closer = Execute._pullWithCast(42, 100)
    TH.assert_nil(closer, 'in sight: no distance change')
    TH.assert_eq(casts, 1, 'in sight: one cast')
    TH.assert_true(state.pull.pulled, 'CAST_SUCCESS: pulled')

    -- In sight, the cast fails without a fizzle (e.g. not ready / cannot see):
    -- not pulled, so dispatch keeps the loop going.
    state.pull.pulled, casts, castResult = false, 0, 'CAST_CANNOTSEE'
    closer = Execute._pullWithCast(42, 100)
    TH.assert_nil(closer, 'failed cast: no distance change')
    TH.assert_false(state.pull.pulled, 'failed cast: not pulled')
    TH.assert_false(Execute.dispatchDone(state.pull.pulled, aggro > 0, ''), 'failed cast: loop tries again')

    -- Fizzles retry up to 5 times inside one attempt.
    castResult, casts = 'CAST_FIZZLE', 0
    Execute._pullWithCast(42, 100)
    TH.assert_eq(casts, 5, 'fizzles: 5 tries in one attempt')

    -- Aggro already on: pulled at once, no cast.
    aggro, casts, state.pull.pulled = 7, 0, false
    Execute._pullWithCast(42, 100)
    TH.assert_true(state.pull.pulled, 'aggro already: pulled')
    TH.assert_eq(casts, 0, 'aggro already: no cast')
end

return M
