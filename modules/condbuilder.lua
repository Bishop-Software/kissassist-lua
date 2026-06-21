-- Macro Condition Builder - adapted from aquietone/condition-builder (MIT)
-- Original: https://github.com/aquietone/condition-builder
-- Simplified for KissAssist: operator buttons, live output preview.
-- Exposes CondBuilder.init(cond), CondBuilder.open(slot, text, onAccept) and CondBuilder.draw().

local mq    = require('mq')
local ImGui = require('ImGui')

local CondBuilder = {}
local _cond  -- modules/cond.lua, wired via CondBuilder.init

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local _isOpen     = false
local _slot       = nil
local _onAccept   = nil
local _expression = ''

-- Live-preview gating. The output box (mq.parse) and the result line both
-- re-parse the expression; doing that every frame spams MQ parser errors for
-- half-typed/invalid input. We recompute only once the expression has settled
-- (_lastEditAt debounce) and only when it actually changed (_shownExpr), so a
-- given expression is parsed exactly once. The Refresh button forces a re-eval.
local _lastEditAt = 0
local _shownExpr  = nil
local _outStr     = ''
local _result     = nil

-- ---------------------------------------------------------------------------
-- Operator buttons
-- ---------------------------------------------------------------------------

local buttons = {
    '${', '}', '[', ']', '(', ')', '.', '!', '&&', '||', '==', '!=', 'Equal', 'NotEqual', 'NULL'
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function CondBuilder.init(cond)
    _cond = cond
end

function CondBuilder.open(slot, currentText, onAccept)
    _slot       = slot
    _expression = currentText or ''
    _onAccept   = onAccept
    _isOpen     = true
    _lastEditAt = os.clock()  -- debounce the initial expression too
    _shownExpr  = nil
    _outStr     = ''
    _result     = nil
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
        if changed then
            _expression = newVal
            _lastEditAt = os.clock()  -- debounce: defer eval until typing settles
        end

        -- Operator buttons
        ImGui.Separator()
        for i, button in ipairs(buttons) do
            if ImGui.Button(button) then
                _expression = _expression .. button
                _lastEditAt = os.clock()  -- debounce, same as typing
            end
            if i % 9 ~= 0 then ImGui.SameLine() end
        end

        -- Recompute only once the expression has settled (debounce) and only
        -- when it actually changed (_shownExpr) — so a given expression is parsed
        -- exactly once instead of re-spamming MQ parser errors on a timer. The
        -- Refresh button (below) forces a re-eval to pick up live state changes.
        local now = os.clock()
        if _expression == '' then
            _outStr, _result, _shownExpr = '', nil, ''
        elseif _expression ~= _shownExpr and (now - _lastEditAt) > 0.4 then
            _shownExpr = _expression
            -- ${Cond[N]} is not an MQ TLO, so resolve nested condition refs the
            -- same way Cond.evalStr does before handing the rest to mq.parse —
            -- otherwise they show up as unparsed NULL. (mac: Cond is KA-internal)
            local resolved = _expression
            if _cond then
                resolved = resolved:gsub('%${Cond%[(%d+)%]}', function(n)
                    return _cond.eval(tonumber(n)) and 'TRUE' or 'FALSE'
                end)
            end
            _outStr = mq.parse(resolved) or ''
            _result = _cond and _cond.evalPreview(_expression) or nil
        end

        -- Live output preview
        ImGui.Separator()
        ImGui.Text('Output')
        ImGui.SameLine()
        -- The preview is parsed once and frozen (re-parsing an invalid expression
        -- re-spams MQ parser errors). Refresh forces a re-eval for live state.
        if ImGui.SmallButton('Refresh##cbrefresh') then
            if _cond then _cond.clearPreviewCache() end
            _shownExpr = nil
        end
        if ImGui.BeginChild('##cbout', -1, ImGui.GetTextLineHeightWithSpacing() * 3, ImGuiChildFlags.Borders, 0) then
            ImGui.TextWrapped(_outStr or '')
        end
        ImGui.EndChild()

        -- Authoritative result — same evaluator the runtime/Now column uses.
        if _result ~= nil then
            ImGui.Text('Result')
            ImGui.SameLine()
            if _result then
                ImGui.TextColored(0, 1, 0, 1, 'TRUE')
            else
                ImGui.TextColored(1, 0, 0, 1, 'FALSE')
            end
        end

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
