-- tests/integration/test_debug_cmds.lua
-- Integration tests for /debug, /kisscheck, /zoneinfo binds.
-- Covers test plan section S2.1.x.
--
-- Run in-game while kissassist is running: /katest debug_cmds
local M = {}

local D = 50  -- ms delay after each mq.cmd() to let the deferred bind execute

function M.run(mq, State, TH)
    TH.setSuite('test_debug_cmds')

    -- Snapshot original debug state so we restore it afterward.
    local origGeneral = State.debug.general
    local origCombat  = State.debug.combat
    local origAll     = State.debug.all

    -- /debug on → sets general flag only (asOnOff path; field='general', onoff=true)
    mq.cmd('/debug on') ; mq.delay(D)
    TH.assert_true(State.debug.general,  '/debug on → debug.general=true')
    TH.assert_false(State.debug.combat,  '/debug on → debug.combat unchanged (false)')

    -- /debug off → clears general flag
    mq.cmd('/debug off') ; mq.delay(D)
    TH.assert_false(State.debug.general, '/debug off → debug.general=false')

    -- /debug combat on → category-specific enable
    mq.cmd('/debug combat on') ; mq.delay(D)
    TH.assert_true(State.debug.combat,   '/debug combat on → debug.combat=true')
    TH.assert_false(State.debug.general, '/debug combat on → debug.general unchanged')

    -- /debug combat off → category-specific disable
    mq.cmd('/debug combat off') ; mq.delay(D)
    TH.assert_false(State.debug.combat,  '/debug combat off → debug.combat=false')

    -- /debug all on → all non-logging flags set to true
    mq.cmd('/debug all on') ; mq.delay(D)
    TH.assert_true(State.debug.all,      '/debug all on → debug.all=true')
    TH.assert_true(State.debug.general,  '/debug all on → debug.general=true')
    TH.assert_true(State.debug.combat,   '/debug all on → debug.combat=true')
    TH.assert_true(State.debug.heals,    '/debug all on → debug.heals=true')
    TH.assert_false(State.debug.logging, '/debug all on → debug.logging unchanged')

    -- /debug all off → all non-logging flags cleared
    mq.cmd('/debug all off') ; mq.delay(D)
    TH.assert_false(State.debug.all,     '/debug all off → debug.all=false')
    TH.assert_false(State.debug.general, '/debug all off → debug.general=false')
    TH.assert_false(State.debug.combat,  '/debug all off → debug.combat=false')

    -- /kisscheck and /zoneinfo are utility prints — verify no crash
    local ok1 = pcall(function() mq.cmd('/kisscheck') mq.delay(D) end)
    TH.assert_true(ok1, '/kisscheck runs without error')

    local ok2 = pcall(function() mq.cmd('/zoneinfo') mq.delay(D) end)
    TH.assert_true(ok2, '/zoneinfo runs without error')

    -- Restore original state
    State.debug.general = origGeneral
    State.debug.combat  = origCombat
    State.debug.all     = origAll
end

return M
