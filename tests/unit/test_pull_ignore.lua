-- tests/unit/test_pull_ignore.lua
-- Pull.ignoreAdd (#144): the ignore-by-ID pull list ("|id|id|"), filled by
-- waitForMob and failed pulls like the .mac's PullIgnoreCheck (mac:9980).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_ignore')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session = { role = 'puller', infoFileName = '', zoneName = '' },
        pull    = { pullLocY = {}, pullLocX = {}, pullLocZ = {}, mobsToIgnoreByID = 'null' },
        timers  = {},
        heal    = { medOn = false },
        combat  = { aggroTargetID = '' },
        pet     = { attackRange = 100 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local p = state.pull

    Pull.ignoreAdd(112, 'test')
    TH.assert_eq(p.mobsToIgnoreByID, '|112|', 'first ID: |112|')
    Pull.ignoreAdd('34', 'test')
    TH.assert_eq(p.mobsToIgnoreByID, '|112|34|', 'second ID appended (string ID accepted)')
    Pull.ignoreAdd(112, 'test')
    TH.assert_eq(p.mobsToIgnoreByID, '|112|34|', 'duplicate not added')
    Pull.ignoreAdd(12, 'test')
    TH.assert_eq(p.mobsToIgnoreByID, '|112|34|12|', '12 is not mistaken for 112')
    Pull.ignoreAdd(0, 'test')
    Pull.ignoreAdd(nil, 'test')
    TH.assert_eq(p.mobsToIgnoreByID, '|112|34|12|', 'ID 0 / nil ignored')

    -- Lookups use "|id|" so partial IDs never match.
    TH.assert_true(p.mobsToIgnoreByID:find('|34|', 1, true) ~= nil, 'lookup finds 34')
    TH.assert_true(p.mobsToIgnoreByID:find('|3|', 1, true) == nil, 'lookup does not find 3')

    -- Empty string start behaves like 'null'.
    p.mobsToIgnoreByID = ''
    Pull.ignoreAdd(7, 'test')
    TH.assert_eq(p.mobsToIgnoreByID, '|7|', 'empty list -> |7|')

    package.loaded['modules.pull'] = nil
end

return M
