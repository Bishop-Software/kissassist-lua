-- tests/unit/test_pull_aggro.lua
-- Utils.pullAggroID: live port of the .mac's /noparse PullAggroTargetID (mac:16247).
-- Regression for #224: pulls never detected aggro because the old
-- State.pull.aggroTargetID field was never written.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_aggro')

    local Utils = require('modules.utils')

    local state = {
        debug  = {},
        combat = { xTSlot = 1, xTSlot2 = 2, myTargetID = 0 },
        pull   = { chainPull = 0, beginMobID = '0' },
    }
    Utils.init(state)

    -- XTarget(n).ID() returns ids[n]; missing slots behave like an empty slot (nil).
    local function setXT(ids)
        MockMQ.reset()
        MockMQ.set('TLO.Me.XTarget', function(n)
            return { ID = function() return ids[n] end }
        end)
    end

    -- Not chain pulling: slot 1 contents, whatever they are.
    state.pull.chainPull = 0
    setXT({})
    TH.assert_eq(Utils.pullAggroID(), 0, 'no chain: empty XTarget -> 0')
    setXT({ [1] = 500 })
    TH.assert_eq(Utils.pullAggroID(), 500, 'no chain: XTarget slot 1 mob -> its ID')

    -- No Auto Hater slot detected: never report aggro.
    state.combat.xTSlot = 0
    setXT({ [0] = 500, [1] = 500 })
    TH.assert_eq(Utils.pullAggroID(), 0, 'xTSlot=0 -> 0')
    state.combat.xTSlot = 1

    -- Chain pulling: returns MyTargetID, only once something changed on XTarget.
    state.pull.chainPull   = 1
    state.combat.myTargetID = 777
    state.pull.beginMobID  = '300'

    setXT({})
    TH.assert_eq(Utils.pullAggroID(), 0, 'chain: empty XTarget -> 0')

    setXT({ [1] = 300 })
    TH.assert_eq(Utils.pullAggroID(), 0, 'chain: only the mob we were already fighting -> 0')

    setXT({ [1] = 777 })
    TH.assert_eq(Utils.pullAggroID(), 777, 'chain: pull target on slot 1 -> MyTargetID')

    setXT({ [1] = 450 })
    TH.assert_eq(Utils.pullAggroID(), 777, 'chain: slot 1 changed since pull start -> MyTargetID')

    setXT({ [1] = 300, [2] = 777 })
    TH.assert_eq(Utils.pullAggroID(), 777, 'chain: slot 2 in use -> MyTargetID')

    -- Slot 2 not detected: only slot 1 counts.
    state.combat.xTSlot2 = 0
    setXT({ [0] = 999, [1] = 300 })
    TH.assert_eq(Utils.pullAggroID(), 0, 'chain: xTSlot2=0 ignores slot 2')
    state.combat.xTSlot2 = 2

    -- chainPull 2 ("just finished") is still chain mode in the .mac (only ==0 is not).
    state.pull.chainPull = 2
    setXT({ [1] = 777 })
    TH.assert_eq(Utils.pullAggroID(), 777, 'chainPull=2 uses chain rules')

    -- Before Utils.init: safe 0.
    package.loaded['modules.utils'] = nil
    local fresh = require('modules.utils')
    TH.assert_eq(fresh.pullAggroID(), 0, 'before init -> 0')
    package.loaded['modules.utils'] = nil
end

return M
