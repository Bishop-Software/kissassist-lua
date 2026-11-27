-- ${KissAssist} TLO (#353), for macros and plugins such as MQ2Boxr:
--   ${KissAssist}             "Paused" or "Running" (exists only while kissassist-lua runs)
--   ${KissAssist.Paused}      TRUE while soft-paused (/kapause)
--   ${KissAssist.State}       "Paused" or "Running"
--   ${KissAssist.Role}        current role
--   ${KissAssist.MainAssist}  current main assist
--   ${KissAssist.Mode}        movement mode: manual, camp or chase (#362)
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
