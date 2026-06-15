-- Macro Condition Builder - adapted from aquietone/condition-builder (MIT)
-- Original: https://github.com/aquietone/condition-builder
-- Simplified for KissAssist: operator buttons, examples, live output preview.
-- Exposes CondBuilder.open(slot, text, onAccept) and CondBuilder.draw().

local mq    = require('mq')
local ImGui = require('ImGui')

local CondBuilder = {}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local _isOpen     = false
local _slot       = nil
local _onAccept   = nil
local _expression = ''

-- ---------------------------------------------------------------------------
-- Operator buttons and example expressions
-- ---------------------------------------------------------------------------

local buttons = {
    '${', '}', '[', ']', '(', ')', '.', '!', '&&', '||', '==', '!=', 'Equal', 'NotEqual', 'NULL'
}

local examples = {
    '${Target.Named}',
    '${Me.PctHPs} > 70 && ${Me.PctMana} < 60',
    '${SpawnCount[pc radius 60]} > 3',
    '${Target.CleanName.Equal[Fippy Darkpaw]}',
    '${Select[${Target.Class.ShortName},CLR,DRU,SHM]}',
    '(${Me.XTarget} > 2 || ${Target.Named}) && ${BurnAllNamed}',
    '!${Me.Buff[Illusion Benefit Greater Jann].ID}',
    '${SpawnCount[${Me.Name}`s pet]} > 0',
    '${Me.XTarget} > 0',
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function CondBuilder.open(slot, currentText, onAccept)
    _slot       = slot
    _expression = currentText or ''
    _onAccept   = onAccept
    _isOpen     = true
end

function CondBuilder.draw()
    if not _isOpen then return end

    local title = _slot and string.format('Condition Builder \xe2\x80\x93 Cond %03d', _slot) or 'Condition Builder'
    local open, isDraw = ImGui.Begin(title, _isOpen)
    _isOpen = open

    if isDraw then
        -- Reference link
        if ImGui.Button('\xee\x89\x90 TLO Reference') then
            os.execute('start https://www.redguides.com/docs/projects/macroquest/reference/top-level-objects/')
        end

        -- Expression input
        ImGui.SetNextItemWidth(-1)
        local newVal, changed = ImGui.InputText('##cbexpr', _expression, 0)
        if changed then _expression = newVal end

        -- Operator buttons
        ImGui.Separator()
        for i, button in ipairs(buttons) do
            if ImGui.Button(button) then
                _expression = _expression .. button
            end
            if i % 9 ~= 0 then ImGui.SameLine() end
        end

        -- Examples picker
        ImGui.Separator()
        if ImGui.BeginCombo('Examples', '') then
            for _, example in ipairs(examples) do
                if ImGui.Selectable(example) then
                    _expression = example
                end
            end
            ImGui.EndCombo()
        end

        -- Live output preview
        ImGui.Separator()
        ImGui.Text('Output')
        if ImGui.BeginChild('##cbout', -1, ImGui.GetTextLineHeightWithSpacing() * 3, ImGuiChildFlags.Borders, 0) then
            ImGui.TextWrapped(mq.parse(_expression))
        end
        ImGui.EndChild()

        -- Apply / Cancel
        ImGui.Separator()
        if ImGui.Button('Apply') then
            if _onAccept then _onAccept(_slot, _expression) end
            _isOpen = false
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel') then
            _isOpen = false
        end
    end

    ImGui.End()
end

return CondBuilder
