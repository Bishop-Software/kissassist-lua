-- combat/util.lua — small helpers shared by the combat modules. They need mq/State,
-- so they live here rather than in modules/helpers.lua (which stays mq-free for unit tests).

local mq      = require('mq')
local Helpers = require('modules.helpers')

local Util = {}
local _state

local dist2D = Helpers.dist2D

function Util.init(state)
    _state = state
end

-- True when a spawn object doesn't exist (ID 0) or is a corpse.
local function spawnGone(sp)
    return (sp.ID() or 0) == 0 or (sp.Type() or ''):lower() == 'corpse'
end

-- True when the spawn with this ID is gone or dead.
local function isDeadOrGone(id)
    return spawnGone(mq.TLO.Spawn('id ' .. tostring(id or 0)))
end

-- /squelch /target the spawn and wait (default 1s) until it is the current target.
local function targetAndWait(id, ms)
    mq.cmd('/squelch /target id ' .. id)
    mq.delay(ms or 1000, function() return (mq.TLO.Target.ID() or 0) == id end)
end

-- 2D distance from the camp anchor to (y, x).
local function distFromCamp(y, x)
    local mv = _state.movement
    return dist2D(mv.campY, mv.campX, y, x)
end

-- The main assist's spawn, looked up by exact name.
local function getMASpawn()
    return mq.TLO.Spawn('=' .. (_state.session.mainAssist or ''))
end

Util.dist2D        = dist2D
Util.spawnGone     = spawnGone
Util.isDeadOrGone  = isDeadOrGone
Util.targetAndWait = targetAndWait
Util.distFromCamp  = distFromCamp
Util.getMASpawn    = getMASpawn

return Util
