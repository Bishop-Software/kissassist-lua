-- tests/unit/test_cond.lua
-- Tests Cond.evalStr and Cond.eval, including the TARGETCHECK sentinel.
-- Requires mock injection (useMock=true) because cond.lua calls mq.parse and mq.TLO.*.
local M = {}

function M.run(TH, MockMQ)
    local Cond = require('modules.cond')

    -- Minimal state and utils stubs — we set cond fields directly per test.
    local state = {
        cond = {
            on          = false,
            size        = 5,
            expressions = {},
        }
    }
    local utils = { debug = function() end }
    Cond.init(state, utils)

    TH.setSuite('test_cond')

    -- Cond.evalStr --------------------------------------------------------
    -- nil / empty → true (no condition = unconditional pass)
    TH.assert_true(Cond.evalStr(nil), 'evalStr(nil) = true')
    TH.assert_true(Cond.evalStr(''),  'evalStr("") = true')

    -- parse returns '1' → truthy
    MockMQ.set('parse:${Me.PctHPs}>50', '1')
    TH.assert_true(Cond.evalStr('${Me.PctHPs}>50'), 'evalStr "1" = true')

    -- parse returns a non-zero, non-FALSE string → truthy
    MockMQ.set('parse:${Target.ID}', '12345')
    TH.assert_true(Cond.evalStr('${Target.ID}'), 'evalStr numeric string = true')

    -- parse returns '0' → false
    MockMQ.set('parse:${Me.PctHPs}<10', '0')
    TH.assert_false(Cond.evalStr('${Me.PctHPs}<10'), 'evalStr "0" = false')

    -- parse returns 'FALSE' → false
    MockMQ.set('parse:${Me.Invis}', 'FALSE')
    TH.assert_false(Cond.evalStr('${Me.Invis}'), 'evalStr "FALSE" = false')

    -- no mock set for this expr → default '0' → false
    TH.assert_false(Cond.evalStr('${UnknownExpr}'), 'evalStr unmocked = false')

    -- Cond.eval — cond.on = false: bypass regardless of slot content -----------
    MockMQ.reset()
    state.cond.on = false
    state.cond.expressions[1] = '${Me.PctHPs}<50'
    MockMQ.set('parse:${Me.PctHPs}<50', '0')   -- would be false if evaluated
    TH.assert_true(Cond.eval(1), 'eval cond.on=false → bypass → true')

    -- Cond.eval — n=0: bypass regardless of cond.on -----------------------
    state.cond.on = true
    TH.assert_true(Cond.eval(0), 'eval n=0 → bypass → true')

    -- Cond.eval — empty slot: no expression → true -------------------------
    state.cond.expressions = {}
    TH.assert_true(Cond.eval(1), 'eval empty slot → true')
    TH.assert_true(Cond.eval(5), 'eval nil slot → true')

    -- Cond.eval — truthy expression ----------------------------------------
    MockMQ.reset()
    state.cond.on = true
    state.cond.expressions[1] = '${Me.PctHPs}>50'
    MockMQ.set('parse:${Me.PctHPs}>50', '1')
    TH.assert_true(Cond.eval(1), 'eval truthy expr → true')

    -- Cond.eval — false expression -----------------------------------------
    state.cond.expressions[2] = '${Me.PctHPs}>99'
    MockMQ.set('parse:${Me.PctHPs}>99', '0')
    TH.assert_false(Cond.eval(2), 'eval false expr → false')

    -- Cond.eval — TARGETCHECK: valid NPC at >0% HP -------------------------
    state.cond.expressions[3] = 'TARGETCHECK'
    MockMQ.reset()
    state.cond.on = true
    state.cond.expressions[3] = 'TARGETCHECK'
    MockMQ.set('TLO.Target',        'SomeMob')   -- tgt() returns non-nil
    MockMQ.set('TLO.Target.Type',   'NPC')
    MockMQ.set('TLO.Target.Dead',   false)
    MockMQ.set('TLO.Target.PctHPs', 80)
    TH.assert_true(Cond.eval(3), 'TARGETCHECK valid NPC 80%HP → true')

    -- TARGETCHECK: no target (tgt() returns nil) ---------------------------
    MockMQ.reset()
    -- TLO.Target not set → proxy returns nil
    TH.assert_false(Cond.eval(3), 'TARGETCHECK no target → false')

    -- TARGETCHECK: target exists but is a PC, not NPC ----------------------
    MockMQ.reset()
    MockMQ.set('TLO.Target',        'FriendlyPC')
    MockMQ.set('TLO.Target.Type',   'PC')
    MockMQ.set('TLO.Target.Dead',   false)
    MockMQ.set('TLO.Target.PctHPs', 100)
    TH.assert_false(Cond.eval(3), 'TARGETCHECK PC type → false')

    -- TARGETCHECK: NPC but Dead=true ---------------------------------------
    MockMQ.reset()
    MockMQ.set('TLO.Target',        'DeadMob')
    MockMQ.set('TLO.Target.Type',   'NPC')
    MockMQ.set('TLO.Target.Dead',   true)
    MockMQ.set('TLO.Target.PctHPs', 0)
    TH.assert_false(Cond.eval(3), 'TARGETCHECK dead NPC → false')

    -- TARGETCHECK: NPC, not dead, but PctHPs=0 (corpse not yet flagged dead)
    MockMQ.reset()
    MockMQ.set('TLO.Target',        'DyingMob')
    MockMQ.set('TLO.Target.Type',   'NPC')
    MockMQ.set('TLO.Target.Dead',   false)
    MockMQ.set('TLO.Target.PctHPs', 0)
    TH.assert_false(Cond.eval(3), 'TARGETCHECK NPC 0%HP → false')

    -- TARGETCHECK embedded inside a longer expr string --------------------
    -- The find() check is a substring match; the whole expr goes to TARGETCHECK path.
    state.cond.expressions[4] = 'USE_TARGETCHECK_ON_TARGET'
    MockMQ.reset()
    MockMQ.set('TLO.Target',        'AnotherMob')
    MockMQ.set('TLO.Target.Type',   'NPC')
    MockMQ.set('TLO.Target.Dead',   false)
    MockMQ.set('TLO.Target.PctHPs', 50)
    TH.assert_true(Cond.eval(4), 'TARGETCHECK substring in expr → true')
end

return M
