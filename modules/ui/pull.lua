-- ui/pull.lua — Pull tab.

local mq = require('mq')
local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local intInput = Helpers.intInput
local Pull     = require('modules.pull')

local PullUI = {}
local _state
local _levelBuf  -- Pull Level text being edited
local _pauseBuf  -- Pull Pause text being edited

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
    if s.pull.chainPull ~= 0 then
        intInput('Chain Pull HP %', s.pull.chainPullHP, 1, 100, 'Pull', 'ChainPullHP',
            function(v) s.pull.chainPullHP = v end)
    end
    -- PullLevel: 'min|max', 'min|max|linked', 'auto' or '0|0'. Applied when
    -- the field loses focus so partial text isn't parsed while typing.
    _levelBuf = _levelBuf or s.pull.levelSetting
    local lvlText = ImGui.InputText('Pull Level', _levelBuf, 0)
    _levelBuf = lvlText
    if ImGui.IsItemDeactivatedAfterEdit() and lvlText ~= s.pull.levelSetting then
        Pull.setPullLevel(lvlText)
        _levelBuf = s.pull.levelSetting
        Config.set('Pull', 'PullLevel', s.pull.levelSetting)
        Config.save()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("min|max, min|max|linked (moves up as you level), auto (your level -5 to +2), 0|0 = any")
    end
    _pauseBuf = _pauseBuf or s.pull.pauseSetting
    local pauseText = ImGui.InputText('Pull Pause', _pauseBuf, 0)
    _pauseBuf = pauseText
    if ImGui.IsItemDeactivatedAfterEdit() and pauseText ~= s.pull.pauseSetting then
        Pull.setPullPause(pauseText)
        Config.set('Pull', 'PullPause', s.pull.pauseSetting)
        Config.save()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("X|Y: pull X minutes, then rest Y minutes. X|Y|condN: also hold pulls while condition N is true. 0 = off")
    end
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
    if s.pull.pauseHold then
        local left = math.floor(math.max(0, (s.timers.pullPause1 or 0) - os.clock()))
        ImGui.TextColored(1, 0.8, 0.2, 1, string.format('Pull Pause: resting, %d:%02d left',
            math.floor(left / 60), left % 60))
    end
    if s.pull.levelMode ~= 'off' then
        ImGui.Text(string.format('Pull Levels: %d to %d (%s)', s.pull.min, s.pull.max, s.pull.levelMode))
    end
    if s.pull.pullArcWidth > 0 then
        ImGui.Text(string.format('Pull Arc: %.0f° to %.0f° (facing %.0f°)',
            s.pull.lSide, s.pull.rSide, s.pull.heading))
    end
end

function PullUI.init(state)
    _state = state
end

return PullUI
