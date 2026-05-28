-- tests/unit/test_utils.lua
-- Tests Utils.timerExpired, Utils.setTimer, Utils.setFlag, Utils.setAll.
-- No mq dependency — runs without mock injection.
local M = {}

function M.run(TH, _MockMQ)
    local Utils = require('modules.utils')

    TH.setSuite('test_utils')

    -- timerExpired: 0 is always in the past
    TH.assert_true(Utils.timerExpired(0), 'timerExpired(0) is true')

    -- timerExpired: far future is not expired
    TH.assert_false(Utils.timerExpired(os.clock() + 1000), 'timerExpired(future) is false')

    -- setTimer(0): result is immediately expired
    local t0 = Utils.setTimer(0)
    TH.assert_true(Utils.timerExpired(t0), 'setTimer(0) immediately expired')

    -- setTimer(60): not yet expired
    local t60 = Utils.setTimer(60)
    TH.assert_false(Utils.timerExpired(t60), 'setTimer(60) not yet expired')

    -- setTimer(60): result is approximately os.clock() + 60
    TH.assert_near(t60 - os.clock(), 60, 0.1, 'setTimer(60) ≈ os.clock()+60')

    -- setTimer(300): large duration also not expired
    local t300 = Utils.setTimer(300)
    TH.assert_false(Utils.timerExpired(t300), 'setTimer(300) not yet expired')

    -- setFlag / setAll: wire to a test state so we don't pollute any live State
    local testState = { debug = {
        general   = false, all       = false,
        buffs     = false, cast      = false,
        chainpull = false, combat    = false,
        heals     = false, logging   = false,
        mez       = false, move      = false,
        pet       = false, pull      = false,
        rk        = false, time      = false,
    }}
    Utils.init(testState)

    TH.assert_false(testState.debug.combat, 'flag combat starts false')
    Utils.setFlag('combat', true)
    TH.assert_true(testState.debug.combat,  'setFlag combat → true')
    Utils.setFlag('combat', false)
    TH.assert_false(testState.debug.combat, 'setFlag combat → false')

    Utils.setAll(true)
    TH.assert_true(testState.debug.combat, 'setAll(true) → combat')
    TH.assert_true(testState.debug.heals,  'setAll(true) → heals')
    TH.assert_true(testState.debug.pull,   'setAll(true) → pull')

    Utils.setAll(false)
    TH.assert_false(testState.debug.combat, 'setAll(false) → combat')
    TH.assert_false(testState.debug.pull,   'setAll(false) → pull')

    -- setFlag with unknown key is silently ignored (guard on nil check)
    local ok = pcall(function() Utils.setFlag('notakey', true) end)
    TH.assert_true(ok, 'setFlag unknown key no error')
end

return M
