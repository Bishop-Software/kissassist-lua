-- ui/combat.lua — Combat tab: Melee, DPS, Debuff, Burn, Aggro, AE sub-tabs.

local mq = require('mq')
local Helpers    = require('modules.ui.helpers')
local CombatSettings = require('modules.combat.settings')
local Movement   = require('modules.movement')
local Roles      = require('modules.roles')
local Config     = Helpers.Config
local checkbox   = Helpers.checkbox
local set      = Helpers.set
local intInput   = Helpers.intInput
local GLT_VALUES  = Helpers.GLT_VALUES
local GLT_LABELS  = Helpers.GLT_LABELS
local ATGT_VALUES = Helpers.ATGT_VALUES
local ATGT_LABELS = Helpers.ATGT_LABELS

local DPS_MODE_LABELS = { 'Off', 'On (each entry from its HP%)', 'On, any HP (wait for spell cooldown)' }

local CombatUI = {}
local _state

-- Switch MA picks (Melee panel). Index into Roles.MA_ROLE_CHOICES; 1 = tank.
local _maPick, _maRolePick, _maBroadcast = nil, 1, true

-- Main Assist: show the current MA and switch it through /kactl ma (#346, #363).
local function drawSwitchMA(s)
    ImGui.Separator()
    ImGui.Text('Main Assist:')
    ImGui.SameLine()
    ImGui.TextColored(0.4, 0.9, 1.0, 1.0, s.session.mainAssist ~= '' and s.session.mainAssist or '(none)')
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('(my role: %s)', s.session.role or '?'))

    local names, curIdx = Roles.maChoices(Roles.maSnapshot())
    if #names == 0 then return end
    if not _maPick or _maPick > #names then _maPick = curIdx end
    ImGui.PushItemWidth(150)
    local pick, pickChanged = ImGui.Combo('##switchmaname', _maPick, names)
    if pickChanged then _maPick = pick end
    ImGui.SameLine()
    local role, roleChanged = ImGui.Combo('##switchmarole', _maRolePick, Roles.MA_ROLE_CHOICES)
    if roleChanged then _maRolePick = role end
    ImGui.PopItemWidth()
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Role for the new main assist (only the new MA takes it;\neveryone else goes back to the role they started with)')
    end
    ImGui.SameLine()
    if ImGui.Button('Switch MA##switchma') then
        mq.cmd(Roles.switchMACommand(names[_maPick], Roles.MA_ROLE_CHOICES[_maRolePick], _maBroadcast))
        _maPick = nil  -- re-read the current MA next frame
    end
    ImGui.SameLine()
    _maBroadcast = ImGui.Checkbox('Broadcast##switchmabc', _maBroadcast)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Tell the other KissAssist characters in the group to switch too (/kactl ma ... group)')
    end
end

-- ---------------------------------------------------------------------------
-- Melee panel
-- ---------------------------------------------------------------------------

function CombatUI.drawMelee()
    local s = _state

    -- Toggles
    checkbox('Melee', s.combat.meleeOn, function(v) set('Melee', 'MeleeOn', v) end)

    checkbox('Auto-Acquire Targets', s.combat.targetSwitchingOn, function(v) set('Melee', 'TargetSwitchingOn', v) end)

    checkbox('Manual Target Swapping', s.combat.manualTargetMode, function(v)
        set('Melee', 'ManualTargetMode', v)
    end)

    checkbox('Use MQ2Melee', s.combat.useMQ2Melee, function(v)
        if not CombatSettings.setMQ2Melee(s, v) then
            printf('\ayMQ2Melee plugin is not loaded. Load it with /plugin mq2melee first.')
            return
        end
        Config.set('Melee', 'UseMQ2Melee', v and tostring(s.combat.mq2MeleeMode or 1) or '0')
        Config.save()
        Movement.resolveStickHow()  -- MQ2Melee does its own sticking
    end)
    if s.combat.useMQ2Melee then
        -- UseMQ2Melee 1 / 2: MQ2Melee's stickmode 0 (automatic) / 1 (its INI stickcmd)
        ImGui.PushItemWidth(170)
        local mode, changed = ImGui.Combo('MQ2Melee Stick##mq2meleemode', s.combat.mq2MeleeMode or 1,
            { 'Automatic', 'MQ2Melee INI stickcmd' })
        ImGui.PopItemWidth()
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('How MQ2Melee sticks to the target: on its own, or with the stickcmd\nfrom your MQ2Melee INI (UseMQ2Melee=2)')
        end
        if changed and mode ~= s.combat.mq2MeleeMode then
            s.combat.mq2MeleeMode = mode
            mq.cmdf('/squelch /melee stickmode=%d', mode == 2 and 1 or 0)
            Config.set('Melee', 'UseMQ2Melee', tostring(mode))
            Config.save()
        end
    end

    checkbox('AutoFire', (s.combat.autoFireOn or 0) ~= 0, function(v) set('Melee', 'AutoFireOn', v) end)

    checkbox('LOS Check', s.combat.losBeforeCombat, function(v) set('General', 'LOSBeforeCombat', v) end)

    if s.session.iAmARogue then
        checkbox('Auto Hide', s.misc.autoHide, function(v)
            Config.set('General', 'AutoHide', nil)  -- drop the old misplaced key
            set('Melee', 'AutoHide', v)
        end)
    end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Assist %',    s.combat.assistAt,      1,  100, 'Melee', 'AssistAt')
    intInput('Melee Dist',  s.combat.meleeDistance,  1,  500, 'Melee', 'MeleeDistance')
    local faceMobLabels = { 'Off', 'Fast (no camera)', 'Smooth (no camera)' }
    local faceMobIdx = (s.movement.faceMobOn or 0) + 1
    ImGui.PushItemWidth(200)
    local newFaceIdx, faceChanged = ImGui.Combo('Face Mob##facemob', faceMobIdx, faceMobLabels)
    if faceChanged then
        local newVal = newFaceIdx - 1
        s.movement.faceMobOn = newVal
        Config.set('Melee', 'FaceMobOn', tostring(newVal))
        Config.save()
    end
    ImGui.PopItemWidth()
    -- Stick style
    ImGui.Spacing()
    -- StickHow as written in the INI; Movement.resolveStickHow turns 'auto' (and
    -- '0', which the mac treats as auto) into the stick for this role.
    local stickValues = { 'auto', 'snaproll', 'behind', 'front', '!front', 'moveback', 'pin', 'I' }
    local stickLabels = {
        'Auto (by role)',
        'Snap roll behind',
        'Behind target',
        'In front of target',
        'Not in front of target',
        'Move back to range',
        'Pin (no rotation)',
        'Disabled (no stick)',
    }
    local stickCurrent = s.movement.dStickHow or 'auto'
    if stickCurrent == '0' or stickCurrent == '' then stickCurrent = 'auto' end
    local stickIdx
    for i, v in ipairs(stickValues) do
        if v:lower() == stickCurrent:lower() then stickIdx = i break end
    end
    if not stickIdx then  -- a value typed into the INI, e.g. 'snaproll front moveback'
        stickValues[#stickValues + 1] = stickCurrent
        stickLabels[#stickLabels + 1] = 'Custom: ' .. stickCurrent
        stickIdx = #stickValues
    end
    ImGui.PushItemWidth(200)
    local newIdx, changed = ImGui.Combo('Stick How##stickhow', stickIdx, stickLabels)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Sticking with: ' .. ((s.movement.stickHow or '0') == '0'
            and 'plain stick' or s.movement.stickHow))
    end
    if changed then
        local newVal = stickValues[newIdx] or 'auto'
        s.movement.dStickHow = newVal
        Config.set('Melee', 'StickHow', newVal)
        Config.save()
        Movement.resolveStickHow()
    end
    ImGui.PopItemWidth()

    drawSwitchMA(s)
end

-- ---------------------------------------------------------------------------
-- DPS entry split/join
-- ---------------------------------------------------------------------------

local function splitDPS(raw)
    -- SpellName[|thresh[|target[|damod]]][|condNNN]  →  spell, thresh, target, damod, cond
    local cond = ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    return parts[1] or '', parts[2] or '0', parts[3] or '', parts[4] or '', cond
end

local function joinDPS(spell, thresh, target, damod, cond)
    local result = spell .. '|' .. thresh
    if target ~= '' or damod ~= '' then result = result .. '|' .. target end
    if damod  ~= ''               then result = result .. '|' .. damod  end
    if cond   ~= ''               then result = result .. '|' .. cond   end
    return result
end

-- ---------------------------------------------------------------------------
-- Aggro panel
-- ---------------------------------------------------------------------------

local function splitAggro(raw)
    -- SpellName[|pct[|glt[|target]]][|condNNN]  →  spell, pct, glt, target, cond
    local cond = ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    return parts[1] or '', parts[2] or '0', parts[3] or '<', parts[4] or '', cond
end

local function joinAggro(spell, pct, glt, target, cond)
    local result = spell .. '|' .. pct .. '|' .. glt
    if target ~= '' then result = result .. '|' .. target end
    if cond   ~= '' then result = result .. '|' .. cond   end
    return result
end

function CombatUI.drawAggro()
    local s = _state

    checkbox('Aggro', s.combat.aggroOn, function(v) set('Aggro', 'AggroOn', v) end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local aggroRaw  = Config.get('Aggro', 'Aggro',     nil) or {}
    local aggroSize = tonumber(Config.get('Aggro', 'AggroSize', '10')) or 10

    local function syncAggroArray()
        s.combat.aggroArray = {}
        for _, slot in ipairs(Config.parseCondArray(aggroRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.combat.aggroArray[#s.combat.aggroArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('aggro_tbl', 6, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Pct',    ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('GtL',    ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, aggroSize do
            local raw     = aggroRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, pct, glt, target, cond = splitAggro(isEmpty and '' or raw)
            local newPct, newGlt, newTarget = pct, glt, target
            local newSpell, newCond, sc, pc, gc, tac, cc

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##aspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local pctNum = tonumber(pct) or 0
            local newPctNum
            newPctNum, pc = ImGui.InputInt('##apct' .. i, pctNum)
            if pc then newPct = tostring(math.max(0, math.min(200, newPctNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local gltIdx = 1
            for k, v in ipairs(GLT_VALUES) do if v == glt then gltIdx = k; break end end
            local newGltIdx
            newGltIdx, gc = ImGui.Combo('##aglt' .. i, gltIdx, GLT_LABELS)
            if gc then newGlt = GLT_VALUES[newGltIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(ATGT_VALUES) do if v == target then targetIdx = k; break end end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##atgt' .. i, targetIdx, ATGT_LABELS)
            if tac then newTarget = ATGT_VALUES[newTargetIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##acond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##agrem' .. i) then
                if i == aggroSize and aggroSize > 1 then
                    aggroRaw[i] = nil
                    aggroSize   = aggroSize - 1
                    Config.set('Aggro', 'AggroSize', tostring(aggroSize))
                else
                    aggroRaw[i] = 'null'
                end
                Config.set('Aggro', 'Aggro', aggroRaw)
                Config.save()
                syncAggroArray()
            end

            if sc or pc or gc or tac or cc then
                local spellVal = sc and newSpell or spell
                aggroRaw[i] = spellVal ~= '' and joinAggro(
                    spellVal,
                    pc  and newPct    or pct,
                    gc  and newGlt    or glt,
                    tac and newTarget or target,
                    cc  and newCond   or cond
                ) or 'null'
                Config.set('Aggro', 'Aggro', aggroRaw)
                Config.save()
                syncAggroArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        aggroSize = aggroSize + 1
        aggroRaw[aggroSize] = 'null'
        Config.set('Aggro', 'AggroSize', tostring(aggroSize))
        Config.set('Aggro', 'Aggro', aggroRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Debuff panel
-- ---------------------------------------------------------------------------

function CombatUI.drawDebuffs()
    local s = _state

    local DEBUFF_ON_LABELS = { 'Off', 'In Combat', 'OOC Also' }
    local debuffOnIdx = (s.debuff.on or 0) + 1
    local newDebuffOnIdx, debuffOnChanged = ImGui.Combo('Debuff##debuffon', debuffOnIdx, DEBUFF_ON_LABELS)
    if debuffOnChanged then
        s.debuff.on = newDebuffOnIdx - 1
        Config.set('Debuff', 'DebuffOn', tostring(s.debuff.on))
        Config.save()
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local debuffRaw  = Config.get('Debuff', 'Debuff',     nil) or {}
    local debuffSize = tonumber(Config.get('Debuff', 'DebuffSize', '0')) or 0

    local function syncDebuffArray()
        s.debuff.slots = {}
        s.debuff.count = 0
        s.debuff.size  = debuffSize
        for i = 1, debuffSize do
            local raw = debuffRaw[i] or 'null'
            if raw ~= 'null' and raw ~= '' then
                local cond    = ''
                local condPos = raw:lower():find('|cond%d')
                if condPos then
                    cond = raw:sub(condPos + 1)
                    raw  = raw:sub(1, condPos - 1)
                end
                local spell  = raw
                local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
                if spell ~= '' then
                    s.debuff.slots[#s.debuff.slots + 1] = { spell = spell, condNo = condNo }
                    s.debuff.count = s.debuff.count + 1
                end
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('debuff_tbl', 3, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,  160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, debuffSize do
            local raw     = debuffRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, cond = '', ''
            if not isEmpty then
                local condPos = raw:lower():find('|cond%d')
                if condPos then
                    cond = raw:sub(condPos + 1)
                    raw  = raw:sub(1, condPos - 1)
                end
                spell = raw
            end
            local newSpell, newCond, sc, cc

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##dbspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##dbcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##dbrem' .. i) then
                if i == debuffSize and debuffSize > 1 then
                    debuffRaw[i] = nil
                    debuffSize   = debuffSize - 1
                    Config.set('Debuff', 'DebuffSize', tostring(debuffSize))
                else
                    debuffRaw[i] = 'null'
                end
                Config.set('Debuff', 'Debuff', debuffRaw)
                Config.save()
                syncDebuffArray()
            end

            if sc or cc then
                local spellVal = sc and newSpell or spell
                local condVal  = cc and newCond  or cond
                debuffRaw[i]   = spellVal ~= '' and (spellVal .. (condVal ~= '' and '|' .. condVal or '')) or 'null'
                Config.set('Debuff', 'Debuff', debuffRaw)
                Config.save()
                syncDebuffArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]##dbadd') then
        debuffSize = debuffSize + 1
        debuffRaw[debuffSize] = 'null'
        Config.set('Debuff', 'DebuffSize', tostring(debuffSize))
        Config.set('Debuff', 'Debuff', debuffRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- DPS rotation panel
-- ---------------------------------------------------------------------------

function CombatUI.drawDPS()
    local s = _state

    -- DPSOn 0/1/2 (mac:1727, 1750); 2 is held in combat.dpsOnOoc
    local dpsMode = s.combat.dpsOn and (s.combat.dpsOnOoc and 2 or 1) or 0
    ImGui.PushItemWidth(260)
    local newMode, modeChanged = ImGui.Combo('DPS##dpson', dpsMode + 1, DPS_MODE_LABELS)
    ImGui.PopItemWidth()
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Off: no DPS rotation.\n'
            .. 'On: each entry starts once the mob is at or below its HP%%; a spell on\n'
            .. '  the global cooldown is skipped for now.\n'
            .. 'On, any HP: entries start at any HP, and the rotation waits out the\n'
            .. '  global spell cooldown so it keeps strict priority order (DPSOn=2).')
    end
    if modeChanged then
        s.combat.dpsOn    = newMode > 1
        s.combat.dpsOnOoc = newMode == 3
        Config.set('DPS', 'DPSOn', tostring(newMode - 1))
        Config.save()
    end

    ImGui.Spacing()
    intInput('DPS Skip %',   s.combat.dpsSkip,     0,  100, 'DPS', 'DPSSkip')
    intInput('DPS Interval', s.combat.dpsInterval, 0, 3600, 'DPS', 'DPSInterval')

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local dpsRaw  = Config.get('DPS', 'DPS',     nil) or {}
    local dpsSize = tonumber(Config.get('DPS', 'DPSSize', '20')) or 20

    -- Rebuild the rotation and the mash/ambush/weave arrays from the edited entries.
    local function syncDpsArray()
        CombatSettings.splitDps(s, dpsRaw)
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('dps_tbl', 6, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('HP%',    ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('DAMod',  ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, dpsSize do
            local raw     = dpsRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, thresh, target, damod, cond = splitDPS(isEmpty and '' or raw)
            local newThresh, newTarget = thresh, target
            local newSpell, newDamod, newCond, sc, tc, tac, dc, cc

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##dspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local threshNum = tonumber(thresh) or 0
            local newThreshNum
            newThreshNum, tc = ImGui.InputInt('##dthresh' .. i, threshNum)
            if tc then newThresh = tostring(math.max(0, math.min(100, newThreshNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(ATGT_VALUES) do if v == target then targetIdx = k; break end end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##dtgt' .. i, targetIdx, ATGT_LABELS)
            if tac then newTarget = ATGT_VALUES[newTargetIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newDamod, dc = ImGui.InputText('##ddamod' .. i, damod, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##dcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##drem' .. i) then
                if i == dpsSize and dpsSize > 1 then
                    dpsRaw[i] = nil
                    dpsSize   = dpsSize - 1
                    Config.set('DPS', 'DPSSize', tostring(dpsSize))
                else
                    dpsRaw[i] = 'null'
                end
                Config.set('DPS', 'DPS', dpsRaw)
                Config.save()
                syncDpsArray()
            end

            if sc or tc or tac or dc or cc then
                local spellVal = sc and newSpell or spell
                dpsRaw[i] = spellVal ~= '' and joinDPS(
                    spellVal,
                    tc  and newThresh  or thresh,
                    tac and newTarget  or target,
                    dc  and newDamod   or damod,
                    cc  and newCond    or cond
                ) or 'null'
                Config.set('DPS', 'DPS', dpsRaw)
                Config.save()
                syncDpsArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        dpsSize = dpsSize + 1
        dpsRaw[dpsSize] = 'null'
        Config.set('DPS', 'DPSSize', tostring(dpsSize))
        Config.set('DPS', 'DPS', dpsRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Burn rotation panel
-- ---------------------------------------------------------------------------

-- .mac Burn layout: SpellName|Target[|condNNN] (mac:11788-11816)
local BURN_TARGETS = { 'Mob', 'Me', 'MA', 'Pet' }

local function joinBurn(spell, target, condNo)
    local result = spell .. '|' .. (target ~= '' and target or 'Mob')
    if condNo > 0 then result = result .. '|' .. string.format('cond%d', condNo) end
    return result
end

function CombatUI.drawBurn()
    local s = _state

    checkbox('Burn', s.combat.burnOn, function(v) set('Burn', 'BurnOn', v) end)

    checkbox('Use Tribute', s.combat.useTribute, function(v) set('Burn', 'UseTribute', v) end)

    ImGui.Spacing()
    local burnNamedLabels = { 'Off', 'Burn all named', 'Burn watch list only' }
    local burnNamedIdx = (s.combat.burnAllNamed or 0) + 1
    ImGui.PushItemWidth(200)
    local newBurnIdx, burnChanged = ImGui.Combo('Burn Named##burnnamed', burnNamedIdx, burnNamedLabels)
    if burnChanged then
        local newVal = newBurnIdx - 1
        s.combat.burnAllNamed = newVal
        Config.set('Burn', 'BurnAllNamed', tostring(newVal))
        Config.save()
    end
    ImGui.PopItemWidth()

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local burnRaw  = Config.get('Burn', 'Burn',     nil) or {}
    local burnSize = tonumber(Config.get('Burn', 'BurnSize', '15')) or 15

    -- Cast.doBurn consumes raw entry strings (same as Combat.init), not parsed slot tables.
    local function syncBurnArray()
        s.combat.burnArray = {}
        for i = 1, burnSize do
            local v = burnRaw[i]
            if v and v ~= '' and v:lower() ~= 'null' then
                s.combat.burnArray[#s.combat.burnArray + 1] = v
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('burn_tbl', 4, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, burnSize do
            local raw     = burnRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, target, condNo = '', 'Mob', 0
            if not isEmpty then spell, target, condNo = Config.parseBurnEntry(raw) end
            local newTarget, newCondNo = target, condNo
            local newSpell, sc, tac, cc

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##bspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(BURN_TARGETS) do
                if v:lower() == target:lower() then targetIdx = k; break end
            end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##btgt' .. i, targetIdx, BURN_TARGETS)
            if tac then newTarget = BURN_TARGETS[newTargetIdx] or 'Mob' end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            if cc then newCondNo = newCondIdx - 1 end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##brem' .. i) then
                if i == burnSize and burnSize > 1 then
                    burnRaw[i] = nil
                    burnSize   = burnSize - 1
                    Config.set('Burn', 'BurnSize', tostring(burnSize))
                else
                    burnRaw[i] = 'null'
                end
                Config.set('Burn', 'Burn', burnRaw)
                Config.save()
                syncBurnArray()
            end

            if sc or tac or cc then
                local spellVal = sc and newSpell or spell
                burnRaw[i] = spellVal ~= '' and joinBurn(spellVal, newTarget, newCondNo) or 'null'
                Config.set('Burn', 'Burn', burnRaw)
                Config.save()
                syncBurnArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        burnSize = burnSize + 1
        burnRaw[burnSize] = 'null'
        Config.set('Burn', 'BurnSize', tostring(burnSize))
        Config.set('Burn', 'Burn', burnRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- AE rotation panel
-- ---------------------------------------------------------------------------

local AE_TARGETS = { 'Mob', 'Single', 'Me', 'MA', 'Pet' }

local function splitAE(raw)
    -- "SpellName|MobCount|Target[|condNNN]" → spell, count, target, cond
    local spell, count, target, cond = '', '1', 'Mob', ''
    if not raw or raw == 'null' or raw == '' then return spell, count, target, cond end
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell  = parts[1] or ''
    count  = parts[2] or '1'
    target = parts[3] or 'Mob'
    return spell, count, target, cond
end

local function joinAE(spell, count, target, cond)
    local result = spell .. '|' .. count .. '|' .. target
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

function CombatUI.drawAE()
    local s = _state

    checkbox('AE On', s.combat.aeOn, function(v) set('AE', 'AEOn', v) end)

    ImGui.Spacing()
    intInput('AE Radius', s.combat.aeRadius, 10, 500, 'AE', 'AERadius')

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local aeRaw  = Config.get('AE', 'AE',     nil) or {}
    local aeSize = tonumber(Config.get('AE', 'AESize', '10')) or 10

    local function syncAEArray()
        s.combat.aeArray = {}
        for i = 1, aeSize do
            local v = aeRaw[i] or 'null'
            if v ~= 'null' and v ~= '' then s.combat.aeArray[i] = v end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('ae_tbl', 5, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Count',  ImGuiTableColumnFlags.WidthFixed,   80)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,   75)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,  160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, aeSize do
            local raw     = aeRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, count, target, cond = splitAE(isEmpty and '' or raw)
            local newCount = count
            local newSpell, newTarget, newCond, sc, nc, tac, cc

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##aespell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local countVal    = tonumber(count) or 1
            local newCountVal
            newCountVal, nc = ImGui.InputInt('##aecount' .. i, countVal, 1, 5)
            if nc then newCount = tostring(math.max(1, newCountVal)) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local tgtIdx = 1  -- ImGui.Combo is 1-based
            for j, v in ipairs(AE_TARGETS) do
                if v:upper() == target:upper() then tgtIdx = j break end
            end
            local newTgtIdx
            newTgtIdx, tac = ImGui.Combo('##aetgt' .. i, tgtIdx, AE_TARGETS)
            newTarget = AE_TARGETS[newTgtIdx] or 'Mob'
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##aecond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##aerem' .. i) then
                if i == aeSize and aeSize > 1 then
                    aeRaw[i] = nil
                    aeSize   = aeSize - 1
                    Config.set('AE', 'AESize', tostring(aeSize))
                else
                    aeRaw[i] = 'null'
                end
                Config.set('AE', 'AE', aeRaw)
                Config.save()
                syncAEArray()
            end

            if sc or nc or tac or cc then
                local sp = sc  and newSpell  or spell
                local ct = nc  and newCount  or count
                local tg = tac and newTarget or target
                local cn = cc  and newCond   or cond
                aeRaw[i] = sp ~= '' and joinAE(sp, ct, tg, cn) or 'null'
                Config.set('AE', 'AE', aeRaw)
                Config.save()
                syncAEArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        aeSize = aeSize + 1
        aeRaw[aeSize] = 'null'
        Config.set('AE', 'AESize', tostring(aeSize))
        Config.set('AE', 'AE', aeRaw)
        Config.save()
    end
end

function CombatUI.init(state)
    _state = state
end

return CombatUI
