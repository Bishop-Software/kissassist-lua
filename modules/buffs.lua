local Config = require('modules.config')

local Buffs = {}
local _state, _utils, _cast

-- Mirrors Bind_Settings buff loading (kissassist.mac:14657-14671) and
-- Pet buff loading from [Pet] INI section.
function Buffs.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    -- [Buffs] section
    _state.buffs.buffsOn        = Config.get('Buffs', 'BuffsOn',        '0') == '1'
    _state.buffs.rebuffOn       = Config.get('Buffs', 'RebuffOn',       '1') == '1'
    _state.buffs.checkBuffsTimer = tonumber(Config.get('Buffs', 'CheckBuffsTimer', '15')) or 15
    _state.buffs.powerSource    = Config.get('Buffs', 'PowerSource',    '') or ''

    local buffsArr = Config.get('Buffs', 'Buffs', nil)
    if type(buffsArr) == 'table' then
        for _, v in ipairs(buffsArr) do
            if v and v ~= '' then
                _state.buffs.buffsArray[#_state.buffs.buffsArray + 1] = v
            end
        end
    end

    -- Mount fields from [General] (mac:4200)
    local mountOnRaw = Config.get('General', 'MountOn', nil)
    if mountOnRaw ~= nil then
        _state.misc.mountOn = mountOnRaw == '1'
    end
    _state.buffs.mountSpell = Config.get('General', 'MountSpell', '') or ''

    -- [Pet] buff list
    _state.buffs.petBuffsOn = Config.get('Pet', 'PetBuffsOn', '0') == '1'
    local petBuffsArr = Config.get('Pet', 'PetBuffs', nil)
    if type(petBuffsArr) == 'table' then
        for _, v in ipairs(petBuffsArr) do
            if v and v ~= '' then
                _state.buffs.petBuffsArray[#_state.buffs.petBuffsArray + 1] = v
            end
        end
    end

    utils.debug('buffs',
        'Buffs.init: buffsOn=%s buffs#=%d petBuffsOn=%s petBuffs#=%d rebuffOn=%s checkBuffsTimer=%d mountOn=%s',
        tostring(_state.buffs.buffsOn),
        #_state.buffs.buffsArray,
        tostring(_state.buffs.petBuffsOn),
        #_state.buffs.petBuffsArray,
        tostring(_state.buffs.rebuffOn),
        _state.buffs.checkBuffsTimer,
        tostring(_state.misc.mountOn))
end

return Buffs
