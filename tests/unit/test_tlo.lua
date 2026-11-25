-- tests/unit/test_tlo.lua
-- ${KissAssist} TLO (#353): member values, registration through mq.DataType /
-- mq.AddTopLevelObject (faked here), the name-in-use case, and unregister.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_tlo')
    MockMQ.reset()

    local Tlo = require('modules.tlo')
    local state = { session = { paused = false, role = 'tank', mainAssist = 'Tankname' } }
    Tlo.init(state)

    local function val(name) return select(2, Tlo.members[name]()) end
    local function typ(name) return (Tlo.members[name]()) end

    -- ── members ─────────────────────────────────────────────────────────────
    TH.assert_eq(typ('Paused'), 'bool', 'Paused is a bool')
    TH.assert_false(val('Paused'), 'Paused FALSE while running')
    TH.assert_eq(val('State'), 'Running', 'State Running')
    TH.assert_eq(val('Role'), 'tank', 'Role')
    TH.assert_eq(val('MainAssist'), 'Tankname', 'MainAssist')
    state.session.paused = true
    TH.assert_true(val('Paused'), 'Paused TRUE while paused')
    TH.assert_eq(val('State'), 'Paused', 'State Paused')
    state.session.paused = false

    -- ── no TLO support (plain mock): register skips quietly ─────────────────
    TH.assert_false(Tlo.register(), 'no mq.DataType: not registered')

    -- ── register with a faked MQ2Lua API ────────────────────────────────────
    local def, addedName, addedFn, removed
    local addResult = true
    MockMQ.DataType = { new = function(_, d) def = d; return 'TYPE' end }
    MockMQ.AddTopLevelObject = function(name, fn) addedName, addedFn = name, fn; return addResult end
    MockMQ.RemoveTopLevelObject = function(name) removed = name end

    TH.assert_true(Tlo.register(), 'registered')
    TH.assert_eq(addedName, 'KissAssist', 'TLO name')
    local t, obj = addedFn('')
    TH.assert_eq(t, 'TYPE', 'TLO returns the data type')
    TH.assert_true(obj == state, 'TLO object is the state table')
    local mt, mv = def.Members.Paused('', obj)
    TH.assert_eq(mt, 'bool', 'data type member Paused: bool')
    TH.assert_false(mv, 'data type member Paused: FALSE')
    TH.assert_eq(def.ToString(obj), 'Running', 'ToString: Running')
    state.session.paused = true
    TH.assert_eq(def.ToString(obj), 'Paused', 'ToString: Paused')
    state.session.paused = false

    addedName = nil
    TH.assert_true(Tlo.register(), 'second register: already registered')
    TH.assert_nil(addedName, 'second register: not added twice')

    Tlo.unregister()
    TH.assert_eq(removed, 'KissAssist', 'unregister removes the TLO')
    removed = nil
    Tlo.unregister()
    TH.assert_nil(removed, 'unregister when not registered: nothing removed')

    -- ── name already in use ─────────────────────────────────────────────────
    addResult = false
    TH.assert_false(Tlo.register(), 'name in use: not registered')
    Tlo.unregister()
    TH.assert_nil(removed, 'name in use: unregister removes nothing')

    MockMQ.DataType, MockMQ.AddTopLevelObject, MockMQ.RemoveTopLevelObject = nil, nil, nil
end

return M
