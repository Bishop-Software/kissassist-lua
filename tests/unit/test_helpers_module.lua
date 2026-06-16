-- tests/unit/test_helpers_module.lua
-- Tests Helpers.dist2D, Helpers.applyDAMod.
-- Pure math — no mq dependency, no mock injection needed.
local M = {}

function M.run(TH, _MockMQ)
    local Helpers = require('modules.helpers')

    TH.setSuite('test_helpers')

    -- dist2D -----------------------------------------------------------

    -- Same point → 0
    TH.assert_near(Helpers.dist2D(0,0,0,0), 0, 0.001, 'dist2D same point = 0')

    -- Pure Y offset
    TH.assert_near(Helpers.dist2D(0,0,5,0), 5.0, 0.001, 'dist2D Y offset = 5')

    -- Pure X offset
    TH.assert_near(Helpers.dist2D(0,0,0,4), 4.0, 0.001, 'dist2D X offset = 4')

    -- Classic 3-4-5 right triangle
    TH.assert_near(Helpers.dist2D(0,0,3,4), 5.0, 0.001, 'dist2D 3-4-5 = 5')

    -- Symmetry: dist(a→b) == dist(b→a)
    local d1 = Helpers.dist2D(10, 20, 30, 40)
    local d2 = Helpers.dist2D(30, 40, 10, 20)
    TH.assert_near(d1, d2, 0.001, 'dist2D symmetric')

    -- Negative coordinates (mirrors EQ coordinate system where N is negative Y)
    TH.assert_near(Helpers.dist2D(-3,0,0,4), 5.0, 0.001, 'dist2D negative Y coord')

    -- Large coords
    TH.assert_near(Helpers.dist2D(0,0,300,400), 500.0, 0.01, 'dist2D large 300-400-500')

    -- applyDAMod -------------------------------------------------------

    -- nil/empty/'+0' → passthrough baseDur
    TH.assert_eq(Helpers.applyDAMod(30, nil),  30, 'applyDAMod(30, nil) = 30')
    TH.assert_eq(Helpers.applyDAMod(30, ''),   30, 'applyDAMod(30, "")  = 30')
    TH.assert_eq(Helpers.applyDAMod(30, '+0'), 30, 'applyDAMod(30, +0)  = 30')

    -- baseDur=0 with passthrough daMod → 0 (no timer)
    TH.assert_eq(Helpers.applyDAMod(0, nil),   0,  'applyDAMod(0, nil)  = 0')
    TH.assert_eq(Helpers.applyDAMod(0, '+0'),  0,  'applyDAMod(0, +0)   = 0')

    -- '+N' relative increase
    TH.assert_eq(Helpers.applyDAMod(30, '+10'), 40, 'applyDAMod +10 → 40')
    TH.assert_eq(Helpers.applyDAMod(30, '+0'),  30, 'applyDAMod +0  → 30 (passthrough path)')

    -- '-N' relative decrease
    TH.assert_eq(Helpers.applyDAMod(30, '-5'),  25, 'applyDAMod -5  → 25')

    -- '-N' clamped at 0 when delta exceeds baseDur
    TH.assert_eq(Helpers.applyDAMod(10, '-40'), 0,  'applyDAMod clamp → 0')
    TH.assert_eq(Helpers.applyDAMod(5,  '-5'),  0,  'applyDAMod exact zero clamp')

    -- Plain number: fixed override, replaces baseDur entirely
    TH.assert_eq(Helpers.applyDAMod(30, '45'),  45, 'applyDAMod fixed 45')
    TH.assert_eq(Helpers.applyDAMod(30, '0'),   0,  'applyDAMod fixed 0')
    TH.assert_eq(Helpers.applyDAMod(0,  '60'),  60, 'applyDAMod fixed 60 from 0 base')
end

return M
