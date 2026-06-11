-- tests/integration/test_switchma.lua
-- Integration tests for the /switchma bind.
-- Covers test plan section S22.5.x.
--
-- Run in-game while kissassist is running: /katest switchma
local M = {}

local D = 250  -- ms delay after each mq.cmd() — combatReset inside onSwitchMA needs time to finish

function M.run(mq, State, TH)
    TH.setSuite('test_switchma')

    local myName = mq.TLO.Me.CleanName() or ''

    -- Snapshot originals
    local origMA       = State.session.mainAssist
    local origIAmMA    = State.session.iAmMA
    local origTargetID = State.combat.calledTargetID

    -- /switchma <name>: basic MA change ------------------------------------
    mq.cmd('/switchma NewTank') ; mq.delay(D)
    TH.assert_eq(State.session.mainAssist, 'NewTank',
        '/switchma NewTank → mainAssist=NewTank')
    TH.assert_eq(State.combat.calledTargetID, 0,
        '/switchma → calledTargetID reset to 0')

    if myName:lower() ~= 'newtank' then
        TH.assert_false(State.session.iAmMA,
            '/switchma NewTank → iAmMA=false (not our name)')
    end

    -- /switchma <myName>: self-as-MA → iAmMA=true -------------------------
    if myName ~= '' then
        mq.cmd('/switchma ' .. myName) ; mq.delay(D)
        TH.assert_eq(State.session.mainAssist, myName,
            '/switchma <myName> → mainAssist=myName')
        TH.assert_true(State.session.iAmMA,
            '/switchma <myName> → iAmMA=true')
    end

    -- /switchma with no argument: bind returns early, state unchanged ------
    local maBefore = State.session.mainAssist
    mq.cmd('/switchma') ; mq.delay(D)
    TH.assert_eq(State.session.mainAssist, maBefore,
        '/switchma (no arg) → mainAssist unchanged')

    -- /switchma <name> <role> 1: state updates even when broadcast skipped -
    mq.cmd('/switchma SilentTank tank 1') ; mq.delay(D)
    TH.assert_eq(State.session.mainAssist, 'SilentTank',
        '/switchma <name> <role> 1 → mainAssist=SilentTank')

    -- Restore original state
    State.session.mainAssist    = origMA
    State.session.iAmMA         = origIAmMA
    State.combat.calledTargetID = origTargetID
end

return M
