-- ui/spells.lua — Spells tab: Spell Slots, Buffs, GoM sub-tabs.

local mq = require('mq')
local Helpers  = require('modules.ui.helpers')
local Control  = require('modules.control')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local set      = Helpers.set
local setText  = Helpers.setText
local intInput = Helpers.intInput

local SpellsUI = {}
local _state

-- ---------------------------------------------------------------------------
-- Spell Slots panel
-- ---------------------------------------------------------------------------

local LSS_LABELS = { 'Off', 'Named Set', 'From INI' }

function SpellsUI.drawSpellSlots()
    checkbox('Check Stuck Gem', _state.cast.checkStuckGem, function(v) set('Spells', 'CheckStuckGem', v) end)
    checkbox('Casting Interrupt', (_state.cast.castingInterruptOn or 0) ~= 0, function(v)
        set('Spells', 'CastingInterruptOn', v)  -- on = 62, the mac's "all" bitmask
    end)

    ImGui.Spacing()

    -- Load Spell Set mode combo
    local lssMode = _state.cast.loadSpellSet or 0
    ImGui.PushItemWidth(120)
    local newModeIdx, modeChanged = ImGui.Combo('Load Spell Set##lss', lssMode + 1, LSS_LABELS)
    ImGui.PopItemWidth()
    if modeChanged then
        lssMode = newModeIdx - 1
        set('Spells', 'LoadSpellSet', lssMode)
    end

    -- SpellSetName input (only visible in mode 1)
    if lssMode == 1 then
        local setName = _state.cast.spellSetName or ''
        ImGui.PushItemWidth(180)
        local newName, nameChanged = ImGui.InputText('Set Name##lssname', setName, 0)
        ImGui.PopItemWidth()
        if nameChanged and newName ~= setName then setText('Spells', 'SpellSetName', newName) end
    end

    ImGui.Spacing()
    local gemSlots = _state.cast.gemSlots or 8
    local gems = Config.get('Spells', 'Gems', {})
    ImGui.PushItemWidth(300)
    for i = 1, gemSlots do
        local current = gems[i] or ''
        local newVal, changed = ImGui.InputText('Gem ' .. i .. '##gem' .. i, current, 0)
        if changed and newVal ~= current then
            gems[i] = newVal
            Control.setEntries('gems', gems)
        end
    end
    ImGui.PopItemWidth()

    ImGui.Spacing()
    if ImGui.Button('Write Current Gems') then
        Config.writeSpells(_state)
    end
    ImGui.SameLine()
    if lssMode == 0 then ImGui.BeginDisabled() end
    if ImGui.Button('Mem Spells') then
        _state.cast.pendingLoadSpellSet = true
    end
    if lssMode == 0 then ImGui.EndDisabled() end
end

-- ---------------------------------------------------------------------------
-- Buffs panel
-- ---------------------------------------------------------------------------

local function splitBuff(raw)
    -- SpellName[|TargetTag][|condNNN]  →  spell, tag, cond
    local spell, tag, cond = raw, '', ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond  = raw:sub(condPos + 1)
        spell = raw:sub(1, condPos - 1)
    end
    local pipePos = spell:find('|')
    if pipePos then
        tag   = spell:sub(pipePos + 1)
        spell = spell:sub(1, pipePos - 1)
    end
    return spell, tag, cond
end

local function joinBuff(spell, tag, cond)
    local result = spell
    if tag  ~= '' then result = result .. '|' .. tag  end
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

function SpellsUI.drawBuffs()
    local s = _state

    checkbox('Buffs On', s.buffs.buffsOn, function(v)
        set('Buffs', 'BuffsOn', v and (s.buffs.buffGroupPets and 2 or 1) or 0)
    end)
    if s.buffs.buffsOn then
        -- BuffsOn=2: also buff group members' pets (mac:4579), checked with the
        -- owner over actors (Lua characters) or DanNet (.mac characters).
        checkbox('Buff Group Pets', s.buffs.buffGroupPets, function(v)
            set('Buffs', 'BuffsOn', v and 2 or 1)  -- Control sets buffGroupPets from BuffsOn 2
        end)
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Also cast your group buffs on group members\' pets (BuffsOn=2).\nOwners running KissAssist Lua are asked directly; .mac owners need\nDanNetOn and MQ2DanNet. Not for cleric, paladin, wizard, bard and\npure melee owners.')
        end
    end
    checkbox('Rebuff On', s.buffs.rebuffOn, function(v) set('Buffs', 'RebuffOn', v) end)
    checkbox('Mount On', s.misc.mountOn, function(v) set('General', 'MountOn', v) end)

    ImGui.Spacing()
    intInput('Check Timer', s.buffs.checkBuffsTimer, 1, 3600, 'Buffs', 'CheckBuffsTimer')

    -- Misc Gem Re-Mem (mac:4701-4705)
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text('Misc Gem Re-Mem')
    ImGui.Spacing()
    local REMEM_LABELS = { 'Off', 'Both', 'Short only', 'LW only' }
    ImGui.PushItemWidth(130)
    -- ImGui.Combo is 1-based; MiscGemRemem is 0-3 (0=off 1=both 2=short 3=LW)
    local newRemem, rrc = ImGui.Combo('Re-Mem Mode##miscremem', (_state.cast.miscGemRemem or 0) + 1, REMEM_LABELS)
    ImGui.PopItemWidth()
    if rrc then set('Spells', 'MiscGemRemem', newRemem - 1) end
    if (_state.cast.miscGemRemem or 0) ~= 0 then
        local maxGem = _state.cast.gemSlots or 8
        intInput('Misc Gem##miscgem', _state.cast.miscGem, 0, maxGem, 'Spells', 'MiscGem',
            function(v)
                _state.cast.reMemMiscSpell = v > 0 and (mq.TLO.Me.Gem(v).Name() or '') or ''
            end)
        intInput('Misc Gem LW##miscgemlw', _state.cast.miscGemLW, 0, maxGem, 'Spells', 'MiscGemLW',
            function(v)
                _state.cast.reMemMiscSpellLW = v > 0 and (mq.TLO.Me.Gem(v).Name() or '') or ''
            end)
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local buffsRaw  = Config.get('Buffs', 'Buffs',     nil) or {}
    local buffsSize = tonumber(Config.get('Buffs', 'BuffsSize', '20')) or 20

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('buffs_tbl', 4, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 2)
        ImGui.TableSetupColumn('Tag',   ImGuiTableColumnFlags.WidthStretch,   1)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, buffsSize do
            local raw     = buffsRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, tag, cond = splitBuff(isEmpty and '' or raw)
            local sc, tc, cc, newSpell, newTag, newCond

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##bspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newTag, tc = ImGui.InputText('##btag' .. i, tag, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##buffrem' .. i) then
                if i == buffsSize and buffsSize > 1 then
                    buffsRaw[i] = nil
                    buffsSize   = buffsSize - 1
                else
                    buffsRaw[i] = 'null'
                end
                Control.setEntries('buffs', buffsRaw, buffsSize)
            end

            if sc or tc or cc then
                local spellVal = sc and newSpell or spell
                buffsRaw[i] = spellVal ~= '' and joinBuff(
                    spellVal,
                    tc and newTag  or tag,
                    cc and newCond or cond
                ) or 'null'
                Control.setEntries('buffs', buffsRaw, buffsSize)
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        buffsSize = buffsSize + 1
        buffsRaw[buffsSize] = 'null'
        Control.setEntries('buffs', buffsRaw, buffsSize)
    end
end

-- ---------------------------------------------------------------------------
-- GoM (Gift of Mana) spell list panel
-- ---------------------------------------------------------------------------

local GOM_TARGETS = { 'MA', 'Me', 'Mob' }

local function splitGom(raw)
    -- "SpellName|Target" → spell, target
    if not raw or raw == 'null' or raw == '' then return '', 'MA' end
    local spell, tgt = raw:match('^([^|]+)|(.+)$')
    if spell then return spell, tgt end
    return raw, 'MA'
end

local function joinGom(spell, tgt)
    return spell .. '|' .. tgt
end

function SpellsUI.drawGoM()
    local gomRaw  = Config.get('GoM', 'GoMSpell', nil) or {}
    local gomSize = tonumber(Config.get('GoM', 'GoMSize', '3')) or 3

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('gom_tbl', 3, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,   70)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, gomSize do
            local raw          = gomRaw[i] or 'null'
            local spell, tgt   = splitGom(raw)
            local sc, tc, newSpell, newTgt

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##gomspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local tgtIdx = 1  -- ImGui.Combo is 1-based
            for j, v in ipairs(GOM_TARGETS) do
                if v:upper() == tgt:upper() then tgtIdx = j break end
            end
            local newTgtIdx
            newTgtIdx, tc = ImGui.Combo('##gomtgt' .. i, tgtIdx, GOM_TARGETS)
            newTgt = GOM_TARGETS[newTgtIdx] or 'MA'
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##gomrem' .. i) then
                if i == gomSize and gomSize > 1 then
                    gomRaw[i] = nil
                    gomSize   = gomSize - 1
                else
                    gomRaw[i] = 'null'
                end
                Control.setEntries('gom', gomRaw, gomSize)
            end

            if sc or tc then
                local s = sc and newSpell or spell
                local t = tc and newTgt   or tgt
                gomRaw[i] = s ~= '' and joinGom(s, t) or 'null'
                Control.setEntries('gom', gomRaw, gomSize)
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        gomSize = gomSize + 1
        gomRaw[gomSize] = 'null'
        Control.setEntries('gom', gomRaw, gomSize)
    end
end

function SpellsUI.init(state)
    _state = state
end

return SpellsUI
