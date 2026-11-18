-- ui/pull.lua — Pull tab.

local mq = require('mq')
local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local intInput = Helpers.intInput
local Pull     = require('modules.pull')
local GroupWatch = require('modules.groupwatch')

local GW_MODE_LABELS = { 'Off', 'Whole group', 'Healers only' }

local PullUI = {}
local _state
local _levelBuf  -- Pull Level text being edited
local _pauseBuf  -- Pull Pause text being edited

-- Split a zone list ('a,b|c') into trimmed entries; '' / 'null' -> {}.
local function splitList(raw)
    local out = {}
    if not raw or raw == '' or raw:lower() == 'null' then return out end
    for entry in raw:gmatch('[^,|]+') do
        entry = entry:match('^%s*(.-)%s*$')
        if entry ~= '' then out[#out + 1] = entry end
    end
    return out
end

-- Read-only view of this zone's MobsToPull / MobsToIgnore from
-- KissAssist_Info.ini. Edit with /addpull and /addignore.
local function drawWatchLists(s)
    if not ImGui.CollapsingHeader('Watch Lists') then return end
    local zone = s.session.zoneName or ''
    ImGui.TextDisabled(string.format('Zone: %s  (edit with /addpull, /addignore)', zone ~= '' and zone or '?'))

    local raw = s.pull.mobsToPullRaw or 'all'
    local pulls = raw:lower() == 'all' and {} or splitList(raw)
    ImGui.Text(string.format('Pull list (%d)', #pulls))
    if #pulls == 0 then
        ImGui.TextDisabled('  all mobs')
    end
    for _, e in ipairs(pulls) do
        -- ':' marks a "pull first" entry (used when Pull Ranking is on).
        local first = e:find(':', 1, true) ~= nil
        local name  = e:gsub(':', '')
        ImGui.BulletText(first and (name .. '  (pull first)') or name)
    end

    local ignores = splitList(s.pull.mobsToIgnore)
    ImGui.Text(string.format('Ignore list (%d)', #ignores))
    if #ignores == 0 then
        ImGui.TextDisabled('  none')
    end
    for _, e in ipairs(ignores) do ImGui.BulletText(e) end
end

-- Group Watch: hold pulls while group members med (GroupWatchOn "1|20",
-- GroupWatchCheck "condN"); saved together by GroupWatch.save().
local function drawGroupWatch(s)
    local h = s.heal
    ImGui.PushItemWidth(200)
    local mode, modeChanged = ImGui.Combo('Group Watch##gwmode', (h.groupWatchOn or 0) + 1, GW_MODE_LABELS)
    if modeChanged then
        h.groupWatchOn = mode - 1
        GroupWatch.save()
    end
    ImGui.PopItemWidth()
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Hold pulls while a group member is low on mana or endurance,\nuntil they med back to 90 percent.')
    end
    if (h.groupWatchOn or 0) > 0 then
        local pct = ImGui.InputInt('Group Watch %##gwpct', h.groupWatchPct or 20)
        if pct ~= (h.groupWatchPct or 20) then
            h.groupWatchPct = math.max(1, math.min(100, pct))
            GroupWatch.save()
        end
        local cond = ImGui.InputInt('Group Watch Cond##gwcond', h.groupWatchCond or 0)
        if cond ~= (h.groupWatchCond or 0) then
            h.groupWatchCond = math.max(0, math.min(s.cond.size or 5, cond))
            GroupWatch.save()
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Also hold pulls while this condition (CondN) is true. 0 = off.')
        end
    end
end

-- One line saying whether pulls can go ahead, and if not, why.
local function drawHoldStatus()
    local reasons = Pull.holdReasons()
    if #reasons == 0 then
        ImGui.TextColored(0.3, 0.9, 0.4, 1, 'Pulling: nothing is holding pulls')
    else
        ImGui.TextColored(1, 0.8, 0.2, 1, 'Pulls held:')
        for _, r in ipairs(reasons) do ImGui.BulletText(r) end
    end
end

local _locBuf  = {}  -- PullLocs text being edited, per slot
local _locZone       -- zone the buffers belong to

-- Editor for this zone's no-pull areas (PullLocs1-5, 'Y,X|Range'), saved to
-- KissAssist_Info.ini. Used while the No-Pull Areas toggle is on.
local function drawNoPullAreas(s)
    if not ImGui.CollapsingHeader('No-Pull Areas') then return end
    local zone = s.session.zoneName or ''
    if zone ~= _locZone then _locBuf, _locZone = {}, zone end
    ImGui.TextDisabled(string.format('Zone: %s  (Y,X|Range: mobs within Range of Y,X are not pulled)',
        zone ~= '' and zone or '?'))
    if not s.pull.pullLocsOn then
        ImGui.TextColored(1, 0.8, 0.2, 1, 'No-Pull Areas is off, so these are not used.')
    end

    local raws = s.pull.pullLocsRaw or {}
    for i = 1, 5 do
        local raw = raws[i] or ''
        ImGui.PushID(i)
        _locBuf[i] = _locBuf[i] or raw
        ImGui.SetNextItemWidth(180)
        local text = ImGui.InputText(string.format('%d', i), _locBuf[i], 0)
        _locBuf[i] = text
        if ImGui.IsItemDeactivatedAfterEdit() and text ~= raw then
            if not Pull.setPullLoc(i, text) then
                printf('\ayNo-pull area %d: "%s" is not Y,X|Range, e.g. 120,-450|60', i, text)
            end
            _locBuf[i] = s.pull.pullLocsRaw[i] or ''
        end
        ImGui.SameLine()
        if ImGui.SmallButton('My Loc') then
            local cur   = Pull.parsePullLoc(raw)
            local range = cur and cur.range or 50
            Pull.setPullLoc(i, string.format('%d,%d|%d', math.floor(mq.TLO.Me.Y() or 0),
                math.floor(mq.TLO.Me.X() or 0), math.floor(range)))
            _locBuf[i] = s.pull.pullLocsRaw[i]
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Centre this area on where you stand (keeps the range, else 50)')
        end
        ImGui.SameLine()
        if ImGui.SmallButton('Clear') then
            Pull.setPullLoc(i, '')
            _locBuf[i] = ''
        end
        ImGui.PopID()
    end
    if Pull.inPullLocArea(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0) then
        ImGui.TextColored(1, 0.8, 0.2, 1, 'You are standing in a no-pull area.')
    end
end

function PullUI.drawPull()
    local s = _state

    -- Toggles
    checkbox('Pull', not s.pull.hold, function(v)
        s.pull.hold = not v
    end)
    -- Only the puller role chain pulls (mac:8841).
    if s.session.role == 'puller' then
        ImGui.SameLine(160)
        checkbox('Chain Pull', s.pull.chainPull ~= 0, function(v)
            s.pull.chainPull = v and 1 or 0
            Config.set('Pull', 'ChainPull', v and '1' or '0')
            Config.save()
        end)
    end

    checkbox('Pull On Return', s.pull.pullOnReturn, function(v)
        s.pull.pullOnReturn = v
        Config.set('Pull', 'PullOnReturn', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(160)
    checkbox('No-Pull Areas', s.pull.pullLocsOn, function(v)
        s.pull.pullLocsOn = v
        Config.set('PullAdvanced', 'PullLocsOn', v and '1' or '0')
        Config.save()
    end)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("Don't pull mobs inside this zone's no-pull areas (set them below)")
    end

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
    if s.session.role == 'pullerpettank' then
        checkbox('Group Puller Role', s.pull.roleToggle, function(v)
            s.pull.roleToggle = v
            Config.set('Pull', 'PullRoleToggle', v and '1' or '0')
            Config.save()
        end)
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Take the group Puller role while pulling (group leader with a merc only)')
        end
        if s.session.iAmABard then ImGui.SameLine(160) end
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
    intInput('Pull Wait (s)', s.pull.pullWait, 0, 3600, 'Pull', 'PullWait', function(v) s.pull.pullWait = v end)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Seconds to wait for respawns when no mob can be found. 0 = off')
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

    ImGui.Spacing()
    ImGui.Separator()
    drawGroupWatch(s)

    -- Read-only status
    ImGui.Spacing()
    ImGui.Separator()
    drawHoldStatus()
    ImGui.Text(string.format('Pull With: %s (range %d)', s.pull.withAlt or 'Melee', s.pull.range or 0))
    if s.pull.pauseHold then
        local left = math.floor(math.max(0, (s.timers.pullPause1 or 0) - os.clock()))
        ImGui.TextColored(1, 0.8, 0.2, 1, string.format('Pull Pause: resting, %d:%02d left',
            math.floor(left / 60), left % 60))
    end
    if (s.timers.pullDelay or 0) > os.clock() then
        local left = math.ceil(s.timers.pullDelay - os.clock())
        ImGui.TextColored(1, 0.8, 0.2, 1, string.format('Pull Wait: waiting for respawns, %ds left', left))
    end
    if s.pull.levelMode ~= 'off' then
        ImGui.Text(string.format('Pull Levels: %d to %d (%s)', s.pull.min, s.pull.max, s.pull.levelMode))
    end
    if s.pull.pullArcWidth > 0 then
        ImGui.Text(string.format('Pull Arc: %.0f° to %.0f° (facing %.0f°)',
            s.pull.lSide, s.pull.rSide, s.pull.heading))
    end

    ImGui.Spacing()
    drawWatchLists(s)
    drawNoPullAreas(s)
end

function PullUI.init(state)
    _state = state
end

return PullUI
