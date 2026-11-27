-- tests/integration/test_switchma.lua
-- Integration tests for the /switchma bind (Roles.switchMA, mac Bind_SwitchMA).
-- Covers test plan section S22.5.x.
--
-- Run in-game while kissassist is running: /kactl test switchma
-- Every command passes the 3rd arg 1 so nothing is broadcast to the group:
-- a broadcast /switchma would change the MA and role on the other boxes too.
local M = {}

local D = 250  -- ms delay after each mq.cmd() — combatReset inside switchMA needs time to finish

function M.run(mq, State, TH)
    TH.setSuite('test_switchma')

    local myName = mq.TLO.Me.CleanName() or ''
    local origRole = State.session.myOriginalRole or State.session.role

    -- Snapshot originals
    local origMA       = State.session.mainAssist
    local origIAmMA    = State.session.iAmMA
    local origTargetID = State.combat.calledTargetID

    -- /switchma <name>: basic MA change ------------------------------------
    mq.cmd('/switchma NewTank tank 1') ; mq.delay(D)
    TH.assert_eq(State.session.mainAssist, 'NewTank',
        '/switchma NewTank → mainAssist=NewTank')
    TH.assert_eq(State.combat.calledTargetID, 0,
        '/switchma → calledTargetID reset to 0')
    TH.assert_eq(State.session.role, origRole,
        '/switchma NewTank → keeps (or returns to) the original role')

    if myName:lower() ~= 'newtank' then
        TH.assert_false(State.session.iAmMA,
            '/switchma NewTank → iAmMA=false (not our name)')
    end

    -- /switchma <myName> tank: self-as-MA → iAmMA=true, role tank ---------
    if myName ~= '' then
        mq.cmd('/switchma ' .. myName .. ' tank 1') ; mq.delay(D)
        TH.assert_eq(State.session.mainAssist, myName,
            '/switchma <myName> → mainAssist=myName')
        TH.assert_true(State.session.iAmMA,
            '/switchma <myName> → iAmMA=true')
        TH.assert_eq(State.session.role, 'tank',
            '/switchma <myName> tank → role=tank')
        TH.assert_eq(State.combat.assistAt, 100,
            '/switchma <myName> tank → assistAt=100 (CheckRoles)')
    end

    -- /switchma with no argument: bind returns early, state unchanged ------
    local maBefore = State.session.mainAssist
    mq.cmd('/switchma') ; mq.delay(D)
    TH.assert_eq(State.session.mainAssist, maBefore,
        '/switchma (no arg) → mainAssist unchanged')

    -- /switchma <name> <role> 1: someone else → back to the original role ---
    mq.cmd('/switchma SilentTank tank 1') ; mq.delay(D)
    TH.assert_eq(State.session.mainAssist, 'SilentTank',
        '/switchma <name> <role> 1 → mainAssist=SilentTank')
    TH.assert_eq(State.session.role, origRole,
        '/switchma <other> → back to the original role')

    -- Restore original MA. The role and its settings were restored by the
    -- last /switchma (someone else → original role + INI baseline).
    State.session.mainAssist    = origMA
    State.session.iAmMA         = origIAmMA
    State.combat.calledTargetID = origTargetID
end

return M
