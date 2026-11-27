-- ${KissAssist} TLO (#353), for macros and plugins such as MQ2Boxr:
--   ${KissAssist}             "Paused" or "Running" (exists only while kissassist-lua runs)
--   ${KissAssist.Paused}      TRUE while soft-paused (/kactl pause)
--   ${KissAssist.State}       "Paused" or "Running"
--   ${KissAssist.Role}        current role
--   ${KissAssist.MainAssist}  current main assist
--   ${KissAssist.Mode}        movement mode: manual, camp or chase (#362)
--   ${KissAssist.LastResult}  outcome of the last /kactl: 'ok' or 'error: <why>' (#363)
--   ${KissAssist.Target}      forced target's spawn ID (/kactl target), 0 when none (#364)
--   ${KissAssist.Hold}        TRUE while holding position (/kactl hold) (#364)
-- The macro registers no TLO, so the name can't clash with kissassist.mac.
local mq      = require('mq')
local Control = require('modules.control')

local Tlo = {}

local NAME = 'KissAssist'

local _state
local _registered = false

-- Member getters, kept apart from mq.DataType so tests can call them directly.
Tlo.members = {
    Paused     = function() return 'bool', _state.session.paused == true end,
    State      = function() return 'string', _state.session.paused and 'Paused' or 'Running' end,
    Role       = function() return 'string', _state.session.role or '' end,
    MainAssist = function() return 'string', _state.session.mainAssist or '' end,
    Mode       = function() return 'string', Control.modeOf(_state) end,
    LastResult = function() return 'string', Control.lastResult or '' end,
    Target     = function() return 'int', (_state.combat and _state.combat.forcedTargetID) or 0 end,
    Hold       = function() return 'bool', _state.session.hold == true end,
}

function Tlo.init(state)
    _state = state
end

-- Returns true once the TLO is registered. Skips quietly when MQ2Lua has no
-- TLO support (the unit-test mock), and warns if the name is already taken.
function Tlo.register()
    if _registered then return true end
    if not (mq.DataType and mq.AddTopLevelObject) then return false end

    local members = {}
    for name, get in pairs(Tlo.members) do
        members[name] = function(_param, _self) return get() end
    end
    local dataType = mq.DataType.new('KissAssistLua', {
        Members  = members,
        ToString = function(_self) return select(2, Tlo.members.State()) end,
    })
    -- MQ2Lua requires exactly one parameter (the [index]) on a TLO function.
    _registered = mq.AddTopLevelObject(NAME, function(_index) return dataType, _state end) == true
    if not _registered then
        printf('\ayKissAssist: could not register the ${%s} TLO (name already in use?)', NAME)
    end
    return _registered
end

-- MQ2Lua also removes a script's TLOs when it ends; this makes it explicit.
function Tlo.unregister()
    if _registered and mq.RemoveTopLevelObject then
        mq.RemoveTopLevelObject(NAME)
    end
    _registered = false
end

return Tlo
