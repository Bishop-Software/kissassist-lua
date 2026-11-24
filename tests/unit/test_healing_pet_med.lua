-- tests/unit/test_healing_pet_med.lua
-- #335 part 1: DoPetMedStuff (end of Sub DoWeMed, mac:4141-4163). A pullerpettank
-- or hunterpettank whose pet is at or below 50% (or with PetForceHealOnMed) holds
-- pulls (heal.petMedding) and heals the pet with a |pet heal until it reaches
-- MedStop; the pet dying or a mob getting aggro ends the hold.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_healing_pet_med')

    local RealConfig = require('modules.config')
    package.loaded['modules.config'] = {
        parseCondArray = RealConfig.parseCondArray,
        get = function(_, _, default) return default end,
    }
    package.loaded['modules.healing'] = nil
    local Heal = require('modules.healing')

    MockMQ.set('TLO.Me.Class.ShortName', 'NEC')
    MockMQ.set('TLO.Spell', function()
        return { TargetType = function() return 'Single' end, Range = function() return 100 end }
    end)
    local state = {
        session = { mainAssist = '', role = 'assist' },
        combat  = { aggroTargetID = '', xTSlot = 1, xSlotTotal = 20 },
        cast    = { castReturn = '' },
        pet     = { on = true, forceHealOnMed = false },
        pull    = { pauseHold = false },
        heal = {
            healsArray = {}, groupHealArray = {}, groupHealTimers = {},
            autoRezOn = 0, autoRezArray = {}, curesArray = {},
            singleHealPoint = 0, singleHealPointMA = 0, singleHealPointRange = 0,
        },
    }
    local casts, said = {}, {}
    local cast = {
        castWhat = function(spell, id)
            casts[#casts + 1] = spell .. '@' .. id
            state.cast.castReturn = 'CAST_SUCCESS'
        end,
    }
    local comms = { announce = function(msg) said[#said + 1] = msg end }
    Heal.init(state, { debug = function() end }, cast, {}, {}, comms)
    local h = state.heal
    h.healsArray = {
        { name = 'Mend Bones|60|pet',  condNo = 0 },
        { name = 'Renew Bones|80|pet', condNo = 0 },
        { name = 'Dead Heal|0|pet',    condNo = 0 },  -- HP field 0: skipped (mac:4148)
        { name = 'Self Heal|50|Me',    condNo = 0 },
    }

    local pet = { id = 77, pct = 70, dist = 30 }
    MockMQ.set('TLO.Me.Pet.ID', function() return pet.id end)
    MockMQ.set('TLO.Me.Pet.PctHPs', function() return pet.pct end)
    MockMQ.set('TLO.Me.Pet.Distance', function() return pet.dist end)
    MockMQ.set('TLO.Me.Pet.CleanName', 'Bonez')
    local invis = false
    MockMQ.set('TLO.Me.Invis', function() return invis end)

    local function reset() casts = {}; said = {} end

    -- Not a pet-tank puller: never holds.
    pet.pct = 40
    Heal.doPetMedStuff()
    TH.assert_false(h.petMedding, 'assist role: no pet heal hold')
    TH.assert_eq(#casts, 0, 'assist role: no pet heal cast')

    state.session.role = 'pullerpettank'
    -- Above 50% without PetForceHealOnMed: no hold.
    pet.pct = 70
    Heal.doPetMedStuff()
    TH.assert_false(h.petMedding, 'pet at 70%: no hold')
    TH.assert_eq(#casts, 0, 'pet at 70%: no cast')

    -- Invisible: the hold doesn't start (a cast would break invis).
    pet.pct = 40
    invis = true
    Heal.doPetMedStuff()
    TH.assert_false(h.petMedding, 'invisible: no hold')
    TH.assert_eq(#casts, 0, 'invisible: no cast')
    invis = false

    -- At or below 50%: hold pulls and heal, bottom of the list first, skipping HP 0.
    pet.pct = 50
    Heal.doPetMedStuff()
    TH.assert_true(h.petMedding, 'pet at 50%: pulls held')
    TH.assert_eq(casts[1], 'Renew Bones@77', 'pet at 50%: last |pet heal with a non-zero HP field')
    TH.assert_eq(said[1], 'Renew Bones on  >> Bonez <<', 'pet heal is broadcast')

    -- Still under MedStop: keeps holding and healing, even above 50%.
    reset()
    pet.pct = 90
    Heal.doPetMedStuff()
    TH.assert_true(h.petMedding, 'pet at 90%: still held (MedStop 100)')
    TH.assert_eq(#casts, 1, 'pet at 90%: heals again')

    -- Out of range: still held, nothing cast.
    reset()
    pet.dist = 150
    Heal.doPetMedStuff()
    TH.assert_true(h.petMedding, 'pet out of range: still held')
    TH.assert_eq(#casts, 0, 'pet out of range: no cast')
    pet.dist = 30

    -- Reaching MedStop ends the hold.
    pet.pct = 100
    Heal.doPetMedStuff()
    TH.assert_false(h.petMedding, 'pet at MedStop: hold ends')

    -- PetForceHealOnMed: holds above 50% too (hunterpettank as well).
    state.session.role = 'hunterpettank'
    state.pet.forceHealOnMed = true
    pet.pct = 90
    Heal.doPetMedStuff()
    TH.assert_true(h.petMedding, 'PetForceHealOnMed: held at 90%')

    -- A mob on us ends the hold.
    state.combat.aggroTargetID = '500'
    Heal.doPetMedStuff()
    TH.assert_false(h.petMedding, 'mob aggro: hold ends')
    state.combat.aggroTargetID = ''

    -- The pet dying ends the hold.
    Heal.doPetMedStuff()
    TH.assert_true(h.petMedding, 'held again')
    pet.id = 0
    Heal.doPetMedStuff()
    TH.assert_false(h.petMedding, 'pet gone: hold ends')
    pet.id = 77

    -- doWeMed runs it, and MedOn off clears the hold.
    MockMQ.set('TLO.Me.PctMana', 100)
    MockMQ.set('TLO.Me.Sitting', false)
    MockMQ.set('TLO.Window', function() return { Open = function() return false end } end)
    Heal.doWeMed()
    TH.assert_true(h.petMedding, 'doWeMed starts the pet heal hold')
    h.medOn = false
    Heal.doWeMed()
    TH.assert_false(h.petMedding, 'MedOn off: pet heal hold ends')

    package.loaded['modules.healing'] = nil
    package.loaded['modules.config']  = nil
end

return M
