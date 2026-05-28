-- tests/integration/test_debug_cmds.lua
-- Integration tests for /debug, /kisscheck, /zoneinfo binds.
-- Covers test plan section S2.1.x.
--
-- REQUIRES: kissassist running on a live character.
-- INVOKE via mq_eval (MQ MCP tool) while the bot is running:
--
--   local TH = require('tests.test_helpers')
--   require('tests.integration.test_debug_cmds').run(mq, KAState, TH)
--   TH.printSummary()

local M = {}

function M.run(mq, State, TH)
    TH.setSuite('test_debug_cmds')

    -- Snapshot original debug state so we restore it afterward.
    local origGeneral = State.debug.general
    local origCombat  = State.debug.combat
    local origAll     = State.debug.all

    -- /debug on → sets general flag only (asOnOff path; field='general', onoff=true)
    mq.cmd('/debug on')
    TH.assert_true(State.debug.general,  '/debug on → debug.general=true')
    TH.assert_false(State.debug.combat,  '/debug on → debug.combat unchanged (false)')

    -- /debug off → clears general flag
    mq.cmd('/debug off')
    TH.assert_false(State.debug.general, '/debug off → debug.general=false')

    -- /debug combat on → category-specific enable
    mq.cmd('/debug combat on')
    TH.assert_true(State.debug.combat,   '/debug combat on → debug.combat=true')
    TH.assert_false(State.debug.general, '/debug combat on → debug.general unchanged')

    -- /debug combat off → category-specific disable
    mq.cmd('/debug combat off')
    TH.assert_false(State.debug.combat,  '/debug combat off → debug.combat=false')

    -- /debug all on → all non-logging flags set to true
    mq.cmd('/debug all on')
    TH.assert_true(State.debug.all,     '/debug all on → debug.all=true')
    TH.assert_true(State.debug.general, '/debug all on → debug.general=true')
    TH.assert_true(State.debug.combat,  '/debug all on → debug.combat=true')
    TH.assert_true(State.debug.heals,   '/debug all on → debug.heals=true')
    TH.assert_false(State.debug.logging,'/debug all on → debug.logging unchanged')

    -- /debug all off → all non-logging flags cleared
    mq.cmd('/debug all off')
    TH.assert_false(State.debug.all,     '/debug all off → debug.all=false')
    TH.assert_false(State.debug.general, '/debug all off → debug.general=false')
    TH.assert_false(State.debug.combat,  '/debug all off → debug.combat=false')

    -- /kisscheck and /zoneinfo are utility prints with no state side-effects;
    -- verify they don't error (pcall success = command registered and ran).
    local ok1 = pcall(function() mq.cmd('/kisscheck') end)
    TH.assert_true(ok1, '/kisscheck runs without error')

    local ok2 = pcall(function() mq.cmd('/zoneinfo') end)
    TH.assert_true(ok2, '/zoneinfo runs without error')

    -- Restore original state
    State.debug.general = origGeneral
    State.debug.combat  = origCombat
    State.debug.all     = origAll
end

return M
