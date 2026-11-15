-- ui/pull.lua — Pull tab.

local mq = require('mq')
local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local intInput = Helpers.intInput
local Pull     = require('modules.pull')

local PullUI = {}
local _state

function PullUI.drawPull()
    local s = _state

    -- Toggles
    checkbox('Pull', not s.pull.hold, function(v)
        s.pull.hold = not v
    end)
    ImGui.SameLine(160)
    checkbox('Chain Pull', s.pull.chainPull ~= 0, function(v)
        s.pull.chainPull = v and 1 or 0
        Config.set('Pull', 'ChainPull', v and '1' or '0')
        Config.save()
    end)

    checkbox('Pull On Return', s.pull.pullOnReturn, function(v)
        s.pull.pullOnReturn = v
        Config.set('Pull', 'PullOnReturn', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(160)
    checkbox('Waypoint Pull', s.pull.pullLocsOn, function(v)
        s.pull.pullLocsOn = v
        Config.set('PullAdvanced', 'PullLocsOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Melee Pull Stick', s.pull.meleeStick, function(v)
        s.pull.meleeStick = v
        Config.set('Pull', 'PullMeleeStick', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(160)
    -- Per session, not saved (mac Bind_SetPullRanking).
    checkbox('Pull Ranking', s.pull.ranking, function(v) Pull.setRanking(v) end)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("Pull the MobsToPull entries marked with ':' first")
    end
    if s.session.iAmABard then
        checkbox('Twist On Pull', s.bard.pullTwistOn, function(v)
            s.bard.pullTwistOn = v
            Config.set('Pull', 'PullTwistOn', v and '1' or '0')
            Config.save()
        end)
    end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Max Radius',  s.pull.maxRadius,    1, 2000, 'Pull', 'MaxRadius',    function(v) s.pull.maxRadius    = v end)
    intInput('Max Z Range', s.pull.maxZRange,    1, 2000, 'Pull', 'MaxZRange',    function(v) s.pull.maxZRange    = v end)
    -- Pull range comes from PullWith (Pull.rangeSet); this scales it.
    intInput('Pull Range %', s.pull.radiusToUse,  1,  100, 'Pull', 'PullRadiusToUse', function(v)
        s.pull.radiusToUse = v
        Pull.rangeSet()
    end)
    intInput('Arc Width°',  s.pull.pullArcWidth,  0,  359, 'Pull', 'PullArcWidth', function(v)
        -- Keep the current aim if an arc is already set, else aim where we face.
        local aimed  = s.pull.lSide ~= s.pull.rSide
        local facing = aimed and s.pull.heading or (mq.TLO.Me.Heading.Degrees() or 0)
        s.pull.pullArcWidth = v
        Pull.setPullAngles(facing, v, true)
    end)
    if s.pull.pullArcWidth > 0 then
        ImGui.SameLine()
        if ImGui.SmallButton('Aim Here') then
            Pull.setPullAngles(mq.TLO.Me.Heading.Degrees() or 0, s.pull.pullArcWidth)
        end
    end

    -- Read-only status
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text(string.format('Pull With: %s (range %d)', s.pull.withAlt or 'Melee', s.pull.range or 0))
    if s.pull.pullArcWidth > 0 then
        ImGui.Text(string.format('Pull Arc: %.0f° to %.0f° (facing %.0f°)',
            s.pull.lSide, s.pull.rSide, s.pull.heading))
    end
end

function PullUI.init(state)
    _state = state
end

return PullUI
