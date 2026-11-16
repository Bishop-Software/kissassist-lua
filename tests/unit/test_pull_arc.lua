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

    package.loaded['modules.pull'] = nil
end

return M
