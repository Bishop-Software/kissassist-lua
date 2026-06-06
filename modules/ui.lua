-- ui.lua — ImGui status and control panel.
-- Registered with mq.imgui.init; drawn each frame by the MQ2Lua runtime.
-- Reads State.* for display; writes go through existing bind toggle functions
-- so UI and /ka* chat commands stay in sync.

local mq = require('mq')

local AF_LABELS = { [0]='OFF', [1]='RANGED', [2]='PAUSED' }
local GLT_VALUES  = { '<', '<<', '>' }
local GLT_LABELS  = { '< gain', '<< sec', '> lose' }
local ATGT_VALUES = { '', 'me', 'ma', 'pet', 'inc' }
local ATGT_LABELS = { 'current', 'me', 'ma', 'pet', 'inc' }
local AF_COLORS = {
    [0] = {0.6, 0.6, 0.6},
    [1] = {0.4, 1.0, 0.4},
    [2] = {1.0, 0.9, 0.1},
}
local AFK_MODE_LABELS   = { 'Off', 'Stranger + GM', 'Stranger only', 'GM only' }
local AFK_ACTION_LABELS = { 'Hold until GM leaves', 'End macro', 'Unload MQ2', 'Quit EQ' }

local Config = require('modules.config')

local UI = {}
local _state
local _open = true
local COL    = 130  -- column width for checkbox SameLine and button widths

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

local function drawStatus()
    local s = _state

    -- Combat state label + color
    local combatLabel, cr, cg, cb
    if s.session.iAmDead then
        combatLabel, cr, cg, cb = 'DEAD',      1.0, 0.2, 0.2
    elseif s.combat.combatStart then
        combatLabel, cr, cg, cb = 'FIGHTING',  1.0, 0.4, 0.4
    elseif s.pull.pulling then
        combatLabel, cr, cg, cb = 'PULLING',   1.0, 0.9, 0.1
    elseif s.movement.returnToCamp then
        combatLabel, cr, cg, cb = 'RETURNING', 1.0, 0.7, 0.2
    elseif s.heal.medding then
        combatLabel, cr, cg, cb = 'MEDDING',   0.4, 0.8, 1.0
    elseif s.session.chaseAssist then
        combatLabel, cr, cg, cb = 'CHASING ' .. (s.movement.whoToChase or ''), 0.8, 0.6, 1.0
    else
        combatLabel, cr, cg, cb = 'IDLE',      0.4, 1.0, 0.4
    end

    -- Row 1: role / MA
    ImGui.Text(string.format('Role: %-14s', s.session.role or ''))
    ImGui.SameLine()
    ImGui.Text(string.format('MA: %s', s.session.mainAssist or ''))

    -- Row 2: state / burn / autofire
    ImGui.Text('State: ')
    ImGui.SameLine()
    ImGui.TextColored(cr, cg, cb, 1.0, combatLabel)
    ImGui.SameLine()
    ImGui.Text(string.format('   Burn: %s', s.combat.burnOn and 'ON' or 'OFF'))
    ImGui.SameLine()
    local af = s.combat.autoFireOn or 0
    local afc = AF_COLORS[af]
    ImGui.Text('  AutoFire: ')
    ImGui.SameLine()
    ImGui.TextColored(afc[1], afc[2], afc[3], 1.0, AF_LABELS[af])

    -- Row 3: target / mob count / aggro %
    local targetName = ''
    local aggroID = tonumber(s.combat.aggroTargetID) or 0
    if aggroID > 0 then
        targetName = mq.TLO.Spawn(aggroID).CleanName() or ''
    end
    ImGui.Text(string.format('Target: %-20s  Mobs: %d', targetName, s.combat.mobCount or 0))
    ImGui.SameLine()
    ImGui.Text('  Aggro: ')
    ImGui.SameLine()
    if (mq.TLO.Me.Level() or 0) < 20 then
        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, 'N/A')
    else
        local pctAggro = mq.TLO.Me.PctAggro() or 0
        local ar, ag, ab
        if     pctAggro >= 100 then ar, ag, ab = 0.2, 1.0, 0.2
        elseif pctAggro >= 75  then ar, ag, ab = 1.0, 0.9, 0.1
        else                        ar, ag, ab = 1.0, 0.3, 0.3
        end
        ImGui.TextColored(ar, ag, ab, 1.0, pctAggro .. '%')
    end

    -- Row 4: camp location / radius
    local mv = s.movement
    local isPuller = ({ puller=true, pullertank=true, pullerpettank=true,
                        hunter=true, hunterpettank=true })[s.session.role or '']
    if isPuller and (mv.campX or 0) == 0 and (mv.campY or 0) == 0 then
        ImGui.TextColored(1.0, 0.2, 0.2, 1.0, 'No Camp Set — run /makecamphere')
    else
        local rtcSuffix = mv.returnToCamp and '  [RTC]' or ''
        ImGui.Text(string.format('Camp: (%.0f, %.0f, %.0f)  Radius: %d%s',
            mv.campY or 0, mv.campX or 0, mv.campZ or 0, mv.campRadius or 0, rtcSuffix))
    end

    -- Row 5 (charm classes only): charmed mob
    if s.session.iAmACharmClass and (s.charm.petId or 0) > 0 then
        local charmName = mq.TLO.Spawn(s.charm.petId).CleanName() or '???'
        ImGui.Text('Charmed: ')
        ImGui.SameLine()
        ImGui.TextColored(1.0, 0.6, 0.2, 1.0, charmName)
    end
end

-- ---------------------------------------------------------------------------
-- Toggle Controls panel
-- ---------------------------------------------------------------------------

local function checkbox(label, value, onChange)
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

local function intInput(label, value, min, max, configSection, configKey, stateSet)
    local newVal = ImGui.InputInt(label, value)
    if newVal ~= value then
        newVal = math.max(min, math.min(max, newVal))
        stateSet(newVal)
        Config.set(configSection, configKey, tostring(newVal))
        Config.save()
    end
end

local function drawControls()
    local s = _state

    checkbox('Mez', s.mez.on ~= 0, function(v)
        s.mez.on = v and 1 or 0
    end)

    checkbox('Loot', s.loot.on ~= 0, function(v)
        mq.cmd(v and '/kalooton' or '/kalootoff')
    end)

    -- Camp & Movement
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text('Camp / Movement')
    if ImGui.Button('Make Camp Here', COL, 0) then mq.cmd('/makecamphere') end
    ImGui.SameLine()
    if ImGui.Button('Camp Off',       COL, 0) then mq.cmd('/campoff')      end
    if ImGui.Button('Chase Me',       COL, 0) then mq.cmd('/chaseme')      end
    ImGui.SameLine()
    if ImGui.Button('Stay Here',      COL, 0) then mq.cmd('/stayhere')     end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Camp Radius', s.movement.campRadius,  1, 1000, 'General', 'CampRadius', function(v) s.movement.campRadius = v end)
    intInput('Med Start %', s.heal.medStart,        1,  100, 'General', 'MedStart',   function(v) s.heal.medStart       = v end)
    intInput('Med Stop %',  s.heal.medStop,         1,  100, 'General', 'MedStop',    function(v) s.heal.medStop        = v end)
end

-- ---------------------------------------------------------------------------
-- Pull panel
-- ---------------------------------------------------------------------------

local function drawPull()
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
    intInput('Pull Range',  s.pull.range,         1,  500, 'Pull', 'PullRange',    function(v) s.pull.range        = v end)
    intInput('Arc Width°',  s.pull.pullArcWidth,  0,  360, 'Pull', 'PullArcWidth', function(v) s.pull.pullArcWidth = v end)

    -- Read-only status
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text('Pull With: ' .. (s.pull.withAlt or 'Melee'))
end

-- ---------------------------------------------------------------------------
-- Melee panel
-- ---------------------------------------------------------------------------

local function drawMelee()
    local s = _state

    -- Toggles
    checkbox('Melee', s.combat.meleeOn, function(v)
        s.combat.meleeOn = v
        Config.set('Melee', 'MeleeOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Target Switch', s.combat.targetSwitchingOn, function(v)
        s.combat.targetSwitchingOn = v
        Config.set('Melee', 'TargetSwitchingOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('AutoFire', (s.combat.autoFireOn or 0) ~= 0, function(_)
        mq.cmd('/autofireon')
    end)

    checkbox('LOS Check', Config.get('General', 'LOSBeforeCombat', '0') == '1', function(v)
        Config.set('General', 'LOSBeforeCombat', v and '1' or '0')
        Config.save()
    end)

    if s.session.iAmARogue then
        checkbox('Auto Hide', s.misc.autoHide, function(v)
            s.misc.autoHide = v
            Config.set('General', 'AutoHide', v and '1' or '0')
            Config.save()
        end)
    end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Assist %',    s.combat.assistAt,      1,  100, 'Melee', 'AssistAt',        function(v) s.combat.assistAt      = v end)
    intInput('Melee Dist',  s.combat.meleeDistance,  1,  500, 'Melee', 'MeleeDistance',   function(v) s.combat.meleeDistance = v end)
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
    local stickValues = { '0', 'behind', 'front', '!front', 'moveback', 'pin', 'I' }
    local stickLabels = {
        'Default (plain stick)',
        'Behind target',
        'In front of target',
        'Not in front of target',
        'Move back to range',
        'Pin (no rotation)',
        'Disabled (no stick)',
    }
    local stickCurrent = s.movement.dStickHow or '0'
    local stickIdx = 1
    for i, v in ipairs(stickValues) do
        if v == stickCurrent then stickIdx = i break end
    end
    ImGui.PushItemWidth(200)
    local newIdx, changed = ImGui.Combo('Stick How##stickhow', stickIdx, stickLabels)
    if changed then
        local newVal = stickValues[newIdx] or '0'
        s.movement.dStickHow = newVal
        Config.set('Melee', 'StickHow', newVal)
        Config.save()
    end
    ImGui.PopItemWidth()
end

-- ---------------------------------------------------------------------------
-- Heal Thresholds panel
-- ---------------------------------------------------------------------------

local function splitHeal(raw)
    -- SpellName[|pct[|tag]][|condNNN]  →  spell, pct, tag, cond
    local spell, pct, tag, cond = '', '0', '', ''
    local condPos = raw:find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell = parts[1] or ''
    pct   = parts[2] or '0'
    tag   = parts[3] or ''
    return spell, pct, tag, cond
end

local function joinHeal(spell, pct, tag, cond)
    local result = spell .. '|' .. pct
    if tag  ~= '' then result = result .. '|' .. tag  end
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

local function drawHealThresholds()
    local s = _state

    checkbox('Heals On', s.heal.healsOn ~= 0, function(v)
        s.heal.healsOn = v and 1 or 0
        Config.set('Heals', 'HealsOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local healsRaw  = Config.get('Heals', 'Heals',     nil) or {}
    local healsSize = tonumber(Config.get('Heals', 'HealsSize', '15')) or 15

    local function syncHealsArray()
        s.heal.healsArray = {}
        for _, slot in ipairs(Config.parseCondArray(healsRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.heal.healsArray[#s.heal.healsArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('heals_tbl', 5, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Pct',   ImGuiTableColumnFlags.WidthFixed,    70)
        ImGui.TableSetupColumn('Tag',   ImGuiTableColumnFlags.WidthFixed,   100)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, healsSize do
            local raw     = healsRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, pct, tag, cond = splitHeal(isEmpty and '' or raw)
            local newSpell, newPct, newTag, newCond = spell, pct, tag, cond
            local sc, pc, tac, cc = false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##hspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local pctNum = tonumber(pct) or 0
            local newPctNum
            newPctNum, pc = ImGui.InputInt('##hpct' .. i, pctNum)
            if pc then newPct = tostring(math.max(1, math.min(100, newPctNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newTag, tac = ImGui.InputText('##htag' .. i, tag, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##hcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##hrem' .. i) then
                if i == healsSize and healsSize > 1 then
                    healsRaw[i] = nil
                    healsSize   = healsSize - 1
                    Config.set('Heals', 'HealsSize', tostring(healsSize))
                else
                    healsRaw[i] = 'null'
                end
                Config.set('Heals', 'Heals', healsRaw)
                Config.save()
                syncHealsArray()
            end

            if sc or pc or tac or cc then
                local spellVal = sc and newSpell or spell
                healsRaw[i] = spellVal ~= '' and joinHeal(
                    spellVal,
                    pc  and newPct or pct,
                    tac and newTag or tag,
                    cc  and newCond or cond
                ) or 'null'
                Config.set('Heals', 'Heals', healsRaw)
                Config.save()
                syncHealsArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        healsSize = healsSize + 1
        healsRaw[healsSize] = 'null'
        Config.set('Heals', 'HealsSize', tostring(healsSize))
        Config.set('Heals', 'Heals', healsRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Spell Slots panel
-- ---------------------------------------------------------------------------

local function drawSpellSlots()
    local gemSlots = _state.cast.gemSlots or 8
    ImGui.PushItemWidth(220)
    for i = 1, gemSlots do
        local current = Config.get('Spells', 'Gem' .. i, '')
        local newVal, changed = ImGui.InputText('Gem ' .. i .. '##gem' .. i, current, 0)
        if changed and newVal ~= current then
            Config.set('Spells', 'Gem' .. i, newVal)
            Config.save()
        end
    end
    ImGui.PopItemWidth()

    ImGui.Spacing()
    if ImGui.Button('Write Current Gems') then
        Config.writeSpells(_state)
    end
end

-- ---------------------------------------------------------------------------
-- Pet panel
-- ---------------------------------------------------------------------------

local function drawPet()
    local s = _state

    -- Row 1
    checkbox('Pet', s.pet.on, function(v)
        mq.cmd(v and '/peton' or '/petoff')
    end)
    ImGui.SameLine(120)
    checkbox('Pet Buffs', s.buffs.petBuffsOn, function(v)
        s.buffs.petBuffsOn = v
        Config.set('Pet', 'PetBuffsOn', v and '1' or '0')
        Config.save()
    end)

    -- Row 2
    checkbox('Shrink', s.pet.shrinkOn, function(v)
        s.pet.shrinkOn = v
        Config.set('Pet', 'PetShrinkOn', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(120)
    checkbox('Toys', s.pet.toysOn, function(v)
        s.pet.toysOn = v
        Config.set('Pet', 'PetToysOn', v and '1' or '0')
        Config.save()
    end)

    -- Row 3
    checkbox('Suspend', s.pet.suspend, function(v)
        s.pet.suspend = v
        Config.set('Pet', 'PetSuspend', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(120)
    checkbox('Hold', s.pet.holdOn ~= 0, function(v)
        s.pet.holdOn = v and 1 or 0
        Config.set('Pet', 'PetHoldOn', v and '1' or '0')
        Config.save()
    end)

    -- Row 4
    checkbox('Taunt Off', s.pet.tauntOverride, function(v)
        s.pet.tauntOverride = v
        Config.set('Pet', 'PetTauntOverride', v and '1' or '0')
        Config.save()
    end)

    -- Editable spell fields
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.PushItemWidth(200)
    local spellVal, spellChanged = ImGui.InputText('Pet Spell##petspell', s.pet.spell, 0)
    if spellChanged and spellVal ~= s.pet.spell then
        s.pet.spell = spellVal
        Config.set('Pet', 'PetSpell', spellVal)
        Config.save()
    end
    if s.pet.shrinkOn then
        local shrinkVal, shrinkChanged = ImGui.InputText('Shrink Spell##shrinkspell', s.pet.shrinkSpell, 0)
        if shrinkChanged and shrinkVal ~= s.pet.shrinkSpell then
            s.pet.shrinkSpell = shrinkVal
            Config.set('Pet', 'PetShrinkSpell', shrinkVal)
            Config.save()
        end
    end
    ImGui.PopItemWidth()
end

-- ---------------------------------------------------------------------------
-- Merc panel
-- ---------------------------------------------------------------------------

local function drawMerc()
    local s = _state

    checkbox('Merc', s.merc.on ~= 0, function(v)
        s.merc.on = v and 1 or 0
        Config.set('Merc', 'MercOn', v and '1' or '0')
        Config.save()
    end)

    intInput('Assist %', s.merc.assistAt, 1, 100, 'Merc', 'MercAssistAt',
        function(v) s.merc.assistAt = v end)

    ImGui.Spacing()
    ImGui.Separator()

    -- Live status
    local mercName  = s.merc.myMerc ~= '' and s.merc.myMerc or '(none)'
    local mercState = mq.TLO.Mercenary.State() or ''
    local sr, sg, sb
    if mercState == 'Active' then
        sr, sg, sb = 0.2, 1.0, 0.2
    elseif mercState == 'DEAD' then
        sr, sg, sb = 1.0, 0.2, 0.2
    else
        sr, sg, sb = 1.0, 0.9, 0.1
    end

    ImGui.Text('Name:  ' .. mercName)
    ImGui.Text('State: ')
    ImGui.SameLine()
    ImGui.TextColored(sr, sg, sb, 1.0, mercState ~= '' and mercState or 'Unknown')

    local assistID   = tonumber(s.merc.assisting) or 0
    local assistName = assistID > 0 and (mq.TLO.Spawn(assistID).CleanName() or '') or ''
    ImGui.Text('Assist: ' .. (assistName ~= '' and assistName or '—'))
end

-- ---------------------------------------------------------------------------
-- Bard panel (class-gated)
-- ---------------------------------------------------------------------------

local function drawBard()
    ---@diagnostic disable-next-line: undefined-field
    local Medley   = mq.TLO.Medley
    local bard     = _state.bard
    local active    = Medley.Active() or false
    local activeSet = Medley.Medley() or '—'

    ImGui.Text(string.format('Active set: %s  (%s)', activeSet, active and 'playing' or 'stopped'))
    ImGui.Separator()

    -- Set switch buttons
    if ImGui.Button(bard.meleeMedley) then mq.cmdf('/medley %s', bard.meleeMedley) end
    ImGui.SameLine()
    if ImGui.Button(bard.burnMedley)  then mq.cmdf('/medley %s', bard.burnMedley)  end
    ImGui.SameLine()
    if ImGui.Button(bard.oorMedley)   then mq.cmdf('/medley %s', bard.oorMedley)   end

    -- Pause / Resume
    ImGui.Spacing()
    if ImGui.Button('Pause')  then mq.cmd('/medley pause')  end
    ImGui.SameLine()
    if ImGui.Button('Resume') then mq.cmd('/medley resume') end
    ImGui.SameLine()
    if ImGui.Button('Stop')   then mq.cmd('/medley stop')   end
end

-- ---------------------------------------------------------------------------
-- Conditions panel
-- ---------------------------------------------------------------------------

local function drawConditions()
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

    ImGui.PushItemWidth(300)
    for i = 1, (s.cond.size or 5) do
        local current = s.cond.expressions[i] or ''
        local newVal, changed = ImGui.InputText(string.format('Cond %03d##cond%d', i, i), current, 0)
        if changed and newVal ~= current then
            s.cond.expressions[i] = newVal ~= '' and newVal or nil
            condArr[i] = newVal ~= '' and newVal or 'null'
            Config.set('KConditions', 'Cond', condArr)
            Config.save()
        end
        ImGui.SameLine()
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
    ImGui.PopItemWidth()

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        s.cond.size = (s.cond.size or 5) + 1
        condArr[s.cond.size] = 'null'
        Config.set('KConditions', 'Cond', condArr)
        Config.set('KConditions', 'CondSize', tostring(s.cond.size))
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Cures panel
-- ---------------------------------------------------------------------------

-- Parse: SpellName[|debuffType[|Me]][|condNNN]
-- debuffType absent or 'me' → no type filter; 'me' alone → self-only scope
local function splitCure(raw)
    local spell, dtype, selfOnly, cond = raw, '', false, ''
    local condPos = raw:find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell = parts[1] or ''
    local arg2 = (parts[2] or ''):lower()
    local arg3 = (parts[3] or ''):lower()
    if arg2 == 'me' then
        selfOnly = true; dtype = ''
    elseif arg2 ~= '' then
        dtype    = arg2
        selfOnly = (arg3 == 'me')
    end
    return spell, dtype, selfOnly, cond
end

local function joinCure(spell, dtype, selfOnly, cond)
    local result = spell
    if dtype ~= '' then
        result = result .. '|' .. dtype
        if selfOnly then result = result .. '|Me' end
    elseif selfOnly then
        result = result .. '|Me'
    end
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

local _CURE_TYPE_LABELS = { '(any)', 'Self', 'Disease', 'Poison', 'Curse', 'Corruption', 'Mezzed' }
local _CURE_TYPE_VALUES = { '',      'me',   'disease', 'poison', 'curse', 'corruption', 'mezzed' }

local function cureTypeToIdx(dtype, selfOnly)
    if dtype == '' and selfOnly then return 2 end  -- Self
    for i, v in ipairs(_CURE_TYPE_VALUES) do
        if v == dtype then return i end
    end
    return 1  -- (any)
end

local function drawCures()
    local s = _state

    local curesOnLabels = { 'Off', 'Everyone', 'Self Only', 'Group Only' }
    local newCuresOnIdx, coc = ImGui.Combo('Cures Mode##curesOn', s.heal.curesOn, curesOnLabels)
    if coc then
        s.heal.curesOn = newCuresOnIdx
        Config.set('Cures', 'CuresOn', tostring(newCuresOnIdx))
        Config.save()
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local curesRaw  = Config.get('Cures', 'Cures',     nil) or {}
    local curesSize = tonumber(Config.get('Cures', 'CuresSize', '5')) or 5

    local function syncCuresArray()
        s.heal.curesArray = {}
        for _, slot in ipairs(Config.parseCondArray(curesRaw)) do
            s.heal.curesArray[#s.heal.curesArray + 1] = slot
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('cures_tbl', 5, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Type',  ImGuiTableColumnFlags.WidthFixed,   100)
        ImGui.TableSetupColumn('Self',  ImGuiTableColumnFlags.WidthFixed,    36)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, curesSize do
            local raw     = curesRaw[i] or ''
            local isEmpty = raw == '' or raw == 'null' or raw == 'NULL'
            local spell, dtype, selfOnly, cond = splitCure(isEmpty and '' or raw)

            ImGui.TableNextRow()

            -- Spell
            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local newSpell, sc = ImGui.InputText('##cspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            -- Type
            ImGui.TableNextColumn()
            local typeIdx    = cureTypeToIdx(dtype, selfOnly)
            local newTypeIdx, tc = ImGui.Combo('##ctype' .. i, typeIdx - 1, _CURE_TYPE_LABELS)
            newTypeIdx = newTypeIdx + 1  -- back to 1-based
            local newDtype    = _CURE_TYPE_VALUES[newTypeIdx] or ''
            -- 'Self' selection collapses selfOnly into the type field; clear selfOnly
            local newSelfOnly = (newTypeIdx == 2) and false or selfOnly

            -- Self checkbox — only meaningful when a debuff type (not Self) is selected
            ImGui.TableNextColumn()
            local selfEnabled = newDtype ~= '' and newDtype ~= 'me'
            if not selfEnabled then ImGui.BeginDisabled() end
            local newSelf, soc = ImGui.Checkbox('##cself' .. i, selfOnly)
            if not selfEnabled then ImGui.EndDisabled() end
            if selfEnabled and soc then newSelfOnly = newSelf end

            -- Cond
            ImGui.TableNextColumn()
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx, cc = ImGui.Combo('##ccond' .. i, condNo + 1, condLabels)
            local newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)

            if sc or tc or (selfEnabled and soc) or cc then
                local finalDtype    = tc    and newDtype    or dtype
                local finalSelf     = soc   and newSelfOnly or ((tc and newTypeIdx == 2) and false or selfOnly)
                local finalCond     = cc    and newCond     or cond
                local finalSpell    = sc    and newSpell    or spell
                local out = joinCure(finalSpell, finalDtype, finalSelf, finalCond)
                curesRaw[i] = (out == '') and 'null' or out
                Config.set('Cures', 'Cures', curesRaw)
                Config.save()
                syncCuresArray()
            end

            -- Remove
            ImGui.TableNextColumn()
            if ImGui.Button('[-]##crem' .. i) then
                if i == curesSize and curesSize > 1 then
                    curesRaw[curesSize] = nil
                    curesSize = curesSize - 1
                    Config.set('Cures', 'CuresSize', tostring(curesSize))
                else
                    curesRaw[i] = 'null'
                end
                Config.set('Cures', 'Cures', curesRaw)
                Config.save()
                syncCuresArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        curesSize = curesSize + 1
        curesRaw[curesSize] = 'null'
        Config.set('Cures', 'Cures', curesRaw)
        Config.set('Cures', 'CuresSize', tostring(curesSize))
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Buffs panel
-- ---------------------------------------------------------------------------

local function splitBuff(raw)
    -- SpellName[|TargetTag][|condNNN]  →  spell, tag, cond
    local spell, tag, cond = raw, '', ''
    local condPos = raw:find('|cond%d')
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

local function drawBuffs()
    local s = _state

    checkbox('Buffs On', s.buffs.buffsOn, function(v)
        s.buffs.buffsOn = v
        Config.set('Buffs', 'BuffsOn', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(120)
    checkbox('Rebuff On', s.buffs.rebuffOn, function(v)
        s.buffs.rebuffOn = v
        Config.set('Buffs', 'RebuffOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('Check Timer', s.buffs.checkBuffsTimer, 1, 3600, 'Buffs', 'CheckBuffsTimer',
        function(v) s.buffs.checkBuffsTimer = v end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local buffsRaw  = Config.get('Buffs', 'Buffs',     nil) or {}
    local buffsSize = tonumber(Config.get('Buffs', 'BuffsSize', '20')) or 20

    local function syncBuffsArray()
        s.buffs.buffsArray = {}
        for _, slot in ipairs(Config.parseCondArray(buffsRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.buffs.buffsArray[#s.buffs.buffsArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('buffs_tbl', 4, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Tag',   ImGuiTableColumnFlags.WidthFixed,   110)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, buffsSize do
            local raw     = buffsRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, tag, cond = splitBuff(isEmpty and '' or raw)
            local sc, tc, cc = false, false, false
            local newSpell, newTag, newCond = spell, tag, cond

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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##buffrem' .. i) then
                if i == buffsSize and buffsSize > 1 then
                    buffsRaw[i] = nil
                    buffsSize   = buffsSize - 1
                    Config.set('Buffs', 'BuffsSize', tostring(buffsSize))
                else
                    buffsRaw[i] = 'null'
                end
                Config.set('Buffs', 'Buffs', buffsRaw)
                Config.save()
                syncBuffsArray()
            end

            if sc or tc or cc then
                local spellVal = sc and newSpell or spell
                buffsRaw[i] = spellVal ~= '' and joinBuff(
                    spellVal,
                    tc and newTag  or tag,
                    cc and newCond or cond
                ) or 'null'
                Config.set('Buffs', 'Buffs', buffsRaw)
                Config.save()
                syncBuffsArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        buffsSize = buffsSize + 1
        buffsRaw[buffsSize] = 'null'
        Config.set('Buffs', 'BuffsSize', tostring(buffsSize))
        Config.set('Buffs', 'Buffs', buffsRaw)
        Config.save()
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

local function drawGoM()
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
            local sc, tc       = false, false
            local newSpell, newTgt = spell, tgt

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##gomspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local tgtIdx = 0
            for j, v in ipairs(GOM_TARGETS) do
                if v == tgt then tgtIdx = j - 1 break end
            end
            local newTgtIdx
            newTgtIdx, tc = ImGui.Combo('##gomtgt' .. i, tgtIdx, GOM_TARGETS)
            newTgt = GOM_TARGETS[newTgtIdx + 1] or 'MA'
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##gomrem' .. i) then
                if i == gomSize and gomSize > 1 then
                    gomRaw[i] = nil
                    gomSize   = gomSize - 1
                    Config.set('GoM', 'GoMSize', tostring(gomSize))
                else
                    gomRaw[i] = 'null'
                end
                Config.set('GoM', 'GoMSpell', gomRaw)
                Config.save()
            end

            if sc or tc then
                local s = sc and newSpell or spell
                local t = tc and newTgt   or tgt
                gomRaw[i] = s ~= '' and joinGom(s, t) or 'null'
                Config.set('GoM', 'GoMSpell', gomRaw)
                Config.save()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        gomSize = gomSize + 1
        gomRaw[gomSize] = 'null'
        Config.set('GoM', 'GoMSize', tostring(gomSize))
        Config.set('GoM', 'GoMSpell', gomRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Aggro panel
-- ---------------------------------------------------------------------------

local function splitAggro(raw)
    -- SpellName[|pct[|glt[|target]]][|condNNN]  →  spell, pct, glt, target, cond
    local spell, pct, glt, target, cond = '', '0', '<', '', ''
    local condPos = raw:find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell  = parts[1] or ''
    pct    = parts[2] or '0'
    glt    = parts[3] or '<'
    target = parts[4] or ''
    return spell, pct, glt, target, cond
end

local function joinAggro(spell, pct, glt, target, cond)
    local result = spell .. '|' .. pct .. '|' .. glt
    if target ~= '' then result = result .. '|' .. target end
    if cond   ~= '' then result = result .. '|' .. cond   end
    return result
end

-- ---------------------------------------------------------------------------
-- DPS panel helpers
-- ---------------------------------------------------------------------------

local function splitDPS(raw)
    -- SpellName[|thresh[|target[|damod]]][|condNNN]  →  spell, thresh, target, damod, cond
    local spell, thresh, target, damod, cond = '', '0', '', '', ''
    local condPos = raw:find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell  = parts[1] or ''
    thresh = parts[2] or '0'
    target = parts[3] or ''
    damod  = parts[4] or ''
    return spell, thresh, target, damod, cond
end

local function joinDPS(spell, thresh, target, damod, cond)
    local result = spell .. '|' .. thresh
    if target ~= '' or damod ~= '' then result = result .. '|' .. target end
    if damod  ~= ''               then result = result .. '|' .. damod  end
    if cond   ~= ''               then result = result .. '|' .. cond   end
    return result
end

local function drawAggro()
    local s = _state

    checkbox('Aggro', s.combat.aggroOn, function(v)
        s.combat.aggroOn = v
        Config.set('Aggro', 'AggroOn', v and '1' or '0')
        Config.save()
    end)

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
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
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
            local newSpell, newPct, newGlt, newTarget, newCond = spell, pct, glt, target, cond
            local sc, pc, gc, tac, cc = false, false, false, false, false

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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##acond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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
-- DPS rotation panel
-- ---------------------------------------------------------------------------

local function drawDPS()
    local s = _state

    checkbox('DPS', s.combat.dpsOn, function(v)
        s.combat.dpsOn = v
        Config.set('DPS', 'DPSOn', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(120)
    checkbox('Debuff All', s.debuff.on ~= 0, function(v)
        s.debuff.on = v and 1 or 0
        Config.set('DPS', 'DebuffAllOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('DPS Skip %',   s.combat.dpsSkip,     0,  100, 'DPS', 'DPSSkip',     function(v) s.combat.dpsSkip     = v end)
    intInput('DPS Interval', s.combat.dpsInterval, 0, 3600, 'DPS', 'DPSInterval', function(v) s.combat.dpsInterval = v end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()
    ImGui.TextColored(0.7, 0.7, 0.7, 1.0, 'HP% 0 = use AssistAt.  HP% >= 101 = debuff slot.')
    ImGui.Spacing()

    local dpsRaw  = Config.get('DPS', 'DPS',     nil) or {}
    local dpsSize = tonumber(Config.get('DPS', 'DPSSize', '20')) or 20

    local function syncDpsArray()
        s.combat.dpsArray = {}
        s.debuff.slots    = {}
        s.debuff.count    = 0
        for _, slot in ipairs(Config.parseCondArray(dpsRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                local parts = {}
                for p in (slot.name .. '|'):gmatch('([^|]*)|') do parts[#parts+1] = p end
                local thresh = tonumber(parts[2]) or 0
                if thresh >= 101 then
                    s.debuff.slots[#s.debuff.slots + 1] = {
                        spell  = parts[1] or '',
                        tag1   = parts[3] or '',
                        tag2   = parts[4] or '',
                        condNo = slot.condNo,
                    }
                    s.debuff.count = s.debuff.count + 1
                else
                    s.combat.dpsArray[#s.combat.dpsArray + 1] = slot
                end
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
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
            local newSpell, newThresh, newTarget, newDamod, newCond = spell, thresh, target, damod, cond
            local sc, tc, tac, dc, cc = false, false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##dspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local threshNum = tonumber(thresh) or 0
            local newThreshNum
            newThreshNum, tc = ImGui.InputInt('##dthresh' .. i, threshNum)
            if tc then newThresh = tostring(math.max(0, math.min(200, newThreshNum))) end
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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##dcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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

local function drawBurn()
    local s = _state

    checkbox('Burn', s.combat.burnOn, function(v)
        s.combat.burnOn = v
        Config.set('Burn', 'BurnOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Use Tribute', s.combat.useTribute, function(v)
        s.combat.useTribute = v
        Config.set('Burn', 'UseTribute', v and '1' or '0')
        Config.save()
    end)

    if not s.combat.combatStart then ImGui.BeginDisabled() end
    if ImGui.Button('Burn Now') then mq.cmd('/burn') end
    if not s.combat.combatStart then ImGui.EndDisabled() end

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

    local function syncBurnArray()
        s.combat.burnArray = {}
        for _, slot in ipairs(Config.parseCondArray(burnRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.combat.burnArray[#s.combat.burnArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('burn_tbl', 6, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('HP%',    ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('DAMod',  ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, burnSize do
            local raw     = burnRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, thresh, target, damod, cond = splitDPS(isEmpty and '' or raw)
            local newSpell, newThresh, newTarget, newDamod, newCond = spell, thresh, target, damod, cond
            local sc, tc, tac, dc, cc = false, false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##bspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local threshNum = tonumber(thresh) or 0
            local newThreshNum
            newThreshNum, tc = ImGui.InputInt('##bthresh' .. i, threshNum)
            if tc then newThresh = tostring(math.max(0, math.min(200, newThreshNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(ATGT_VALUES) do if v == target then targetIdx = k; break end end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##btgt' .. i, targetIdx, ATGT_LABELS)
            if tac then newTarget = ATGT_VALUES[newTargetIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newDamod, dc = ImGui.InputText('##bdamod' .. i, damod, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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

            if sc or tc or tac or dc or cc then
                local spellVal = sc and newSpell or spell
                burnRaw[i] = spellVal ~= '' and joinDPS(
                    spellVal,
                    tc  and newThresh  or thresh,
                    tac and newTarget  or target,
                    dc  and newDamod   or damod,
                    cc  and newCond    or cond
                ) or 'null'
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
    local condPos = raw:find('|cond%d')
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

local function drawAE()
    local s = _state

    checkbox('AE On', s.combat.aeOn, function(v)
        s.combat.aeOn = v
        Config.set('AE', 'AEOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('AE Radius', s.combat.aeRadius, 10, 500, 'AE', 'AERadius',
        function(v) s.combat.aeRadius = v end)

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
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
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
            local newSpell, newCount, newTarget, newCond = spell, count, target, cond
            local sc, nc, tac, cc = false, false, false, false

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
            local tgtIdx = 0
            for j, v in ipairs(AE_TARGETS) do
                if v:upper() == target:upper() then tgtIdx = j - 1 break end
            end
            local newTgtIdx
            newTgtIdx, tac = ImGui.Combo('##aetgt' .. i, tgtIdx, AE_TARGETS)
            newTarget = AE_TARGETS[newTgtIdx + 1] or 'Mob'
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##aecond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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

-- ---------------------------------------------------------------------------
-- AFK Tools panel
-- ---------------------------------------------------------------------------

local function drawAfkTools()
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

-- ---------------------------------------------------------------------------
-- Draw callback — registered with mq.imgui.init
-- ---------------------------------------------------------------------------

local function draw()
    if not _open then return end
    if ImGui.Begin('KissAssist') then
        drawStatus()
        ImGui.Separator()
        if ImGui.BeginTabBar('KATabs') then
            if ImGui.BeginTabItem('Combat') then
                if ImGui.BeginTabBar('KACombatTabs') then
                    if ImGui.BeginTabItem('Melee') then
                        drawMelee()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('DPS') then
                        drawDPS()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Burn') then
                        drawBurn()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Aggro') then
                        drawAggro()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('AE') then
                        drawAE()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Healing') then
                if ImGui.BeginTabBar('KAHealingTabs') then
                    if ImGui.BeginTabItem('Heals') then
                        drawHealThresholds()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Cures') then
                        drawCures()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Spells') then
                if ImGui.BeginTabBar('KASpellsTabs') then
                    if ImGui.BeginTabItem('Spells') then
                        drawSpellSlots()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Buffs') then
                        drawBuffs()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('GoM') then
                        drawGoM()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Support') then
                if ImGui.BeginTabBar('KASupportTabs') then
                    if ImGui.BeginTabItem('Pet') then
                        drawPet()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Merc') then
                        drawMerc()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Pull') then
                drawPull()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Config') then
                if ImGui.BeginTabBar('KAConfigTabs') then
                    if ImGui.BeginTabItem('Settings') then
                        drawControls()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Conditions') then
                        drawConditions()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('AFK Tools') then
                        drawAfkTools()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if _state.session.iAmABard then
                if ImGui.BeginTabItem('Bard') then
                    drawBard()
                    ImGui.EndTabItem()
                end
            end
            ImGui.EndTabBar()
        end
    end
    ImGui.End()
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function UI.init(state)
    _state = state
    mq.imgui.init('KissAssist', draw)
    mq.bind('/kaui', function() _open = not _open end)
end

return UI
