-- tests/unit/test_pull_arc.lua
-- Pull arc math (#226): Pull.pullAngles mirrors Sub SetPullAngles (mac:14490);
-- Pull.headingTo returns MQ's HeadingTo.Degrees: compass, clockwise (0 = north
-- = +Y, 90 = east = -X; EQ's +X is west).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_arc')
    MockMQ.reset()
    local Pull = require('modules.pull')

    -- headingTo: camp at origin.
    TH.assert_near(Pull.headingTo(0, 0, 100, 0),    0, 0.001, 'headingTo: +Y -> 0')
    TH.assert_near(Pull.headingTo(0, 0, 0, 100),  270, 0.001, 'headingTo: +X (west) -> 270')
    TH.assert_near(Pull.headingTo(0, 0, -100, 0), 180, 0.001, 'headingTo: -Y (south) -> 180')
    TH.assert_near(Pull.headingTo(0, 0, 0, -100),  90, 0.001, 'headingTo: -X (east) -> 90')
    TH.assert_near(Pull.headingTo(0, 0, 100, 100), 315, 0.001, 'headingTo: +Y+X (northwest) -> 315')
    TH.assert_near(Pull.headingTo(50, 50, 150, 50), 0, 0.001, 'headingTo: offset camp')

    -- pullAngles: no wrap.
    local l, r = Pull.pullAngles(90, 90)
    TH.assert_near(l,  45, 0.001, 'pullAngles(90,90) left = 45')
    TH.assert_near(r, 135, 0.001, 'pullAngles(90,90) right = 135')

    -- Wrap on the left (through 0).
    l, r = Pull.pullAngles(10, 90)
    TH.assert_near(l, 325, 0.001, 'pullAngles(10,90) left wraps to 325')
    TH.assert_near(r,  55, 0.001, 'pullAngles(10,90) right = 55')

    -- Wrap on the right (through 360).
    l, r = Pull.pullAngles(350, 60)
    TH.assert_near(l, 320, 0.001, 'pullAngles(350,60) left = 320')
    TH.assert_near(r,  20, 0.001, 'pullAngles(350,60) right wraps to 20')

    -- Facing north, the old code's bug case: the arc must be centred on 0.
    l, r = Pull.pullAngles(0, 90)
    TH.assert_near(l, 315, 0.001, 'pullAngles(0,90) left = 315')
    TH.assert_near(r,  45, 0.001, 'pullAngles(0,90) right = 45')

    -- arcPoint: compass heading from camp (0 north = +Y, 90 east = -X).
    local y, x = Pull.arcPoint(0, 0, 0, 100)
    TH.assert_near(y, 100, 0.001, 'arcPoint north: +Y')
    TH.assert_near(x,   0, 0.001, 'arcPoint north: X unchanged')
    y, x = Pull.arcPoint(0, 0, 90, 100)
    TH.assert_near(y,    0, 0.001, 'arcPoint east: Y unchanged')
    TH.assert_near(x, -100, 0.001, 'arcPoint east: -X')

    -- drawArc: dotted edges on the MQ2Map map, cleared when the arc goes off.
    local state = {
        session  = { role = 'puller', infoFileName = '', zoneName = '' },
        pull     = { pullArcWidth = 0, maxRadius = 200, arcMarks = {} },
        timers   = {}, heal = { medOn = false }, combat = { aggroTargetID = '' },
        pet      = {}, misc = {},
        movement = { campX = 0, campY = 0, campRadius = 30 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    MockMQ.reset()
    MockMQ.set('TLO.Plugin', function() return { IsLoaded = function() return true end } end)
    state.movement.campY, state.movement.campX = 1000, -500
    state.pull.maxRadius    = 200   -- after Pull.init, which loads the config default (350)
    state.pull.pullArcWidth = 90
    Pull.setPullAngles(0, 90, true)   -- edges at 315 (NW) and 45 (NE)
    TH.assert_eq(#state.pull.arcMarks, 8, 'drawArc: 4 markers per edge')
    -- NE edge end: 200 out at 45 degrees = Y +141, X -141 (east is -X)
    TH.assert_true(MockMQ.cmdCalled('/squelch /maploc size 10 color 255 200 0 1141 -641 label Pull arc R'),
        'drawArc: labelled marker at the right edge end')
    TH.assert_true(MockMQ.cmdCalled('/squelch /maploc size 10 color 255 200 0 1141 -359 label Pull arc L'),
        'drawArc: labelled marker at the left edge end')
    Pull.setPullAngles(0, 0, true)
    TH.assert_eq(#state.pull.arcMarks, 0, 'width 0: markers cleared')
    TH.assert_true(MockMQ.cmdCalled('/squelch /maploc remove 1141 -641'), 'width 0: markers removed by loc')
    TH.assert_false(MockMQ.cmdCalled('/squelch /maploc remove'), 'never a bare /maploc remove (would clear all locs)')

    state.session.role = 'assist'
    Pull.setPullAngles(0, 90, true)
    TH.assert_eq(#state.pull.arcMarks, 0, 'non-puller role: no markers')

    package.loaded['modules.pull'] = nil
end

return M
