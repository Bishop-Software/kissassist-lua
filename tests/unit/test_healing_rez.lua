-- tests/unit/test_healing_rez.lua
-- Regression test for the rez-extraction bug: rez spells live in the [Heals]
-- Heals array tagged with a rez type (e.g. "Gift of Resurrection|0|rez"). The
-- .mac hoists these out of Heals into a dedicated AutoRez array at load
-- (mac:6087-6111); Heal.init must do the same so rezWithCheck/rezCheck can find
-- them. Previously the port read a nonexistent [Heals] AutoRez key, leaving
-- autoRezArray empty and the paladin never rezzing.
--
-- Drives the real Heal.init with a fake modules.config (feeds the Heals array)
-- and MockMQ for the Spell/Class TLOs, then asserts the heals-vs-rez partition.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_healing_rez')

    -- Borrow the real parseCondArray (config was evicted, so this is fresh/real),
    -- then swap in a fake Config that returns our Heals array and defaults for the
    -- rest. get() always receives a default from init, so unmapped keys are safe.
    local RealConfig = require('modules.config')
    local realParseCondArray = RealConfig.parseCondArray

    local healsInput = {
        'Lay on Hands|20|Me',                 -- heal (kept)
        "Marr's Gift|100|Me|Cond8",           -- heal w/ cond (kept)
        'Gift of Resurrection|0|rez',         -- rez (hoisted)
        'Battlefield Rez|0|rezcombat',        -- combat-only rez (hoisted)
        'Quiet Rez|0|rezooc',                 -- ooc-only rez (hoisted)
        'Blessed Rez|0|rez|Cond5',            -- rez w/ cond (hoisted, condNo preserved)
    }

    local fakeCfg = { Heals = { Heals = healsInput } }
    local FakeConfig = {
        parseCondArray = realParseCondArray,
        get = function(section, key, default)
            local sec = fakeCfg[section]
            local v   = sec and sec[key]
            if v == nil then return default end
            return v
        end,
    }

    -- Install the fake and evict healing so it re-requires with the fake bound.
    package.loaded['modules.config']  = FakeConfig
    package.loaded['modules.healing'] = nil
    local Heal = require('modules.healing')

    -- TLOs Heal.init touches: class (for medStat) and Spell(x).TargetType/Range
    -- (for the groupHeal/singleHealPoint derivations). Non-group single spells.
    MockMQ.set('TLO.Me.Class.ShortName', 'PAL')
    MockMQ.set('TLO.Spell', function()
        return {
            TargetType = function() return 'Single' end,
            Range      = function() return 0 end,
        }
    end)

    -- Minimal state: only the heal sub-table (arrays + the singleHealPoint scalars
    -- read before their defaults are applied) and a session table for session.heals.
    local state = {
        session = {},
        heal = {
            healsArray           = {},
            groupHealArray       = {},
            groupHealTimers      = {},
            autoRezArray         = {},
            curesArray           = {},
            singleHealPoint      = 0,
            singleHealPointMA    = 0,
            singleHealPointRange = 0,
        },
    }
    local utils = { debug = function() end }
    local noop  = {}

    Heal.init(state, utils, noop, noop, noop, noop)

    -- Rez entries hoisted into autoRezArray, in original order --------------------
    local rez = state.heal.autoRezArray
    TH.assert_eq(#rez, 4, 'autoRezArray has 4 rez entries')
    TH.assert_eq(rez[1] and rez[1].name, 'Gift of Resurrection|0|rez', 'rez[1] = plain rez')
    TH.assert_eq(rez[2] and rez[2].name, 'Battlefield Rez|0|rezcombat', 'rez[2] = rezcombat')
    TH.assert_eq(rez[3] and rez[3].name, 'Quiet Rez|0|rezooc',          'rez[3] = rezooc')
    TH.assert_eq(rez[4] and rez[4].name, 'Blessed Rez|0|rez',           'rez[4] = rez (cond stripped from name)')
    TH.assert_eq(rez[4] and rez[4].condNo, 5, 'rez[4] preserves condNo=5')

    -- Non-rez heals kept in healsArray, rez entries excluded ----------------------
    local heals = state.heal.healsArray
    TH.assert_eq(#heals, 2, 'healsArray keeps only the 2 non-rez entries')
    TH.assert_eq(heals[1] and heals[1].name, 'Lay on Hands|20', 'heals[1] = Lay on Hands')
    TH.assert_eq(heals[2] and heals[2].name, "Marr's Gift|100|Me", 'heals[2] = Marr\'s Gift')

    -- No rez spell leaked into the heal rotation ---------------------------------
    for i, e in ipairs(heals) do
        local rezType = (e.name:match('^[^|]+|[^|]+|([^|]*)') or ''):lower()
        TH.assert_false(rezType:find('rez', 1, true) ~= nil,
            'healsArray[' .. i .. '] is not a rez entry')
    end

    -- Cleanup: evict the fake so later suites re-require the real config/healing.
    package.loaded['modules.config']  = nil
    package.loaded['modules.healing'] = nil
end

return M
