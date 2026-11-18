-- pull/util.lua — helpers shared across the pull code: distances, the aggro
-- check, name-list matching, stopping movement, PullReset, and a few small
-- pieces the pull loop used to repeat (own-corpse grab, /moveto to a mob).
-- Step 1 of the pull module split (see the pull_module_split_plan).

local mq = require('mq')

local Util = {}
local _state, _utils, _healing

-- Roles that pull (mac CheckRoles). Also used by init.lua and groupwatch.lua.
Util.PULLER_ROLES = {
    puller = true, pullertank = true, pullerpettank = true, hunter = true, hunterpettank = true,
}

function Util.init(state, utils, healing)
    _state   = state
    _utils   = utils
    _healing = healing
end

function Util.isPullerRole(role)
    return Util.PULLER_ROLES[role or ''] == true
end

-- 2D XY distance.
function Util.dist2D(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- 3D distance from a point to the camp location.
function Util.distToCamp3D(y, x, z)
    local mv = _state.movement
    local dy = (y or 0) - (mv.campY or 0)
    local dx = (x or 0) - (mv.campX or 0)
    local dz = (z or 0) - (mv.campZ or 0)
    return math.sqrt(dy * dy + dx * dx + dz * dz)
end

-- True once the pull has drawn aggro (live XTarget check; see Utils.pullAggroID).
function Util.hasAggro()
    return _utils.pullAggroID() > 0
end

-- Case-insensitive name search in a comma/pipe-separated list.
-- '*' prefix = substring match; '#' prefix = strip then exact; plain = exact.
function Util.inNameList(list, name)
    if not list or list == 'null' or list == 'all' or list == '' then return false end
    local lname = name:lower()
    for entry in (list..'|'):gmatch('([^,|]+)[,|]') do
        entry = entry:match('^%s*(.-)%s*$')
        local ch = entry:sub(1, 1)
        if ch == '*' then
            if lname:find(entry:sub(2):lower(), 1, true) then return true end
        elseif ch == '#' then
            if lname == entry:sub(2):lower() then return true end
        else
            if lname == entry:lower() then return true end
        end
    end
    return false
end

function Util.stopMoving()
    mq.cmd('/squelch /moveto off')
    mq.cmd('/squelch /nav stop')
    mq.cmd('/squelch /stick off')
end

-- Mirrors Sub PullReset (mac:10565).
function Util.pullReset()
    local s = _state
    s.pull.pulling        = false
    s.pull.pulled         = false
    s.combat.myTargetID   = 0
    s.combat.myTargetName = '0'
    s.movement.toClose    = false
    mq.cmd('/attack off')
    Util.stopMoving()
    mq.cmd('/squelch /target clear')
end

-- Spawn ID in an XTarget slot (0 for slot 0 or an empty slot).
function Util.xtSlotID(slot)
    if (slot or 0) == 0 then return 0 end
    return mq.TLO.Me.XTarget(slot).ID() or 0
end

-- /moveto a mob, stopping dist away; underwater when our feet are wet
-- (mac:9726-9728, 9744-9748).
function Util.moveToMob(mobID, dist)
    local uwSuffix = mq.TLO.Me.FeetWet() and ' uw' or ''
    mq.cmdf('/moveto id %d mdist %d%s', mobID, math.floor(dist), uwSuffix)
end

-- GrabCorpse during a pull: if CorpseRecoveryOn and our own corpse is within
-- radius, drag it (mac:9645 with flag 1, mac:10370 with flag 2). True when we
-- are now dragging a corpse, so the pull should head back to camp.
function Util.grabOwnCorpse(radius, flag)
    local s = _state
    if (s.heal.corpsRecoveryOn or 0) == 0 or not _healing or s.misc.dragCorpse then return false end
    local selfName = mq.TLO.Me.CleanName() or ''
    if (mq.TLO.SpawnCount('pccorpse ' .. selfName .. ' radius ' .. radius)() or 0) == 0 then return false end
    _healing.grabCorpse(flag)
    return s.misc.dragCorpse == true
end

return Util
