local mq = require('mq')

local Afk = {}

local _state, _combat, _comms, _config

local function posseLoaded()
    return mq.TLO.Plugin('MQ2Posse').IsLoaded() == true
end

function Afk.init(state, _utils, combat, comms, config)
    _state  = state
    _combat = combat
    _comms  = comms
    _config = config

    _state.afk.on       = tonumber(_config.get('AFKTools', 'AFKToolsOn',  '1')) or 1
    _state.afk.gmAction = tonumber(_config.get('AFKTools', 'AFKGMAction', '1')) or 1
    _state.afk.pcRadius = tonumber(_config.get('AFKTools', 'AFKPCRadius', '500')) or 500
    _state.afk.campOnDeath = tonumber(_config.get('AFKTools', 'CampOnDeath', '0')) or 0

    -- Set MQ2Posse camp radius if stranger detection is active (mac:16412-16414)
    if (_state.afk.on == 1 or _state.afk.on == 2) and posseLoaded() then
        mq.cmdf('/posse radius %d', _state.afk.pcRadius)
    elseif (_state.afk.on == 1 or _state.afk.on == 2) and not posseLoaded() then
        printf('\ayAFKTools: stranger detection enabled but MQ2Posse not loaded — stranger check disabled')
    end
end

-- Camp out when not in the camp zone — mirrors Sub DoICampA (mac:6199).
-- CampOnDeath 1 waits for the 10-minute timer set on zoning (timers.campOnDeath,
-- mac:11125) without blocking the loop; 2 camps at once. Returns true when camping.
function Afk.doICamp()
    local mode = _state.afk.campOnDeath
    if mode == 1 then
        local left = (_state.timers.campOnDeath or 0) - os.clock()
        if left > 0 then
            if not _state.afk.waitingToCamp then
                printf('yCamping Due to Not in Camp Zone. Waiting for %d Seconds', math.ceil(left))
                _state.afk.waitingToCamp = true
            end
            return false
        end
        printf('rTime Expired. Camping Now.')
    elseif mode == 2 then
        printf('rI am not where I am suppose to be. Time to camp out.')
    else
        return false
    end
    _state.afk.waitingToCamp = false
    if _state.session.iAmABard then mq.cmd('/medley stop') end  -- CastBardCheck
    mq.cmd('/camp desktop')
    mq.delay(10000)
    _state.terminate = true
    return true
end

-- Main AFK safety monitor — mirrors Sub AFKTools (mac:11665).
function Afk.check()
    -- Out of the camp zone: only CampOnDeath runs (mac:11668-11671)
    if _state.movement.campZone ~= mq.TLO.Zone.ID() then
        if _state.afk.campOnDeath ~= 0 then Afk.doICamp() end
        return
    end
    if _state.afk.waitingToCamp then
        printf('gBack in the camp zone. Aborting! Camping.')
        _state.afk.waitingToCamp = false
    end

    -- Skip while in active combat with heals running (mac:11672)
    if _state.heal.healsOn ~= 0 and _state.combat.aggroTargetID ~= '' then return end

    -- Stranger detection (AFKToolsOn == 1 or 2) (mac:11673-11693)
    if (_state.afk.on == 1 or _state.afk.on == 2) and posseLoaded() then
        local holding = false
        while (mq.TLO.Posse.Strangers() or 0) >= 1 do ---@diagnostic disable-line: undefined-field
            if not holding then
                printf('\ay[AHTools] Macro on hold due to player activity in camp radius.')
                _comms.announce('**PCS DETECTED IN CAMP RADIUS**')
                mq.cmd('/beep')
                holding = true
            end
            mq.delay(1000)
            -- Keep combat running while held (mac:11683-11687)
            if _state.combat.dpsOn or _state.combat.meleeOn then
                _combat.checkForCombat(0, 'AFKTools1', 0)
            else
                _combat.checkForCombat(1, 'AFKTools2', 0)
            end
            mq.doevents()
        end
    end

    -- GM detection (AFKToolsOn == 1 or 3) (mac:11694-11716)
    if (_state.afk.on == 1 or _state.afk.on == 3) then
        if (mq.TLO.SpawnCount('GM')() or 0) >= 1 then
            local action = _state.afk.gmAction

            if action == 1 then
                -- Hold until GM leaves (mac:11697-11704)
                local holding = false
                while (mq.TLO.SpawnCount('GM')() or 0) >= 1 do
                    if not holding then
                        printf('\ay[AHTools] Macro on hold due to GM Presence')
                        _comms.announce('** GM DETECTED **')
                        mq.cmd('/beep')
                        holding = true
                    end
                    mq.delay(1000)
                    mq.doevents()
                end
            elseif action == 2 then
                printf('\ar[AHTools] Ending Macro due to GM Presence')
                _state.terminate = true
            elseif action == 3 then
                printf('\ar[AHTools] Unloading MQ2 due to GM Presence')
                mq.cmd('/unload')
            elseif action == 4 then
                printf('\ar[AHTools] Quitting out of EQ due to GM Presence')
                mq.cmd('/quit')
            end
        end
    end
end

return Afk
