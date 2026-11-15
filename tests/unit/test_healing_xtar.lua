-- tests/unit/test_healing_xtar.lua
-- #278 part 1: XTarHeal - heal the people in chosen XTarget slots.
-- Heal.setXTargetHealList ports SetXTargetHealList (mac:15266); the
-- checkHealth most-hurt scan covers the XTarget slots (mac:6446, 6497).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_healing_xtar')

    local RealConfig = require('modules.config')
    package.loaded['modules.config'] = {
        parseCondArray = RealConfig.parseCondArray,
        get = function(_, _, default) return default end,
    }
    package.loaded['modules.healing'] = nil
    local Heal = require('modules.healing')

    MockMQ.set('TLO.Me.Class.ShortName', 'CLR')
    local state = {
        session = { mainAssist = '' },
        combat  = { aggroTargetID = '', xTSlot = 1, xSlotTotal = 20 },
        cast    = { castReturn = '' },
        heal = {
            healsArray = {}, groupHealArray = {}, groupHealTimers = {},
            autoRezArray = {}, curesArray = {},
            singleHealPoint = 0, singleHealPointMA = 0, singleHealPointRange = 0,
        },
    }
    local casts = {}
    local cast  = {
        castWhat = function(_, id) casts[#casts + 1] = id; state.cast.castReturn = 'CAST_SUCCESS' end,
    }
    Heal.init(state, { debug = function() end }, cast, {}, {}, {})
    local h = state.heal
    TH.assert_eq(h.xTarHeal, 0, 'XTarHeal defaults to 0 (off)')

    -- ---- slot list (SetXTargetHealList) ----
    local types = { [1] = 'Auto Hater', [2] = 'Auto Hater', [3] = 'Specific PC', [4] = 'Target' }
    MockMQ.set('TLO.Me.XTarget', function(i)
        return { TargetType = function() return types[i] or 'Empty Target' end }
    end)
    local function list(v) return table.concat(Heal.setXTargetHealList(v), ',') end
    TH.assert_eq(list('5|6|7'), '5,6,7', '5|6|7: those slots')
    TH.assert_eq(list('5'), '5', 'single slot')
    TH.assert_eq(list('3|0|5'), '3', 'a 0 ends the list')
    TH.assert_eq(list('25|4'), '4', 'slots past the XTarget total are skipped')
    TH.assert_eq(list('Xtar slots here Example: 5|6|7'), '', 'mac placeholder text: no slots')
    TH.assert_eq(list(''), '', 'empty: no slots')
    TH.assert_eq(list('null'), '', 'null: no slots')
    state.combat.xSlotTotal = 5
    TH.assert_eq(list('all'), '3,4,5', 'all: every slot but Auto Hater')
    TH.assert_eq(list('AUTO'), '3,4,5', 'auto (any case): same as all')
    TH.assert_eq(list('autopc'), '3', 'autopc: Specific PC slots only')
    state.combat.xSlotTotal = 20

    -- ---- most-hurt scan ----
    local xt = {}  -- slot -> {id, pct, dist, type}
    MockMQ.set('TLO.Me.XTarget', function(i)
        local e = xt[i] or { id = 0, pct = 100, dist = 0, type = '' }
        return {
            ID = function() return e.id end, PctHPs = function() return e.pct end,
            Distance = function() return e.dist end, Type = function() return e.type end,
            CleanName = function() return 'Friend' .. i end,
            TargetType = function() return 'Specific PC' end,
        }
    end)
    MockMQ.set('TLO.Spawn', function(q)
        local id = tonumber(q:match('^id (%d+)$'))
        local e
        for _, v in pairs(xt) do if v.id == id then e = v end end
        return {
            ID = function() return e and e.id or 0 end, Type = function() return e and e.type or '' end,
            Distance = function() return e and e.dist or 9999 end,
            Class = { ShortName = function() return 'WAR' end },
        }
    end)
    MockMQ.set('TLO.Spell', function()
        return { TargetType = function() return 'Single' end, Range = function() return 200 end,
                 AERange = function() return 0 end }
    end)
    MockMQ.set('TLO.Me.PctHPs', 100)
    MockMQ.set('TLO.Me.ID', 1)
    MockMQ.set('TLO.Group.Members', 0)
    MockMQ.set('TLO.Group.AvgHPs', 100)
    -- checkHealth calls Group.Injured(90)() for the group-heal check (CLR can group heal)
    MockMQ.set('TLO.Group.Injured', function() return function() return 0 end end)

    h.healsOn, h.singleHealPoint, h.singleHealPointRange = 2, 80, 100
    h.healsArray = { { name = 'Remedy|90', condNo = 0 } }
    h.autoRezOn = 0

    local function scan(mode, slots)
        casts = {}
        h.xTarHeal, h.xTarToHeal = mode, slots
        Heal.checkHealth('test')
        return casts[1]
    end

    xt = { [3] = { id = 50, pct = 40, dist = 50, type = 'PC' } }
    TH.assert_eq(scan(2, { 3 }), 50, 'XTarget only: hurt XTarget PC healed')
    TH.assert_eq(scan(1, { 3 }), 50, 'group + XTarget, no group: XTarget PC healed')
    TH.assert_nil(scan(0, { 3 }), 'XTarHeal off: XTarget PC not healed')
    TH.assert_nil(scan(2, {}), 'no slots: nobody healed')

    xt = { [3] = { id = 50, pct = 60, dist = 50, type = 'PC' }, [4] = { id = 51, pct = 30, dist = 50, type = 'PC' } }
    TH.assert_eq(scan(2, { 3, 4 }), 51, 'most hurt slot is healed first')

    xt = { [1] = { id = 52, pct = 10, dist = 50, type = 'NPC' }, [3] = { id = 50, pct = 60, dist = 50, type = 'PC' } }
    TH.assert_eq(scan(2, { 1, 3 }), 50, 'the Auto Hater slot (mobs) is skipped')

    xt = { [3] = { id = 50, pct = 40, dist = 150, type = 'PC' } }
    TH.assert_nil(scan(2, { 3 }), 'out of SingleHealPointRange: not healed')
    xt = { [3] = { id = 50, pct = 40, dist = 50, type = 'Corpse' } }
    TH.assert_nil(scan(2, { 3 }), 'corpse: not healed')
    xt = { [3] = { id = 50, pct = 90, dist = 50, type = 'PC' } }
    TH.assert_nil(scan(2, { 3 }), 'above SingleHealPoint: not healed')

    package.loaded['modules.healing'] = nil
    package.loaded['modules.config']  = nil
end

return M
