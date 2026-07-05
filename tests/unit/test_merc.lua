-- tests/unit/test_merc.lua
-- Regression test for the merc "never assists" bug: Mercenary.State returns an
-- UPPERCASE string ("ACTIVE"/"SUSPENDED"/"DEAD"/"NONE", see MQ2MercenaryType.cpp),
-- but Merc.check compared it against 'Active' (mixed case) with Lua's case-sensitive
-- ==, so the active-check was always false and /mercassist never fired.
local M = {}

-- Merc.init reads Config (returns defaults, fine) and probes a couple of TLOs;
-- seed benign mocks so it doesn't error, then override state fields directly.
local function makeState()
    return {
        merc    = { on = 1, assistAt = 100, assisting = 0, inGroup = false, myMerc = '' },
        combat  = { myTargetID = 0, combatStart = false },
        session = { role = 'assist' },
        pull    = { mob = 0 },
    }
end

-- Group.Member(1) must be callable AND expose .Owner.Name()/.Name().
-- Resets recorded cmds/returns first so each block asserts in isolation.
local function seedInitTLOs(MockMQ, mercState)
    MockMQ.reset()
    MockMQ.set('TLO.Me.CleanName', 'Tester')
    MockMQ.set('TLO.Mercenary.State', mercState or 'NONE')
    MockMQ.set('TLO.Group.Member', function()
        return setmetatable(
            { Owner = { Name = function() return '' end }, Name = function() return '' end },
            { __call = function() return false end })
    end)
    -- Dead-merc revive probe: Window(x).Child(y).Enabled()
    MockMQ.set('TLO.Window', function()
        return { Child = function() return { Enabled = function() return false end } end }
    end)
    -- Spawn('id N').PctHPs()
    MockMQ.set('TLO.Spawn', function()
        return { PctHPs = function() return 100 end }
    end)
end

function M.run(TH, MockMQ)
    TH.setSuite('test_merc')

    package.loaded['modules.merc'] = nil
    local Merc = require('modules.merc')
    local utils = { debug = function() end }

    -- 1. ACTIVE + combatStart + target ≤ assistAt → fires /mercassist and latches ----
    do
        seedInitTLOs(MockMQ, 'ACTIVE')
        local s = makeState()
        Merc.init(s, utils)
        s.merc.on = 1; s.merc.assistAt = 100
        s.combat.myTargetID = 555
        s.combat.combatStart = true
        Merc.check()
        TH.assert_true(MockMQ.cmdCalled('/mercassist'), 'ACTIVE state → /mercassist issued')
        TH.assert_eq(s.merc.assisting, 555, 'assisting latches to target id')
        TH.assert_true(s.merc.inGroup, 'ACTIVE marks inGroup')
    end

    -- 2. Regression guard: the literal 'Active' (old buggy value) must NOT be used ---
    do
        seedInitTLOs(MockMQ, 'Active')  -- MQ never returns this casing
        local s = makeState()
        Merc.init(s, utils)
        s.merc.on = 1; s.merc.assistAt = 100
        s.combat.myTargetID = 777
        s.combat.combatStart = true
        Merc.check()
        TH.assert_false(MockMQ.cmdCalled('/mercassist'),
            "mixed-case 'Active' is never returned by MQ → no assist (documents the bug)")
    end

    -- 3. SUSPENDED merc → no assist -------------------------------------------------
    do
        seedInitTLOs(MockMQ, 'SUSPENDED')
        local s = makeState()
        Merc.init(s, utils)
        s.merc.on = 1; s.merc.assistAt = 100
        s.combat.myTargetID = 999
        s.combat.combatStart = true
        Merc.check()
        TH.assert_false(MockMQ.cmdCalled('/mercassist'), 'SUSPENDED → no /mercassist')
    end

    -- 4. MercOn = 0 → early return, no assist even when ACTIVE ----------------------
    do
        seedInitTLOs(MockMQ, 'ACTIVE')
        local s = makeState()
        Merc.init(s, utils)
        s.merc.on = 0
        s.combat.myTargetID = 111
        s.combat.combatStart = true
        Merc.check()
        TH.assert_false(MockMQ.cmdCalled('/mercassist'), 'MercOn=0 → disabled')
    end

    -- 5. Target changed while assisting → re-assist --------------------------------
    do
        seedInitTLOs(MockMQ, 'ACTIVE')
        local s = makeState()
        Merc.init(s, utils)
        s.merc.on = 1; s.merc.assistAt = 100
        s.merc.assisting = 200            -- already assisting an old target
        s.combat.myTargetID = 300         -- new target
        s.combat.combatStart = true
        Merc.check()
        TH.assert_true(MockMQ.cmdCalled('/mercassist'), 'new target → re-assist')
        TH.assert_eq(s.merc.assisting, 300, 're-assist updates latch to new target')
    end

    package.loaded['modules.merc'] = nil
end

return M
