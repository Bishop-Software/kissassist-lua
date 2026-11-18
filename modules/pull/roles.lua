-- pull/roles.lua — puller and hunter role setup (CheckRoles) and the EQ
-- group Puller role toggle for a pullerpettank (PullRoleToggle).
-- Step 3 of the pull module split (see the pull_module_split_plan).

local mq   = require('mq')
local Util = require('modules.pull.util')

local Roles = {}
local _state, _utils

local dist2D = Util.dist2D

function Roles.init(state, utils)
    _state = state
    _utils = utils
end

-- Hunter role setup from CheckRoles (mac:8735-8798). Runs at startup after the
-- INI is loaded. A hunter engages at 100%. With ReturnToCamp on, it is turned
-- off: the hunter fights where it pulls and walks back only when it runs out of
-- mobs. With it off, the hunter stays put and pulls on its way back (StayPut +
-- PullOnReturn). Main assist identity is set in init.lua (TANK_ROLES).
function Roles.setupHunterRole()
    local s    = _state
    local role = s.session.role
    if role ~= 'hunter' and role ~= 'hunterpettank' then return end
    s.combat.assistAt = 100
    if s.combat.useMQ2Melee then
        mq.cmdf('/squelch /melee aggro=%d', role == 'hunter' and 1 or 0)
    end
    if s.movement.returnToCamp then
        s.movement.returnToCamp = false
        s.movement.stayPut      = false
    else
        s.movement.stayPut  = true
        s.pull.pullOnReturn = true
    end
    if role == 'hunterpettank' then
        s.session.chaseAssist = false
        s.misc.mountOn        = false
        s.pet.assistAt        = 100
    end
    if (mq.TLO.Me.Pet.ID() or 0) > 0 then mq.cmd('/pet follow') end
    _utils.debug('pull', 'setupHunterRole: role=%s stayPut=%s pullOnReturn=%s',
        role, tostring(s.movement.stayPut), tostring(s.pull.pullOnReturn))
end

-- Puller role setup from CheckRoles (mac:8688-8734, 8803-8826). Runs at startup
-- after the INI is loaded. Pullers always return to camp: executePull only walks
-- back and waits for the mob when ReturnToCamp is on, and the INI default is 0.
-- Main assist identity is set in init.lua (TANK_ROLES); pet taunt is handled by
-- the pet module; the PullRoleToggle group-leader check is in Pull.init.
function Roles.setupPullerRole()
    local s    = _state
    local role = s.session.role
    if role ~= 'puller' and role ~= 'pullertank' and role ~= 'pullerpettank' then return end
    s.movement.returnToCamp     = true
    s.session.chaseAssist       = false
    -- Leash: past this, ReturnToCamp turns off (mac CampRadiusExceed)
    s.movement.campRadiusExceed = (s.pull.maxRadius or 0) + 200
    if s.combat.useMQ2Melee then
        mq.cmdf('/squelch /melee aggro=%d', role == 'pullertank' and 1 or 0)
    end
    if role ~= 'puller' then s.combat.assistAt = 100 end
    if role == 'pullerpettank' then
        s.combat.meleeOn = false  -- the pet does the fighting
        s.misc.mountOn   = false
        s.pet.assistAt   = 100
    end
    -- Pet: guard if it's close by, else follow (mac:8705, 8728, 8818)
    if (mq.TLO.Me.Pet.ID() or 0) > 0 then
        mq.cmd((mq.TLO.Me.Pet.Distance() or 999) <= (s.movement.campRadius or 30)
            and '/pet guard' or '/pet follow')
    end
    _utils.debug('pull', 'setupPullerRole: role=%s campRadiusExceed=%d',
        role, s.movement.campRadiusExceed)
end

-- PullRoleToggle (mac:10586 PullModeToggle): a pullerpettank who leads the
-- group with a merc in it takes the EQ group Puller role (3) for a pull of a
-- mob outside camp, and drops it again back in camp after a successful pull.
local function isGroupPuller()
    local myID = mq.TLO.Me.ID() or 0
    return myID > 0 and (mq.TLO.Group.Puller.ID() or 0) == myID
end

function Roles.roleToggle(on, mobID)
    local s = _state
    if not s.pull.roleToggle or s.session.role ~= 'pullerpettank' then return end
    if (mq.TLO.Group.Leader.ID() or 0) ~= (mq.TLO.Me.ID() or -1) then return end
    if (mq.TLO.SpawnCount('group mercenary')() or 0) == 0 then return end
    local name = mq.TLO.Me.CleanName() or ''
    if on then
        if isGroupPuller() then return end
        local sp = mq.TLO.Spawn('id ' .. (mobID or 0))
        if not sp() or dist2D(sp.X() or 0, sp.Y() or 0, s.movement.campX, s.movement.campY)
                       <= s.movement.campRadius then
            return
        end
        mq.cmdf('/grouproles set %s 3', name)
        mq.delay(1000, isGroupPuller)
        if isGroupPuller() then printf('\ag+ You have been set to be group puller.') end
    else
        if not isGroupPuller() then return end
        mq.cmdf('/grouproles unset %s 3', name)
        mq.delay(1000, function() return not isGroupPuller() end)
        if not isGroupPuller() then printf('\ag+ You are no longer group puller.') end
    end
end

return Roles
