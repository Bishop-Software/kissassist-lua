-- tests/integration/test_switchma.lua
-- Integration tests for the /switchma bind and SWITCHMA comms broadcast.
-- Covers test plan section S22.5.x.
--
-- REQUIRES: kissassist running on a live character.
-- INVOKE via mq_eval (MQ MCP tool) while the bot is running:
--
--   local TH = require('tests.test_helpers')
--   require('tests.integration.test_switchma').run(mq, KAState, TH)
--   TH.printSummary()

local M = {}

function M.run(mq, State, TH)
    TH.setSuite('test_switchma')

    -- Read the current character's name — used to test iAmMA logic.
    local myName = mq.TLO.Me.CleanName() or ''

    -- Snapshot originals
    local origMA      = State.session.mainAssist
    local origIAmMA   = State.session.iAmMA
    local origTargetID = State.combat.calledTargetID

    -- /switchma <name>: basic MA change ------------------------------------
    mq.cmd('/switchma NewTank')
    TH.assert_eq(State.session.mainAssist, 'NewTank',
        '/switchma NewTank → mainAssist=NewTank')
    TH.assert_eq(State.combat.calledTargetID, 0,
        '/switchma → calledTargetID reset to 0')

    -- iAmMA should be false since 'NewTank' != current character name
    -- (unless this character's name happens to be 'NewTank', but that's astronomically unlikely)
    if myName:lower() ~= 'newtank' then
        TH.assert_false(State.session.iAmMA,
            '/switchma NewTank → iAmMA=false (not our name)')
    end

    -- /switchma <myName>: self-as-MA → iAmMA=true -------------------------
    if myName ~= '' then
        mq.cmd('/switchma ' .. myName)
        TH.assert_eq(State.session.mainAssist, myName,
            '/switchma <myName> → mainAssist=myName')
        TH.assert_true(State.session.iAmMA,
            '/switchma <myName> → iAmMA=true')
    end

    -- /switchma with no argument: bind returns early, state unchanged ------
    local maBefore = State.session.mainAssist
    mq.cmd('/switchma')
    TH.assert_eq(State.session.mainAssist, maBefore,
        '/switchma (no arg) → mainAssist unchanged')

    -- /switchma <name> with doWhat=1: suppresses broadcast ----------------
    -- Use the doWhat=1 form to verify state still updates (broadcast skip is observable
    -- only via comms monitoring; here we just confirm the state change fires).
    mq.cmd('/switchma SilentTank tank 1')
    TH.assert_eq(State.session.mainAssist, 'SilentTank',
        '/switchma <name> <role> 1 → mainAssist=SilentTank')

    -- Restore original state
    State.session.mainAssist      = origMA
    State.session.iAmMA           = origIAmMA
    State.combat.calledTargetID   = origTargetID
end

return M
