local mq     = require('mq')
local Config = require('modules.config')

local Heal = {}

local _state, _utils, _cast

-- Mirrors Bind_Settings heals/cures/general-med sections (kissassist.mac:14750).
-- Defaults match LoadIni defaults in the mac.
function Heal.init(state, utils, cast)
    _state = state
    _utils = utils
    _cast  = cast

    -- [General] medding + group-watch (GroupWatchOn may encode pct as "1|20")
    _state.heal.medOn           = Config.get('General', 'MedOn',     '1') == '1'
    _state.heal.medStart        = tonumber(Config.get('General', 'MedStart',   '20'))  or 20
    _state.heal.medStop         = tonumber(Config.get('General', 'MedStop',    '100')) or 100
    _state.heal.medCombat       = Config.get('General', 'MedCombat', '0') == '1'
    _state.heal.corpsRecoveryOn = Config.get('General', 'CorpseRecoveryOn', '0') ~= '0'

    local gwRaw = Config.get('General', 'GroupWatchOn', '0') or '0'
    if gwRaw:find('|', 1, true) then
        local gwOn, gwPct = gwRaw:match('^([^|]+)|(.+)$')
        _state.heal.groupWatchOn  = (gwOn or '0') ~= '0'
        _state.heal.groupWatchPct = tonumber(gwPct) or _state.heal.groupWatchPct
    else
        _state.heal.groupWatchOn = gwRaw ~= '0'
    end

    -- [Heals]
    _state.heal.healsOn         = Config.get('Heals', 'HealsOn',         '0') == '1'
    _state.heal.healInterval    = tonumber(Config.get('Heals', 'HealInterval', '0'))  or 0
    _state.heal.autoRezOn       = Config.get('Heals', 'AutoRezOn',       '0') == '1'
    _state.heal.xTarHeal        = Config.get('Heals', 'XTarHeal',        '0') == '1'
    _state.heal.xTarHealList    = Config.get('Heals', 'XTarHealList',    '')  or ''
    _state.heal.healGroupPetsOn = Config.get('Heals', 'HealGroupPetsOn', '0') == '1'
    _state.heal.rezMeLast       = Config.get('Heals', 'RezMeLast',       '0') == '1'

    local healsRaw = Config.get('Heals', 'Heals', nil)
    if type(healsRaw) == 'table' then
        for _, v in ipairs(healsRaw) do
            if v and v ~= '' and v ~= 'NULL' and v ~= 'null' then
                _state.heal.healsArray[#_state.heal.healsArray + 1] = v
            end
        end
    end

    -- [Cures]
    _state.heal.curesOn = Config.get('Cures', 'CuresOn', '0') == '1'

    local curesRaw = Config.get('Cures', 'Cures', nil)
    if type(curesRaw) == 'table' then
        for _, v in ipairs(curesRaw) do
            if v and v ~= '' and v ~= 'NULL' and v ~= 'null' then
                _state.heal.curesArray[#_state.heal.curesArray + 1] = v
            end
        end
    end

    _utils.debug('heals', string.format(
        'Heal.init done — healsOn=%s(%d) curesOn=%s(%d) medOn=%s medStart=%d medStop=%d',
        tostring(_state.heal.healsOn),  #_state.heal.healsArray,
        tostring(_state.heal.curesOn),  #_state.heal.curesArray,
        tostring(_state.heal.medOn), _state.heal.medStart, _state.heal.medStop))
end

-- Step 5.2: Heal.checkHealth()   — self-triage + single-heal dispatch
-- Step 5.3: Heal.doGroupHealStuff() — group heal + HoT + medding
-- Step 5.4: Heal.checkCures()    — debuff removal + WriteDebuffs
-- Step 5.5: Heal.rezCheck()      — rez dead group members via MQ2Rez
-- Step 5.6: wire above into Combat.fight() and main loop

return Heal
