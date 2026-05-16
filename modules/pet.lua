local mq     = require('mq')
local Config = require('modules.config')

local Pet = {}
local _state, _utils, _cast, _buffs

-- Roles where pet guard/follow stance is actively managed
local PULL_ROLES    = {puller=true, pullertank=true, pettank=true, pullerpettank=true}
-- Roles where pet taunt should be ON
local PETTANK_ROLES = {pettank=true, pullerpettank=true, hunterpettank=true}

-- ---------------------------------------------------------------------------
-- Step 8.1: Pet.init — scaffold + INI wiring
-- ---------------------------------------------------------------------------

function Pet.init(state, utils, cast, buffs)
    _state = state
    _utils = utils
    _cast  = cast
    _buffs = buffs

    -- Load pet INI fields not already loaded by Buffs.init.
    -- Buffs.init owns: on, shrinkOn, shrinkSpell, toysOn, toysArray.
    _state.pet.spell        = Config.get('Pet', 'PetSpell',        '') or ''
    _state.pet.focus        = Config.get('Pet', 'PetFocus',        '') or ''
    -- 0=off, 1=pending (send command once), 2=already sent this pet
    _state.pet.focusOn      = tonumber(Config.get('Pet', 'PetFocusOn', '0')) or 0
    _state.pet.holdOn       = tonumber(Config.get('Pet', 'PetHoldOn',  '0')) or 0
    _state.pet.suspend      = Config.get('Pet', 'PetSuspend',      '0') == '1'
    _state.pet.tauntOverride = Config.get('Pet', 'PetTauntOverride', '0') == '1'
    _state.pet.toysGave     = _state.pet.toysGave or ''

    _utils.debug('pet', 'Pet.init: spell=%s focusOn=%d holdOn=%d suspend=%s',
        _state.pet.spell, _state.pet.focusOn,
        _state.pet.holdOn, tostring(_state.pet.suspend))
end

-- ---------------------------------------------------------------------------
-- Step 8.2: petStateCheck + Pet.doPetStuff
-- ---------------------------------------------------------------------------

-- Toggle Companion's Suspension AA; updates state.pet.activeState after cast.
-- Mirrors Sub PetStateCheck (kissassist.mac:5191-5206).
local function petStateCheck()
    local suspAA = mq.TLO.Me.AltAbility("Companion's Suspension")
    if (suspAA() or 0) > 0 then
        while not mq.TLO.Me.AltAbilityReady("Companion's Suspension")() do
            printf('\awWaiting on Suspend Minion AA to be ready.')
            mq.delay(1000)
        end
        mq.cmd('/alt act ' .. (mq.TLO.Me.AltAbility("Companion's Suspension").ID() or 0))
        mq.delay(5000, function() return not (mq.TLO.Window('CastingWindow').Open() or false) end)
        mq.doevents()
    else
        printf('\awYou do not have the "Companion\'s Suspension" AA, PetSuspend being turned off.')
        _state.pet.suspend = false
    end
    if (mq.TLO.Me.Pet.ID() or 0) > 0 then
        _state.pet.activeState = 1
    end
end

-- Summon, focus-swap, stance, hold/focus setup for the pet.
-- Mirrors Sub DoPetStuff (kissassist.mac:5210-5398).
function Pet.doPetStuff()
    local s = _state

    -- Entry guards (mac:5211-5212)
    if not s.pet.on then return end
    if s.movement.campZone ~= mq.TLO.Zone.ID() then return end
    if (s.combat.aggroTargetID or 0) ~= 0 then return end
    if mq.TLO.Me.Invis() then return end
    if mq.TLO.Me.Hovering() then return end

    -- Event drain (mac:5213-5217)
    mq.doevents()

    local petSpell = s.pet.spell
    if petSpell == '' then return end

    -- Focus resolution: parse "FocusPet|FocusSlot|FocusBuff" (mac:5220-5233)
    local focusPet, focusSlot, focusBuff = '', '', ''
    if s.pet.focus ~= '' then
        local parts = {}
        for p in (s.pet.focus .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
        focusPet  = parts[1] or ''
        focusSlot = parts[2] or ''
        focusBuff = parts[3] or ''
    end
    local focusCurrent = ''
    if focusSlot == '' or focusSlot == 'null' then
        focusPet = ''; focusSlot = ''
    elseif focusSlot ~= 'buff' then
        focusCurrent = mq.TLO.Me.Inventory(focusSlot).Name() or ''
    else
        focusCurrent = focusBuff
    end
    local focusSwitch = false

    -- Familiar banish (mac:5234)
    local petCleanName = mq.TLO.Me.Pet.CleanName() or ''
    if petCleanName ~= '' and petCleanName == (mq.TLO.Me.Name() or '') .. "'s familiar" then
        mq.cmd('/pet get lost')
    end

    local hasPet  = (mq.TLO.Me.Pet.ID() or 0) > 0
    local petMana = mq.TLO.Spell(petSpell).Mana() or 999999
    local myMana  = mq.TLO.Me.CurrentMana() or 0

    -- -------------------------------------------------------------------------
    -- No-pet path (mac:5237-5352)
    -- -------------------------------------------------------------------------
    if not hasPet and petMana <= myMana then
        printf('\awI have no pet. %ss live longer when we have pets.', mq.TLO.Me.Class() or '')
        s.pet.activeState = 0
        s.pet.toysGave    = ''
        if s.pet.focusOn == 2 then s.pet.focusOn = 1 end
        if s.pet.holdOn  == 2 then s.pet.holdOn  = 1 end

        -- Focus item equip before summoning (mac:5245-5258)
        if focusPet ~= '' and (mq.TLO.FindItemCount('=' .. focusPet)() or 0) > 0 then
            if focusSlot ~= 'buff' then
                if not ((mq.TLO.Cursor.ID() or 0) > 0) and focusPet ~= focusCurrent then
                    mq.cmd(string.format('/exchange "%s" %s', focusPet, focusSlot))
                    focusSwitch = true
                    mq.delay(1000)
                end
            else
                if focusBuff ~= '' and focusBuff ~= 'null' then
                    if not ((mq.TLO.Me.Buff(focusBuff).ID() or 0) > 0)
                       and not ((mq.TLO.Me.Song(focusBuff).ID() or 0) > 0) then
                        _cast.castWhat(focusPet, mq.TLO.Me.ID(), 'DoPetStuff')
                    end
                end
            end
        end

        mq.doevents()
        mq.delay(300)

        if s.pet.suspend then
            -- Suspend path: unsuspend or summon (mac:5274-5306)
            if s.pet.totCount == 1 and s.pet.activeState == 0 and s.pet.suspendState == 1 then
                printf('\awI have a suspended pet, summoning it now!')
                petStateCheck()
            end
            local inBook = (mq.TLO.Me.Book(petSpell)() or 0) > 0
            if s.pet.totCount < 2 and s.pet.suspendState == 0 and s.pet.activeState == 0
               and inBook and petMana <= myMana then
                local deadline = mq.gettime() + 60000
                while mq.gettime() < deadline do
                    printf('\awARISE %s', petSpell)
                    local ret = _cast.castWhat(petSpell, mq.TLO.Me.ID(), 'DoPetStuff')
                    if ret == 'CAST_COMPONENTS' then
                        printf('\awYou are missing components to make this pet.')
                        return
                    end
                    mq.delay(1000, function() return (mq.TLO.Me.Pet.ID() or 0) > 0 end)
                    if (mq.TLO.Me.Pet.ID() or 0) > 0 then
                        printf('\awMy pet is now: %s from %s', mq.TLO.Me.Pet.CleanName() or '', petSpell)
                        s.pet.activeState = 1
                        _buffs.checkPetBuffs()
                        if s.pet.toysOn then
                            Pet.petToys(mq.TLO.Me.Pet.CleanName() or '')
                        end
                    end
                    petStateCheck()
                    if s.pet.totCount == 2 or not s.pet.suspend or mq.gettime() >= deadline then
                        break
                    end
                end
            end
        else
            -- Normal summon (mac:5307-5328)
            local inBook = (mq.TLO.Me.Book(petSpell)() or 0) > 0
            if inBook and petMana <= myMana then
                local deadline = mq.gettime() + 60000
                while mq.gettime() < deadline do
                    printf('\awARISE %s', petSpell)
                    local ret = _cast.castWhat(petSpell, mq.TLO.Me.ID(), 'DoPetStuff')
                    if ret == 'CAST_COMPONENTS' then
                        printf('\awYou are missing components to make this pet.')
                        return
                    end
                    mq.delay(1000, function() return (mq.TLO.Me.Pet.ID() or 0) > 0 end)
                    if mq.gettime() >= deadline or (mq.TLO.Me.Pet.ID() or 0) > 0 then break end
                end
                if (mq.TLO.Me.Pet.ID() or 0) > 0 then
                    printf('\awMy pet is now: %s from %s', mq.TLO.Me.Pet.CleanName() or '', petSpell)
                    s.pet.activeState = 1
                end
                -- Focus swap-back (mac:5324-5327)
                if focusSwitch and not ((mq.TLO.Cursor.ID() or 0) > 0) then
                    mq.cmd(string.format('/exchange "%s" %s', focusCurrent, focusSlot))
                    mq.delay(1000)
                end
            end
        end

        -- Pet stance after summon: puller/pettank roles (mac:5334-5344)
        local role = s.session.role
        if PULL_ROLES[role] then
            if not s.session.chaseAssist then
                local petDist = mq.TLO.Me.Pet.Distance() or 0
                local campRad = s.movement.campRadius or 100
                if petDist <= campRad then
                    if (mq.TLO.Pet.Stance() or '') ~= 'guard'  then mq.cmd('/pet guard') end
                else
                    if (mq.TLO.Pet.Stance() or '') ~= 'follow' then mq.cmd('/pet follow') end
                end
            else
                if (mq.TLO.Pet.Stance() or '') ~= 'follow' then mq.cmd('/pet follow') end
            end
        end
        if s.pet.holdOn == 1 then
            mq.cmd('/pet hold on')
            s.pet.holdOn = 2
        end
        if s.pet.focusOn == 1 then
            mq.cmd('/pet focus on')
            s.pet.focusOn = 2
        end

    -- -------------------------------------------------------------------------
    -- Has-pet path: maintain stance/hold/focus (mac:5353-5373)
    -- -------------------------------------------------------------------------
    elseif hasPet then
        local role = s.session.role
        if PULL_ROLES[role] then
            if not s.session.chaseAssist then
                local petDist = mq.TLO.Me.Pet.Distance() or 0
                local campRad = s.movement.campRadius or 100
                if petDist <= campRad then
                    if (mq.TLO.Pet.Stance() or '') ~= 'guard'  then mq.cmd('/pet guard') end
                else
                    if (mq.TLO.Pet.Stance() or '') ~= 'follow' then mq.cmd('/pet follow') end
                end
            else
                if (mq.TLO.Pet.Stance() or '') ~= 'follow' then mq.cmd('/pet follow') end
            end
        end
        if s.pet.holdOn == 1 then
            mq.cmd('/pet hold on')
            s.pet.holdOn = 2
        end
        if s.pet.focusOn == 1 then
            mq.cmd('/pet focus on')
            s.pet.focusOn = 2
        end
    end

    -- Taunt management (mac:5374-5382)
    if (mq.TLO.Me.Pet.ID() or 0) > 0 then
        if not s.pet.tauntOverride then
            if not (mq.TLO.Pet.Taunt() or false) then
                if PETTANK_ROLES[s.session.role] then mq.cmd('/pet taunt on') end
            else
                if not PETTANK_ROLES[s.session.role] then mq.cmd('/pet taunt off') end
            end
        end
    end

    -- checkPetBuffs (mac:5383)
    _buffs.checkPetBuffs()

    -- PetToys: give if pet present and not already given to this pet (mac:5386-5389)
    if (mq.TLO.Me.Pet.ID() or 0) > 0 and s.pet.toysOn then
        local curName = mq.TLO.Me.Pet.CleanName() or ''
        if not s.pet.toysGave:find(curName, 1, true)
           and not s.pet.toysGave:find('Summoned', 1, true) then
            Pet.petToys(curName)
            s.pet.toysGave = curName
        end
    end

    -- pettank/hunterpettank: if owner is away from camp but pet is guarding, follow owner (mac:5391)
    local role = s.session.role
    if role == 'pettank' or role == 'hunterpettank' then
        local myDist = math.sqrt(
            (mq.TLO.Me.Y() - s.movement.campY)^2 +
            (mq.TLO.Me.X() - s.movement.campX)^2)
        local petY   = mq.TLO.Me.Pet.Y() or s.movement.campY
        local petX   = mq.TLO.Me.Pet.X() or s.movement.campX
        local petDistFromCamp = math.sqrt(
            (petY - s.movement.campY)^2 +
            (petX - s.movement.campX)^2)
        local campRad = s.movement.campRadius or 100
        if myDist > campRad and petDistFromCamp <= campRad
           and (mq.TLO.Pet.Stance() or ''):upper() == 'GUARD' then
            mq.cmd('/pet follow')
        end
    end

    -- MiscGemRemem: remem misc gem if pet is out and gem drifted (mac:5392-5396)
    local miscGem = s.cast.miscGem or 0
    if (mq.TLO.Me.Pet.ID() or 0) > 0 and miscGem > 0 and (s.cast.miscGemRemem or 0) ~= 0 then
        local gemName = mq.TLO.Me.Gem(miscGem).Name() or ''
        if gemName ~= (s.cast.reMemMiscSpell or '') and _cast.castMemSpell then
            s.combat.dontMoveMe = true
            _cast.castMemSpell(s.cast.reMemMiscSpell, miscGem, false, 'DoPetStuff')
            s.combat.dontMoveMe = false
        end
    end

    _utils.debug('pet', 'Pet.doPetStuff: done (pet=%d)', mq.TLO.Me.Pet.ID() or 0)
end

-- ---------------------------------------------------------------------------
-- Step 8.3: Pet.petToys — item-giving helpers (stub)
-- ---------------------------------------------------------------------------

function Pet.petToys(...)
    -- TODO Step 8.3: port PetToys cluster (mac:5521-6034)
end

-- ---------------------------------------------------------------------------
-- Step 8.4: Pet.checkRampPets — rampage-pet wait (stub)
-- ---------------------------------------------------------------------------

function Pet.checkRampPets()
    -- TODO Step 8.4: port CheckRampPets (mac:9571-9585)
end

return Pet
