-- ui/settings.lua — Config tab: Settings, Conditions, AFK Tools sub-tabs.

local mq = require('mq')
local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local intInput = Helpers.intInput

local AFK_MODE_LABELS   = { 'Off', 'Stranger + GM', 'Stranger only', 'GM only' }
local AFK_ACTION_LABELS = { 'Hold until GM leaves', 'End macro', 'Unload MQ2', 'Quit EQ' }

local Settings = {}
local _state

function Settings.drawControls()
    local s = _state

    local campSet = s.movement.campX ~= 0 or s.movement.campY ~= 0
    if not campSet then ImGui.BeginDisabled() end
    checkbox('Return to Camp', s.movement.returnToCamp, function(v)
        s.movement.returnToCamp = v
    end)
    if not campSet then ImGui.EndDisabled() end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Camp Radius', s.movement.campRadius,  1, 1000, 'General', 'CampRadius', function(v) s.movement.campRadius = v end)
    intInput('Med Start %', s.heal.medStart,        1,  100, 'General', 'MedStart',   function(v) s.heal.medStart       = v end)
    intInput('Med Stop %',  s.heal.medStop,         1,  100, 'General', 'MedStop',    function(v) s.heal.medStop        = v end)
end

function Settings.drawConditions()
    local s = _state

    checkbox('Conditions On', s.cond.on, function(v)
        s.cond.on = v
        Config.set('KConditions', 'ConOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    -- Conditions are stored as an indexed array under the 'Cond' key.
    local condArr = Config.get('KConditions', 'Cond', nil) or {}

    if ImGui.BeginTable('##condtbl', 3, 0) then
        ImGui.TableSetupColumn('Expression', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Label',      ImGuiTableColumnFlags.WidthFixed,   68)
        ImGui.TableSetupColumn('',           ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, (s.cond.size or 5) do
            local current = s.cond.expressions[i] or ''
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0)
            ImGui.PushItemWidth(-1)
            local newVal, changed = ImGui.InputText('##cond' .. i, current, 0)
            ImGui.PopItemWidth()
            if changed and newVal ~= current then
                s.cond.expressions[i] = newVal ~= '' and newVal or nil
                condArr[i] = newVal ~= '' and newVal or 'null'
                Config.set('KConditions', 'Cond', condArr)
                Config.save()
            end
            ImGui.TableSetColumnIndex(1)
            -- Match the INI/pickle key the expression is stored under (Cond1,
            -- Cond10, Cond100 — unpadded, per config.lua's `ra` reader).
            ImGui.Text(string.format('Cond%d', i))
            ImGui.TableSetColumnIndex(2)
            if ImGui.Button('[-]##condrem' .. i) then
                s.cond.expressions[i] = nil
                if i == s.cond.size and s.cond.size > 1 then
                    condArr[s.cond.size] = nil
                    s.cond.size = s.cond.size - 1
                    Config.set('KConditions', 'CondSize', tostring(s.cond.size))
                else
                    condArr[i] = 'null'
                end
                Config.set('KConditions', 'Cond', condArr)
                Config.save()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        s.cond.size = (s.cond.size or 5) + 1
        condArr[s.cond.size] = 'null'
        Config.set('KConditions', 'Cond', condArr)
        Config.set('KConditions', 'CondSize', tostring(s.cond.size))
        Config.save()
    end
end

function Settings.drawAfkTools()
    local s = _state

    ImGui.PushItemWidth(200)
    local newMode, modeChanged = ImGui.Combo('Mode##afkmode', s.afk.on + 1, AFK_MODE_LABELS)
    if modeChanged then
        s.afk.on = newMode - 1
        Config.set('AFKTools', 'AFKToolsOn', tostring(s.afk.on))
        Config.save()
        if (s.afk.on == 1 or s.afk.on == 2) and mq.TLO.Plugin('MQ2Posse').IsLoaded() then
            mq.cmdf('/posse radius %d', s.afk.pcRadius)
        end
    end
    ImGui.PopItemWidth()

    -- GM Action: only when mode includes GM detection
    if s.afk.on == 1 or s.afk.on == 3 then
        ImGui.Spacing()
        ImGui.PushItemWidth(200)
        local newAction, actionChanged = ImGui.Combo('GM Action##afkgmaction', math.max(1, s.afk.gmAction), AFK_ACTION_LABELS)
        if actionChanged then
            s.afk.gmAction = newAction
            Config.set('AFKTools', 'AFKGMAction', tostring(newAction))
            Config.save()
        end
        ImGui.PopItemWidth()
    end

    -- PC Radius: only when mode includes stranger detection
    if s.afk.on == 1 or s.afk.on == 2 then
        ImGui.Spacing()
        local newRadius = ImGui.InputInt('PC Radius##afkpcradius', s.afk.pcRadius)
        if newRadius ~= s.afk.pcRadius then
            newRadius = math.max(1, math.min(5000, newRadius))
            s.afk.pcRadius = newRadius
            Config.set('AFKTools', 'AFKPCRadius', tostring(newRadius))
            Config.save()
            if mq.TLO.Plugin('MQ2Posse').IsLoaded() then
                mq.cmdf('/posse radius %d', newRadius)
            end
        end
    end
end

function Settings.init(state)
    _state = state
end

return Settings
