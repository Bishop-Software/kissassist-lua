-- tests/unit/test_weave.lua
-- |weave DPS entries (#296): Settings.splitDps routes tagged entries (case-insensitive,
-- like the mac's ${String.Find[]}) and Cast.castWeave mirrors Sub CastWeave (mac:3004).
local M = {}

local function nulls(n)
    local t = {}
    for i = 1, n do t[i] = 'null' end
    return t
end

function M.run(TH, MockMQ)
    TH.setSuite('test_weave')
    MockMQ.reset()

    -- ── Settings.splitDps ────────────────────────────────────────────────────
    local Settings = require('modules.combat.settings')
    local s = {
        combat = {},
        arrays = { mashArray = nulls(10), beforeArray = nulls(5), weaveArray = nulls(5) },
    }
    Settings.splitDps(s, {
        'Repudiate|99|Tap|Mash',
        'Bash|99|ambush',
        'Duskbringer Chest|99|Tap|Weave|Cond28',
        'Ecliptic Fang|98',
        'null',
        'Unified Phoenix Feather|93|weave',
    })
    TH.assert_eq(s.arrays.mashArray[1], 'Repudiate|99|Tap', 'split: |Mash (any case) -> mashArray, tag stripped')
    TH.assert_eq(s.arrays.mashArray[2], 'null', 'split: one mash entry')
    TH.assert_eq(s.arrays.beforeArray[1], 'Bash|99', 'split: |ambush -> beforeArray')
    TH.assert_eq(s.arrays.weaveArray[1], 'Duskbringer Chest|99|Tap|Cond28', 'split: |Weave -> weaveArray, cond kept')
    TH.assert_eq(s.arrays.weaveArray[2], 'Unified Phoenix Feather|93', 'split: |weave -> weaveArray')
    TH.assert_eq(s.arrays.weaveArray[3], 'null', 'split: two weave entries')
    TH.assert_eq(#s.combat.dpsArray, 1, 'split: only untagged entries in the rotation')
    TH.assert_eq(s.combat.dpsArray[1].name, 'Ecliptic Fang|98', 'split: rotation entry')

    -- Re-split (DPS editor) clears stale tag entries.
    Settings.splitDps(s, { 'Ecliptic Fang|98' })
    TH.assert_eq(s.arrays.weaveArray[1], 'null', 're-split: weaveArray cleared')
    TH.assert_eq(s.arrays.mashArray[1], 'null', 're-split: mashArray cleared')
    TH.assert_eq(s.arrays.beforeArray[1], 'null', 're-split: beforeArray cleared')
    TH.assert_eq(#s.combat.dpsArray, 1, 're-split: rotation rebuilt')

    -- ── Cast.castWeave ───────────────────────────────────────────────────────
    local Utils = require('modules.utils')
    local Cast  = require('modules.cast')
    local state = {
        cast    = {},
        session = {},
        combat  = { dpsOn = true, dpsOnOoc = false, myTargetID = 42 },
        arrays  = { weaveArray = nulls(5) },
    }
    Cast.init(state, Utils)
    Cast.setCond({ eval = function(n) return n ~= 5 end })   -- Cond5 is false

    local function callable(v) return function() return v end end
    local calls = {}
    local realCastWhat = Cast.castWhat
    Cast.castWhat = function(name, id) calls[#calls + 1] = name .. '@' .. tostring(id); return 'CAST_SUCCESS' end

    -- env = { state=, hp=, type=, aa={}, item={}, disc={} (ranked names owned/ready) }
    local function setEnv(env)
        MockMQ.reset()
        calls = {}
        MockMQ.set('TLO.Me.State', env.state or 'STAND')
        MockMQ.set('TLO.Spawn', function()
            return { ID = callable(42), Type = callable(env.type or 'NPC'), PctHPs = callable(env.hp or 50) }
        end)
        local aa, item, disc = env.aa or {}, env.item or {}, env.disc or {}
        MockMQ.set('TLO.Me.AltAbilityReady',    function(n) return callable(aa[n] == true) end)
        MockMQ.set('TLO.Me.ItemReady',          function(n) return callable(item[n] == true) end)
        MockMQ.set('TLO.Me.CombatAbilityReady', function(n) return callable(disc[n] == true) end)
        MockMQ.set('TLO.Me.CombatAbility',      function(n) return callable(disc[n] and 1 or nil) end)
        MockMQ.set('TLO.Me.Book',               function() return callable(nil) end)
        MockMQ.set('TLO.Me.Gem',                function() return callable(nil) end)
    end
    local function weave(list)
        for i = 1, 5 do state.arrays.weaveArray[i] = list[i] or 'null' end
    end

    weave({ 'Unified Phoenix Feather|93', 'Duskbringer Chest|99|Cond5' })

    -- DPSOn=1: entry HP% above the mob's HP is skipped; Cond5 false skips the other.
    setEnv({ hp = 95, item = { ['Unified Phoenix Feather'] = true, ['Duskbringer Chest'] = true } })
    TH.assert_false(Cast.castWeave(42), 'castWeave: HP% gate and false cond -> nothing cast')
    TH.assert_eq(#calls, 0, 'castWeave: no castWhat calls')

    -- Mob below the entry's HP%: the ready item fires.
    setEnv({ hp = 90, item = { ['Unified Phoenix Feather'] = true } })
    TH.assert_true(Cast.castWeave(42), 'castWeave: ready item below HP% -> cast')
    TH.assert_eq(calls[1], 'Unified Phoenix Feather@42', 'castWeave: castWhat(name, target)')

    -- DPSOn=2 ignores the per-entry HP%.
    state.combat.dpsOnOoc = true
    setEnv({ hp = 95, item = { ['Unified Phoenix Feather'] = true } })
    TH.assert_true(Cast.castWeave(42), 'castWeave: DPSOn=2 ignores HP%')
    state.combat.dpsOnOoc = false

    -- Nothing ready -> nothing cast (spells are never woven).
    setEnv({ hp = 50 })
    TH.assert_false(Cast.castWeave(42), 'castWeave: nothing ready -> false')

    -- Disc named without its rank is found ready through the owned rank.
    weave({ 'Fyrthek Mantle|99' })
    setEnv({ hp = 50, disc = { ['Fyrthek Mantle Rk. II'] = true } })
    TH.assert_true(Cast.castWeave(42), 'castWeave: base disc name ready via owned rank')

    -- Corpse target, not standing, and an entry with no HP% all end the pass.
    setEnv({ hp = 50, type = 'Corpse', disc = { ['Fyrthek Mantle Rk. II'] = true } })
    TH.assert_false(Cast.castWeave(42), 'castWeave: corpse target -> false')
    setEnv({ hp = 50, state = 'SIT', disc = { ['Fyrthek Mantle Rk. II'] = true } })
    TH.assert_false(Cast.castWeave(42), 'castWeave: not standing -> false')
    weave({ 'Fyrthek Mantle' })
    setEnv({ hp = 50, disc = { ['Fyrthek Mantle Rk. II'] = true } })
    TH.assert_false(Cast.castWeave(42), 'castWeave: entry without HP% -> false')

    Cast.castWhat = realCastWhat
end

return M
