local mq     = require('mq')
local Config = require('modules.config')

local Cond = {}
local _state

function Cond.init(state, _utils)  -- utils: unused, kept for callers
    _state = state
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

-- Warn once per distinct expression that couldn't be evaluated (it's treated as false).
local _warned = {}
local function warnUnevaluable(expr, parsed)
    if _warned[expr] then return end
    _warned[expr] = true
    printf('\ayKissAssist \arCondition could not be evaluated, treating as false: \aw%s \ar(parsed: \aw%s\ar)',
        expr, parsed)
end

-- Mac outer variables that [KConditions] expressions may read (#295). In the mac,
-- conditions run in the macro's context and can see these; they aren't MQ TLOs, so
-- mq.parse would return NULL. Keys are lowercase (macro variable names ignore case).
-- Ints/bools become numbers the way the mac declares them (int, 0/1).
local function b2n(v) return v and 1 or 0 end
local MAC_VARS = {
    burnon        = function(s) return b2n(s.combat.burnOn) end,         -- mac:16714
    burnactive    = function(s) return b2n(s.combat.burnActive) end,     -- mac:16712
    combatstart   = function(s) return b2n(s.combat.combatStart) end,    -- mac:16734
    dpspaused     = function(s) return b2n(s.dps.paused) end,            -- mac:16745
    iamma         = function(s) return b2n(s.session.iAmMA) end,         -- mac:16773
    mytargetid    = function(s) return s.combat.myTargetID or 0 end,     -- mac:16826
    aggrotargetid = function(s)                                          -- mac:16699
        local v = s.combat.aggroTargetID
        return (v == nil or v == '') and 0 or v
    end,
    role          = function(s) return s.session.role or '' end,
    mainassist    = function(s) return s.session.mainAssist or '' end,   -- mac:16793
}

-- Replace ${Var} and ${Var.Equal[x]} / .NotEqual[x] / .Find[x] / .Length for the
-- MAC_VARS above. String compares ignore case, like MQ's string members. Anything
-- else (TLOs, unknown members) is left for mq.parse.
local function resolveMacVars(expr)
    if not _state then return expr end
    return (expr:gsub('%${([%a_][%w_]*)([^${}]*)}', function(name, rest)
        local get = MAC_VARS[name:lower()]
        if not get then return nil end
        local ok, v = pcall(get, _state)
        if not ok then return nil end
        v = tostring(v)
        if rest == '' then return v end
        local member, arg = rest:match('^%.(%a+)%[(.*)%]$')
        if not member then member = rest:match('^%.(%a+)$') end
        member = member and member:lower()
        local lv, la = v:lower(), (arg or ''):lower()
        if member == 'equal'    then return lv == la and 'TRUE' or 'FALSE' end
        if member == 'notequal' then return lv ~= la and 'TRUE' or 'FALSE' end
        if member == 'find' then
            local p = lv:find(la, 1, true)
            return p and tostring(p) or 'NULL'
        end
        if member == 'length' then return tostring(#v) end
        return nil
    end))
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
    -- Resolve mac variables (${BurnOn}, ${Role.NotEqual[x]}, ...) — not TLOs either.
    expr = resolveMacVars(expr)
    local result = mq.parse(expr)
    if result == nil then return false end
    if result == 'FALSE' or result == '0' or result == 'NULL' then return false end
    if result == 'TRUE'  or result == '1' then return true end
    -- mq.parse leaves MQ operators (!  &&  ||) and NULL untouched; normalize to Lua.
    -- !<number>: MQ treats 0 as false, nonzero as true, so !0=true, !13=false.
    result = result:gsub('NULL', '0')
    result = result:gsub('!=', '~=')  -- before the !<x> rewrites below
    result = result:gsub('!(%d+)', function(n) return tonumber(n) == 0 and 'true' or 'false' end)
    result = result:gsub('!TRUE', 'false'):gsub('!FALSE', 'true')
    -- Any '!' left negates a group, e.g. '!(TRUE && FALSE)' (#297). '!=' is already '~=',
    -- so every remaining '!' is a logical not.
    result = result:gsub('!', ' not ')
    result = result:gsub('TRUE', 'true'):gsub('FALSE', 'false')
    result = result:gsub('&&', ' and '):gsub('||', ' or ')
    local fn = load('return ' .. result)
    if fn then
        local ok, val = pcall(fn)
        if ok then return val ~= nil and val ~= false and val ~= 0 end
    end
    -- Fail closed: an expression we can't evaluate must not fire its entry every time.
    warnUnevaluable(expr, result)
    return false
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
