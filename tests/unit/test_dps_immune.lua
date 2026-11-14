-- tests/unit/test_dps_immune.lua
-- Cast.combatCast must stop re-casting a DPS spell on a mob that came back
-- CAST_IMMUNE to it, while still casting it on other mobs. Before the fix the
-- IMMUNE result set no slot timer and the spell never landed, so it was recast
-- on every gem refresh for the whole fight.
local M = {}

local function makeState(targetID)
    return {
        session = { iAmDead = false, iAmABard = false, iAmMA = true, role = 'assist', mainAssist = '' },
        combat  = {
            dpsArray = { { name = 'Test Snare|100', condNo = 0 } },
            myTargetID = targetID, slotTimers = {}, dpsImmune = {},
            dpsSkip = 0, dpsOn = false, assistAt = 100, meleeOn = false,
            targetSwitchingOn = false, manualTargetMode = false,
        },
        dps  = { paused = false },
        cast = {},
    }
end

-- Seed just enough TLOs for one mob-targeted spell entry to reach castWhat.
local function seedTLOs(MockMQ, s)
    MockMQ.reset()
    MockMQ.set('TLO.Target.ID', function() return s.combat.myTargetID end)
    MockMQ.set('TLO.Target.Buff', function()
        return { ID = function() return nil end, Caster = function() return nil end }
    end)
    MockMQ.set('TLO.Spawn', function()
        return {
            Type = function() return 'NPC' end, ID = function() return s.combat.myTargetID end,
            PctHPs = function() return 50 end, CleanName = function() return 'a mob' end,
        }
    end)
    MockMQ.set('TLO.Spell', function(name)
        return {
            RankName = function() return name end, Category = function() return '' end,
            TargetType = function() return 'Single' end,
            HasSPA = function() return function() return false end end,
        }
    end)
    MockMQ.set('TLO.Me.SpellReady', function() return function() return true end end)
    -- Self-buff skip probe for 'me' entries: Me.Buff(x).ID() / Me.Song(x).ID()
    local noBuff = function() return { ID = function() return nil end } end
    MockMQ.set('TLO.Me.Buff', noBuff)
    MockMQ.set('TLO.Me.Song', noBuff)
end

function M.run(TH, MockMQ)
    TH.setSuite('test_dps_immune')

    package.loaded['modules.cast'] = nil
    local Cast = require('modules.cast')
    local utils = { debug = function() end }

    local s = makeState(555)
    seedTLOs(MockMQ, s)
    Cast.init(s, utils)

    local realCastWhat = Cast.castWhat
    local casts = 0
    Cast.castWhat = function() casts = casts + 1; return 'CAST_IMMUNE' end

    -- 1. IMMUNE result is remembered for that mob and spell -----------------------
    Cast.combatCast()
    TH.assert_eq(casts, 1, 'first pass casts the spell')
    TH.assert_true(s.combat.dpsImmune[555] and s.combat.dpsImmune[555]['Test Snare'],
        'IMMUNE recorded for mob 555 / Test Snare')

    -- 2. Same mob again → skipped ------------------------------------------------
    Cast.combatCast()
    TH.assert_eq(casts, 1, 'immune mob → spell not recast')

    -- 3. Different mob → still cast ----------------------------------------------
    s.combat.myTargetID = 556
    Cast.combatCast()
    TH.assert_eq(casts, 2, 'other mob → spell cast normally')

    -- 4. Self-targeted entry coming back IMMUNE is not recorded -------------------
    s.combat.myTargetID = 557
    s.combat.dpsArray = { { name = 'Test Self|100|me', condNo = 0 } }
    Cast.combatCast()
    TH.assert_eq(casts, 3, "'me' entry was cast")
    TH.assert_true(s.combat.dpsImmune[557] == nil and s.combat.dpsImmune[0] == nil,
        "'me' entries are never marked immune")

    Cast.castWhat = realCastWhat
    package.loaded['modules.cast'] = nil
end

return M
