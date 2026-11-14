-- tests/unit/test_pull_map.lua
-- Pull.paintMap (#259): draw the pull/camp radii with /mapfilter once the
-- puller is in camp, mirroring Sub PaintMap (mac:8917).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_map')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session  = { role = 'pullertank', infoFileName = '', zoneName = '' },
        pull     = { pullLocY = {}, pullLocX = {}, pullLocZ = {}, mapSet = false },
        timers   = {},
        heal     = { medOn = false },
        combat   = { aggroTargetID = '' },
        pet      = { attackRange = 100 },
        movement = { campX = 100, campY = 200, campRadius = 40 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local p = state.pull
    p.range, p.maxRadius = 243, 200

    -- me: { x=, y= }, mapLoaded: bool
    local function setEnv(me, mapLoaded)
        MockMQ.reset()
        MockMQ.set('TLO.Plugin', function() return { IsLoaded = function() return mapLoaded end } end)
        MockMQ.set('TLO.Me.X', me.x)
        MockMQ.set('TLO.Me.Y', me.y)
    end

    -- Not in camp: nothing painted.
    setEnv({ x = 100, y = 300 }, true)
    Pull.paintMap()
    TH.assert_false(MockMQ.cmdMatched('mapfilter'), 'outside camp radius: no /mapfilter')
    TH.assert_false(p.mapSet, 'outside camp radius: mapSet stays false')

    -- MQ2Map not loaded: nothing painted.
    setEnv({ x = 100, y = 200 }, false)
    Pull.paintMap()
    TH.assert_false(MockMQ.cmdMatched('mapfilter'), 'MQ2Map not loaded: no /mapfilter')

    -- In camp with MQ2Map: all four circles, once.
    setEnv({ x = 110, y = 210 }, true)
    Pull.paintMap()
    TH.assert_true(MockMQ.cmdCalled('/squelch /mapfilter CastRadius 243'),  'CastRadius = pull range')
    TH.assert_true(MockMQ.cmdCalled('/squelch /mapfilter SpellRadius 200'), 'SpellRadius = MaxRadius')
    TH.assert_true(MockMQ.cmdCalled('/squelch /mapfilter PullRadius 200'),  'PullRadius = MaxRadius')
    TH.assert_true(MockMQ.cmdCalled('/squelch /mapfilter CampRadius 40'),   'CampRadius = camp radius')
    TH.assert_true(p.mapSet, 'mapSet set after painting')

    setEnv({ x = 110, y = 210 }, true)
    Pull.paintMap()
    TH.assert_false(MockMQ.cmdMatched('mapfilter'), 'already painted: no repeat')

    -- Clearing mapSet (as /makecamphere does) repaints.
    p.mapSet = false
    Pull.paintMap()
    TH.assert_true(MockMQ.cmdCalled('/squelch /mapfilter CampRadius 40'), 'mapSet cleared: repaints')

    -- No camp set: nothing painted.
    p.mapSet = false
    state.movement.campX, state.movement.campY = 0, 0
    setEnv({ x = 0, y = 0 }, true)
    Pull.paintMap()
    TH.assert_false(MockMQ.cmdMatched('mapfilter'), 'no camp: no /mapfilter')

    package.loaded['modules.pull'] = nil
end

return M
