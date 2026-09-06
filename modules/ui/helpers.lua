-- ui/helpers.lua — shared ImGui widgets and lookup tables used across the
-- ui/* tab modules. Stateless: takes everything it needs as parameters.

local Config = require('modules.config')

local Helpers = {}
Helpers.Config = Config

Helpers.GLT_VALUES  = { '<', '<<', '>' }
Helpers.GLT_LABELS  = { '< gain', '<< sec', '> lose' }
Helpers.ATGT_VALUES = { '', 'me', 'ma', 'pet', 'inc', 'weave', 'mash', 'ambush' }
Helpers.ATGT_LABELS = { 'current', 'me', 'ma', 'pet', 'inc', 'weave', 'mash', 'ambush' }

function Helpers.checkbox(label, value, onChange)
    local W, H = 40, 20
    local cx, cy = ImGui.GetCursorScreenPos()
    local dl = ImGui.GetWindowDrawList()
    ImGui.InvisibleButton('##tog_' .. label, W, H)
    if ImGui.IsItemClicked() then onChange(not value) end
    local col = value
        and ImGui.GetColorU32(0.2, 0.78, 0.35, 1.0)
        or  ImGui.GetColorU32(0.45, 0.45, 0.45, 1.0)
    dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + W, cy + H), col, H * 0.5)
    local knobX = value and (cx + W - H * 0.5) or (cx + H * 0.5)
    dl:AddCircleFilled(ImVec2(knobX, cy + H * 0.5), H * 0.5 - 2, 0xFFFFFFFF)
    ImGui.SameLine()
    ImGui.Text(label)
end

function Helpers.intInput(label, value, min, max, configSection, configKey, stateSet)
    local newVal = ImGui.InputInt(label, value)
    if newVal ~= value then
        newVal = math.max(min, math.min(max, newVal))
        stateSet(newVal)
        Config.set(configSection, configKey, tostring(newVal))
        Config.save()
    end
end

return Helpers
