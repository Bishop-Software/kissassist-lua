local mq     = require('mq')
local Config = require('modules.config')

local Combat = {}
local _state, _utils, _cast

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

return Combat
