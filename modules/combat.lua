local mq     = require('mq')
local Config = require('modules.config')

local Combat = {}
local _state, _utils, _cast

-- 2D camp-distance helper (mirrors Math.Distance[y1,x1:y2,x2] in kissassist.mac)
local function dist2D(y1, x1, y2, x2)
    return math.sqrt((y1 - y2)^2 + (x1 - x2)^2)
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

    -- Tank: target must appear on the XTarget auto-hater list
    if _state.session.role == 'tank'
       and _state.combat.mobCount <= _state.combat.xSlotTotal then
        local maName = _state.session.mainAssist
        local maType = _state.session.mainAssistType
        if (mq.TLO.Spawn(maName .. ' ' .. maType .. ' group').ID() or 0) ~= 0 then
            if (mq.TLO.SpawnCount('id ' .. mobID .. ' xtarhater') or 0) == 0 then
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
        if (mq.TLO.SpawnCount('pc ' .. stripped) or 0) > 0 then return false end
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

    _state.combat.validTarget = true
    return true
end

-- Mirrors Bind_Settings (DPS/Melee/Burn/General sections) from kissassist.mac.
-- Loads combat arrays and wires state.combat flags from INI.
function Combat.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    -- Engagement toggles
    _state.combat.dpsOn       = Config.get('DPS',   'DPSOn',   '1') == '1'
    _state.combat.meleeOn     = Config.get('Melee', 'MeleeOn', '1') == '1'

    -- Assist-at percent: prefer INI; fall back to CLI-parsed session value (default 95)
    _state.combat.assistAt    = tonumber(Config.get('Melee', 'AssistAt',
                                    tostring(_state.session.assistAt)))
                                or _state.session.assistAt

    _state.combat.meleeDistance = tonumber(Config.get('Melee', 'MeleeDistance', '30')) or 30

    -- Burn flags
    _state.combat.burnOnNamed = Config.get('Burn', 'BurnAllNamed', '0') == '1'
    -- autoBurnTimer: not yet in INI — defaults to 0 (disabled)
    -- TODO: add AutoBurnTimer key to config.lua [Burn] section when available

    -- Camp radius
    _state.movement.campRadius       = tonumber(Config.get('General', 'CampRadius', '50')) or 50
    _state.movement.campRadiusExceed = Config.get('General', 'CampRadiusExceed', '0') == '1'

    -- DPS spell/AA/disc array — entries may carry type suffixes (e.g. "Roar|disc")
    -- castWhat() reads from this array and dispatches by type.
    local dpsArr = Config.get('DPS', 'DPS', nil)
    if type(dpsArr) == 'table' then
        for _, v in ipairs(dpsArr) do
            if v and v ~= '' then
                _state.combat.dpsArray[#_state.combat.dpsArray + 1] = v
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

    -- Named-mob watch list — sourced from KissAssist_Info.ini (zone-specific shared file).
    -- TODO: load NamedWatch entries from KissAssist_Info.ini when that file is added to Config.
    -- _state.combat.namedWatchList stays empty until that config path is wired.

    utils.debug('combat', 'Combat.init: dpsOn=%s meleeOn=%s assistAt=%d meleeDistance=%d dps#=%d burn#=%d campRadius=%d',
        tostring(_state.combat.dpsOn),
        tostring(_state.combat.meleeOn),
        _state.combat.assistAt,
        _state.combat.meleeDistance,
        #_state.combat.dpsArray,
        #_state.combat.burnArray,
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
    if not _state.combat.meleeOn and not _state.combat.dpsOn and not _state.mez.mezOn then return end
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
    if not _state.combat.meleeOn and not _state.combat.dpsOn and not _state.mez.mezOn then return end
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
            local j = mq.TLO.SpawnCount('xtarhater') or 0
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

return Combat
