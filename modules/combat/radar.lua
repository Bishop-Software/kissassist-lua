-- combat/radar.lua — mob counting and target validation: MobRadar (XTarget hater count,
-- aggroTargetID), the camp NPC count, and ValidateTarget. mobRadar and validateTarget
-- share the private _nearspawnFallback flag, so they live together.

local mq     = require('mq')
local Config = require('modules.config')
local Util   = require('modules.combat.util')

local Radar = {}
local _state, _utils
local _nearspawnFallback = false  -- set by mobRadar when NearestSpawn fallback fires

local distFromCamp = Util.distFromCamp
local getMASpawn   = Util.getMASpawn

function Radar.init(state, utils)
    _state = state
    _utils = utils
end

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
local function mobRadar(mode, radius)
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

Radar.validateTarget = validateTarget
Radar.campNpcCount   = campNpcCount
Radar.mobRadar       = mobRadar

return Radar
