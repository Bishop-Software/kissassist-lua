-- combat/targeting.lua — target acquisition: non-MA Assist, MA GetCombatTarget, and
-- CombatTargetCheck target sync. Mob counting/validation lives in combat/radar.lua.

local mq    = require('mq')
local Util  = require('modules.combat.util')
local Radar = require('modules.combat.radar')

local Targeting = {}
local _state, _utils
local Combat  -- modules/combat.lua facade; used for Combat.mobRadar calls

local dist2D        = Util.dist2D
local isDeadOrGone  = Util.isDeadOrGone
local targetAndWait = Util.targetAndWait
local distFromCamp  = Util.distFromCamp
local getMASpawn    = Util.getMASpawn
local validateTarget = Radar.validateTarget
local campNpcCount   = Radar.campNpcCount

function Targeting.init(state, utils, combat)
    _state = state
    _utils = utils
    Combat = combat
end

-- Mirrors Sub Assist (kissassist.mac:748).
-- Non-MA path: use Group.MainAssist shortcut or /assist MainAssist to acquire target.
-- MA path skipped here — MA calls getCombatTarget() instead.
-- Both paths validate and lock state.combat.myTargetID.
local function assist(_fromWhere)
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
local function getCombatTarget()
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
local function combatTargetCheck(setTarget)
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

Targeting.assist            = assist
Targeting.getCombatTarget   = getCombatTarget
Targeting.combatTargetCheck = combatTargetCheck

return Targeting
