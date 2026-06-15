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
-- mq.parse only expands TLOs — it does not evaluate comparison operators.
-- '${Me.PctHPs} < 75' with HP=100 yields '100 < 75', not 'FALSE'.
-- We evaluate the expanded result as a Lua expression to handle this case.
function Cond.evalStr(expr)
    if not expr or expr == '' then return true end
    -- Resolve ${Cond[N]} before mq.parse — Cond is not an MQ TLO.
    expr = expr:gsub('%${Cond%[(%d+)%]}', function(n)
        return Cond.eval(tonumber(n)) and 'TRUE' or 'FALSE'
    end)
    local result = mq.parse(expr)
    if result == nil then return false end
    if result == 'FALSE' or result == '0' then return false end
    if result == 'TRUE'  or result == '1' then return true end
    -- mq.parse leaves MQ operators (!  &&  ||) and NULL untouched; normalize to Lua.
    -- !<number>: MQ treats 0 as false, nonzero as true, so !0=true, !13=false.
    result = result:gsub('NULL', '0')
    result = result:gsub('!(%d+)', function(n) return tonumber(n) == 0 and 'true' or 'false' end)
    result = result:gsub('!TRUE', 'false'):gsub('!FALSE', 'true')
    result = result:gsub('TRUE', 'true'):gsub('FALSE', 'false')
    result = result:gsub('&&', ' and '):gsub('||', ' or ')
    local fn = load('return ' .. result)
    if fn then
        local ok, val = pcall(fn)
        if ok then return not not val end
    end
    return result ~= ''
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
