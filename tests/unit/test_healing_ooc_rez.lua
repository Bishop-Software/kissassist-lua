-- tests/unit/test_healing_ooc_rez.lua
-- #335 part 2: the out-of-combat rez pass in Sub RezCheck (mac:6976-7018). Out of
-- combat, nearby PC corpses of guild mates, fellowship members, or on an XTarHeal
-- XTarget slot are rezzed, each at most every 3 minutes. Other corpses are left
-- to AutoRezAll; a Call of the Wild style rez skips players already in zone.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_healing_ooc_rez')

    local RealConfig = require('modules.config')
    package.loaded['modules.config'] = {
        parseCondArray = RealConfig.parseCondArray,
        get = function(_, _, default) return default end,
    }
    package.loaded['modules.healing'] = nil
    local Heal = require('modules.healing')

    MockMQ.set('TLO.Me.Class.ShortName', 'CLR')
    MockMQ.set('TLO.Spell', function(name)
        return { TargetType = function() return 'Single' end, Range = function() return 100 end,
                 RankName = function() return name end }
    end)
    local state = {
        session = { mainAssist = '' },
        combat  = { aggroTargetID = '', combatStart = false, xTSlot = 1, xSlotTotal = 20 },
        cast    = { castReturn = '' },
        misc    = { dmz = false },
        movement = { campRadius = 60 },
        heal = {
            healsArray = {}, groupHealArray = {}, groupHealTimers = {},
            autoRezOn = 0, autoRezArray = {}, curesArray = {},
            singleHealPoint = 0, singleHealPointMA = 0, singleHealPointRange = 0,
            oocRezTimers = {}, battleRezTimers = {}, corpseRezCheck = 'null',
        },
    }
    local casts, said = {}, {}
    local cast = {
        castWhat = function(spell, id, from)
            casts[#casts + 1] = string.format('%s@%d:%s', spell, id, from)
            state.cast.castReturn = 'CAST_SUCCESS'
        end,
    }
    local comms = { announce = function(msg) said[#said + 1] = msg end }
    Heal.init(state, { debug = function() end }, cast, {}, {}, comms)
    local h = state.heal
    h.autoRezOn    = 1
    h.autoRezAll   = false
    h.autoRezArray = { { name = 'Resurrection|0|rez', condNo = 0 } }
    h.xTarHeal     = 1
    h.xTarToHeal   = { 1, 3 }  -- slot 1 is the Auto Hater slot (xTSlot): ignored

    MockMQ.set('TLO.Me.SpellReady', function() return function() return true end end)
    MockMQ.set('TLO.Me.CleanName', 'Me')
    local myGuild = 'Knights'
    MockMQ.set('TLO.Me.Guild', function() return myGuild end)

    -- The corpses, nearest first.
    local corpses = {
        { id = 101, name = "Guildie's corpse",  guild = 'Knights' },
        { id = 102, name = "Stranger's corpse", guild = 'Others' },
        { id = 103, name = "Pal's corpse",      guild = '' },        -- fellowship member
        { id = 104, name = "Xt's corpse",       guild = '' },        -- on XTarget slot 3
        { id = 105, name = "Hater's corpse",    guild = '' },        -- on the Auto Hater slot
    }
    local inZone = {}
    -- SpawnCount(q) and Me.SpellReady(x) are called twice (TLO(q)()), so return callables.
    MockMQ.set('TLO.SpawnCount', function(q)
        local n = 0
        local who = q:match('^pc =(.+)$')
        if q:find('^pccorpse') then n = #corpses
        elseif who then n = inZone[who] and 1 or 0 end
        return function() return n end
    end)
    MockMQ.set('TLO.NearestSpawn', function(j)
        local c = corpses[j]
        return { ID = function() return c and c.id end, Type = function() return 'Corpse' end,
                 CleanName = function() return c and c.name end, Guild = function() return c and c.guild end }
    end)
    MockMQ.set('TLO.Spawn', function() return { ID = function() return 0 end } end)  -- no own corpse
    MockMQ.set('TLO.Me.Fellowship.Member', function(name)
        if name == 'Pal' then return function() return 'Pal' end end
        return nil
    end)
    local xt = { [1] = 105, [3] = 104 }
    MockMQ.set('TLO.Me.XTarget', function(slot)
        return { ID = function() return xt[slot] or 0 end, Type = function() return 'Corpse' end }
    end)
    -- /tar id N targets N.
    MockMQ.set('TLO.Target.ID', function()
        local calls = MockMQ.calls()
        for i = #calls, 1, -1 do
            local id = calls[i]:match('/tar id (%d+)')
            if id then return tonumber(id) end
        end
        return 0
    end)
    MockMQ.set('TLO.Target.Distance', 20)

    local function has(list, v)
        for _, x in ipairs(list) do if x == v then return true end end
        return false
    end

    Heal.rezCheck()
    TH.assert_true(has(casts, 'Resurrection@101:RezCheckX'), 'guild mate corpse rezzed')
    TH.assert_false(has(casts, 'Resurrection@102:RezCheckX'), 'stranger corpse not rezzed')
    TH.assert_true(has(casts, 'Resurrection@103:RezCheckX'), 'fellowship member corpse rezzed')
    TH.assert_true(has(casts, 'Resurrection@104:RezCheckX'), 'XTarHeal XTarget corpse rezzed')
    TH.assert_false(has(casts, 'Resurrection@105:RezCheckX'), 'corpse on the Auto Hater slot not rezzed')
    TH.assert_eq(#casts, 3, 'three OOC rezzes')
    TH.assert_true(has(said, "Rezzing =>> Guildie's corpse <<="), 'OOC rez is broadcast')
    TH.assert_true((h.oocRezTimers[101] or 0) > os.clock() + 170, 'OOC rez sets the 3-minute timer')

    -- Within 3 minutes: not rezzed again.
    casts = {}
    Heal.rezCheck()
    TH.assert_eq(#casts, 0, 'timers running: no repeat rez')

    -- In combat: no OOC pass.
    h.oocRezTimers = {}
    state.combat.combatStart = true
    Heal.rezCheck()
    TH.assert_eq(#casts, 0, 'in combat: no OOC rez')
    state.combat.combatStart = false

    -- XTarHeal off: the XTarget corpse no longer qualifies.
    h.xTarHeal = 0
    Heal.rezCheck()
    TH.assert_false(has(casts, 'Resurrection@104:RezCheckX'), 'XTarHeal off: XTarget corpse not rezzed')
    TH.assert_true(has(casts, 'Resurrection@101:RezCheckX'), 'XTarHeal off: guild mate still rezzed')
    h.xTarHeal = 1

    -- An unguilded rezzer doesn't treat unguilded corpses as guild mates.
    casts, h.oocRezTimers = {}, {}
    myGuild = ''
    Heal.rezCheck()
    TH.assert_false(has(casts, 'Resurrection@101:RezCheckX'), 'unguilded: other guild corpse not rezzed')
    TH.assert_false(has(casts, 'Resurrection@105:RezCheckX'), 'unguilded: unguilded corpse not rezzed')
    TH.assert_true(has(casts, 'Resurrection@103:RezCheckX'), 'unguilded: fellowship corpse still rezzed')
    myGuild = 'Knights'

    -- RezGuildFellowship off: guild and fellowship corpses are left alone, the
    -- XTarHeal XTarget corpse is still rezzed; with XTarHeal off too, nothing is.
    TH.assert_true(h.rezGuildFellowship, 'RezGuildFellowship defaults on')
    casts, h.oocRezTimers = {}, {}
    h.rezGuildFellowship = false
    Heal.rezCheck()
    TH.assert_false(has(casts, 'Resurrection@101:RezCheckX'), 'RezGuildFellowship off: guild corpse not rezzed')
    TH.assert_false(has(casts, 'Resurrection@103:RezCheckX'), 'RezGuildFellowship off: fellowship corpse not rezzed')
    TH.assert_true(has(casts, 'Resurrection@104:RezCheckX'), 'RezGuildFellowship off: XTarget corpse still rezzed')
    casts, h.oocRezTimers = {}, {}
    h.xTarHeal = 0
    Heal.rezCheck()
    TH.assert_eq(#casts, 0, 'RezGuildFellowship and XTarHeal off: no OOC rez')
    h.xTarHeal, h.rezGuildFellowship = 1, true

    -- A Call of the Wild style rez skips a player already in zone.
    casts, h.oocRezTimers = {}, {}
    h.autoRezArray = { { name = 'Call of the Wild|0|rez', condNo = 0 } }
    inZone.Guildie = true
    Heal.rezCheck()
    TH.assert_false(has(casts, 'Call of the Wild@101:RezCheckX'), 'Call of the Wild: player in zone skipped')
    TH.assert_true(has(casts, 'Call of the Wild@103:RezCheckX'), 'Call of the Wild: player out of zone rezzed')

    package.loaded['modules.healing'] = nil
    package.loaded['modules.config']  = nil
end

return M
