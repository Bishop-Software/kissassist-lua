local mq = require('mq')

local Afk = {}

local _state, _utils, _combat, _comms

local function posseLoaded()
    return mq.TLO.Plugin('MQ2Posse').IsLoaded() == true
end

function Afk.init(state, utils, combat, comms)
    _state  = state
    _utils  = utils
    _combat = combat
    _comms  = comms

    _state.afk.on       = tonumber(require('modules.config').get('AFKTools', 'AFKToolsOn',  '0')) or 0
    _state.afk.gmAction = tonumber(require('modules.config').get('AFKTools', 'AFKGMAction', '1')) or 1
    _state.afk.pcRadius = tonumber(require('modules.config').get('AFKTools', 'AFKPCRadius', '500')) or 500

    -- Set MQ2Posse camp radius if stranger detection is active (mac:16412-16414)
    if (_state.afk.on == 1 or _state.afk.on == 2) and posseLoaded() then
        mq.cmdf('/posse radius %d', _state.afk.pcRadius)
    elseif (_state.afk.on == 1 or _state.afk.on == 2) and not posseLoaded() then
        _utils.debug('AFKTools: stranger detection enabled but MQ2Posse not loaded — stranger check disabled')
    end
end

-- Main AFK safety monitor — mirrors Sub AFKTools (mac:11665).
function Afk.check()
    -- Wrong zone: defer to movement (mac:11668-11671)
    if mq.TLO.Zone.ID() ~= (_state.movement.campZone or 0) then return end

    -- Skip while in active combat with heals running (mac:11672)
    if _state.heal.healsOn and _state.combat.aggroTargetID ~= 0 then return end

    -- Stranger detection (AFKToolsOn == 1 or 2) (mac:11673-11693)
    if (_state.afk.on == 1 or _state.afk.on == 2) and posseLoaded() then
        local holding = false
        while (mq.TLO.Posse.Strangers() or 0) >= 1 do ---@diagnostic disable-line: undefined-field
            if not holding then
                _utils.debug('[AHTools] Macro on hold due to player activity in camp radius.')
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
                        _utils.debug('[AHTools] Macro on hold due to GM Presence')
                        _comms.announce('** GM DETECTED **')
                        mq.cmd('/beep')
                        holding = true
                    end
                    mq.delay(1000)
                    mq.doevents()
                end
            elseif action == 2 then
                _utils.debug('[AHTools] Ending Macro due to GM Presence')
                _state.terminate = true
            elseif action == 3 then
                _utils.debug('[AHTools] Unloading MQ2 due to GM Presence')
                mq.cmd('/unload')
            elseif action == 4 then
                _utils.debug('[AHTools] Quitting out of EQ due to GM Presence')
                mq.cmd('/quit')
            end
        end
    end
end

return Afk
