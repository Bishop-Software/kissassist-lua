-- tests/unit/test_pull_ignore.lua
-- Pull.ignoreAdd (#144): the pull ignore list ("|id|id|", the .mac's
-- PullIgnore1), filled by waitForMob and failed pulls like PullIgnoreCheck
-- (mac:9980). It is separate from MobsToIgnoreByID (combat refuses those) and
-- is cleared every 5 minutes (mac:8998).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_ignore')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session = { role = 'puller', infoFileName = '', zoneName = '' },
        pull    = { mobsToIgnoreByID = 'null', ignore1 = 'null' },
        timers  = {},
        heal    = { medOn = false },
        combat  = { aggroTargetID = '' },
        pet     = { attackRange = 100 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local p = state.pull

    Pull.ignoreAdd(112, 'test')
    TH.assert_eq(p.ignore1, '|112|', 'first ID: |112|')
    Pull.ignoreAdd('34', 'test')
    TH.assert_eq(p.ignore1, '|112|34|', 'second ID appended (string ID accepted)')
    Pull.ignoreAdd(112, 'test')
    TH.assert_eq(p.ignore1, '|112|34|', 'duplicate not added')
    Pull.ignoreAdd(12, 'test')
    TH.assert_eq(p.ignore1, '|112|34|12|', '12 is not mistaken for 112')
    Pull.ignoreAdd(0, 'test')
    Pull.ignoreAdd(nil, 'test')
    TH.assert_eq(p.ignore1, '|112|34|12|', 'ID 0 / nil ignored')
    TH.assert_eq(p.mobsToIgnoreByID, 'null', 'MobsToIgnoreByID (combat ignore) untouched')

    -- Lookups use "|id|" so partial IDs never match.
    TH.assert_true(Pull.onPullIgnore(34), 'lookup finds 34')
    TH.assert_false(Pull.onPullIgnore(3), 'lookup does not find 3')

    -- Empty string start behaves like 'null'.
    p.ignore1 = ''
    Pull.ignoreAdd(7, 'test')
    TH.assert_eq(p.ignore1, '|7|', 'empty list -> |7|')

    -- 5-minute clear and dead-entry cleanup (Pull.pullIgnoreTick).
    local alive = { [7] = 'NPC', [8] = 'Corpse' }
    MockMQ.set('TLO.Spawn', function(q)
        local id = tonumber(q:match('%d+'))
        return { ID = function() return alive[id] and id or 0 end,
                 Type = function() return alive[id] end }
    end)
    p.ignore1 = '|7|8|9|'
    state.timers.pullAlert = os.clock() + 60
    Pull.pullIgnoreTick()
    TH.assert_eq(p.ignore1, '|7|', 'tick: corpses and despawned mobs dropped')
    state.timers.pullAlert = 0
    Pull.pullIgnoreTick()
    TH.assert_eq(p.ignore1, 'null', 'timer expired: list cleared')
    TH.assert_near(state.timers.pullAlert, os.clock() + 300, 1, 'next clear in 5 minutes')

    package.loaded['modules.pull'] = nil
end

return M
