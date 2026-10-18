local mq      = require('mq')
local Config  = require('modules.config')
local Settings  = require('modules.combat.settings')
local Util      = require('modules.combat.util')
local Abilities = require('modules.combat.abilities')

local Combat = {}
local _state, _utils, _cast, _heal, _movement, _bard, _mez, _debuff, _buffs, _comms, _merc, _charm
local _nearspawnFallback = false  -- set by mobRadar when NearestSpawn fallback fires

local dist2D        = Util.dist2D
local isDeadOrGone  = Util.isDeadOrGone
local targetAndWait = Util.targetAndWait
local distFromCamp  = Util.distFromCamp
local getMASpawn    = Util.getMASpawn

-- Ability helpers (modules/combat/abilities.lua)
local beforeAttack = Abilities.beforeAttack
local combatPet    = Abilities.combatPet
local namedWatch   = Abilities.namedWatch
local groupEscape  = Abilities.groupEscape
local aeCheck      = Abilities.aeCheck
local checkGoM     = Abilities.checkGoM
local rogueHide    = Abilities.rogueHide
Combat.feignAggroCheck = Abilities.feignAggroCheck
Combat.aggroCheck      = Abilities.aggroCheck

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
            if distFromCamp(mobY, mobX) > meleeDistCheck then
                return false
            end
        end
    end

    -- "Eye of" charm-NPC: don't attack "eye of <name>" when that PC is present
    if mobName:lower():find('eye of ', 1, true) then
        local stripped = mobName:sub(8)
        if (mq.TLO.SpawnCount('pc name ' .. stripped)() or 0) > 0 then return false end
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
            if mobID == (getMASpawn().ID() or 0) then return false end
        end
    end

    -- Pull-specific checks: only active while pull module is pulling (Step 7.8).
    if _state.pull.pulling then
        local mobY = sp and sp.Y() or 0
        local mobX = sp and sp.X() or 0
        -- Reject if any non-group PC is within 30 units of the mob.
        if (mq.TLO.SpawnCount(string.format('pc radius 30 loc %s,%s nogroup', mobY, mobX))() or 0) > 0 then
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

-- Expose groupEscape for debuff.lua (mac:7858).
Combat.groupEscape = groupEscape

-- Mirrors Bind_Settings (DPS/Melee/Burn/General sections) from kissassist.mac.
-- Loads combat arrays and wires state.combat flags from INI.
function Combat.init(state, utils, cast, heal, movement, bard, cond, mez, debuff, buffs, comms, merc, charm)
    _state    = state
    _utils    = utils
    _cast     = cast
    _heal     = heal
    _movement = movement
    _bard     = bard
    _mez      = mez
    _debuff   = debuff
    _buffs    = buffs
    _comms    = comms
    _merc     = merc
    _charm    = charm

    Util.init(state)
    Abilities.init(state, utils, cast, cond, mez, Combat)
    Settings.load(state, utils)
end

-- NPCs in LOS within radius of me, excluding alert-3 (already-checked non-mezzed) mobs.
-- This is the mac's MobRadar 'los' count (mac:7150); unlike the XTarget scan below it
-- also sees mem-blurred mezzed mobs that have dropped off XTarget.
local function campNpcCount(radius)
    return mq.TLO.SpawnCount('npc targetable los radius ' .. radius .. ' zradius 50 noalert 3')() or 0
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
    if _state.combat.manualTargetMode and _state.combat.myTargetID ~= 0 then
        if not isDeadOrGone(_state.combat.myTargetID) then return end
    end

    mq.doevents()
    Combat.mobRadar('los', _state.combat.meleeDistance)

    local mobCount = _state.combat.mobCount
    local aggroID  = tonumber(_state.combat.aggroTargetID) or 0
    local ma       = _state.session.mainAssist
    local maSpawn  = getMASpawn()
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
    if _state.combat.manualTargetMode and _state.combat.myTargetID ~= 0 then
        if not isDeadOrGone(_state.combat.myTargetID) then return end
    end

    mq.doevents()

    -- Stale aggroTargetID2 check
    local aggroID2 = tonumber(_state.combat.aggroTargetID2) or 0
    if aggroID2 ~= 0 then
        if isDeadOrGone(aggroID2) then
            _state.combat.aggroTargetID2 = '0'
            aggroID2 = 0
        end
    end

    Combat.mobRadar('los', _state.combat.meleeDistance)

    local mobCount  = _state.combat.mobCount
    local aggroID   = tonumber(_state.combat.aggroTargetID) or 0
    local maSpawn   = getMASpawn()
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
        targetAndWait(aggroID)

    elseif (mobCount >= 2 or (xSlot2 ~= 0 and (mq.TLO.Me.XTarget(xSlot2).ID() or 0) ~= 0))
           and aggroID ~= 0 then
        -- Multiple mobs — priority: named > alert-4 > closest/hurt/level
        local namedID = mq.TLO.Spawn('xtarhater named').ID() or 0
        if namedID ~= 0 then
            targetAndWait(namedID)

        elseif (mq.TLO.Alert(4).Size() or 0) > 0 then
            local a4sp   = mq.TLO.Spawn('xtarhater alert 4')
            local a4id   = a4sp and a4sp.ID() or 0
            local a4type = a4id ~= 0 and (mq.TLO.Spawn('id ' .. a4id).Type() or '') or ''
            if a4id ~= 0 and a4type:lower() ~= 'corpse' then
                local nearA4 = mq.TLO.NearestSpawn(1, 'xtarhater alert 4')
                local nearID = nearA4 and nearA4.ID() or 0
                if nearID ~= 0 then
                    targetAndWait(nearID)
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
                            targetAndWait(tempID)
                        end
                    else
                        tempID = applyPriority(false)
                        local tSp = mq.TLO.Spawn('id ' .. tempID)
                        if (mq.TLO.Target.ID() or 0) ~= tempID
                           and (tSp and tSp.Distance() or 999) <= md then
                            targetAndWait(tempID)
                        end
                    end
                end
            end
        end

    elseif aggroID == 0 and _state.mez.mobFlag and (mobCount > 0 or campNpcCount(md) > 0) then
        -- MezMobFlag: scan for mem-blurred mobs inside camp radius
        local blurSp = mq.TLO.NearestSpawn(1, 'npc targetable los radius ' .. md .. ' zradius 50 noalert 3')
        local blurID = blurSp and blurSp.ID() or 0
        if blurID ~= 0 then
            local bY = blurSp.Y() or 0
            local bX = blurSp.X() or 0
            if distFromCamp(bY, bX) < md then
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
        if isDeadOrGone(myID) then
            _state.combat.lastTargetID = myID
            _state.combat.myTargetID   = 0
            return
        end
    end

    -- Manual target mode: skip MA/non-MA override logic while target is alive.
    -- Dead/gone clear above still applies so we re-engage normally when mob dies.
    if _state.combat.manualTargetMode and _state.combat.myTargetID ~= 0 then return end

    local cMyTargetID = _state.combat.myTargetID
    local ma          = _state.session.mainAssist
    local maSpawn     = getMASpawn()
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
                                mq.cmdf('/echo [KA] %s is TANKING-> %s <- ID:%s', petName, _state.combat.myTargetName, tgtID)
                            end
                            _state.combat.lastCalledTargetID = tgtID
                        end
                    end
                else
                    if _state.combat.myTargetID ~= 0 and not _state.combat.manualTargetMode then
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
        local function petSwitch()
            if _state.combat.petTargetSwitch
               and (mq.TLO.Me.Pet.ID() or 0) ~= 0
               and mq.TLO.Pet.Combat() then
                mq.cmd('/pet attack')
                mq.delay(500)
                mq.cmd('/pet swarm')
            end
        end
        if _state.combat.xTarAutoSet
           and not mq.TLO.Group.Member(ma).Index()
           and not _state.session.iAmMA then
            if (mq.TLO.Spawn('id ' .. newID).Type() or ''):lower() ~= 'pc' then
                targetAndWait(newID)
                local xSlot = _state.combat.xTSlot
                if xSlot > 0 then
                    local xtID = mq.TLO.Me.XTarget(xSlot).ID() or 0
                    if xtID == 0 or xtID ~= newID then
                        mq.cmd('/xtarget set ' .. xSlot .. ' currenttarget')
                    end
                end
                petSwitch()
            end
        elseif setTarget ~= 0 then
            targetAndWait(newID)
            petSwitch()
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
        if (getMASpawn().ID() or 0) ~= 0
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
        local campDist = distFromCamp(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= _state.movement.campRadius then return end
    end

    -- CombatRadius: MaxRangeTo+5 if it exceeds MeleeDistance (mac:1056)
    local sp = mq.TLO.Spawn('id ' .. myID)
    local maxRange     = sp and sp.MaxRangeTo() or 0
    local combatRadius = _state.combat.meleeDistance
    if maxRange > combatRadius then combatRadius = maxRange + 5 end

    -- Deferred: CheckCures/CheckHealth (M5), DoWeChase (M7), DPS meter (M9)

    -- Mez runs before the engage block (BeforeAttack/melee/discs) so a fresh pull
    -- doesn't wake adds before they can be locked down (mac:1069-1071).
    if _mez and _state.mez.on ~= 0 then _mez.check(fromWhere) end
    if _mez then _mez.aeCheck() end

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

    local maSpawn  = getMASpawn()
    local maY, maX = (maSpawn and maSpawn.Y() or 0), (maSpawn and maSpawn.X() or 0)
    local tgtY = sp and sp.Y() or 0
    local tgtX = sp and sp.X() or 0
    local campToMA = distFromCamp(maY, maX)
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
            _state.merc.assisting        = 0  -- reset so merc re-assists this fight (mac:1084)
            _state.combat.combatStart    = true
            local tgtName = mq.TLO.Spawn('id ' .. myID).CleanName() or '?'
            mq.cmd('/echo  ATTACKING -> ' .. tgtName .. ' <-')
            if _bard then _bard.doBardStuff() end
            -- Tank-announce on first engage (mac:1088-1089)
            if role == 'tank' or role == 'pullertank' or role == 'hunter' then
                if _comms then
                    _comms.announce(string.format('TANKING-> %s <- ID:%d', tgtName, myID))
                end
            elseif role == 'pettank' or role == 'pullerpettank' or role == 'hunterpettank' then
                local petName = mq.TLO.Me.Pet.CleanName() or 'Pet'
                if _comms then
                    _comms.announce(string.format('%s is TANKING-> %s <- ID:%d', petName, tgtName, myID))
                end
            end
            -- Hunter: close gap before combat announce (mac:1112 context)
            if (role == 'hunter' or role == 'hunterpettank')
               and not _state.combat.useMQ2Melee and _movement then
                _movement.checkStick(0, 0)
            end
        end

        -- Look level when not underwater (mac:1095)
        if not mq.TLO.Me.FeetWet() then mq.cmd('/squelch /look 0') end

        -- Merc re-assist on target change (mac:1144)
        if _merc then _merc.check() end

        -- Initiate attack (mac:1097-1127)
        if not _state.combat.attacking then
            if _state.combat.meleeOn then
                -- Bards: Casting.ID stays non-zero while songs play (same gate as cast.lua:201).
                if not _state.session.iAmABard
                        and ((mq.TLO.Me.Casting.ID() or 0) ~= 0
                             or mq.TLO.Window('CastingWindow').Open()) then
                    goto skip_first_engage
                end
                _state.combat.attacking = true
                if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                if _state.combat.autoFireOn ~= 1 then
                    -- Normal melee first engage (mac:1101-1114)
                    local isTankLike = role == 'tank' or role == 'pullertank' or role == 'hunter'
                    if isTankLike and (mq.TLO.Me.Skill('Taunt')() or 0) > 0
                       and mq.TLO.Me.AbilityReady('Taunt')() then
                        mq.cmd('/doability Taunt')
                    end
                    if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
                        beforeAttack(myID, 1)
                    end
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
                    -- AutoFireOn==1: ranged only — BeforeAttack, no melee stick (mac:1116)
                    if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
                        beforeAttack(myID, 1)
                    end
                end
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

            if _state.terminate then break end

            -- Died mid-fight (or now hovering as a corpse): stop the loop so we
            -- don't spam casts/attacks while dead ("too distracted to cast").
            if _state.session.iAmDead or mq.TLO.Me.Hovering() then
                Combat.combatReset(0, fromWhere .. '_died')
                break
            end

            -- Manual target mode: if player switches in-game target to a different
            -- NPC mid-fight, break out so checkForCombat picks up the new target.
            if _state.combat.manualTargetMode then
                local liveID   = mq.TLO.Target.ID() or 0
                local liveType = (mq.TLO.Target.Type() or ''):lower()
                if liveID ~= 0 and liveID ~= myID
                   and liveType ~= 'corpse' and liveType ~= 'pc' then
                    _state.combat.myTargetID = liveID
                    break
                end
            end

            -- Mez/AE-mez runs before the casting gate so bards (always "casting"
            -- via MQ2Medley) are not permanently blocked from mezzing.
            if _mez then _mez.check('Combat') end
            if _mez then _mez.aeCheck() end

            -- Pause all commands while player or script is casting.
            -- Bards: Casting.ID stays non-zero while songs play — skip gate for bards.
            if not _state.session.iAmABard
                    and ((mq.TLO.Me.Casting.ID() or 0) ~= 0
                         or mq.TLO.Window('CastingWindow').Open()) then
                mq.delay(50)
                goto continue_fight
            end

            -- Face mob every tick when enabled (mac:1094); skip when MQ2Melee handles facing
            do
                local faceMob = _state.movement.faceMobOn or 0
                if faceMob > 0 and myID ~= 0 and not _state.combat.useMQ2Melee then
                    local meState = mq.TLO.Me.State() or ''
                    if meState == 'STAND' or (mq.TLO.Me.Mount.ID() or 0) ~= 0 then
                        local faceMode = (faceMob == 2) and 'nolook' or 'fast nolook'
                        local fsp = mq.TLO.Spawn('id ' .. myID)
                        local mobY = fsp and fsp.Y() or 0
                        local mobX = fsp and fsp.X() or 0
                        mq.cmdf('/squelch /face %s loc %f,%f', faceMode, mobY, mobX)
                    end
                end
            end

            -- Burn if flagged (mac:1139-1141)
            if _state.combat.burnOn and _state.combat.burnID ~= 0 then
                if _cast.doBurn then _cast.doBurn() end
                _state.combat.burnID = 0
            end

            -- Merc re-assist during the fight, not just on engage (mac:1605). Ranged
            -- assists that skip the melee-engage merc call still get checked here.
            if _merc then _merc.check() end

            -- AE rotation: threshold-triggered AE/multi-target spells (mac:12473-12560)
            aeCheck()

            -- GoM: cast free spell on Gift of Mana proc (mac:11497-11580)
            checkGoM()

            -- Offtank auto-promote: MA is gone, assume MA role (mac:1143)
            if _state.session.role == 'offtank'
               and (getMASpawn().ID() or 0) == 0 then
                mq.cmd('/switchma ' .. (mq.TLO.Me.CleanName() or '') .. ' tank')
            end
            -- Re-stick if mob moved beyond MaxRangeTo and stick dropped (mac:1150); MQ2Melee repositions itself
            if not _state.combat.useMQ2Melee and _movement and _state.combat.meleeOn then
                local _mob = mq.TLO.Spawn('id ' .. myID)
                if _mob and (_mob.Distance() or 0) > (_mob.MaxRangeTo() or 999)
                   and not mq.TLO.Stick.Active() then
                    _movement.checkStick(0, 1)
                end
            end
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
            if not _state.combat.namedCheck then namedWatch(false) end

            -- GroupEscape: evac if MA dies mid-combat (mac:1589 CheckBeforeCast)
            groupEscape()

            -- Non-chainpull DPS path (mac:1178-1200): only a plain puller that is chain-pulling skips it
            if not (role == 'puller' and _state.pull.chainPull ~= 0) then
                -- Dead/paused: exit combat (mac:1185-1187)
                if isDeadOrGone(myID) or _state.dps.paused then
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
                    if (_state.debuff.on or 0) > 0 and _debuff then
                        _debuff.check(_state.combat.myTargetID)
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
                -- Melee re-attack or autofire re-engage (mac:1218-1248)
                if _state.combat.autoFireOn ~= 1 then
                    if _state.combat.attacking and _state.combat.meleeOn then
                        -- Uses the live Target like the mac: after mezzing an add (still at
                        -- 100%) this stays false, so we don't swing at the mob we just mezzed.
                        local tgtPct  = mq.TLO.Target.PctHPs() or 100
                        local tgtDist = mq.TLO.Target.Distance() or 999
                        if tgtPct <= _state.combat.assistAt and tgtDist < combatRadius then
                            -- Re-target if we drifted (mac:1222-1224)
                            if not _state.combat.targetSwitchingOn
                               and not _state.combat.manualTargetMode
                               and (mq.TLO.Target.ID() or 0) ~= myID then
                                targetAndWait(myID, 500)
                            end
                            -- Re-engage, or keep the stick (mac:1225-1230)
                            if _movement then
                                if not mq.TLO.Me.Combat() then
                                    if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                                    _movement.checkStick(0, 1)
                                elseif not _state.combat.useMQ2Melee and not mq.TLO.Stick.Active() then
                                    _movement.checkStick(1, 0)
                                end
                            end
                        elseif not mq.TLO.Me.Combat() and _state.session.iAmMA
                               and not _state.combat.useMQ2Melee
                               and (mq.TLO.Target.ID() or 0) ~= 0 then
                            -- MA only: keep attack on while standing (mac:1231-1237)
                            local meState = (mq.TLO.Me.State() or ''):upper()
                            if meState == 'STAND' or meState == 'MOUNT' then
                                mq.cmd('/squelch /attack on')
                            end
                        end
                    end
                elseif _state.combat.autoFireOn == 1 then
                    -- AutoFireOn==1: re-enable autofire if toggled off (mac:1241-1248)
                    if _state.combat.combatStart and not mq.TLO.Me.AutoFire() then
                        local tgtMezzed = (mq.TLO.Target.Mezzed.ID() or 0)
                        if (mq.TLO.Target.ID() or 0) == myID and tgtMezzed == 0 then
                            if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                            mq.cmd('/autofire')
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
        if _state.pet.activeState ~= 0 and _state.pet.combatOn and myID ~= 0 then
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
           and (_state.combat.aggroTargetID or '') ~= '' and _debuff then
            _debuff.check(_state.combat.myTargetID)
        end
        -- BeforeAttack condCheck=2: fire only |cond entries (mac:1330)
        if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
            beforeAttack(myID, 2)
        end
    end

    -- Mana item cast after rotation (mac:1213 CastMana combat)
    if _buffs and _state.buffs.buffsOn then _buffs.castMana() end

    _utils.debug('combat', 'fight: done from=%s', tostring(fromWhere))
end

-- Mirrors Sub CombatReset (kissassist.mac:2144).
-- sFlag: 0=full reset (DPS output + loot), 1=quick reset (skip DPS/loot).
-- Clears CombatStart, stops attack, resets all target tracking fields.
function Combat.combatReset(sFlag, calledFrom)
    _utils.debug('combat', 'combatReset: enter sFlag=%s from=%s', tostring(sFlag), tostring(calledFrom))

    if _state.session.role == 'manual' then return end

    -- DPS meter output (deferred — MQ2DPSAdv not yet wired, Step M9)

    Combat.mobRadar('los', _state.combat.meleeDistance)

    -- Mez array and immune-ID cleanup (mac:2196–2214)
    if _state.mez.on > 0 then
        local myTID  = _state.combat.myTargetID
        local xTotal = _state.combat.xSlotTotal
        for j = 1, xTotal do
            local entry = _state.arrays.mezArray[j]
            if entry and entry[1] ~= 'NULL' then
                if entry[1] == tostring(myTID) or isDeadOrGone(entry[1]) then
                    _state.arrays.mezArray[j] = {'NULL','NULL','NULL'}
                end
            end
        end
        local immuneIDs = _state.mez.immuneIDs or ''
        if immuneIDs ~= '' then
            local kept = {}
            for id in immuneIDs:gmatch('|([^|]+)') do
                if not isDeadOrGone(id) then
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
            if not isDeadOrGone(id) then
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
    -- Bard: reset dpsTwisting so next doBardStuff tick transitions back to OOC medley.
    if _bard and _state.session.iAmABard then _state.bard.dpsTwisting = false end

    -- Stop attacking and clear target; reset autofire (mac:2246-2250)
    if _state.combat.useMQ2Melee then mq.cmd('/squelch /melee melee=0') end
    mq.cmd('/squelch /attack off')
    if mq.TLO.Me.AutoFire() then mq.cmd('/autofire') end
    if _state.combat.autoFireOn == 2 then _state.combat.autoFireOn = 1 end
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
        if isDeadOrGone(burnID) then
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

    -- Release combat stick; if ChaseAssist is on, doWeChase manages stick itself (mac:2326)
    if mq.TLO.Stick.Active() and not _state.session.chaseAssist then
        mq.cmd('/squelch /stick off')
    end

    -- Re-enable MQ2Melee melee mode for next engagement (mac:2246 inverse)
    if _state.combat.useMQ2Melee then mq.cmd('/squelch /melee melee=1') end

    if _debuff then _debuff.resetFight() end
    if _charm  then _charm.resetFight()  end

    -- ROG auto-stealth after combat ends (mac:2328)
    rogueHide()

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
        local campDist = distFromCamp(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= _state.movement.campRadius then return end
    end

    if _state.session.iAmDead then return end
    if _state.pull.chainPull == 2 or _state.dps.paused then return end

    -- Re-acquire a valid living target within camp radius before declaring adds (mac:2346).
    -- Manual target mode owns selection — don't force a re-lock onto the tracked mob.
    local myID = _state.combat.myTargetID
    if (mq.TLO.Target.ID() or 0) == 0 and myID ~= 0 and not _state.combat.manualTargetMode then
        local sp = mq.TLO.Spawn('id ' .. myID)
        if sp and (sp.ID() or 0) ~= 0 then
            local spDist = distFromCamp(sp.Y() or 0, sp.X() or 0)
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
        local aggrDist = distFromCamp(aggrY, aggrX)
        local addExpiry = _state.timers.addSpam or 0
        if aggrDist <= _state.movement.campRadius and os.clock() >= addExpiry then
            mq.cmd('/popup Add(s) in camp detected')
            local isTank = role == 'tank' or role == 'pullertank'
                        or role == 'pettank' or role == 'pullerpettank'
            if _state.session.iAmMA or isTank then
                if _comms then
                    _comms.announce('Add(s) in camp detected')
                else
                    mq.cmd('/echo Add(s) in camp detected')
                end
            end
            if role == 'pullertank' or role == 'pullerpettank' then
                _state.pull.pulled = false
            end
            _state.timers.addSpam = os.clock() + 5
        end
    end

    -- Puller still returning toward camp — don't stall (mac:2358)
    if isPuller and _state.pull.pulled then
        local campDist = distFromCamp(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= 15 then return end
    end

    -- Tank roles acquire aggroTargetID if no target (mac:2359)
    local isTankRole = role == 'tank'    or role == 'pullertank'
                    or role == 'pettank' or role == 'pullerpettank'
                    or role == 'hunter' or role == 'hunterpettank'
    if (mq.TLO.Target.ID() or 0) == 0 and isTankRole and aggroID ~= 0
       and not _state.combat.manualTargetMode then
        mq.cmd('/squelch /target id ' .. aggroID)
    end

    -- Stale myTargetID cleanup: if current target is not an NPC, clear it (mac:2360)
    local tgtType = (mq.TLO.Target.Type() or ''):lower()
    if tgtType ~= 'npc' and myID ~= 0 then
        if isDeadOrGone(myID) then
            _state.combat.lastTargetID = myID
            _state.combat.myTargetID   = 0
        end
        -- Manual target mode: keep the dead/gone cleanup above (so after-death
        -- auto-pick still fires) but don't clear a target the player is holding.
        if not _state.combat.manualTargetMode then
            mq.cmd('/squelch /target clear')
        end
        return
    end

    _utils.debug('combat', 'checkForAdds: mobCount=%d from=%s', mobCount, tostring(calledFrom))
end

-- Port of GetCombatPosition 0 (kissassist.mac:627-678). Called only when LOSBeforeCombat=1.
-- Only repositions for a mob that is already within MeleeDistance but out of line of sight.
-- A mob farther out (e.g. one still being pulled) gets up to 3s to arrive; if it doesn't,
-- we stay put rather than running out to it.
local _combatPosSpam = 0
local function getCombatPosition(mobID)
    if _state.dps.paused then return end
    local function mob() return mq.TLO.Spawn('id ' .. mobID) end
    local function dist() return math.floor(mob().Distance3D() or 999) end
    if (mob().ID() or 0) == 0 then return end
    local md = _state.combat.meleeDistance

    if dist() > md then
        mq.delay(3000, function() return dist() <= md end)
        if dist() > md then
            if os.clock() > _combatPosSpam then
                printf('\awGet Combat Position Failed. Target is too far away(%d).', dist())
                _combatPosSpam = os.clock() + 5
            end
            return
        end
    end

    if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
    local distanceCheck = _state.combat.meleeOn and math.floor(mob().MaxRangeTo() or md) or md
    local distanceFrom  = distanceCheck - 2
    local function inPosition() return dist() <= distanceCheck and mob().LineOfSight() end
    local timeout = os.clock() + 5

    local meshLoaded = _state.pull.moveUse == 'nav' and (mq.TLO.Navigation.MeshLoaded() or false)
    if meshLoaded then
        while os.clock() < timeout do
            if not mq.TLO.Navigation.Active() then
                mq.cmdf('/squelch /nav id %d dist=%d los=on', mobID, distanceFrom)
            end
            if inPosition() then break end
            mq.delay(500)
        end
        if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
        if dist() > distanceCheck and mob().LineOfSight() then
            mq.cmdf('/squelch /moveto id %d dist %d', mobID, distanceFrom)
        end
    else
        mq.cmdf('/squelch /moveto id %d dist %d', mobID, distanceFrom)
        mq.delay(5000, inPosition)
        if mq.TLO.MoveTo.Moving() then mq.cmd('/squelch /moveto off') end
    end
end

-- Mirrors Sub CheckForCombat (kissassist.mac:484).
-- Called from the main loop each tick when dpsOn or meleeOn.
-- skipCombat: 0=full combat path, 1=healer/no-DPS mode (cures/heals only, no melee)
-- waitTime: EngageWaitTimer initial countdown in 50ms ticks (0 = no wait)
function Combat.checkForCombat(skipCombat, fromWhere, waitTime)
    skipCombat = skipCombat or 0
    fromWhere  = fromWhere  or 'main'
    waitTime   = waitTime   or 0

    if _state.session.role == 'manual' then return end

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
        if _state.session.iAmDead then
            local sickBuff  = mq.TLO.Me.Buff('Resurrection Sickness')
            local hasSick   = sickBuff and (sickBuff.ID() or 0) ~= 0
            local myName    = mq.TLO.Me.CleanName() or ''
            local corpseCount = mq.TLO.SpawnCount('pccorpse ' .. myName)() or 0
            if hasSick or corpseCount == 0 then
                _state.session.iAmDead = false
            end
        end

        Combat.mobRadar('los', _state.combat.meleeDistance)

        if _movement then _movement.doWeChase() end

        -- Hard guards: bail if combat is not appropriate now (mac:493)
        local aggroID  = tonumber(_state.combat.aggroTargetID) or 0
        local mobCount = _state.combat.mobCount
        if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end
        if mq.TLO.Me.Hovering() then return end
        if _state.session.iAmDead and aggroID == 0 then return end
        if mobCount == 0 and aggroID == 0 then
            -- Tank: after a kill, mezzed adds that were mem-blurred off XTarget are still
            -- in camp. Let getCombatTarget's MezMobFlag scan find them (mac:493, mac:899).
            if not (_state.session.iAmMA and _state.mez.mobFlag
                    and campNpcCount(_state.combat.meleeDistance) > 0) then
                return
            end
        end
        if not _state.combat.dpsOn and not _state.combat.meleeOn then return end

        -- Bard DPS twist (deferred — bard module)

        -- EngageWaitTimer: deadline after which we stop waiting for a target (mac:496)
        local engageDeadline = os.clock() + (waitTime * 0.05)

        if not _state.session.iAmMA then
            -- Non-MA: assist loop with EngageWaitTimer (mac:499–515)
            while true do
                local maID   = getMASpawn().ID() or 0

                if _state.session.role ~= 'offtank' or maID ~= 0 then
                    Combat.assist(fromWhere)
                    -- SwitchMA return value (deferred — DanNet/EQBC Step M9)
                else
                    -- Offtank with dead MA: promote self to MA (mac:508-511)
                    mq.cmd('/switchma ' .. (mq.TLO.Me.CleanName() or '') .. ' tank')
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
            -- Reposition to LOS before engaging (mac:516)
            if _state.combat.losBeforeCombat then
                local tid = _state.combat.myTargetID
                if tid ~= 0 and aggroID ~= 0 then
                    local tgtSp = mq.TLO.Spawn('id ' .. tid)
                    if tgtSp and not tgtSp.LineOfSight() then
                        getCombatPosition(tid)
                    end
                end
            end

        else
            -- MA/Offtank path: wait for mob in melee radius then select target (mac:520–535)
            local role     = _state.session.role
            local isPuller = role == 'pullertank' or role == 'pullerpettank'
                          or role == 'hunter'     or role == 'hunterpettank'

            if not isPuller then
                local aID = tonumber(_state.combat.aggroTargetID) or 0
                if aID ~= 0 then
                    while true do
                        if isDeadOrGone(aID) then break end

                        local md       = _state.combat.meleeDistance
                        local meY      = mq.TLO.Me.Y() or 0
                        local meX      = mq.TLO.Me.X() or 0
                        local campDist = distFromCamp(meY, meX)
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
        -- NamedWatch IgnoreTarget=true: scan xtarhater for nearby named (mac:576)
        if not _state.combat.namedCheck then namedWatch(true) end
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
            if isDeadOrGone(myID) then
                Combat.combatReset(0, fromWhere .. '_targetDead')
            end
        end
    end

    _utils.debug('combat', 'checkForCombat: done from=%s', fromWhere)
end

return Combat
