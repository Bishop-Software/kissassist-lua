-- pull/arc.lua — the pull arc and the MQ2Map drawing: compass heading, arc
-- edges, the /maploc markers along each edge, aiming the arc, the in-arc test
-- for a mob (figureMobAngle), and painting the pull/camp radii (paintMap).
-- Step 3 of the pull module split (see the pull_module_split_plan).
--
-- Calls to other pull functions go through the facade table (Pull.*).

local mq   = require('mq')
local Util = require('modules.pull.util')

local Arc = {}
local _state
local Pull  -- the facade (modules/pull.lua), set by Arc.init

local dist2D = Util.dist2D

function Arc.init(state, pull)
    _state = state
    Pull   = pull
end

-- Compass heading in degrees from (fromY, fromX) to (toY, toX): 0 = north,
-- clockwise (90 = east), the same as Me.Heading.Degrees and the arc facing.
-- MQ's raw HeadingTo value (MQ2SpawnType.cpp) runs counter-clockwise; its
-- .Degrees member, which the mac reads (mac:14515), is 360 minus that. EQ's +X
-- is west, so the raw value alone mirrors east and west.
function Arc.headingTo(fromY, fromX, toY, toX)
    -- Computed directly (east = fromX - toX, north = toY - fromY) rather than as
    -- 360 - raw, which leaves 360 instead of 0 due north from rounding.
    ---@diagnostic disable-next-line: deprecated
    local deg = math.deg(math.atan2(fromX - toX, toY - fromY))
    if deg < 0 then deg = deg + 360 end
    return deg
end

-- Left/right edges of a pull arc of `width` degrees centred on `facing`, wrapped
-- into 0-360. Mirrors Sub SetPullAngles (mac:14490).
function Arc.pullAngles(facing, width)
    local half  = width * 0.5
    local lSide = facing - half
    if lSide < 0 then lSide = 360 + lSide end
    local rSide = facing + half
    if rSide > 360 then rSide = rSide - 360 end
    return lSide, rSide
end

-- ---------------------------------------------------------------------------
-- Pull arc on the MQ2Map map (Lua port addition). MQ2Map can't draw lines, so
-- each edge of the arc is a dotted line of /maploc markers from the camp out to
-- MaxRadius; with the PullRadius circle (paintMap) that outlines the wedge.
-- ---------------------------------------------------------------------------
local ARC_DOTS = 4   -- markers per edge, evenly spaced out to MaxRadius

local function mapLoaded()
    local plugin = mq.TLO.Plugin('MQ2Map')
    return plugin ~= nil and plugin.IsLoaded() == true
end

local function isArcRole()
    local role = _state.session.role or ''
    return role:find('puller', 1, true) ~= nil or role:find('hunter', 1, true) ~= nil
end

-- Remove the arc markers this session placed (never a bare "/maploc remove",
-- which deletes every map loc).
function Arc.clearArc()
    local marks = _state.pull.arcMarks or {}
    if #marks > 0 and mapLoaded() then
        for _, loc in ipairs(marks) do mq.cmdf('/squelch /maploc remove %s', loc) end
    end
    _state.pull.arcMarks = {}
end

-- Point `dist` from camp on compass heading `deg` (0 north = +Y, 90 east = -X).
function Arc.arcPoint(campY, campX, deg, dist)
    local r = math.rad(deg)
    return campY + dist * math.cos(r), campX - dist * math.sin(r)
end

-- Redraw the arc's edges around the camp. Clears them when the arc is off,
-- there's no camp, or this isn't a puller/hunter role.
function Arc.drawArc()
    Pull.clearArc()
    local p, mv = _state.pull, _state.movement
    if (p.pullArcWidth or 0) <= 0 or not isArcRole() then return end
    if (mv.campX or 0) == 0 and (mv.campY or 0) == 0 then return end
    if not mapLoaded() then return end
    local radius = p.maxRadius or 0
    if radius <= 0 then return end
    local marks = {}
    for _, side in ipairs({ { p.lSide, 'Pull arc L' }, { p.rSide, 'Pull arc R' } }) do
        for i = 1, ARC_DOTS do
            local y, x = Pull.arcPoint(mv.campY, mv.campX, side[1], radius * i / ARC_DOTS)
            -- MQ2Map tags map locs by whole-number loc, so place and remove by that.
            local loc = string.format('%d %d', math.floor(y + 0.5), math.floor(x + 0.5))
            local label = (i == ARC_DOTS) and (' label ' .. side[2]) or ''
            mq.cmdf('/squelch /maploc size 10 color 255 200 0 %s%s', loc, label)
            marks[#marks + 1] = loc
        end
    end
    p.arcMarks = marks
end

-- Aim the pull arc: store its edges and facing in State.pull (mac:14490).
-- A width of 0 turns it off and clears the map markers.
function Arc.setPullAngles(facing, width, quiet)
    if not width or width <= 0 then Pull.clearArc() return end
    facing = facing or 0
    local p = _state.pull
    p.lSide, p.rSide = Pull.pullAngles(facing, width)
    p.heading = facing
    if not quiet then
        printf('\aySetting Pull Angles. Facing: \at%.2f\ay Left Side: \at%.2f\ay Right Side: \at%.2f\ay Width: \at%d',
            facing, p.lSide, p.rSide, width)
    end
    Pull.drawArc()
end

-- Check whether mobID falls within the configured pull arc.
-- Mac: FigureMobAngle (mac:14511-14520)
-- The .mac reads Spawn[mob].HeadingTo[CampY,CampX], but MQ's HeadingTo ignores its
-- argument and measures from the player, so it only matches the camp while the
-- puller stands there. Measure from the camp itself.
function Arc.figureMobAngle(mobID)
    local sp = mq.TLO.Spawn('id ' .. mobID)
    if not sp() then return false end
    local dir = Pull.headingTo(_state.movement.campY, _state.movement.campX, sp.Y() or 0, sp.X() or 0)
    local lSide, rSide = _state.pull.lSide, _state.pull.rSide
    -- lSide >= rSide means the arc wraps through 0/360.
    if lSide >= rSide then
        if dir < lSide and dir > rSide then return false end
    else
        if dir < lSide or dir > rSide then return false end
    end
    return true
end

-- Draw the pull and camp radii on the MQ2Map map. Mirrors Sub PaintMap
-- (mac:8917), run once while the puller stands in camp (mac:8494, MapSet).
-- MQ2Map anchors CampRadius/PullRadius at the player's position when they are
-- set, so this only paints from inside the camp radius. CastRadius follows the
-- player and shows the pull range. /makecamphere clears mapSet to repaint.
function Arc.paintMap()
    local s = _state
    if s.pull.mapSet then return end
    if s.movement.campX == 0 and s.movement.campY == 0 then return end
    if not mq.TLO.Plugin('MQ2Map').IsLoaded() then return end
    local d = dist2D(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, s.movement.campY, s.movement.campX)
    if d > (s.movement.campRadius or 0) then return end
    mq.cmdf('/squelch /mapfilter CastRadius %d', s.pull.range or 0)
    mq.cmdf('/squelch /mapfilter SpellRadius %d', s.pull.maxRadius or 0)
    mq.cmdf('/squelch /mapfilter PullRadius %d', s.pull.maxRadius or 0)
    mq.cmdf('/squelch /mapfilter CampRadius %d', s.movement.campRadius or 0)
    Pull.drawArc()  -- the arc's edges, around the (new) camp
    s.pull.mapSet = true
end

return Arc
