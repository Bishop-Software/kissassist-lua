-- tests/integration/test_switchtarget.lua
-- Integration tests for /kactl target (was /kaswitchtarget, #363; forced target #364).
-- Covers test plan section S76.1.x.
--
-- Run in-game while kissassist is running: /kactl test switchtarget
local M = {}

local D = 250  -- ms delay after each mq.cmd() to let the deferred bind execute

function M.run(mq, State, TH)
    TH.setSuite('test_switchtarget')

    -- Snapshot originals
    local origMyTargetID    = State.combat.myTargetID
    local origAggroTargetID = State.combat.aggroTargetID

    -- /kactl target clear: clears myTargetID + aggroTargetID ------------------------
    State.combat.myTargetID    = 999
    State.combat.aggroTargetID = '999'
    mq.cmd('/kactl target clear') ; mq.delay(D)

    TH.assert_eq(State.combat.myTargetID, 0,      '/kactl target clear → myTargetID=0')
    TH.assert_eq(State.combat.aggroTargetID, '',  '/kactl target clear → aggroTargetID cleared')
    TH.assert_eq(mq.TLO.KissAssist.LastResult(), 'ok', '${KissAssist.LastResult} ok')

    -- /kactl target <id>: on an NPC (the nearest, if any) sets aggroTargetID and
    -- the forced target (#364); cleared again before the main loop can engage it.
    local origForced = State.combat.forcedTargetID
    local npcID = mq.TLO.NearestSpawn('npc').ID() or 0
    if npcID ~= 0 then
        State.combat.myTargetID    = 777
        State.combat.aggroTargetID = '0'
        mq.cmd('/kactl target ' .. npcID) ; mq.delay(D)

        TH.assert_eq(State.combat.myTargetID, 0,                 '/kactl target <npc id> → myTargetID=0')
        TH.assert_eq(State.combat.aggroTargetID, tostring(npcID), '/kactl target <npc id> → aggroTargetID=supplied id')
        TH.assert_eq(State.combat.forcedTargetID, npcID,          '/kactl target <npc id> → forced target set')
        mq.cmd('/kactl target clear') ; mq.delay(D)
    end

    -- A PC (myself) is refused (#364): nothing changes
    local myID = mq.TLO.Me.ID() or 0
    if myID ~= 0 then
        State.combat.myTargetID    = 777
        State.combat.aggroTargetID = '0'
        mq.cmd('/kactl target ' .. myID) ; mq.delay(D)

        TH.assert_eq(State.combat.myTargetID, 777,  '/kactl target <myself> → refused, myTargetID unchanged')
        TH.assert_eq(State.combat.aggroTargetID, '0', '/kactl target <myself> → refused, aggroTargetID unchanged')
    end

    -- No such spawn, or no argument: nothing changes, LastResult says why ------------
    State.combat.aggroTargetID = '555'
    mq.cmd('/kactl target 999999999') ; mq.delay(D)
    TH.assert_eq(State.combat.aggroTargetID, '555', '/kactl target <bad id> → nothing changed')
    TH.assert_true((mq.TLO.KissAssist.LastResult() or ''):find('^error:') ~= nil,
        '${KissAssist.LastResult} error: after a bad id')
    mq.cmd('/kactl target') ; mq.delay(D)
    TH.assert_eq(State.combat.aggroTargetID, '555', '/kactl target (no argument) → nothing changed')

    -- Restore original state
    State.combat.myTargetID    = origMyTargetID
    State.combat.aggroTargetID = origAggroTargetID
    State.combat.forcedTargetID = origForced
end

return M
