local mq     = require('mq')
local Config = require('modules.config')

local Pet = {}
local _state, _utils, _cast

-- Step 8.1: scaffold + INI wiring
-- Steps 8.2–8.3: Pet.doPetStuff + Pet.petToys (summon, focus swap, item-giving)
-- Step 8.4: Pet.checkRampPets (rampage-pet wait) + main loop wiring

function Pet.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    -- Load pet INI fields not already loaded by Buffs.init.
    -- Buffs.init owns: PetOn, PetShrinkOn, PetShrinkSpell, PetToysOn, PetToys.
    _state.pet.spell   = Config.get('Pet', 'PetSpell',   '') or ''
    _state.pet.focus   = Config.get('Pet', 'PetFocus',   '') or ''
    _state.pet.focusOn = Config.get('Pet', 'PetFocusOn', '0') == '1'
    _state.pet.holdOn  = Config.get('Pet', 'PetHoldOn',  '0') == '1'
    _state.pet.suspend = Config.get('Pet', 'PetSuspend', '0') == '1'

    _utils.debug('pet', 'Pet.init: spell=%s focusOn=%s holdOn=%s suspend=%s',
        _state.pet.spell, tostring(_state.pet.focusOn),
        tostring(_state.pet.holdOn), tostring(_state.pet.suspend))
end

return Pet
