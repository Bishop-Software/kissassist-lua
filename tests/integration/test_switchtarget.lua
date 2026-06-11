-- tests/integration/test_switchtarget.lua
-- Integration tests for the /kaswitchtarget bind.
-- Covers test plan section S76.1.x.
--
-- Run in-game while kissassist is running: /katest switchtarget
local M = {}

local D = 250  -- ms delay after each mq.cmd() to let the deferred bind execute

function M.run(mq, State, TH)
    TH.setSuite('test_switchtarget')

    -- Snapshot originals
    local origMyTargetID    = State.combat.myTargetID
    local origAggroTargetID = State.combat.aggroTargetID

    -- /kaswitchtarget with no in-game target: clears myTargetID + aggroTargetID -----
    State.combat.myTargetID    = 999
    State.combat.aggroTargetID = '999'
    mq.cmd('/cleartarget') ; mq.delay(D)
    mq.cmd('/kaswitchtarget') ; mq.delay(D)

    TH.assert_eq(State.combat.myTargetID, 0,
        '/kaswitchtarget (no target) → myTargetID=0')
    TH.assert_eq(State.combat.aggroTargetID, '',
        '/kaswitchtarget (no target) → aggroTargetID cleared')

    -- /kaswitchtarget with an in-game target: sets aggroTargetID to target ID ------
    local currentTarget = mq.TLO.Target.ID() or 0
    if currentTarget == 0 then
        -- No target available; try targeting self so we can exercise the code path
        mq.cmd('/target ' .. (mq.TLO.Me.CleanName() or '')) ; mq.delay(D)
        currentTarget = mq.TLO.Target.ID() or 0
    end

    if currentTarget ~= 0 then
        State.combat.myTargetID    = 888
        State.combat.aggroTargetID = '0'
        mq.cmd('/kaswitchtarget') ; mq.delay(D)

        TH.assert_eq(State.combat.myTargetID, 0,
            '/kaswitchtarget (with target) → myTargetID=0')
        TH.assert_eq(State.combat.aggroTargetID, tostring(currentTarget),
            '/kaswitchtarget (with target) → aggroTargetID=targetID')
    end

    -- Restore original state
    State.combat.myTargetID    = origMyTargetID
    State.combat.aggroTargetID = origAggroTargetID
end

return M
