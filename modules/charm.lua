local mq     = require('mq')
local Config = require('modules.config')

local Charm = {}
local _state, _utils, _cast, _pet, _bard, _comms

-- Classes that can use charm: Druid (animals), Enchanter (any), Necro (undead), Bard (any).
local CHARM_CLASSES = { DRU = true, ENC = true, NEC = true, BRD = true }

-- Port of Sub DoCharmStuff / CreateTimersCharm / CharmRadar (KS_Charm.inc).
function Charm.init(state, utils, cast, pet, bard, comms)
    _state = state
    _utils = utils
    _cast  = cast
    _pet   = pet
    _bard  = bard
    _comms = comms

    local class = (mq.TLO.Me.Class.ShortName() or ''):upper()
    _state.session.iAmACharmClass = CHARM_CLASSES[class] == true

    if not _state.session.iAmACharmClass then return end

    -- [Charm] INI section — mirrors LoadIni Charm block (KS_Charm.inc:LoadIni calls)
    _state.charm.on       = Config.get('Charm', 'CharmOn',       '0') == '1'
    _state.charm.spell    = Config.get('Charm', 'CharmSpell',    '') or ''
    _state.charm.minLevel = tonumber(Config.get('Charm', 'CharmMinLevel', '5'))  or 5
    _state.charm.maxLevel = tonumber(Config.get('Charm', 'CharmMaxLevel', '0'))  or 0
    _state.charm.radius   = tonumber(Config.get('Charm', 'CharmRadius',   '50')) or 50
    _state.charm.keep     = Config.get('Charm', 'CharmKeep', '0') == '1'

    -- Per-zone immune list from KissAssist_Info.ini — mirrors LoadIni "${ZoneName}" CharmImmune
    local zoneName = mq.TLO.Zone.ShortName() or ''
    local infoFile = _state.session.infoFileName or 'KissAssist_Info.ini'
    local immune   = mq.TLO.Ini(infoFile, zoneName, 'CharmImmune', 'NULL')() or 'NULL'
    local aaImm    = mq.TLO.Ini(infoFile, zoneName, 'AACharmImmune', '0')() or '0'
    _state.charm.immuneList = (immune:lower() == 'null' or immune == '') and '' or immune
    _state.charm.aaImmune   = aaImm == '1'

    -- Per-slot timer tables (CreateTimersCharm: 30 slots each)
    for i = 1, 30 do
        _state.charm.slotTimers[i] = 0
        _state.charm.cmTimers[i]   = 0
        _state.charm.count[i]      = 0
    end

    _utils.debug('charm', 'Charm.init: class=%s on=%s spell=%s radius=%d keep=%s',
        class, tostring(_state.charm.on), _state.charm.spell,
        _state.charm.radius, tostring(_state.charm.keep))
end

-- Scan XTarget haters within CharmRadius; populate charmArray, mobCount, mobAECount, aeClosest.
-- Port of Sub CharmRadar (KS_Charm.inc).
local function charmRadar()
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end

    local radius = _state.charm.radius

    local mobCount   = mq.TLO.SpawnCount('xtarhater')() or 0
    local mobAECount = mq.TLO.SpawnCount('xtarhater radius ' .. radius)() or 0

    -- XTSlot non-auto-hater bump (mirrors mezRadar pattern)
    local xtSlot = _state.combat.xTSlot or 0
    if xtSlot > 0 then
        local xt = mq.TLO.Me.XTarget(xtSlot)
        if xt and (xt.ID() or 0) > 0 and (xt.TargetType() or '') ~= 'Auto Hater' then
            mobCount   = mobCount   + 1
            mobAECount = mobAECount + 1
        end
    end

    _state.charm.mobCount   = mobCount
    _state.charm.mobAECount = mobAECount

    -- Add nearby haters not already tracked (mac: add to first NULL slot)
    local arr = _state.arrays.charmArray
    if mobAECount > 0 then
        for i = 1, mobAECount do
            local sp = mq.TLO.NearestSpawn(i, 'xtarhater radius ' .. radius)
            if sp then
                local id = sp.ID() or 0
                if id > 0 then
                    local found = false
                    for _, entry in ipairs(arr) do
                        if entry[1] == id then found = true; break end
                    end
                    if not found then
                        for _, entry in ipairs(arr) do
                            if entry[1] == 0 then
                                entry[1] = id
                                entry[2] = sp.Level() or 0
                                entry[3] = sp.CleanName() or ''
                                _utils.debug('charm', 'charmRadar: adding %s (ID:%d)', entry[3], id)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    local closest = mq.TLO.NearestSpawn(1, 'xtarhater radius ' .. radius)
    _state.charm.aeClosest = closest and (closest.ID() or 0) or 0

    _utils.debug('charm', 'charmRadar: mobCount=%d mobAECount=%d aeClosest=%d',
        mobCount, mobAECount, _state.charm.aeClosest)
end

-- Zero out a charmArray slot and reset its per-slot timers.
local function clearSlot(entry, i)
    entry[1] = 0
    entry[2] = 0
    entry[3] = 'NULL'
    _state.charm.slotTimers[i] = 0
    _state.charm.count[i]      = 0
end

-- Returns true if spawnID appears on any XTarget hater slot (slots 1-13).
local function isOnXTarget(spawnID)
    for i = 1, 13 do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and (xt.ID() or 0) == spawnID then return true end
    end
    return false
end

-- Main charm loop. Port of Sub DoCharmStuff (KS_Charm.inc).
function Charm.check(sentFrom)
    if not _state.session.iAmACharmClass then return end
    if not _state.charm.on then return end
    if mq.TLO.Me.Hovering() then return end
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end

    -- Already have a pet — nothing to charm
    if (mq.TLO.Me.Pet.ID() or 0) > 0 then return end

    local class  = (mq.TLO.Me.Class.ShortName() or ''):upper()
    local isBard = _state.session.iAmABard
    local keep   = _state.charm.keep

    local maName  = _state.session.mainAssist or ''
    local maSpawn = maName ~= '' and mq.TLO.Spawn('=' .. maName) or nil
    local maID    = maSpawn and (maSpawn.ID() or 0) or 0
    local maAlive = maID > 0 and (maSpawn.Type() or ''):lower() ~= 'mercenary'

    -- CharmKeep zone guard (mac: CharmPetZone check at DoCharmStuff entry)
    if keep and _state.charm.petZone ~= '' then
        local curZone = mq.TLO.Zone.ShortName() or ''
        if _state.charm.petZone ~= curZone then
            _utils.debug('charm', 'Charm.check: keep pet in zone %s, we are in %s — skip',
                _state.charm.petZone, curZone)
            return
        end
        -- Right zone: verify saved pet spawn still exists
        if _state.charm.petId > 0 then
            local petSpawn = mq.TLO.Spawn('id ' .. _state.charm.petId)
            if not petSpawn or (petSpawn.ID() or 0) == 0 then
                printf('\ay[Charm] Charm pet (ID:%d) is dead — resetting.', _state.charm.petId)
                _state.charm.petId  = 0
                _state.charm.petZone = ''
            end
        end
    end

    -- CharmKeep=0: if petId is set but we have no pet, charm broke
    if not keep and _state.charm.petId ~= 0 then
        _utils.debug('charm', 'Charm.check: charm broke (no keep mode) — resetting petId')
        _comms.announce('[Kiss] *** Charm BROKE!! ***')
        _state.charm.petId  = 0
        _state.charm.petZone = ''
    end

    -- No combat target and MA is alive — nothing to charm yet (mirrors mez guard)
    if _state.combat.myTargetID == 0 and maAlive then return end

    _state.charm.mobDone = false
    _utils.debug('charm', 'Charm.check: enter sentFrom=%s', sentFrom)

    charmRadar()

    local spell = _state.charm.spell
    if spell == '' or spell:lower() == 'null' then return end

    -- Spell / AA ready check; bards skip (mac: skip ready gate if IAmABard)
    local isAA      = (mq.TLO.Me.AltAbility(spell)() ~= nil)
    local spellReady = mq.TLO.Me.SpellReady(spell)() or mq.TLO.Me.AltAbilityReady(spell)()
    if not isBard and not spellReady then
        _utils.debug('charm', 'Charm.check: %s not ready — return', spell)
        return
    end

    -- Gem check: if it is a book spell and not currently memmed, mem it then return
    -- (mac: /MemSpell ${MiscGem} "${CharmSpell}" ... /return)
    if not isAA and not mq.TLO.Me.Gem(spell)() then
        local miscGem = tonumber(Config.get('SpellS', 'MiscGem', '0')) or 0
        if miscGem > 0 then
            mq.cmdf('/MemSpell %d "%s"', miscGem, spell)
            mq.delay(15000, function()
                return mq.TLO.Me.Gem(miscGem) and
                       (mq.TLO.Me.Gem(miscGem).Name() or '') == spell
            end)
        end
        _utils.debug('charm', 'Charm.check: %s not in gem — memming, return', spell)
        return
    end

    local arr = _state.arrays.charmArray
    for i = 1, math.min(#arr, 13) do
        local entry   = arr[i]
        local mobID   = entry[1]
        local mobLvl  = entry[2]
        local mobName = entry[3]

        -- Empty slot
        if mobID == 0 then goto continue_charm end

        local mob = mq.TLO.Spawn('id ' .. tostring(mobID))

        -- Dead or despawned (mac: type corpse check)
        if not mob or (mob.ID() or 0) == 0 or (mob.Type() or ''):lower() == 'corpse' then
            clearSlot(entry, i)
            goto continue_charm
        end

        -- CharmKeep: only recharm the specific saved pet
        if keep and _state.charm.petId ~= 0 and mobID ~= _state.charm.petId then
            clearSlot(entry, i)
            goto continue_charm
        end

        -- MA's current target with no charm pet — let group kill it
        if mobID == _state.combat.myTargetID and maAlive and _state.charm.petId == 0 then
            clearSlot(entry, i)
            goto continue_charm
        end

        -- Level range filter
        local maxLvl = _state.charm.maxLevel
        if mobLvl < _state.charm.minLevel or (maxLvl > 0 and mobLvl > maxLvl) then
            clearSlot(entry, i)
            goto continue_charm
        end

        -- NEC: undead body type only
        if class == 'NEC' and (mob.Body.Name() or '') ~= 'Undead' then
            clearSlot(entry, i)
            goto continue_charm
        end

        -- DRU: animal body type only
        if class == 'DRU' and (mob.Body.Name() or '') ~= 'Animal' then
            clearSlot(entry, i)
            goto continue_charm
        end

        -- Line of sight
        if not mob.LineOfSight() then goto continue_charm end

        -- BRD is MA with active aggro — don't charm while we're tanking the kill target
        if isBard and _state.session.iAmMA
           and (_state.combat.aggroTargetID or 0) ~= 0
           and mobID == _state.combat.myTargetID then
            goto continue_charm
        end

        -- Name-based immune list (comma-separated, stored per zone in KissAssist_Info.ini)
        if _state.charm.immuneList ~= '' then
            local lName = (mobName or ''):lower()
            for entry_name in _state.charm.immuneList:gmatch('[^,]+') do
                if lName == entry_name:match('^%s*(.-)%s*$'):lower() then
                    _utils.debug('charm', 'Charm.check: %s on immuneList — skip', mobName)
                    _state.charm.cmTimers[i] = os.clock() + 60
                    clearSlot(entry, i)
                    goto continue_charm
                end
            end
        end

        -- CharmKeep: saved pet must still be within radius
        if keep and mobID == _state.charm.petId then
            if (mob.Distance() or 999) > _state.charm.radius then
                _utils.debug('charm', 'Charm.check: keep-pet ID:%d outside radius — skip', mobID)
                goto continue_charm
            end
        end

        -- Mana check (skip for AAs)
        if not isAA then
            local manaCost = mq.TLO.Spell(spell).Mana() or 0
            if (mq.TLO.Me.CurrentMana() or 0) < manaCost then goto continue_charm end
        end

        -- MA alive and mob not on XTarget — let normal combat handle it
        if maAlive and not isOnXTarget(mobID) then
            _utils.debug('charm', 'Charm.check: mob ID:%d not on XTarget, MA alive — return', mobID)
            return
        end

        -- Runtime immune IDs (set by Charm.cast on CAST_IMMUNE)
        if _state.charm.immuneIds ~= ''
           and _state.charm.immuneIds:find('|' .. tostring(mobID), 1, true) then
            clearSlot(entry, i)
            goto continue_charm
        end

        -- BRD: disengage before charming (mac: /squelch /attack off)
        if isBard then mq.cmd('/squelch /attack off') end

        -- Attempt charm (Charm.cast implemented in step 24.4)
        Charm.cast(mobID, i)

        -- On success: back off pet, record petId, notify group
        if (mq.TLO.Me.Pet.ID() or 0) > 0 then
            mq.cmd('/squelch /pet back off')
            _state.charm.petId   = mq.TLO.Me.Pet.ID()
            _state.charm.petZone = mq.TLO.Zone.ShortName() or ''
            -- Bard: enable pet as DPS source (mac: PetOn=1 PetCombatOn=1 PetAssistAt=98)
            if isBard then
                _state.pet.on       = true
                _state.pet.combatOn = true
                _state.pet.assistAt = 98
            end
            _comms.announce('[Kiss] *** Charm Successful ***')
            _state.charm.mobDone = true
            return
        end

        ::continue_charm::
    end

    _utils.debug('charm', 'Charm.check: leave')
end

-- Cast charm spell on mobId; set per-slot recharm timer on success.
-- Handles resist (retry once with mez debuff), immune (add to immuneIds), cancelled.
-- Port of Sub CharmMobs (KS_Charm.inc) — implemented in step 24.4.
function Charm.cast(mobId, timerIdx)
end

-- Clear charmArray and all per-slot timers. Called on zone change and death reset.
function Charm.resetFight()
    if not _state then return end
    local arr = _state.arrays.charmArray
    for i = 1, #arr do
        arr[i][1] = 0
        arr[i][2] = 0
        arr[i][3] = 'NULL'
        if _state.charm.slotTimers then _state.charm.slotTimers[i] = 0 end
        if _state.charm.count      then _state.charm.count[i]      = 0 end
    end
    _state.charm.mobCount   = 0
    _state.charm.mobAECount = 0
    _state.charm.aeClosest  = 0
    _state.charm.mobDone    = false
end

return Charm
