-- tests/unit/test_buffs.lua
-- Verifies State.buffs fields added for the BUFFSTATE actors system (#113).
local M = {}

function M.run(TH, _MockMQ)
    local State = require('modules.state')

    TH.setSuite('test_buffs')

    -- memberBuffs table exists and is empty at init
    TH.assert_true(State.buffs.memberBuffs ~= nil,       'memberBuffs declared')
    TH.assert_eq(type(State.buffs.memberBuffs), 'table', 'memberBuffs is a table')
    TH.assert_eq(next(State.buffs.memberBuffs), nil,     'memberBuffs empty at init')

    -- memberBuffsExpiry table exists and is empty at init
    TH.assert_true(State.buffs.memberBuffsExpiry ~= nil,       'memberBuffsExpiry declared')
    TH.assert_eq(type(State.buffs.memberBuffsExpiry), 'table', 'memberBuffsExpiry is a table')
    TH.assert_eq(next(State.buffs.memberBuffsExpiry), nil,     'memberBuffsExpiry empty at init')

    -- Simulate populating as the BUFFSTATE handler would
    State.buffs.memberBuffs[12345]       = { ['Spirit of Wolf'] = os.clock() + 60 }
    State.buffs.memberBuffsExpiry[12345] = os.clock() + 90

    TH.assert_true(State.buffs.memberBuffs[12345] ~= nil,                  'memberBuffs[id] set')
    TH.assert_true(State.buffs.memberBuffs[12345]['Spirit of Wolf'] ~= nil, 'memberBuffs[id][spell] set')
    TH.assert_true(State.buffs.memberBuffsExpiry[12345] > os.clock(),       'memberBuffsExpiry[id] in future')

    -- Simulate staleness: expiry in the past
    State.buffs.memberBuffsExpiry[12345] = os.clock() - 1
    TH.assert_true(State.buffs.memberBuffsExpiry[12345] < os.clock(), 'stale expiry is in the past')
end

return M
