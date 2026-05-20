local mq     = require('mq')
local Config = require('modules.config')

local Combat = {}
local _state, _utils, _cast, _heal, _movement, _bard, _cond, _mez
local _nearspawnFallback = false  -- set by mobRadar when NearestSpawn fallback fires

-- 2D camp-distance helper (mirrors Math.Distance[y1,x1:y2,x2] in kissassist.mac)
local function dist2D(y1, x1, y2, x2)
    return math.sqrt((y1 - y2)^2 + (x1 - x2)^2)
end

-- Mirrors Sub BeforeAttack (kissassist.mac:2022).
-- Fires pre-combat abilities from beforeArray before first melee swing.
-- condCheck: 1=all entries, 2=only entries that have |cond flag set.
local function beforeAttack(_tarID, condCheck)
    local beforeArr = _state.arrays.beforeArray
    for i = 1, #beforeArr do
        local entry = beforeArr[i]
        if not entry or entry == 'null' then return end
        if (mq.TLO.Target.ID() or 0) == 0 then return end

        local name = entry:match('^([^|]+)') or entry
        if not name or name == '' or name == 'null' then return end

        -- condCheck==2: skip entries without |cond (conditional-only pass)
        if not entry:find('|cond', 1, true) and condCheck == 2 then
            goto next_before
        end
        -- Condition guard: skip if this entry's condition evaluates false
        if _cond then
            local cp = entry:find('|cond', 1, true)
            if cp then
                local condNo = tonumber(entry:sub(cp + 5, cp + 7)) or 0
                if condNo > 0 and not _cond.eval(condNo) then goto next_before end
            end
        end

        -- Item
        local item = mq.TLO.FindItem('=' .. name)
        if item and (item.ID() or 0) ~= 0 and mq.TLO.Me.ItemReady(name)() then
            mq.cmd('/useitem "' .. name .. '"')
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- AA
        elseif (mq.TLO.Me.AltAbility(name).ID() or 0) ~= 0
               and mq.TLO.Me.AltAbilityReady(name)()
               and (mq.TLO.Me.AltAbility(name).Type() or 0) ~= 5
               and name:lower() ~= 'twincast' then
            mq.cmd('/alt act ' .. (mq.TLO.Me.AltAbility(name).ID() or 0))
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- Discipline (CombatAbility)
        elseif mq.TLO.Me.CombatAbilityReady(name)()
               and (mq.TLO.Spell(name) ~= nil)
               and ((mq.TLO.Spell(name).EnduranceCost() or 0) < (mq.TLO.Me.CurrentEndurance() or 0)) then
            mq.cmd('/disc "' .. name .. '"')
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- Activated skill/ability
        elseif (mq.TLO.Me.Skill(name)() or 0) > 0 and mq.TLO.Me.AbilityReady(name)() then
            mq.cmd('/doability "' .. name .. '"')
            mq.cmd('/echo ## Before Attack >> ' .. name .. ' <<')
        -- command: prefix (deferred — CastCommand)
        end

        mq.delay(150)
        ::next_before::
    end
end

-- Mirrors Sub CombatPet (kissassist.mac:2056).
-- Sends pet to attack the current myTargetID mob if in range and below PetAssistAt%.
local function combatPet()
    if (mq.TLO.Me.Pet.ID() or 0) == 0 then return end
    if mq.TLO.Pet.Combat() then return end
    if _state.dps.paused then return end
    if not _state.pet.combatOn then return end

    Combat.combatTargetCheck(1)
    local myID = _state.combat.myTargetID
    if myID == 0 then return end

    local sp       = mq.TLO.Spawn('id ' .. myID)
    local dist3D   = sp and sp.Distance3D() or 999
    local role     = _state.session.role

    -- Pulling: summon pet if too far away (mac:2066-2075, Summon Companion AA)
    if _state.pull.pulling then
        if (mq.TLO.Me.AltAbility('Summon Companion').ID() or 0) ~= 0
           and mq.TLO.Me.AltAbilityReady('Summon Companion')()
           and (mq.TLO.Me.Pet.Distance() or 0) > 79 then
            mq.cmd('/echo Pet! Get over here!')
            -- CastAA deferred — cast module not yet wired
        end
    end

    -- Wait for target buffs if target just changed (mac:2076-2078, minor)
    -- BreakMez for pettank roles (mac:2080)
    local pRole = _state.session.role or ''
    if _mez and (pRole == 'pettank' or pRole == 'pullerpettank' or pRole == 'hunterpettank') then
        _mez.breakMez()
    end
    if mq.TLO.Target.Mezzed.ID() then return end

    -- Send pet to attack or follow based on role and distance (mac:2082-2116)
    local petAttackRange = _state.pet.attackRange
    local campY = _state.movement.campY
    local campX = _state.movement.campX
    local meY   = mq.TLO.Me.Y() or 0
    local meX   = mq.TLO.Me.X() or 0

    if role == 'pettank' or role == 'pullerpettank' then
        if _state.movement.returnToCamp then
            local petY = mq.TLO.Me.Pet.Y() or 0
            local petX = mq.TLO.Me.Pet.X() or 0
            local petCampDist = dist2D(campY, campX, petY, petX)
            local meCampDist  = dist2D(campY, campX, meY, meX)
            local petStance   = mq.TLO.Me.Pet.Stance() or ''
            if petStance ~= 'FOLLOW' then
                if petCampDist > _state.movement.campRadius
                   or meCampDist > _state.movement.campRadius then
                    mq.cmd('/pet follow')
                elseif meCampDist <= _state.movement.campRadius and dist3D > petAttackRange then
                    mq.cmd('/pet follow')
                end
            end
            if dist2D(campY, campX, meY, meX) <= _state.movement.campRadius
               and dist3D < petAttackRange then
                mq.cmd('/pet attack')
                mq.delay(250)
                mq.cmd('/pet swarm')
            end
        else
            if dist3D < petAttackRange then
                mq.cmd('/pet attack')
                mq.delay(250)
                mq.cmd('/pet swarm')
            elseif (mq.TLO.Me.Pet.Stance() or '') ~= 'FOLLOW' then
                mq.cmd('/pet follow')
            end
        end
    else
        if dist3D < petAttackRange then
            mq.cmd('/pet attack')
            mq.delay(250)
            mq.cmd('/pet swarm')
        elseif (mq.TLO.Me.Pet.Stance() or '') ~= 'FOLLOW' then
            mq.cmd('/pet follow')
        end
    end
    _state.timers.petAttack = os.clock() + 3
end

-- Mirrors Sub ValidateTarget (kissassist.mac:948).
-- Validates current Target (or spawnID) as a legal attack target.
-- Returns true if valid. Sets state.combat.validTarget as a side-effect.
-- Pull-specific checks (PullValid loop, PCNear, BadLevel, etc.) deferred to pull.lua (Step 5.x).
local function validateTarget(spawnID)
    local spObj
    local mobID, mobName, mobType
    if spawnID and spawnID ~= 0 then
        spObj   = mq.TLO.Spawn('id ' .. spawnID)
        mobID   = spObj and spObj.ID()        or 0
        mobName = spObj and spObj.CleanName() or ''
        mobType = spObj and spObj.Type()      or ''
    else
        spObj   = nil
        mobID   = mq.TLO.Target.ID()        or 0
        mobName = mq.TLO.Target.CleanName() or ''
        mobType = mq.TLO.Target.Type()      or ''
    end

    _state.combat.validTarget = false
    if mobID == 0 then return false end

    local badTypes = {
        AURA=true, BANNER=true, CAMPFIRE=true, CORPSE=true,
        CHEST=true, ITEM=true, TRIGGER=true, TRAP=true,
        TIMER=true, MOUNT=true, Mercenary=true,
    }
    if badTypes[mobType] or badTypes[mobType:upper()] then return false end

    -- Ignore-by-ID list (pipe-delimited "id|" entries stored in pull state)
    local ignByID = _state.pull.mobsToIgnoreByID or 'null'
    if ignByID ~= 'null' and ignByID:find(mobID .. '|', 1, true) then return false end

    -- Tank: target must appear on the XTarget auto-hater list.
    -- Bypassed when Me.Combat() is true and the mob is the current target
    -- (Me.Combat() fallback in mobRadar already validated it as a live aggressor).
    if _state.session.role == 'tank'
       and _state.combat.mobCount <= _state.combat.xSlotTotal then
        local maName = _state.session.mainAssist
        local maType = _state.session.mainAssistType
        if (mq.TLO.Spawn(maName .. ' ' .. maType .. ' group').ID() or 0) ~= 0 then
            local inXtar = (mq.TLO.SpawnCount('id ' .. mobID .. ' xtarhater')() or 0) > 0
            if not inXtar and not (_nearspawnFallback and (mq.TLO.Me.Combat() or false)) then
                return false
            end
        end
    end

    -- Distance-from-camp check for tank roles when ReturnToCamp is active
    local sp = spObj or mq.TLO.Spawn('id ' .. mobID)
    local meleeDistCheck = _state.combat.meleeDistance
    local maxRange = sp and sp.MaxRangeTo() or 0
    if maxRange > meleeDistCheck then meleeDistCheck = maxRange + 5 end

    if _state.movement.returnToCamp and not _state.pull.pulling then
        local tankRoles = { tank=true, pullertank=true, pettank=true, pullerpettank=true }
        if tankRoles[_state.session.role] then
            local mobY = sp and sp.Y() or 0
            local mobX = sp and sp.X() or 0
            if dist2D(_state.movement.campY, _state.movement.campX, mobY, mobX) > meleeDistCheck then
                return false
            end
        end
    end

    -- "Eye of" charm-NPC: don't attack "eye of <name>" when that PC is present
    if mobName:lower():find('eye of ', 1, true) then
        local stripped = mobName:sub(8)
        if (mq.TLO.SpawnCount('pc ' .. stripped)() or 0) > 0 then return false end
    end

    -- PC-owned pet
    if mobType == 'Pet' or mobType == 'pet' then
        local masterType = (sp and sp.Master.Type()) or ''
        if masterType == 'PC' then return false end
    end

    -- Charmed target
    if (mq.TLO.Target.ID() or 0) == mobID and mq.TLO.Target.Charmed() then
        return false
    end

    -- PC check (Zek PvP server exception: skip group members and MA)
    if mobType == 'PC' or mobType == 'pc' then
        local server = mq.TLO.EverQuest.Server() or ''
        if server ~= 'zek' then
            return false
        else
            if (mq.TLO.Spawn('id ' .. mobID .. ' group').ID() or 0) ~= 0 then return false end
            if mobID == (mq.TLO.Spawn('=' .. _state.session.mainAssist).ID() or 0) then return false end
        end
    end

    -- Pull-specific checks: only active while pull module is pulling (Step 7.8).
    if _state.pull.pulling then
        local mobY = sp and sp.Y() or 0
        local mobX = sp and sp.X() or 0
        -- Reject if any non-group PC is within 30 units of the mob.
        if (mq.TLO.SpawnCount('pc radius 30 loc ' .. mobY .. ',' .. mobX .. ' nogroup')() or 0) > 0 then
            return false
        end
        -- Reject if mob level is outside configured pull level range.
        local mobLevel = (sp and sp.Level()) or 0
        local lvMin = _state.pull.min or 0
        local lvMax = _state.pull.max or 0
        if lvMin > 0 and mobLevel < lvMin then return false end
        if lvMax > 0 and mobLevel > lvMax then return false end
    end

    _state.combat.validTarget = true
    return true
end

-- Expose validateTarget for pull.lua (Step 7.8).
Combat.validateTarget = validateTarget

-- Mirrors Bind_Settings (DPS/Melee/Burn/General sections) from kissassist.mac.
-- Loads combat arrays and wires state.combat flags from INI.
function Combat.init(state, utils, cast, heal, movement, bard, cond, mez)
    _state    = state
    _utils    = utils
    _cast     = cast
    _heal     = heal
    _movement = movement
    _bard     = bard
    _cond     = cond
    _mez      = mez

    -- Engagement toggles; DPSOn==2 enables out-of-combat DPS rotation (mac DPSOn)
    local dpsOnVal            = tonumber(Config.get('DPS', 'DPSOn', '1')) or 1
    _state.combat.dpsOn       = dpsOnVal >= 1
    _state.combat.dpsOnOoc    = dpsOnVal == 2
    _state.combat.dpsSkip     = tonumber(Config.get('DPS', 'DPSSkip',     '20')) or 20
    _state.combat.dpsInterval = tonumber(Config.get('DPS', 'DPSInterval', '2'))  or 2
    _state.combat.meleeOn           = Config.get('Melee', 'MeleeOn',          '1') == '1'
    _state.combat.targetSwitchingOn = Config.get('Melee', 'TargetSwitchingOn', '0') == '1'

    -- Assist-at percent: prefer INI; fall back to CLI-parsed session value (default 95)
    _state.combat.assistAt    = tonumber(Config.get('Melee', 'AssistAt',
                                    tostring(_state.session.assistAt)))
                                or _state.session.assistAt

    _state.combat.meleeDistance = tonumber(Config.get('Melee', 'MeleeDistance', '30')) or 30

    -- Burn flags
    _state.combat.burnOnNamed = Config.get('Burn', 'BurnAllNamed', '0') == '1'
    -- autoBurnTimer: not yet in INI — defaults to 0 (disabled)
    -- TODO: add AutoBurnTimer key to config.lua [Burn] section when available

    -- DPS spell/AA/disc array — parsed into { name, condNo } slots.
    local rawDps = Config.get('DPS', 'DPS', nil)
    if type(rawDps) == 'table' then
        for _, slot in ipairs(Config.parseCondArray(rawDps)) do
            if slot and slot.name and slot.name ~= '' then
                _state.combat.dpsArray[#_state.combat.dpsArray + 1] = slot
            end
        end
    end

    -- Burn spell/disc array
    local burnArr = Config.get('Burn', 'Burn', nil)
    if type(burnArr) == 'table' then
        for _, v in ipairs(burnArr) do
            if v and v ~= '' then
                _state.combat.burnArray[#_state.combat.burnArray + 1] = v
            end
        end
    end

    -- Debuff-all: compute debuffCount from DPS array (slots with hp threshold >= 101 are debuff-all entries)
    _state.debuff.on = tonumber(Config.get('DPS', 'DebuffAllOn', '0')) or 0
    local debuffCount = 0
    for _, dpsEntry in ipairs(_state.combat.dpsArray) do
        local thresh = tonumber(dpsEntry.name:match('^[^|]*|([^|]*)') or '') or 0
        if thresh >= 101 then
            debuffCount = debuffCount + 1
        else
            break  -- debuff slots are always first in the array
        end
    end
    _state.debuff.count = debuffCount

    -- Aggro management array — parsed into { name, condNo } slots.
    _state.combat.aggroOn = Config.get('Aggro', 'AggroOn', '0') == '1'
    local rawAggro = Config.get('Aggro', 'Aggro', nil)
    if type(rawAggro) == 'table' then
        for _, slot in ipairs(Config.parseCondArray(rawAggro)) do
            if slot and slot.name and slot.name ~= '' then
                _state.combat.aggroArray[#_state.combat.aggroArray + 1] = slot
            end
        end
    end

    -- Pet combat config
    _state.pet.assistAt = tonumber(Config.get('Pet', 'PetAssistAt', '100')) or 100
    _state.pet.combatOn = Config.get('Pet', 'PetCombatOn', '1') == '1'

    -- Named-mob watch list — sourced from KissAssist_Info.ini (zone-specific shared file).
    -- TODO: load NamedWatch entries from KissAssist_Info.ini when that file is added to Config.
    -- _state.combat.namedWatchList stays empty until that config path is wired.

    utils.debug('combat', 'Combat.init: dpsOn=%s meleeOn=%s assistAt=%d meleeDistance=%d dps#=%d burn#=%d debuffCount=%d aggroOn=%s campRadius=%d',
        tostring(_state.combat.dpsOn),
        tostring(_state.combat.meleeOn),
        _state.combat.assistAt,
        _state.combat.meleeDistance,
        #_state.combat.dpsArray,
        #_state.combat.burnArray,
        _state.debuff.count,
        tostring(_state.combat.aggroOn),
        _state.movement.campRadius)
end

-- Mirrors MobRadar (kissassist.mac:7143).
-- mode 'los': iterate XTarget auto-hater slots, check 2D radius + z-range + optional LOS.
-- mode 'pull': stub for pull.lua (returns without mutating state).
-- Sets state.combat.mobCount; sets state.combat.aggroTargetID to closest living hater.
function Combat.mobRadar(mode, radius)
    -- DMZ guard: no combat in non-instance DMZ zones
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then
        return
    end

    if mode == 'pull' then
        -- Pull-mode mob detection handled in pull.lua (Step 5.x).
        return
    end

    -- 'los' mode: scan XTarget auto-hater slots
    local count       = 0
    local closestDist = math.huge
    local closestID   = ''
    local losCheck    = Config.get('General', 'LOSBeforeCombat', '0') == '1'
    local meZ         = mq.TLO.Me.Z() or 0

    for i = 1, _state.combat.xSlotTotal do
        local xt = mq.TLO.Me.XTarget(i)
        if not xt then break end
        local ttType = xt.TargetType() or ''
        if ttType ~= 'Auto Hater' then goto continue end

        local id   = xt.ID()   or 0
        local typ  = xt.Type() or ''
        if id == 0 or typ == 'Corpse' then goto continue end

        local dist = xt.Distance() or 999
        local zOff = math.abs((xt.Z() or meZ) - meZ)
        if dist > radius or zOff > 50 then goto continue end

        if losCheck then
            local sp = mq.TLO.Spawn('id ' .. id)
            if not sp or sp.LineOfSight() ~= true then goto continue end
        end

        count = count + 1
        if dist < closestDist then
            closestDist = dist
            closestID   = tostring(id)
        end

        ::continue::
    end

    -- XTSlot fallback: if the macro's assigned xtar slot holds a living non-auto-hater,
    -- ensure it is counted (mirrors the XTSlot post-check in MobRadar).
    local slot = _state.combat.xTSlot
    if slot > 0 then
        local xt  = mq.TLO.Me.XTarget(slot)
        local xid = xt and xt.ID() or 0
        if xid ~= 0 and (xt.Type() or '') ~= 'Corpse' then
            if count == 0 then
                count     = 1
                closestID = tostring(xid)
            elseif (xt.TargetType() or '') ~= 'Auto Hater' then
                count = count + 1
            end
        end
    end

    -- Fallback: only when Me.Combat() is true (character is being attacked).
    -- Tries current target first, then nearest NPC within a generous radius.
    -- _nearspawnFallback tells validateTarget to skip the xtarhater filter.
    _nearspawnFallback = false
    if count == 0 and (mq.TLO.Me.Combat() or false) then
        local tgt   = mq.TLO.Target
        local tID   = tgt.ID()   or 0
        local tType = (tgt.Type() or ''):lower()
        if tID ~= 0 and tType == 'npc' then
            count              = 1
            closestID          = tostring(tID)
            _nearspawnFallback = true
        else
            local nearSp = mq.TLO.NearestSpawn(1, 'npc radius 100 zradius 50')
            local nearID = nearSp and (nearSp.ID() or 0) or 0
            if nearID ~= 0 then
                count              = 1
                closestID          = tostring(nearID)
                _nearspawnFallback = true
            end
        end
    end

    _state.combat.mobCount = count

    -- Update aggroTargetID only when we found something, or clear it when empty.
    if closestID ~= '' then
        _state.combat.aggroTargetID = closestID
    elseif count == 0 then
        _state.combat.aggroTargetID = ''
    end

    _utils.debug('combat', 'mobRadar(%s,%d): mobCount=%d aggro=%s',
        mode, radius, count, _state.combat.aggroTargetID)
end

-- Mirrors Sub Assist (kissassist.mac:748).
-- Non-MA path: use Group.MainAssist shortcut or /assist MainAssist to acquire target.
-- MA path skipped here — MA calls getCombatTarget() instead.
-- Both paths validate and lock state.combat.myTargetID.
function Combat.assist(_fromWhere)
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end
    if not _state.combat.meleeOn and not _state.combat.dpsOn and _state.mez.on == 0 then return end
    if _state.dps.paused then return end
    if mq.TLO.Me.Hovering() then return end
    if _state.pull.pulled and _state.combat.myTargetID ~= 0 and _state.session.iAmMA then return end

    mq.doevents()
    Combat.mobRadar('los', _state.combat.meleeDistance)

    local mobCount = _state.combat.mobCount
    local aggroID  = tonumber(_state.combat.aggroTargetID) or 0
    local ma       = _state.session.mainAssist
    local maSpawn  = mq.TLO.Spawn('=' .. ma)
    local maID     = maSpawn and maSpawn.ID() or 0
    local maDist   = maSpawn and maSpawn.Distance() or 999

    if mobCount > 0 or aggroID ~= 0 then
        if maID ~= 0 then
            if maDist < 200 then
                local groupMAID  = mq.TLO.Group.MainAssist.ID() or 0
                if groupMAID ~= 0 and groupMAID == maID then
                    -- Group MA shortcut: use Me.GroupAssistTarget
                    local assistTgtID = mq.TLO.Me.GroupAssistTarget.ID() or 0
                    if assistTgtID ~= 0 then
                        mq.cmd('/target id ' .. assistTgtID)
                        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == assistTgtID end)
                    elseif (mq.TLO.Target.ID() or 0) ~= 0 then
                        mq.cmd('/squelch /target clear')
                        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == 0 end)
                        _state.combat.myTargetID = 0
                    end
                else
                    -- Manual /assist
                    mq.cmd('/assist ' .. ma)
                    mq.delay(1000, function() return mq.TLO.Me.AssistComplete() == true end)
                    local xSlot = _state.combat.xTSlot
                    if _state.combat.xTarAutoSet
                       and not mq.TLO.Group.Member(ma).Index()
                       and not _state.session.iAmMA
                       and xSlot > 0
                       and (mq.TLO.Me.XTarget(xSlot).ID() or 0) == 0
                       and (mq.TLO.Target.Type() or '') ~= 'PC' then
                        mq.cmd('/xtarget set ' .. xSlot .. ' currenttarget')
                    end
                end
            elseif _state.session.role == 'offtank' then
                -- MA out of range and we're offtank — nothing to do
                return
            elseif aggroID ~= 0 then
                if (mq.TLO.Spawn('id ' .. aggroID).Distance() or 999) <= _state.combat.meleeDistance then
                    mq.cmd('/squelch /target id ' .. aggroID)
                    mq.delay(1000)
                end
            end
        end
    end

    local targetID = mq.TLO.Target.ID() or 0
    if targetID == 0 then return end

    local tempTargetID = targetID
    local valid = validateTarget(nil)

    if not valid then
        _state.combat.myTargetID   = 0
        _state.combat.myTargetName = ''
        return
    end

    if (mq.TLO.Target.ID() or 0) ~= tempTargetID then
        mq.cmd('/squelch /target clear')
        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == 0 end)
        mq.cmd('/target id ' .. tempTargetID)
        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) ~= 0 end)
    end

    local xSlot = _state.combat.xTSlot
    if _state.combat.xTarAutoSet
       and not mq.TLO.Group.Member(ma).Index()
       and not _state.session.iAmMA
       and xSlot > 0
       and (mq.TLO.Me.XTarget(xSlot).ID() or 0) == 0
       and (mq.TLO.Target.Type() or '') ~= 'PC' then
        mq.cmd('/xtarget set ' .. xSlot .. ' currenttarget')
    end

    _state.combat.myTargetID   = mq.TLO.Target.ID() or 0
    _state.combat.myTargetName = mq.TLO.Target.CleanName() or ''
    _state.combat.lastTargetID = _state.combat.myTargetID

    _utils.debug('combat', 'assist: myTarget=%s id=%d', _state.combat.myTargetName, _state.combat.myTargetID)
end

-- Mirrors Sub GetCombatTarget (kissassist.mac:818).
-- MA/offtank path: selects a target from XTarget auto-hater slots.
-- Priority: named mob > mez-immune (alert 4) > closest with hurt/level tie-breaks.
-- Falls back to mem-blurred mob scan when no haters remain and MezMobFlag is set.
function Combat.getCombatTarget()
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end
    if not _state.combat.meleeOn and not _state.combat.dpsOn and _state.mez.on == 0 then return end
    if _state.dps.paused then return end
    if mq.TLO.Me.Hovering() then return end
    if _state.pull.pulled and _state.combat.myTargetID ~= 0 and _state.session.iAmMA then return end

    mq.doevents()

    -- Stale aggroTargetID2 check
    local aggroID2 = tonumber(_state.combat.aggroTargetID2) or 0
    if aggroID2 ~= 0 then
        local sp2    = mq.TLO.Spawn('id ' .. aggroID2)
        local sp2typ = sp2 and sp2.Type() or ''
        if not sp2 or (sp2.ID() or 0) == 0 or sp2typ:lower() == 'corpse' then
            _state.combat.aggroTargetID2 = '0'
            aggroID2 = 0
        end
    end

    Combat.mobRadar('los', _state.combat.meleeDistance)

    local mobCount  = _state.combat.mobCount
    local aggroID   = tonumber(_state.combat.aggroTargetID) or 0
    local ma        = _state.session.mainAssist
    local maSpawn   = mq.TLO.Spawn('=' .. ma)
    local maID      = maSpawn and maSpawn.ID() or 0
    local iAmMA     = _state.session.iAmMA
    local isOfftank = _state.session.role == 'offtank'
    local noMA      = maID == 0

    if not (iAmMA or (noMA and isOfftank)) then return end

    -- Clear self-target when mobs are present
    if (mq.TLO.Target.CleanName() or '') == (mq.TLO.Me.CleanName() or '')
       and (mobCount > 0 or aggroID ~= 0) then
        mq.cmd('/squelch /target clear')
    end

    local xSlot2 = _state.combat.xTSlot2
    local md     = _state.combat.meleeDistance

    if mobCount == 1
       and (xSlot2 == 0 or (mq.TLO.Me.XTarget(xSlot2).ID() or 0) == 0)
       and aggroID ~= 0 then
        -- Single mob
        mq.cmd('/squelch /target id ' .. aggroID)
        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == aggroID end)

    elseif (mobCount >= 2 or (xSlot2 ~= 0 and (mq.TLO.Me.XTarget(xSlot2).ID() or 0) ~= 0))
           and aggroID ~= 0 then
        -- Multiple mobs — priority: named > alert-4 > closest/hurt/level
        local namedID = mq.TLO.Spawn('xtarhater named').ID() or 0
        if namedID ~= 0 then
            mq.cmd('/squelch /target id ' .. namedID)
            mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == namedID end)

        elseif (mq.TLO.Alert(4).Size() or 0) > 0 then
            local a4sp   = mq.TLO.Spawn('xtarhater alert 4')
            local a4id   = a4sp and a4sp.ID() or 0
            local a4type = a4id ~= 0 and (mq.TLO.Spawn('id ' .. a4id).Type() or '') or ''
            if a4id ~= 0 and a4type:lower() ~= 'corpse' then
                local nearA4 = mq.TLO.NearestSpawn(1, 'xtarhater alert 4')
                local nearID = nearA4 and nearA4.ID() or 0
                if nearID ~= 0 then
                    mq.cmd('/squelch /target id ' .. nearID)
                    mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == nearID end)
                end
            end

        else
            -- Iterate all xtarhater spawns; find closest, highest level, most hurt
            local j = mq.TLO.SpawnCount('xtarhater')() or 0
            if j > 0 then
                local first = mq.TLO.NearestSpawn(1, 'xtarhater')
                local firstID = first and first.ID() or 0
                if firstID ~= 0 then
                    local closestID   = firstID
                    local highestID   = firstID
                    local mostHurtID  = firstID
                    local highestLvl  = first.Level()  or 0
                    local mostHurtPct = first.PctHPs() or 100

                    for n = 2, j do
                        local ns  = mq.TLO.NearestSpawn(n, 'xtarhater')
                        local nid = ns and ns.ID() or 0
                        if nid == 0 then break end
                        local pct = ns.PctHPs() or 100
                        local lvl = ns.Level()  or 0
                        if pct < mostHurtPct then mostHurtID = nid; mostHurtPct = pct end
                        if lvl > highestLvl   then highestID  = nid; highestLvl  = lvl end
                    end

                    -- undead/special animation IDs that warrant level-based priority upgrade
                    local undeadAnims = {[26]=true,[32]=true,[71]=true,[72]=true,[110]=true,[111]=true}
                    local tempID = closestID
                    local campY  = _state.movement.campY
                    local campX  = _state.movement.campX

                    local function applyPriority(inCamp)
                        local mhSp = mq.TLO.Spawn('id ' .. mostHurtID)
                        local mhY  = mhSp and mhSp.Y() or 0
                        local mhX  = mhSp and mhSp.X() or 0
                        local mhIn = inCamp
                            and dist2D(campY, campX, mhY, mhX) <= md
                            or  (not inCamp and (mhSp and mhSp.Distance() or 999) <= md)
                        if mostHurtID ~= 0 and closestID ~= mostHurtID and mhIn then
                            tempID = mostHurtID
                        end
                        if tempID ~= highestID then
                            local cSp = mq.TLO.Spawn('id ' .. tempID)
                            local hSp = mq.TLO.Spawn('id ' .. highestID)
                            local hY  = hSp and hSp.Y() or 0
                            local hX  = hSp and hSp.X() or 0
                            local hIn = inCamp
                                and dist2D(campY, campX, hY, hX) <= md
                                or  (not inCamp and (hSp and hSp.Distance() or 999) <= md)
                            if (cSp and cSp.Level() or 0) < (hSp and hSp.Level() or 0)
                               and undeadAnims[cSp and cSp.Animation() or 0]
                               and hIn then
                                tempID = highestID
                            end
                        end
                        return tempID
                    end

                    if _state.movement.returnToCamp then
                        tempID = applyPriority(true)
                        local tSp = mq.TLO.Spawn('id ' .. tempID)
                        local tY  = tSp and tSp.Y() or 0
                        local tX  = tSp and tSp.X() or 0
                        if (mq.TLO.Target.ID() or 0) ~= tempID
                           and dist2D(campY, campX, tY, tX) <= md then
                            mq.cmd('/squelch /target id ' .. tempID)
                            mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == tempID end)
                        end
                    else
                        tempID = applyPriority(false)
                        local tSp = mq.TLO.Spawn('id ' .. tempID)
                        if (mq.TLO.Target.ID() or 0) ~= tempID
                           and (tSp and tSp.Distance() or 999) <= md then
                            mq.cmd('/squelch /target id ' .. tempID)
                            mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == tempID end)
                        end
                    end
                end
            end
        end

    elseif aggroID == 0 and mobCount > 0 and _state.mez.mobFlag then
        -- MezMobFlag: scan for mem-blurred mobs inside camp radius
        local blurSp = mq.TLO.NearestSpawn(1, 'npc targetable los radius ' .. md .. ' zradius 50 noalert 3')
        local blurID = blurSp and blurSp.ID() or 0
        if blurID ~= 0 then
            local bY = blurSp.Y() or 0
            local bX = blurSp.X() or 0
            if dist2D(_state.movement.campY, _state.movement.campX, bY, bX) < md then
                mq.cmd('/squelch /target id ' .. blurID)
                _state.mez.mobFlag = false
                mq.delay(1500, function()
                    return (mq.TLO.Target.ID() or 0) == blurID
                        and mq.TLO.Target.BuffsPopulated() == true
                end)
                if mq.TLO.Target.Mezzed.ID() then
                    _state.combat.aggroTargetID2 = tostring(blurID)
                    _state.combat.myTargetID     = mq.TLO.Target.ID() or 0
                    _state.combat.myTargetName   = mq.TLO.Target.CleanName() or ''
                    _state.combat.lastTargetID   = _state.combat.myTargetID
                else
                    if (mq.TLO.Target.ID() or 0) ~= 0 then
                        mq.cmd('/squelch /alert add 3 id ' .. blurID)
                    end
                end
                return
            end
            _state.mez.mobFlag = false
        end
    end

    local targetID = mq.TLO.Target.ID() or 0
    if targetID == 0 then return end

    local tempID = targetID
    local valid  = validateTarget(nil)

    if not valid then
        _state.combat.myTargetID   = 0
        _state.combat.myTargetName = ''
        return
    end

    if (mq.TLO.Target.ID() or 0) ~= tempID then
        mq.cmd('/squelch /target clear')
        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == 0 end)
        mq.cmd('/target id ' .. tempID)
        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) ~= 0 end)
    end

    _state.combat.myTargetID   = mq.TLO.Target.ID() or 0
    _state.combat.myTargetName = mq.TLO.Target.CleanName() or ''
    _state.combat.lastTargetID = _state.combat.myTargetID

    _utils.debug('combat', 'getCombatTarget: myTarget=%s id=%d', _state.combat.myTargetName, _state.combat.myTargetID)
end

-- Mirrors Sub CombatTargetCheck (kissassist.mac:1337).
-- Syncs state.combat.myTargetID to the group assist target or a CalledTargetID from events.
-- setTarget: 0=no forced re-target, 1=re-target when changed, 2=bypass DPSPaused guard
function Combat.combatTargetCheck(setTarget)
    setTarget = setTarget or 0

    if _state.session.iAmMA then
        if _state.combat.targetSwitchingOn
           and (mq.TLO.Target.ID() or 0) ~= 0
           and (mq.TLO.Target.Type() or ''):lower() == 'corpse' then
            return
        end
    else
        if _state.combat.targetSwitchingOn then return end
    end

    if _state.dps.paused and setTarget ~= 2 then return end

    -- Clear myTargetID if current target is dead or gone
    local myID = _state.combat.myTargetID
    if myID ~= 0 then
        local sp     = mq.TLO.Spawn('id ' .. myID)
        local spType = sp and sp.Type() or ''
        if (sp and sp.ID() or 0) == 0 or spType:lower() == 'corpse' then
            _state.combat.lastTargetID = myID
            _state.combat.myTargetID   = 0
            return
        end
    end

    local cMyTargetID = _state.combat.myTargetID
    local ma          = _state.session.mainAssist
    local maSpawn     = mq.TLO.Spawn('=' .. ma)
    local maID        = maSpawn and maSpawn.ID() or 0
    local groupMAID   = mq.TLO.Group.MainAssist.ID() or 0

    if maID ~= 0 and groupMAID ~= 0 and maID == groupMAID then
        if not _state.session.iAmMA then
            -- Non-MA: sync myTargetID to group assist target
            local assistID = mq.TLO.Me.GroupAssistTarget.ID() or 0
            if (mq.TLO.Target.ID() or 0) ~= assistID then
                if _state.combat.myTargetID ~= assistID
                   and assistID ~= 0
                   and (mq.TLO.Spawn('id ' .. assistID .. ' npc').ID() or 0) ~= 0 then
                    _state.combat.myTargetID = assistID
                end
            end
        else
            -- MA: accept new target when TargetSwitchingOn, or re-lock when not
            local tgtID = mq.TLO.Target.ID() or 0
            if tgtID ~= 0 and tgtID ~= _state.combat.myTargetID then
                if _state.combat.targetSwitchingOn then
                    local tgtType      = mq.TLO.Target.Type() or ''
                    local tgtTypeLower = tgtType:lower()
                    local isPCOwned    = tgtTypeLower == 'pet'
                                        and (mq.TLO.Target.Master.Type() or '') == 'PC'
                    local isNonPC      = tgtTypeLower ~= 'pc'
                                        and tgtTypeLower ~= 'mercenary'
                    if isNonPC and not isPCOwned then
                        _state.combat.myTargetID   = tgtID
                        _state.combat.myTargetName = mq.TLO.Target.CleanName() or ''
                        if _state.combat.lastCalledTargetID ~= tgtID then
                            local role = _state.session.role
                            local petName = mq.TLO.Me.Pet.CleanName() or 'Pet'
                            if role == 'tank' or role == 'pullertank' or role == 'hunter' then
                                mq.cmd('/echo [KA] TANKING-> ' .. _state.combat.myTargetName .. ' <- ID:' .. tgtID)
                            elseif role == 'pettank' or role == 'pullerpettank' or role == 'hunterpettank' then
                                mq.cmd('/echo [KA] ' .. petName .. ' is TANKING-> ' .. _state.combat.myTargetName .. ' <- ID:' .. tgtID)
                            end
                            _state.combat.lastCalledTargetID = tgtID
                        end
                    end
                else
                    if _state.combat.myTargetID ~= 0 then
                        mq.cmd('/target id ' .. _state.combat.myTargetID)
                        mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == _state.combat.myTargetID end)
                    end
                end
            end
        end
        _state.combat.calledTargetID = 0
        mq.doevents()  -- drain AttackCalled events
    else
        -- No group MA: process CalledTargetID set by AttackCalled event handler
        _state.combat.eventFlag = false
        mq.doevents()
        if _state.combat.calledTargetID ~= 0
           and _state.combat.calledTargetID ~= _state.combat.myTargetID then
            _state.combat.myTargetID     = _state.combat.calledTargetID
            _state.combat.calledTargetID = 0
        end
    end

    -- Re-target if myTargetID changed
    local newID = _state.combat.myTargetID
    if cMyTargetID ~= newID and (mq.TLO.Target.ID() or 0) ~= newID
       and newID ~= 0 and (mq.TLO.Spawn('id ' .. newID).ID() or 0) ~= 0 then
        if _state.combat.xTarAutoSet
           and not mq.TLO.Group.Member(ma).Index()
           and not _state.session.iAmMA then
            if (mq.TLO.Spawn('id ' .. newID).Type() or ''):lower() ~= 'pc' then
                mq.cmd('/squelch /target id ' .. newID)
                mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == newID end)
                local xSlot = _state.combat.xTSlot
                if xSlot > 0 then
                    local xtID = mq.TLO.Me.XTarget(xSlot).ID() or 0
                    if xtID == 0 or xtID ~= newID then
                        mq.cmd('/xtarget set ' .. xSlot .. ' currenttarget')
                    end
                end
            end
        elseif setTarget ~= 0 then
            mq.cmd('/squelch /target id ' .. newID)
            mq.delay(1000, function() return (mq.TLO.Target.ID() or 0) == newID end)
        end
        _state.combat.myTargetName = mq.TLO.Spawn('id ' .. newID).CleanName() or ''
        _state.combat.lastTargetID = newID
    end

    _utils.debug('combat', 'combatTargetCheck: myTarget=%s id=%d lastID=%d',
        _state.combat.myTargetName, _state.combat.myTargetID, _state.combat.lastTargetID)
end

-- Mirrors Sub Combat (kissassist.mac:1036).
-- Executes the melee/spell combat loop for the current myTargetID until the mob dies.
-- Called from checkForCombat once a target has been acquired.
function Combat.fight(fromWhere)
    mq.doevents()

    local myID = _state.combat.myTargetID
    if myID == 0 or (mq.TLO.Target.ID() or 0) == 0 then return end
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end

    -- LOS check; hunter roles bypass it (mac:1042-1043)
    local role     = _state.session.role
    local isHunter = role == 'hunter' or role == 'hunterpettank'
    if not mq.TLO.Target.LineOfSight() and not isHunter then return end

    if _state.dps.paused then return end

    -- Mezzed target: non-MA won't attack below assistAt% to avoid breaking mez (mac:1047-1053)
    if mq.TLO.Target.Mezzed.ID() then
        if (mq.TLO.Spawn('=' .. _state.session.mainAssist).ID() or 0) ~= 0
           and not _state.session.iAmMA then
            local pct = mq.TLO.Spawn('id ' .. myID).PctHPs() or 100
            if pct <= _state.combat.assistAt then
                mq.delay(500)
                return
            end
        end
    end

    -- Puller: don't engage while actively pulling and outside camp radius (mac:1039)
    local isPuller = role == 'puller' or role == 'pullertank' or role == 'pullerpettank'
    if isPuller and _state.pull.pulling then
        local campDist = dist2D(_state.movement.campY, _state.movement.campX,
                                mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= _state.movement.campRadius then return end
    end

    -- CombatRadius: MaxRangeTo+5 if it exceeds MeleeDistance (mac:1056)
    local sp = mq.TLO.Spawn('id ' .. myID)
    local maxRange     = sp and sp.MaxRangeTo() or 0
    local combatRadius = _state.combat.meleeDistance
    if maxRange > combatRadius then combatRadius = maxRange + 5 end

    -- Deferred: CheckCures/CheckHealth (M5), DoWeChase (M7), MezCheck (M4.x), DPS meter (M9)

    -- Initial pet engagement check (mac:1078)
    sp = mq.TLO.Spawn('id ' .. myID)
    if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
       and (sp and sp.Distance3D() or 999) < _state.pet.attackRange then
        combatPet()
    end

    -- Determine range condition (mob in melee range or MA+target both in camp) (mac:1080)
    sp = mq.TLO.Spawn('id ' .. myID)
    local mobPct  = sp and sp.PctHPs() or 100
    local mobDist = sp and sp.Distance()  or 999
    local spType  = sp and sp.Type()      or ''

    local maSpawn  = mq.TLO.Spawn('=' .. _state.session.mainAssist)
    local maY, maX = (maSpawn and maSpawn.Y() or 0), (maSpawn and maSpawn.X() or 0)
    local tgtY = sp and sp.Y() or 0
    local tgtX = sp and sp.X() or 0
    local campToMA = dist2D(_state.movement.campY, _state.movement.campX, maY, maX)
    local maToTgt  = dist2D(maY, maX, tgtY, tgtX)
    local cr       = _state.movement.campRadius
    local inRange  = mobDist < combatRadius
                  or (campToMA <= cr and maToTgt <= cr)

    -- ─── Main engage block: not corpse, HP ≤ assistAt (MA always engages), in range ──
    if spType:lower() ~= 'corpse'
       and (_state.session.iAmMA or mobPct <= _state.combat.assistAt)
       and inRange then

        -- CombatStart: announce first attack (mac:1081-1093)
        if not _state.combat.combatStart then
            _utils.debug('combat', 'fight: CombatStart set, Attacking=%s', tostring(_state.combat.attacking))
            _state.session.mercAssisting = false
            _state.combat.combatStart    = true
            local tgtName = mq.TLO.Spawn('id ' .. myID).CleanName() or '?'
            mq.cmd('/echo  ATTACKING -> ' .. tgtName .. ' <-')
            if _bard then _bard.doBardStuff() end
            -- BroadCast (deferred M9); echo locally for now
            if role == 'tank' or role == 'pullertank' or role == 'hunter' then
                mq.cmd('/echo [KA] TANKING-> ' .. tgtName .. ' <- ID:' .. myID)
            elseif role == 'pettank' or role == 'pullerpettank' or role == 'hunterpettank' then
                local petName = mq.TLO.Me.Pet.CleanName() or 'Pet'
                mq.cmd('/echo [KA] ' .. petName .. ' is TANKING-> ' .. tgtName .. ' <- ID:' .. myID)
            end
            -- Hunter LOS position (deferred M7)
        end

        -- Face mob every tick when enabled (mac:1094)
        if _state.movement.faceMobOn and (mq.TLO.Target.ID() or 0) ~= 0
           and (mq.TLO.Me.Standing() or mq.TLO.Me.Mount.ID()) then
            mq.cmd('/squelch /face fast nolook')
        end

        -- Look level when not underwater (mac:1095)
        if not mq.TLO.Me.FeetWet() then mq.cmd('/squelch /look 0') end

        -- Initiate attack (mac:1097-1127); AutoFireOn treated as always off (deferred)
        if not _state.combat.attacking then
            if _state.combat.meleeOn then
                if (mq.TLO.Me.Casting.ID() or 0) ~= 0
                        or mq.TLO.Window('CastingWindow').Open() then
                    goto skip_first_engage
                end
                _state.combat.attacking = true
                if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                -- Taunt for tank/hunter on first engage (mac:1105)
                local isTankLike = role == 'tank' or role == 'pullertank' or role == 'hunter'
                if isTankLike and (mq.TLO.Me.Skill('Taunt')() or 0) > 0
                   and mq.TLO.Me.AbilityReady('Taunt')() then
                    mq.cmd('/doability Taunt')
                end
                -- BeforeAttack abilities before first swing (mac:1107)
                if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
                    beforeAttack(myID, 1)
                end
                -- Pet (mac:1108-1110)
                if _state.pet.combatOn and (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
                    sp = mq.TLO.Spawn('id ' .. myID)
                    if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
                       and not mq.TLO.Pet.Combat() then
                        combatPet()
                    end
                end
                if _movement then _movement.checkStick(0, 1) end
                if _movement then _movement.zAxisCheck() end
            else
                -- MeleeOn off: pet-only combat (mac:1119-1127)
                if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
                if _state.pet.combatOn and (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
                    sp = mq.TLO.Spawn('id ' .. myID)
                    if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
                       and not mq.TLO.Pet.Combat() then
                        combatPet()
                        _state.combat.attacking = true
                    end
                end
            end
        end
        ::skip_first_engage::

        -- Enable mez-mob scan for tank roles (mac:1131)
        if role == 'tank' or role == 'pullertank'
           or role == 'pettank' or role == 'pullerpettank' then
            _state.mez.mobFlag = true
        end

        -- ─── Inner combat while loop (mac:1132-1315) ─────────────────────────
        while true do
            -- Drain all pending events before each iteration (mac:1135-1138)
            repeat
                _state.combat.eventFlag = false
                mq.doevents()
            until not _state.combat.eventFlag

            -- Pause all commands while player or script is casting
            if (mq.TLO.Me.Casting.ID() or 0) ~= 0
                    or mq.TLO.Window('CastingWindow').Open() then
                mq.delay(50)
                goto continue_fight
            end

            -- Burn if flagged (mac:1139-1141)
            if _state.combat.burnOn and _state.combat.burnID ~= 0 then
                if _cast.doBurn then _cast.doBurn() end
                _state.combat.burnID = 0
            end

            -- Deferred: SwitchMA offtank (M9), MercsDoWhat (M6)
            -- Deferred: stick/distance maintenance (M7)
            if _mez then _mez.check('Combat') end
            if _mez then _mez.aeCheck() end
            if _bard then _bard.doBardStuff() end
            -- AggroCheck (mac:1165)
            if _state.combat.aggroOn and _cast and _cast.castWhat then
                Combat.aggroCheck()
            end

            -- CheckCures / CheckHealth (mac:1166-1167)
            if _heal then
                _heal.checkCures()
                _heal.checkHealth('Combat')
            end

            -- NamedWatch: trigger burn on named mob in range (mac:1177, mac:12884)
            if not _state.combat.namedCheck and _state.combat.burnOnNamed then
                sp = mq.TLO.Spawn('id ' .. myID)
                if sp and (sp.Distance() or 999) <= _state.combat.meleeDistance then
                    local tName   = sp.CleanName() or ''
                    local isNamed = sp.Named() or false
                    -- Also check namedWatchList (BurnAllNamed==2 mode: specific mobs only)
                    if not isNamed and #_state.combat.namedWatchList > 0 then
                        for _, wName in ipairs(_state.combat.namedWatchList) do
                            if wName ~= '' and wName ~= 'null' then
                                local ws = mq.TLO.Spawn(wName)
                                if ws and ws.ID() == myID and ws.CleanName() == tName then
                                    isNamed = true
                                    break
                                end
                            end
                        end
                    end
                    if isNamed then
                        mq.cmd('/popup *** Mob:(' .. tName .. ') is a NAMED!')
                        mq.cmd('/echo *** Mob:(' .. tName .. ') is a NAMED!')
                        if _cast.doBurn then _cast.doBurn() end
                        _state.combat.namedCheck = true
                    end
                end
            end

            -- Non-chainpull DPS path (mac:1178-1200)
            if not (isPuller and _state.pull.chainPull) then
                sp = mq.TLO.Spawn('id ' .. myID)
                local curType = (sp and sp.Type() or ''):lower()
                -- Dead/paused: exit combat (mac:1185-1187)
                if curType == 'corpse' or (sp and sp.ID() or 0) == 0 or _state.dps.paused then
                    Combat.combatReset(0, fromWhere .. '_inner')
                    break
                end

                if _state.combat.dpsOn then
                    -- Make visible if pure caster with no aggro timer (mac:1190)
                    if not _state.combat.meleeOn
                       and (_state.timers.aggroOff or 0) == 0
                       and mq.TLO.Me.Invis() then
                        mq.cmd('/makemevisible')
                    end
                    -- DoDebuffStuff: apply debuff-all DPS slots to target + nearby haters (mac:1179)
                    if (_state.debuff.on or 0) > 0 and _cast.doDebuffStuff then
                        _cast.doDebuffStuff(_state.combat.myTargetID)
                        myID = _state.combat.myTargetID
                        if myID == 0 then
                            Combat.combatReset(0, fromWhere .. '_afterDebuff')
                            break
                        end
                    end
                    -- CombatCast (mac:1191) — cast module provides this in Step M4.6+
                    if _cast.combatCast then
                        local ccResult = _cast.combatCast()
                        myID = _state.combat.myTargetID
                        if myID == 0 then
                            Combat.combatReset(0, fromWhere .. '_afterCast')
                            break
                        end
                        -- tcnc = this cast no combat: restart loop iteration (mac:1196)
                        if ccResult == 'tcnc' then goto continue_fight end
                    end
                else
                    -- MashButtons (deferred)
                end
            end

            -- WriteDebuffs + second cure/heal check (mac:1200-1215)
            if _heal then
                _heal.writeDebuffs()
                _heal.checkCures()
                _heal.checkHealth('Combat2')
            end

            -- Sync target state (mac:1216)
            Combat.combatTargetCheck(1)
            myID = _state.combat.myTargetID

            -- Re-engage if target alive and in range (mac:1217-1253)
            sp = mq.TLO.Spawn('id ' .. (myID ~= 0 and myID or 0))
            if myID ~= 0 and (sp and sp.Type() or ''):lower() ~= 'corpse'
               and not _state.dps.paused then
                -- Melee re-attack (mac:1218-1240); AutoFireOn always off here (deferred)
                if _state.combat.attacking and _state.combat.meleeOn then
                    local tgtPct  = sp and sp.PctHPs() or 100
                    local tgtDist = sp and sp.Distance() or 999
                    if tgtPct <= _state.combat.assistAt and tgtDist < combatRadius then
                        -- Re-target if we drifted (mac:1222-1224)
                        if not _state.combat.targetSwitchingOn
                           and (mq.TLO.Target.ID() or 0) ~= myID then
                            mq.cmd('/squelch /target id ' .. myID)
                            mq.delay(500, function()
                                return (mq.TLO.Target.ID() or 0) == myID
                            end)
                        end
                        -- CheckStick (deferred M7)
                    end
                    -- Keep attack on while standing (mac:1237)
                    if (mq.TLO.Target.ID() or 0) ~= 0 then
                        local meState = (mq.TLO.Me.State() or ''):lower()
                        if meState == 'stand' or meState == 'mount' then
                            mq.cmd('/squelch /attack on')
                        end
                    end
                end
                -- Pet engagement each iteration (mac:1249-1253)
                if _state.pet.combatOn and (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
                    sp = mq.TLO.Spawn('id ' .. myID)
                    if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
                       and not mq.TLO.Pet.Combat() then
                        combatPet()
                    end
                end
                -- ChainPull puller path (deferred M5)

            else
                -- Target dead or gone (mac:1278-1309)
                if _state.dps.paused or not _state.combat.targetSwitchingOn then
                    Combat.combatReset(0, fromWhere .. '_targetGone')
                    break
                end
                -- TargetSwitching: MA acquires next target (mac:1283-1308)
                if _state.session.iAmMA then
                    local curTgt = mq.TLO.Target.ID() or 0
                    if curTgt ~= 0 and curTgt ~= myID then
                        _state.combat.lastTargetID = myID
                        _state.combat.myTargetID   = 0
                        Combat.combatTargetCheck(1)
                        myID = _state.combat.myTargetID
                        if myID == 0 then
                            _state.combat.myTargetID = _state.combat.lastTargetID
                            Combat.combatReset(0, fromWhere .. '_noNextTarget')
                            break
                        end
                        goto continue_fight
                    else
                        Combat.combatReset(0, fromWhere .. '_maNoTarget')
                        break
                    end
                else
                    Combat.combatReset(0, fromWhere .. '_noTarget')
                    break
                end
            end

            -- FeignAggroCheck: exit loop if still feigning after this iteration (mac:1310-1314)
            if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then
                Combat.feignAggroCheck()
                mq.delay(250)
                if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then break end
            end

            ::continue_fight::
        end

    -- ─── Out-of-HP-range block: mob in camp but above assistAt% (mac:1316-1331) ──
    elseif inRange then
        -- Burn check
        if _state.combat.burnOn and _state.combat.burnID ~= 0 then
            if _cast.doBurn then _cast.doBurn(_state.combat.burnID) end
            _state.combat.burnID = 0
        end
        -- Sync target
        if _state.combat.dpsOn or _state.combat.meleeOn or _state.pet.activeState then
            Combat.combatTargetCheck(1)
            myID = _state.combat.myTargetID
        end
        -- Pet / mez (mac:1322-1329)
        if _state.pet.activeState and _state.pet.combatOn and myID ~= 0 then
            if _mez then _mez.check('Combat') end
            sp = mq.TLO.Spawn('id ' .. myID)
            if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
               and not mq.TLO.Pet.Combat() then
                combatPet()
            end
        end
        -- Deferred: Bard twist (mac:1327, M8)
        -- DebuffAllOn==2: debuff adds even when not at melee range (mac:1328)
        if (_state.debuff.on or 0) == 2 and _state.combat.myTargetID ~= 0
           and (_state.combat.aggroTargetID or '') ~= '' and _cast.doDebuffStuff then
            _cast.doDebuffStuff(_state.combat.myTargetID)
        end
        -- BeforeAttack condCheck=2: fire only |cond entries (mac:1330)
        if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
            beforeAttack(myID, 2)
        end
    end

    _utils.debug('combat', 'fight: done from=%s', tostring(fromWhere))
end

-- Mirrors Sub FeignAggroCheck (kissassist.mac:14524).
-- If still feigning/invis after combat, waits out the aggroOff timer before standing.
function Combat.feignAggroCheck()
    local expiry = _state.timers.aggroOff or 0
    if expiry ~= 0 and os.clock() < expiry then
        while mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() do
            mq.doevents()
            mq.delay(250)
        end
    else
        mq.doevents()
    end
end

-- Mirrors Sub AggroCheck (kissassist.mac:2373).
-- Iterates aggroArray casting aggro-management abilities based on pctAggro thresholds.
-- Entry format: spellName|pct|glt|target  where glt is < (gain) >> << (secondary) >> > (lose).
function Combat.aggroCheck()
    local myID = _state.combat.myTargetID
    if myID == 0 then return end
    local sp = mq.TLO.Spawn('id ' .. myID)
    if not sp or (sp.Type() or ''):lower() == 'corpse' or (sp.ID() or 0) == 0 then return end

    -- MA with target-switching: sync target first (mac:2383)
    if _state.session.iAmMA and _state.combat.targetSwitchingOn
       and (mq.TLO.Target.ID() or 0) ~= 0
       and (mq.TLO.Target.ID() or 0) ~= myID
       and _state.combat.combatStart then
        Combat.combatTargetCheck(1)
    end
    if _state.combat.myTargetID == 0 then return end

    for _, entry in ipairs(_state.combat.aggroArray) do
        if not entry then break end
        local condNo = entry.condNo or 0
        if condNo > 0 and _cond and not _cond.eval(condNo) then goto next_aggro end
        local rawEntry = entry.name or ''
        if rawEntry == 'null' or rawEntry == '' then break end

        -- Parse: spellName|pct|glt|target
        local parts = {}
        for p in (rawEntry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
        local spellName  = parts[1] or ''
        local pct        = tonumber(parts[2] or '') or 0
        local glt        = parts[3] or ''
        local targetType = parts[4] or ''

        if spellName == '' or spellName == 'null' then goto next_aggro end

        -- Skip active self-disc (mac:2410)
        if (mq.TLO.Me.CombatAbility(spellName).ID() or 0) ~= 0 then
            local asSp = mq.TLO.Spell(spellName)
            if asSp and (asSp.Duration() or 0) > 0
               and ((asSp.TargetType() or ''):lower() == 'self')
               and (mq.TLO.Me.ActiveDisc.ID() or 0) ~= 0 then
                goto next_aggro
            end
        end

        -- Ability ready check (mac:2395)
        if not mq.TLO.Me.SpellReady(spellName)()
           and not mq.TLO.Me.AltAbilityReady(spellName)()
           and not mq.TLO.Me.AbilityReady(spellName)()
           and not mq.TLO.Me.CombatAbilityReady(spellName)() then
            goto next_aggro
        end

        -- Aggro threshold check (mac:2397-2409)
        local myPct  = mq.TLO.Me.PctAggro() or 0
        local secPct = mq.TLO.Target.SecondaryPctAggro() or 0
        if glt == '<' then
            -- Gain aggro: cast when my aggro is below pct
            if pct <= myPct then goto next_aggro end
        elseif glt == '<<' then
            -- Secondary aggro: cast when secondary holder is above (pct-100)%
            local adjPct = pct - 100
            if secPct == 0 or secPct < adjPct then goto next_aggro end
        elseif glt == '>' then
            -- Lose aggro: cast when my aggro is above pct
            if pct > myPct then goto next_aggro end
        else
            goto next_aggro
        end

        -- Resolve cast target (mac:2412-2420)
        local aggroTID = myID
        local tl = targetType:lower()
        if tl == 'me' then
            aggroTID = mq.TLO.Me.ID() or 0
        elseif tl == 'ma' then
            aggroTID = mq.TLO.Spawn('=' .. _state.session.mainAssist).ID() or 0
        elseif tl == 'pet' then
            aggroTID = mq.TLO.Me.Pet.ID() or 0
        elseif tl == 'inc' then
            -- INC: target mob only when in melee range; skip if close (mac:2421)
            if (mq.TLO.Spawn('id ' .. myID).Distance() or 0) < _state.combat.meleeDistance then
                goto next_aggro
            end
        end
        if aggroTID == 0 then goto next_aggro end

        -- Cast (mac:2423)
        local result = _cast.castWhat(spellName, aggroTID, 'Aggro', 0, 0)
        if result == 'CAST_SUCCESS' then
            printf('Casting >> %s << to control AGGRO(%s) on %s',
                spellName, glt,
                mq.TLO.Spawn('id ' .. aggroTID).CleanName() or '')
            -- Start aggroOff timer on lose-aggro cast if feigning/invis (mac:2427-2429)
            if glt == '>' and (_state.timers.aggroOff or 0) == 0 then
                if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then
                    _state.timers.aggroOff = os.clock() + 20
                end
            end
            break  -- one aggro ability per call (mac:2431)
        end
        -- Break-early if threshold already satisfied after failed cast (mac:2433-2435)
        if glt == '>' and pct > myPct then break end
        if glt == '<<' and secPct < (pct - 100) then break end
        if glt == '<' and pct < myPct then break end

        ::next_aggro::
    end
    _utils.debug('combat', 'aggroCheck: leave')
end

-- Mirrors Sub CombatReset (kissassist.mac:2144).
-- sFlag: 0=full reset (DPS output + loot), 1=quick reset (skip DPS/loot).
-- Clears CombatStart, stops attack, resets all target tracking fields.
function Combat.combatReset(sFlag, calledFrom)
    _utils.debug('combat', 'combatReset: enter sFlag=%s from=%s', tostring(sFlag), tostring(calledFrom))

    -- DPS meter output (deferred — MQ2DPSAdv not yet wired, Step M9)

    Combat.mobRadar('los', _state.combat.meleeDistance)

    -- Mez array and immune-ID cleanup (mac:2196–2214)
    if _state.mez.on > 0 then
        local myTID  = _state.combat.myTargetID
        local xTotal = _state.combat.xSlotTotal
        for j = 1, xTotal do
            local entry = _state.arrays.mezArray[j]
            if entry and entry[1] ~= 'NULL' then
                local sp = mq.TLO.Spawn('id ' .. entry[1])
                if entry[1] == tostring(myTID)
                   or not sp or (sp.ID() or 0) == 0
                   or (sp.Type() or ''):lower() == 'corpse' then
                    _state.arrays.mezArray[j] = {'NULL','NULL','NULL'}
                end
            end
        end
        local immuneIDs = _state.mez.immuneIDs or ''
        if immuneIDs ~= '' then
            local kept = {}
            for id in immuneIDs:gmatch('|([^|]+)') do
                local sp = mq.TLO.Spawn('id ' .. id)
                if sp and (sp.ID() or 0) ~= 0 and (sp.Type() or ''):lower() ~= 'corpse' then
                    kept[#kept+1] = id
                end
            end
            _state.mez.immuneIDs = #kept > 0 and ('|' .. table.concat(kept, '|')) or ''
        end
        _state.mez.mobDone = false
    end

    -- MobsToIgnoreByID: remove dead/corpse entries (mac:2216–2224)
    local ignoreIDs = _state.pull.mobsToIgnoreByID or 'null'
    if ignoreIDs ~= 'null' and ignoreIDs ~= '' then
        local kept = {}
        for id in ignoreIDs:gmatch('|([^|]+)') do
            local sp = mq.TLO.Spawn('id ' .. id)
            if sp and (sp.ID() or 0) ~= 0 and (sp.Type() or ''):lower() ~= 'corpse' then
                kept[#kept+1] = id
            end
        end
        _state.pull.mobsToIgnoreByID = #kept > 0 and ('|' .. table.concat(kept, '|')) or 'null'
    end

    -- Core state reset (mac:2226–2234)
    _state.combat.calledTargetID  = 0
    _state.combat.aggroTargetID2  = '0'
    _state.combat.myTargetID      = 0
    _state.combat.myTargetName    = ''
    _state.combat.lastTargetID    = 0
    _state.combat.validTarget     = false
    _state.combat.combatStart     = false
    _state.pull.pulled            = false
    -- Bard: reset dpsTwisting so next doBardStuff tick transitions back to OOR medley.
    if _bard and _state.session.iAmABard then _state.bard.dpsTwisting = false end

    -- Stop attacking and clear target (mac:2247,2250)
    mq.cmd('/squelch /attack off')
    mq.cmd('/squelch /target clear')

    -- Reset XTarget slot to auto-hater for non-MA (mac:2252–2254)
    if _state.combat.xTarAutoSet and not mq.TLO.Me.Hovering() then
        local ma = _state.session.mainAssist
        if (mq.TLO.Group.Member(ma).Index() or 0) == 0 and not _state.session.iAmMA then
            local xSlot = _state.combat.xTSlot
            if xSlot > 0 then
                mq.cmd('/xtarget set ' .. xSlot .. ' autohater')
            end
        end
    end

    -- Pet: send back to camp (mac:2263–2266)
    if (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
        _state.timers.petAttack = 0
        mq.cmd('/pet back off')
        -- PetHold re-enable (deferred — pet module Step M6)
    end

    -- Clear per-slot DPS timers on fight end (mac CreateTimersDPS; Step 13.1)
    for k in pairs(_state.combat.slotTimers) do _state.combat.slotTimers[k] = 0 end

    -- Combat flags (mac:2280–2282)
    _state.combat.attacking  = false
    _state.combat.burnActive = false
    _state.dps.target        = 0

    -- Clear burn state if burn target died (mac:2283–2287)
    local burnID = _state.combat.burnID
    if burnID ~= 0 then
        local bSp = mq.TLO.Spawn('id ' .. burnID)
        if not bSp or (bSp.ID() or 0) == 0 or (bSp.Type() or ''):lower() == 'corpse' then
            _state.combat.burnCalled = false
            _state.combat.burnID     = 0
            mq.cmd('/echo Burn Target is Dead. Pausing Burn.')
        end
    end

    -- Loot (deferred — loot module Step M8)
    -- Bard stuff (deferred — bard module)

    -- TargetSwitching reset for non-MA (mac:2311)
    if not _state.session.iAmMA then
        _state.combat.targetSwitchingOn = false
    end

    -- Reset tank and pet-follow timers (mac:2312,2314)
    _state.timers.tank      = os.clock() + 30
    _state.timers.petFollow = os.clock() + 60

    -- Wait up to 2s for aggroOff timer to clear (mac:2315 /delay 2s ${AggroOffTimer}==0)
    mq.delay(2000, function()
        local exp = _state.timers.aggroOff or 0
        return exp == 0 or os.clock() >= exp
    end)

    -- Drain pending events (mac:2321–2325)
    repeat
        _state.combat.eventFlag = false
        mq.doevents()
    until not _state.combat.eventFlag

    -- Stick release and MQ2Melee re-enable (deferred — movement module Step 7.x)

    _utils.debug('combat', 'combatReset: done from=%s', tostring(calledFrom))
end

-- Mirrors Sub CheckForAdds (kissassist.mac:2333).
-- Called after each combat pass to detect and announce new mobs in camp.
function Combat.checkForAdds(calledFrom)
    Combat.mobRadar('los', _state.combat.meleeDistance)

    local mobCount = _state.combat.mobCount
    local aggroID  = tonumber(_state.combat.aggroTargetID) or 0

    if mobCount <= 1 then return end
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end
    if _state.pull.pulling then return end
    if not _state.combat.dpsOn and not _state.combat.meleeOn then return end

    local role     = _state.session.role
    local isPuller = role == 'puller' or role == 'pullertank' or role == 'pullerpettank'

    if isPuller then
        local campDist = dist2D(_state.movement.campY, _state.movement.campX,
                                mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= _state.movement.campRadius then return end
    end

    if _state.session.iAmDead then return end
    if _state.pull.chainPull == 2 or _state.dps.paused then return end

    -- Re-acquire a valid living target within camp radius before declaring adds (mac:2346)
    local myID = _state.combat.myTargetID
    if (mq.TLO.Target.ID() or 0) == 0 and myID ~= 0 then
        local sp = mq.TLO.Spawn('id ' .. myID)
        if sp and (sp.ID() or 0) ~= 0 then
            local spDist = dist2D(_state.movement.campY, _state.movement.campX,
                                   sp.Y() or 0, sp.X() or 0)
            if spDist < _state.movement.campRadius then
                mq.cmd('/squelch /target id ' .. myID)
                return
            end
        end
    end

    -- Add spam popup + optional broadcast (mac:2351–2356)
    if aggroID ~= 0 and myID == 0 then
        local aggrSp   = mq.TLO.Spawn('id ' .. aggroID)
        local aggrY    = aggrSp and aggrSp.Y() or 0
        local aggrX    = aggrSp and aggrSp.X() or 0
        local aggrDist = dist2D(_state.movement.campY, _state.movement.campX, aggrY, aggrX)
        local addExpiry = _state.timers.addSpam or 0
        if aggrDist <= _state.movement.campRadius and os.clock() >= addExpiry then
            mq.cmd('/popup Add(s) in camp detected')
            local isTank = role == 'tank' or role == 'pullertank'
                        or role == 'pettank' or role == 'pullerpettank'
            if _state.session.iAmMA or isTank then
                -- BroadCast (deferred — DanNet/EQBC Step M9)
                mq.cmd('/echo [KA] Add(s) in camp detected')
            end
            if role == 'pullertank' or role == 'pullerpettank' then
                _state.pull.pulled = false
            end
            _state.timers.addSpam = os.clock() + 5
        end
    end

    -- Puller still returning toward camp — don't stall (mac:2358)
    if isPuller and _state.pull.pulled then
        local campDist = dist2D(_state.movement.campY, _state.movement.campX,
                                mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= 15 then return end
    end

    -- Tank roles acquire aggroTargetID if no target (mac:2359)
    local isTankRole = role == 'tank'    or role == 'pullertank'
                    or role == 'pettank' or role == 'pullerpettank'
                    or role == 'hunter' or role == 'hunterpettank'
    if (mq.TLO.Target.ID() or 0) == 0 and isTankRole and aggroID ~= 0 then
        mq.cmd('/squelch /target id ' .. aggroID)
    end

    -- Stale myTargetID cleanup: if current target is not an NPC, clear it (mac:2360)
    local tgtType = (mq.TLO.Target.Type() or ''):lower()
    if tgtType ~= 'npc' and myID ~= 0 then
        local sp = mq.TLO.Spawn('id ' .. myID)
        if not sp or (sp.ID() or 0) == 0 or (sp.Type() or ''):lower() == 'corpse' then
            _state.combat.lastTargetID = myID
            _state.combat.myTargetID   = 0
        end
        mq.cmd('/squelch /target clear')
        return
    end

    _utils.debug('combat', 'checkForAdds: mobCount=%d from=%s', mobCount, tostring(calledFrom))
end

-- Mirrors Sub CheckForCombat (kissassist.mac:484).
-- Called from the main loop each tick when dpsOn or meleeOn.
-- skipCombat: 0=full combat path, 1=healer/no-DPS mode (cures/heals only, no melee)
-- waitTime: EngageWaitTimer initial countdown in 50ms ticks (0 = no wait)
function Combat.checkForCombat(skipCombat, fromWhere, waitTime)
    skipCombat = skipCombat or 0
    fromWhere  = fromWhere  or 'main'
    waitTime   = waitTime   or 0

    -- ChaseAssist + moving guard: don't interrupt a moving non-MA chaser (mac:485)
    if _state.session.chaseAssist and mq.TLO.Me.Moving() then
        local myName     = mq.TLO.Me.CleanName() or ''
        local whoToChase = _state.movement.whoToChase
        if not _state.session.iAmMA or whoToChase ~= myName then
            return
        end
    end

    if skipCombat == 0 then
        -- Clear iAmDead once resurrection sickness fades and corpse despawns (mac:489)
        if _state.session.iAmDead
           and (_state.movement.campZone == (mq.TLO.Zone.ID() or 0)) then
            local sickBuff  = mq.TLO.Me.Buff('Resurrection Sickness')
            local hasSick   = sickBuff and (sickBuff.ID() or 0) ~= 0
            local myName    = mq.TLO.Me.CleanName() or ''
            local corpseCount = mq.TLO.SpawnCount('pccorpse ' .. myName)() or 0
            if hasSick or corpseCount == 0 then
                _state.session.iAmDead = false
            end
        end

        Combat.mobRadar('los', _state.combat.meleeDistance)

        -- DoWeChase (deferred — movement module Step 7.x)

        -- Hard guards: bail if combat is not appropriate now (mac:493)
        local aggroID  = tonumber(_state.combat.aggroTargetID) or 0
        local mobCount = _state.combat.mobCount
        if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end
        if mq.TLO.Me.Hovering() then return end
        if _state.session.iAmDead and aggroID == 0 then return end
        if mobCount == 0 and aggroID == 0 then return end
        if not _state.combat.dpsOn and not _state.combat.meleeOn then return end

        -- Bard DPS twist (deferred — bard module)

        -- EngageWaitTimer: deadline after which we stop waiting for a target (mac:496)
        local engageDeadline = os.clock() + (waitTime * 0.05)

        if not _state.session.iAmMA then
            -- Non-MA: assist loop with EngageWaitTimer (mac:499–515)
            while true do
                local maName = _state.session.mainAssist
                local maID   = mq.TLO.Spawn('=' .. maName).ID() or 0

                if _state.session.role ~= 'offtank' or maID ~= 0 then
                    Combat.assist(fromWhere)
                    -- SwitchMA return value (deferred — DanNet/EQBC Step M9)
                else
                    -- Offtank with dead MA → would switchMA (deferred)
                    break
                end

                if _heal then _heal.checkHealth('CheckForCombat') end

                local myTID = _state.combat.myTargetID
                local aID   = tonumber(_state.combat.aggroTargetID) or 0
                if myTID ~= 0 or _state.session.role ~= 'assist'
                   or os.clock() >= engageDeadline or aID == 0 then
                    break
                end
                mq.delay(50)
            end
            -- LOSBeforeCombat position check (deferred — movement module Step 7.x)

        else
            -- MA/Offtank path: wait for mob in melee radius then select target (mac:520–535)
            local role     = _state.session.role
            local isPuller = role == 'pullertank' or role == 'pullerpettank'
                          or role == 'hunter'     or role == 'hunterpettank'

            if not isPuller then
                local aID = tonumber(_state.combat.aggroTargetID) or 0
                if aID ~= 0 then
                    while true do
                        local sp = mq.TLO.Spawn('id ' .. aID)
                        if not sp or (sp.ID() or 0) == 0
                           or (sp.Type() or ''):lower() == 'corpse' then break end

                        local md       = _state.combat.meleeDistance
                        local meY      = mq.TLO.Me.Y() or 0
                        local meX      = mq.TLO.Me.X() or 0
                        local campDist = dist2D(_state.movement.campY, _state.movement.campX, meY, meX)
                        local cnt
                        if campDist > md then
                            cnt = mq.TLO.SpawnCount('xtarhater radius ' .. md .. ' zradius 50')() or 0
                        else
                            local cY = _state.movement.campY
                            local cX = _state.movement.campX
                            cnt = mq.TLO.SpawnCount('xtarhater loc ' .. cX .. ' ' .. cY
                                                   .. ' radius ' .. md .. ' zradius 50')() or 0
                        end
                        _state.combat.mobCount = cnt

                        if cnt > 0 or os.clock() >= engageDeadline then break end
                        mq.delay(50)
                    end
                end
            end

            Combat.getCombatTarget()
        end

        -- Engage combat for the acquired target (Step 4.5)
        if _state.combat.myTargetID ~= 0 then
            Combat.fight(fromWhere)
        end

        -- FeignAggroCheck: if we FD'd to drop aggro, wait before standing (mac:538)
        if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then
            Combat.feignAggroCheck()
        end

        -- ChainPull==2: puller signaled all done, exit combat pass (mac:540)
        if _state.pull.chainPull == 2 then return end
    end

    if _mez then _mez.check('checkForCombat') end
    if _mez then _mez.aeCheck() end

    -- SkipCombat==1 healer loop (mac:563-580)
    if skipCombat == 1 and _heal then
        _heal.checkCures()
        _heal.checkHealth('SkipCombat')
    end

    -- CheckForAdds: scan for new mobs that entered camp during combat (mac:586)
    Combat.checkForAdds(fromWhere)

    -- Tank/pullertank: camp movement and mob-count gating (mac:587–599)
    local role = _state.session.role
    if role == 'tank' or role == 'pullertank' then
        -- DoWeChase, DoWeMove, EnduranceCheck (deferred — movement/buffs modules)
    elseif role ~= 'manual' then
        -- Non-manual non-tank: CombatReset if our target died (mac:601)
        local myID = _state.combat.myTargetID
        if myID ~= 0 then
            local sp     = mq.TLO.Spawn('id ' .. myID)
            local spType = sp and sp.Type() or ''
            if (sp and sp.ID() or 0) == 0 or spType:lower() == 'corpse' then
                Combat.combatReset(0, fromWhere .. '_targetDead')
            end
        end
    end

    _utils.debug('combat', 'checkForCombat: done from=%s', fromWhere)
end

return Combat
