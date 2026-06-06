local mq     = require('mq')
local Config = require('modules.config')

local Cond = {}
local _state, _utils

function Cond.init(state, utils)
    _state = state
    _utils = utils
end

-- Reads [KConditions] INI section into state.cond.
-- Conditions are stored as an indexed array under the 'Cond' key.
-- Migrates old CondNNN string keys to array format on first load.
function Cond.load()
    _state.cond.on   = Config.get('KConditions', 'ConOn',    '0') == '1'
    _state.cond.size = tonumber(Config.get('KConditions', 'CondSize', '5')) or 5

    local condArr = Config.get('KConditions', 'Cond', nil)
    if not condArr then
        -- Migrate old CondNNN string keys into array format
        condArr = {}
        local migrated = false
        for i = 1, _state.cond.size do
            local oldKey = string.format('Cond%03d', i)
            local val = Config.get('KConditions', oldKey, '')
            if val ~= '' then
                condArr[i] = val
                Config.set('KConditions', oldKey, nil)
                migrated = true
            else
                condArr[i] = 'null'
            end
        end
        Config.set('KConditions', 'Cond', condArr)
        if migrated then Config.save() end
    end

    _state.cond.expressions = {}
    for i = 1, _state.cond.size do
        local val = condArr[i]
        if val and val ~= 'null' and val ~= '' then
            _state.cond.expressions[i] = val
        end
    end
end

-- Evaluate an arbitrary TLO expression string. Returns true if the result is truthy.
function Cond.evalStr(expr)
    if not expr or expr == '' then return true end
    local result = mq.parse(expr)
    return result ~= nil and result ~= 'FALSE' and result ~= '0'
end

-- Evaluate condition slot n.
-- Returns true when: conditions are globally off, n is 0, slot is empty, or expression is truthy.
-- The TARGETCHECK sentinel runs a live target-validity check instead of expression eval.
function Cond.eval(n)
    if not _state.cond.on or n == 0 then return true end
    local expr = _state.cond.expressions[n]
    if not expr or expr == '' then return true end
    if expr:find('TARGETCHECK') then
        local tgt = mq.TLO.Target
        return tgt() ~= nil
            and tgt.Type() == 'NPC'
            and not tgt.Dead()
            and (tgt.PctHPs() or 0) > 0
    end
    return Cond.evalStr(expr)
end

return Cond
