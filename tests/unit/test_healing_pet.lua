-- tests/unit/test_healing_pet.lua
-- #278 parts 2 and 3: DoPetHealStuff (mac:6777-6795) heals my own pet from the
-- heal list's 'pet' entries, and HealAgain (mac:6383-6385) re-runs the heal
-- pass straight after a heal lands or a cast is cancelled.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_healing_pet')

    local RealConfig = require('modules.config')
    package.loaded['modules.config'] = {
        parseCondArray = RealConfig.parseCondArray,
        get = function(_, _, default) return default end,
    }
    package.loaded['modules.healing'] = nil
    local Heal = require('modules.healing')

    local myClass, selfClass = 'NEC', 'NEC'
    MockMQ.set('TLO.Me.Class.ShortName', function() return myClass end)
    local state = {
        session = { mainAssist = '' },
        combat  = { aggroTargetID = '', xTSlot = 1, xSlotTotal = 20 },
        cast    = { castReturn = '' },
        pet     = { on = true },
        heal = {
            healsArray = {}, groupHealArray = {}, groupHealTimers = {},
            autoRezOn = 0, autoRezArray = {}, curesArray = {},
            singleHealPoint = 0, singleHealPointMA = 0, singleHealPointRange = 0,
        },
    }
    local casts, result = {}, 'CAST_SUCCESS'
    local cast = {
        castWhat = function(spell, id) casts[#casts + 1] = spell .. '@' .. id; state.cast.castReturn = result end,
    }
    Heal.init(state, { debug = function() end }, cast, {}, {}, {})
    local h = state.heal

    local pet = { id = 77, pct = 50, dist = 30 }
    MockMQ.set('TLO.Me.Pet.ID', function() return pet.id end)
    MockMQ.set('TLO.Me.Pet.PctHPs', function() return pet.pct end)
    MockMQ.set('TLO.Me.Pet.Distance', function() return pet.dist end)
    MockMQ.set('TLO.Me.Pet.CleanName', 'Fido')
    MockMQ.set('TLO.Spell', function()
        return { TargetType = function() return 'Single' end, Range = function() return 100 end,
                 AERange = function() return 0 end }
    end)
    local selfPct = 100
    MockMQ.set('TLO.Me.PctHPs', function() return selfPct end)
    MockMQ.set('TLO.Me.ID', 1)
    MockMQ.set('TLO.Me.CleanName', 'Me')
    MockMQ.set('TLO.Spawn', function(q)
        local isMe = q == 'id 1'
        return { ID = function() return isMe and 1 or 0 end, Type = function() return 'PC' end,
                 Distance = function() return 0 end,
                 Class = { ShortName = function() return selfClass end } }
    end)
    MockMQ.set('TLO.Group.Members', 0)
    MockMQ.set('TLO.Group.AvgHPs', 100)
    MockMQ.set('TLO.Group.Injured', function() return function() return 0 end end)

    h.healsOn, h.singleHealPoint, h.singleHealPointRange = 1, 80, 100

    local function run()
        casts = {}
        Heal.checkHealth('test')
        return casts
    end

    -- ---- DoPetHealStuff ----
    h.healsArray = { { name = 'Remedy|90', condNo = 0 }, { name = 'Mend Companion|60|pet', condNo = 0 } }
    result = 'CAST_NOTREADY'
    TH.assert_eq(table.concat(run(), ' '), 'Mend Companion@77', 'non-healer class: pet healed with the pet entry')
    pet.pct = 70
    TH.assert_eq(#run(), 0, 'pet above the entry HP%: not healed')
    pet.pct, pet.dist = 50, 150
    TH.assert_eq(#run(), 0, 'pet out of spell range: not healed')
    pet.dist, state.pet.on = 30, false
    TH.assert_eq(#run(), 0, 'PetOn off: pet not healed')
    state.pet.on, pet.id = true, 0
    TH.assert_eq(#run(), 0, 'no pet: nothing healed')
    pet.id = 77
    h.healsArray = { { name = 'Mend Companion|60|pet', condNo = 0 }, { name = 'Bigger Mend|60|pet', condNo = 0 } }
    TH.assert_eq(#run(), 2, 'a heal that fails moves on to the next pet entry')

    -- ---- HealAgain ----
    result = 'CAST_SUCCESS'
    TH.assert_eq(#run(), 5, 'pet heal lands: re-scan, capped at 5 passes')
    pet.pct = 100
    h.healsArray = { { name = 'Remedy|90', condNo = 0 } }
    selfPct = 50
    TH.assert_eq(#run(), 5, 'self heal lands: re-scan, capped at 5 passes')
    result = 'CAST_CANCELLED'
    TH.assert_eq(#run(), 5, 'self heal cancelled: re-scan')
    result = 'CAST_NEEDMANA'
    TH.assert_eq(#run(), 1, 'out of mana: no re-scan')
    result, selfClass = 'CAST_SUCCESS', 'BER'
    TH.assert_eq(#run(), 1, 'heal on a berserker lands: no re-scan (mac:6716)')
    selfClass = 'NEC'
    TH.assert_false(h.healAgain, 'HealAgain cleared when checkHealth returns')

    package.loaded['modules.healing'] = nil
    package.loaded['modules.config']  = nil
end

return M
