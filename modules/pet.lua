local mq     = require('mq')
local Config = require('modules.config')

local Pet = {}
local _state, _utils, _cast, _buffs, _movement

-- Roles where pet guard/follow stance is actively managed
local PULL_ROLES    = {puller=true, pullertank=true, pettank=true, pullerpettank=true}
-- Roles where pet taunt should be ON
local PETTANK_ROLES = {pettank=true, pullerpettank=true, hunterpettank=true}

-- ---------------------------------------------------------------------------
-- Step 8.3: module-level toy-session state (reset at start of each petToys call)
-- ---------------------------------------------------------------------------
local _bagNum     = 0   -- working bag slot index (0 = not found yet)
local _bagNumLast = 0   -- last used slot (persists; 99 = inventory full)
local _itemsGiven = 0   -- items currently pending in GiveWnd trade window
local _toyItems   = {}  -- {name, slot, slot2} entries for return-on-reject tracking

-- ---------------------------------------------------------------------------
-- Step 8.1: Pet.init — scaffold + INI wiring
-- ---------------------------------------------------------------------------

function Pet.init(state, utils, cast, buffs, movement)
    _state    = state
    _utils    = utils
    _cast     = cast
    _buffs    = buffs
    _movement = movement

    -- Load pet INI fields not already loaded by Buffs.init.
    -- Buffs.init owns: on, shrinkOn, shrinkSpell, toysOn, toysArray.
    _state.pet.spell         = Config.get('Pet', 'PetSpell',        '') or ''
    _state.pet.focus         = Config.get('Pet', 'PetFocus',        '') or ''
    -- 0=off, 1=pending (send command once), 2=already sent this pet
    _state.pet.focusOn       = tonumber(Config.get('Pet', 'PetFocusOn', '0')) or 0
    _state.pet.holdOn        = tonumber(Config.get('Pet', 'PetHoldOn',  '0')) or 0
    _state.pet.suspend       = Config.get('Pet', 'PetSuspend',      '0') == '1'
    _state.pet.tauntOverride = Config.get('Pet', 'PetTauntOverride', '0') == '1'
    _state.pet.toysGave      = _state.pet.toysGave or ''
    _state.pet.toysDone      = false
    _state.pet.petRampageOn  = Config.get('Pull', 'PetRampPullWait', '0') == '1'

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
-- Step 8.3: Item-giving helpers + Pet.petToys
-- ---------------------------------------------------------------------------

-- Cast a toy spell on self (creates item on cursor). Returns true if cancelled.
-- Mirrors Sub CastPetToys (kissassist.mac:5521-5558).
local function castPetToys(spell)
    local retryCount = 0
    local cancelled  = false
    while true do
        retryCount = retryCount + 1
        local ret = _cast.castWhat(spell, mq.TLO.Me.ID(), 'Pet-nomem')
        if ret == 'CAST_SUCCESS' then
            printf('\awCasting pet toy spell >> %s <<', spell)
            break
        elseif ret == 'CAST_FIZZLE' then
            if retryCount > 4 then cancelled = true; break end
            if not (mq.TLO.Me.GemTimer(spell)() or false)
               and (mq.TLO.Me.SpellReady(spell)() or false) then
                mq.delay(500)
            else
                mq.delay(500, function()
                    return not (mq.TLO.Me.GemTimer(spell)() or false)
                end)
            end
        elseif ret == 'CAST_RECOVER' then
            retryCount = retryCount - 1
            mq.delay(500, function()
                return not (mq.TLO.Me.SpellInCooldown() or false)
                   and not (mq.TLO.Me.GemTimer(spell)() or false)
                   and (mq.TLO.Me.SpellReady(spell)() or false)
            end)
        else
            cancelled = true; break
        end
    end
    return cancelled
end

-- Move a named item from inventory to cursor; track slot for return-on-reject.
-- Mirrors Sub PickUpItem (kissassist.mac:5562-5582).
local function pickUpItem(itemName)
    if (mq.TLO.FindItemCount('=' .. itemName)() or 0) == 0 then return end
    local fi    = mq.TLO.FindItem('=' .. itemName)
    local slot  = fi.ItemSlot() or 0
    local slot2 = fi.ItemSlot2() or -1
    -- Mac adjusts: slots >22 are inside containers (subtract 22 for pack index)
    if slot > 22 then slot = slot - 22 end
    -- ItemSlot2 is 0-based inside bag; convert to 1-based for /itemnotify
    if slot2 > -1 then slot2 = slot2 + 1 end

    _toyItems[#_toyItems + 1] = {name = itemName, slot = slot, slot2 = slot2}

    if slot2 < 0 then
        mq.cmd('/nomodkey /itemnotify pack' .. slot .. ' leftmouseup')
    else
        mq.cmdf('/nomodkey /itemnotify in pack%s %s leftmouseup', slot, slot2)
    end
    mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
end

-- Find an empty top-level inventory bag slot for holding summoned containers.
-- Sets _bagNum; sets _bagNumLast=99 if inventory is full.
-- Mirrors Sub OpenInvSlot (kissassist.mac:5836-5879).
local function openInvSlot()
    if _bagNum ~= 0 then return end
    -- Cursor must be clear or we cannot place a bag
    if (mq.TLO.Cursor.ID() or 0) > 0 then
        _bagNumLast = 99
        return
    end
    local maxSlots = mq.TLO.Me.NumBagSlots() or 10
    -- Pass 1: find a slot with no item at all (truly empty)
    for i = 1, maxSlots do
        if not (mq.TLO.Me.Inventory('pack' .. i).Container() or false) then
            if (mq.TLO.Me.Inventory('pack' .. i).ID() or 0) == 0 then
                _bagNum = i
                break
            end
        end
    end
    -- Pass 2: find a non-container slot when free inventory > 1
    if _bagNum == 0 then
        for i = 1, maxSlots do
            if not (mq.TLO.Me.Inventory('pack' .. i).Container() or false) then
                if (mq.TLO.Me.FreeInventory() or 0) > 1 then
                    _bagNum = i
                else
                    _bagNumLast = 99
                end
                break
            end
        end
    end
    if _bagNum ~= 0 and _bagNum ~= _bagNumLast then
        _bagNumLast = _bagNum
        printf('\awPet Toys: Inventory slot %d is empty, using that one.', _bagNum)
    end
end

-- Destroy the summoned phantom/arcane bag in _bagNum if all contents are NoRent.
-- Mirrors Sub DestroyBag (kissassist.mac:5885-5917).
local function destroyBag()
    local inv   = mq.TLO.Me.Inventory('pack' .. _bagNum)
    local slots = inv.Container() or 0
    if (inv.Items() or 0) > 0 then
        for j = 1, slots do
            local item = inv.Item(j)
            if (item.Name() or '') ~= '' and not (item.NoRent() or false) then
                printf('\awBag has non-summoned item(s). Aborting delete. Pet Toys Off.')
                _state.pet.toysOn = false
                return
            end
        end
    end
    local name = inv.Name() or ''
    local isSummonedBag = name:find('Arcane Weapon Pack',   1, true)
                       or name:find('Arcane Armor Pack',    1, true)
                       or name:find('Arcane Heirloom Pack', 1, true)
                       or name:find('Phantom Weapon Pack',  1, true)
                       or name:find('Phantom Armor Pack',   1, true)
                       or name:find('Phantom Heirloom Pack',1, true)
                       or name:find('Phantom Satchel',      1, true)
                       or name:find('Pouch of Quellious',   1, true)
    if isSummonedBag then
        mq.cmd('/nomodkey /itemnotify pack' .. _bagNum .. ' leftmouseup')
        mq.delay(5000, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
        local curName = mq.TLO.Cursor.Name() or ''
        if (curName:find('Pack', 1, true) and (curName:find('Arcane', 1, true) or curName:find('Phantom', 1, true)))
           or curName:find('Phantom Satchel',    1, true)
           or curName:find('Pouch of Quellious', 1, true) then
            mq.cmd('/destroy')
        end
        mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
end

-- Target pet, move cursor item into trade window, confirm give.
-- gItem='giveitems' flushes the current trade window without picking up anything new.
-- Mirrors Sub GiveTo (kissassist.mac:5923-6031).
local function giveTo(gItem, gTarget, giveNow)
    if gItem ~= 'giveitems' then
        -- Target the pet
        if (mq.TLO.Target.ID() or 0) ~= gTarget then
            mq.cmd('/target id ' .. gTarget)
            mq.delay(2000, function() return (mq.TLO.Target.ID() or 0) == gTarget end)
        end
        -- Move close enough for trade
        local dist    = mq.TLO.Target.Distance() or 0
        local campRad = _state.movement.campRadius or 100
        if dist > 5 and dist <= campRad then
            mq.cmd('/moveto id ' .. gTarget .. ' mdist 5')
            mq.delay(5000, function() return mq.TLO.MoveTo.Stopped() or false end)
        end
        if (mq.TLO.Me.Mount.ID() or 0) > 0 then
            mq.cmd('/dismount')
            mq.delay(2000, function() return (mq.TLO.Me.Mount.ID() or 0) == 0 end)
        end
        if mq.TLO.Me.Levitating() then
            mq.cmd('/removelev')
            mq.delay(2000, function() return not mq.TLO.Me.Levitating() end)
        end
        -- Ensure item is on cursor
        if (mq.TLO.Cursor.ID() or 0) == 0 then
            if (mq.TLO.FindItemCount('=' .. gItem)() or 0) > 0 then
                pickUpItem(gItem)
            else
                printf('\awItem: %s Not Found in Inventory. Check item name.', gItem)
                return
            end
        end
        local gItemID   = mq.TLO.FindItem('=' .. gItem).ID() or 0
        local dropCount = 0
        while (mq.TLO.Cursor.ID() or 0) > 0 and dropCount < 4 do
            if mq.TLO.Cursor.NoRent() then
                if (mq.TLO.Cursor.ID() or 0) == gItemID then
                    mq.cmd('/nomodkey /click left target')
                    mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                    _itemsGiven = _itemsGiven + 1
                else
                    printf('\awItem: %s Not on cursor. Dropping to inventory.', gItem)
                    mq.cmd('/autoinventory')
                    mq.delay(1000)
                end
            else
                printf('\awItem: %s is not Summoned. Dropping to inventory.', mq.TLO.Cursor.Name() or '')
                mq.cmd('/autoinventory')
                mq.delay(1000)
            end
            dropCount = dropCount + 1
        end
        if (mq.TLO.Cursor.ID() or 0) > 0 then
            printf('\awItem still on Cursor. Wrong item or inventory full.')
            return
        end
    else
        giveNow = true
    end

    -- Confirm trade when window opens
    mq.delay(3000, function() return mq.TLO.Window('GiveWnd').Open() or false end)
    if mq.TLO.Window('GiveWnd').Open() then
        if giveNow or _itemsGiven == 4 then
            mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
            printf('\awGiving Item(s) to %s', mq.TLO.Target.CleanName() or 'pet')
            mq.delay(2000, function() return not (mq.TLO.Window('GiveWnd').Open() or false) end)
            mq.delay(1500)
            _itemsGiven = 0
        end
    end

    -- Handle rejected/returned item: put back where it came from (mac:5995-6029)
    local dropCount = 0
    while (mq.TLO.Cursor.ID() or 0) > 0 and dropCount < 8 do
        local curName = mq.TLO.Cursor.Name() or ''
        local returned = false
        for idx, entry in ipairs(_toyItems) do
            if entry ~= 'removed' and entry.name == curName then
                if entry.slot2 < 0 then
                    mq.cmd('/nomodkey /itemnotify pack' .. entry.slot .. ' leftmouseup')
                else
                    mq.cmdf('/nomodkey /itemnotify in pack%s %s leftmouseup', entry.slot, entry.slot2)
                end
                _toyItems[idx] = 'removed'
                returned = true
                break
            end
        end
        if not returned then
            if mq.TLO.Cursor.NoRent() then
                mq.cmd('/destroy')
            else
                mq.cmd('/autoinventory')
            end
        end
        mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        dropCount = dropCount + 1
    end
    if giveNow then _toyItems = {} end
end

-- Main pet toy orchestration. Casts or retrieves each toy and gives it to the pet.
-- Mirrors Sub PetToys (kissassist.mac:5586-5830).
function Pet.petToys(petName)
    if (mq.TLO.Me.Pet.ID() or 0) == 0 then return end

    -- Reset toy-session state
    _bagNum     = 0
    _itemsGiven = 0
    _toyItems   = {}
    openInvSlot()

    local petID    = mq.TLO.Spawn('pet ' .. petName).ID() or 0
    local petLevel = petID > 0 and (mq.TLO.Spawn('id ' .. petID).Level() or 1) or 1

    local s = _state
    if not s.pet.toysOn then return end
    if _bagNumLast == 99 then
        printf('\awInventory is full. Pet Toys disabled.')
        s.pet.toysOn = false
        return
    end
    if _bagNum == 0 then
        printf('\awNo empty Top Inventory slot. Pet Toys disabled.')
        s.pet.toysOn = false
        return
    end

    local isMyPet  = (mq.TLO.Me.Pet.CleanName() or '') == petName
    local toysTemp = s.pet.toysGave

    if isMyPet then
        if not toysTemp:find(petName, 1, true) then
            toysTemp       = petName
            s.pet.toysGave = petName
        end
    else
        toysTemp = ''
    end

    local invWasOpen = mq.TLO.Window('InventoryWindow').Open() or false
    local gaveItem   = invWasOpen

    -- Iterate toys array (mac:5636-5823)
    for i = 1, #(s.pet.toysArray or {}) do
        local rawEntry = s.pet.toysArray[i] or ''
        if rawEntry == 'Null' or rawEntry == '' then goto continue end

        -- condNo / |cond evaluation deferred to M10 — skip |cond entries silently
        -- Strip |cond... suffix
        local fullText = rawEntry:match('^(.-)%|cond') or rawEntry

        -- Parse pipe-delimited: PetToySpell|Item1|Item2...
        local parts = {}
        for p in (fullText .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
        local pCount1     = #parts
        local petToySpell = parts[1] or ''
        local pIdx        = 1
        local secondPart, lastPart, petToyCheck = '', '', ''

        if pCount1 > 1 then
            pIdx       = 2
            secondPart = parts[2] or ''
            lastPart   = parts[3] or ''
            if secondPart ~= '' and secondPart ~= 'null' and lastPart == secondPart then
                petToyCheck = ':' .. secondPart .. '2'
            else
                petToyCheck = ':' .. secondPart .. '1'
            end
        else
            petToySpell = fullText
            secondPart  = ''
            petToyCheck = petToySpell .. ':'
        end
        lastPart = ''

        -- Skip-already-given and level-76 auto-equip guards (isMyPet only)
        if isMyPet then
            if toysTemp:find(petName, 1, true) and toysTemp:find(petToyCheck, 1, true) then
                goto continue
            end
            if petLevel >= 76 then
                local lc = petToySpell:lower()
                if lc:find('muzzle') or lc:find('visor') or lc:find('belt') or lc:find('plate') then
                    goto continue
                end
            end
        end

        local spellInBook = (mq.TLO.Me.Book(petToySpell)() or 0) > 0
        local invItem     = petToySpell == 'inventory'
                            and (mq.TLO.FindItemCount('=' .. secondPart)() or 0) > 0

        if spellInBook or invItem then
            local castFlag1 = 0

            if spellInBook then
                if castPetToys(petToySpell) then goto continue end
                mq.delay(15000, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                if (mq.TLO.Cursor.ID() or 0) == 0 then return end
            end

            -- Handle summoned container on cursor (mac:5695-5741)
            local cursorName = mq.TLO.Cursor.Name() or ''
            if (mq.TLO.Cursor.Container() or false) or cursorName:find('Folded', 1, true) then
                castFlag1 = 0
                local slotOpen = (mq.TLO.Me.Inventory('pack' .. _bagNum).ID() or 0) == 0
                mq.cmd('/nomodkey /itemnotify pack' .. _bagNum .. ' leftmouseup')
                while true do
                    if not slotOpen then
                        mq.delay(3000, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                    else
                        mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                    end
                    if (mq.TLO.Cursor.ID() or 0) > 0 then
                        if not (mq.TLO.Cursor.Container() or false) then
                            mq.cmd('/autoinventory')
                        else
                            mq.cmd('/nomodkey /itemnotify pack' .. _bagNum .. ' leftmouseup')
                        end
                    end
                    mq.delay(2000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                    if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory') end
                    local packName = mq.TLO.Me.Inventory('pack' .. _bagNum).Name() or ''
                    if packName:lower():find('folded') then
                        mq.cmd('/nomodkey /itemnotify pack' .. _bagNum .. ' rightmouseup')
                        printf('\awOpening %s', packName)
                        mq.delay(1000)
                        mq.delay(3000, function() return mq.TLO.Window('CastingWindow').Open() or false end)
                        slotOpen = false
                    else
                        mq.delay(1000)
                        break
                    end
                end
                if mq.TLO.Me.Inventory('pack' .. _bagNum).Container() then
                    mq.cmd('/nomodkey /itemnotify pack' .. _bagNum .. ' rightmouseup')
                    mq.delay(1000)
                end
            elseif cursorName:find('Summoned:', 1, true) then
                castFlag1 = 1
            else
                castFlag1 = 0
            end

            -- Give loop: hand each pipe-part item to the pet (mac:5743-5795)
            while true do
                if (mq.TLO.FindItemCount('=' .. secondPart)() or 0) > 0 then
                    giveTo(secondPart, petID, false)
                elseif (mq.TLO.Cursor.ID() or 0) > 0 then
                    secondPart = mq.TLO.Cursor.Name() or ''
                    giveTo(secondPart, petID, true)
                elseif pIdx == 1 and secondPart == '' then
                    castFlag1 = 2
                    break
                else
                    break
                end
                mq.delay(1000)

                -- Record this item as given
                if toysTemp:find(':' .. secondPart .. '1', 1, true) then
                    toysTemp = toysTemp .. string.format('|%s:%s2', petToySpell, secondPart)
                else
                    toysTemp = toysTemp .. string.format('|%s:%s1', petToySpell, secondPart)
                end
                if isMyPet then s.pet.toysGave = toysTemp end

                -- Advance to next pipe segment; skip already-given or auto-equipped items
                local keepGiving = true
                lastPart   = secondPart
                secondPart = ''
                while pIdx < pCount1 do
                    pIdx = pIdx + 1
                    local candidate = parts[pIdx] or ''
                    if candidate == '' then break end
                    if candidate ~= 'null' and candidate == lastPart then
                        petToyCheck = ':' .. candidate .. '2'
                    else
                        petToyCheck = ':' .. candidate .. '1'
                    end
                    local skip = false
                    if isMyPet then
                        if toysTemp:find(petName, 1, true) and toysTemp:find(petToyCheck, 1, true) then
                            skip = true
                        end
                        if not skip and petLevel >= 76 then
                            local lc = petToySpell:lower()
                            if lc:find('muzzle') or lc:find('visor') or lc:find('belt') or lc:find('plate') then
                                skip = true
                            end
                        end
                    end
                    if not skip then
                        secondPart = candidate
                        break
                    end
                    lastPart = candidate
                end

                if secondPart == '' or secondPart == 'null' then break end
                -- Summoned-item path: flush window then re-cast for next item
                if castFlag1 == 1 then
                    if mq.TLO.Window('GiveWnd').Open() then giveTo('giveitems', petID, true) end
                    if castPetToys(petToySpell) then keepGiving = false; break end
                    mq.delay(15000, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
                end
                if not keepGiving then break end
            end

            -- castFlag1==2: heirloom-bag path — give everything in the bag slot (mac:5796-5810)
            if castFlag1 == 2 then
                secondPart = ''
                local bagSlots = mq.TLO.Me.Inventory('pack' .. _bagNum).Container() or 0
                for j = 1, bagSlots do
                    if petToySpell:find('heirloom', 1, true) and isMyPet and j < 4 then
                        goto next_j
                    end
                    local jItem = mq.TLO.Me.Inventory('pack' .. _bagNum).Item(j)
                    if (jItem.ID() or 0) > 0 and (jItem.Name() or '') ~= '' then
                        secondPart = jItem.Name() or ''
                        giveTo(secondPart, petID, false)
                    end
                    mq.delay(1000)
                    ::next_j::
                end
                if secondPart ~= '' and not toysTemp:find(petToySpell, 1, true) then
                    toysTemp = toysTemp .. '|' .. petToySpell .. ':AllContents'
                    if isMyPet then s.pet.toysGave = toysTemp end
                end
            end

            -- Flush any remaining trade window items
            if mq.TLO.Window('GiveWnd').Open() then giveTo('giveitems', petID, true) end

            -- Destroy the summoned bag if it's a known phantom/arcane pack (mac:5814-5820)
            local packName = mq.TLO.Me.Inventory('pack' .. _bagNum).Name() or ''
            if packName:find('Arcane Weapon Pack',    1, true)
               or packName:find('Arcane Armor Pack',   1, true)
               or packName:find('Arcane Heirloom Pack',1, true)
               or packName:find('Phantom Weapon Pack', 1, true)
               or packName:find('Phantom Armor Pack',  1, true)
               or packName:find('Phantom Heirloom Pack',1,true)
               or packName:find('Phantom Satchel',     1, true)
               or packName:find('Pouch of Quellious',  1, true) then
                destroyBag()
            end
        end

        ::continue::
    end

    -- Finalise (mac:5824-5829)
    s.pet.toysGave = toysTemp
    -- Close inventory window if it wasn't open before petToys opened it
    if mq.TLO.Window('InventoryWindow').Open() and not gaveItem then
        mq.cmd('/keypress inventory')
    end
    s.pet.toysDone = true
    if _movement and s.movement.returnToCamp then
        _movement.doWeMove(0, 'PetToys')
    end

    _utils.debug('pet', 'Pet.petToys: done (petName=%s)', petName)
end

-- ---------------------------------------------------------------------------
-- Pet.checkRampPets — wait for rampage pets to poof before the next pull.
-- Port of CheckRampPets (kissassist.mac:9571-9585).
-- ---------------------------------------------------------------------------

function Pet.checkRampPets()
    if mq.TLO.Me.CombatState() == 'COMBAT' then return end
    local myName = mq.TLO.Me.CleanName() or ''
    for i = 0, 20 do
        local petSpawn = mq.TLO.Spawn(myName .. "'s_pet0" .. i)
        if (petSpawn.ID() or 0) > 0 then
            printf('\aw+++ My rampage pet is up: (%s|%d), HOLDING . . .',
                petSpawn.Name() or '', petSpawn.ID() or 0)
            while (petSpawn.ID() or 0) > 0 and mq.TLO.Me.CombatState() ~= 'COMBAT' do
                mq.delay(100)
            end
            if mq.TLO.Me.CombatState() == 'COMBAT' then return end
        end
    end
end

return Pet
