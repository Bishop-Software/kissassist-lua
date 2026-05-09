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

return Combat
