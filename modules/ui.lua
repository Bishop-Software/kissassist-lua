-- ui.lua — ImGui status and control panel.
-- Registered with mq.imgui.init; drawn each frame by the MQ2Lua runtime.
-- Reads State.* for display; writes go through existing bind toggle functions
-- so UI and /ka* chat commands stay in sync.

local mq = require('mq')

local Config = require('modules.config')

local UI = {}
local _state
local _open = true

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

local function drawStatus()
    local s = _state

    -- Combat state label + color
    local combatLabel, cr, cg, cb
    if s.session.iAmDead then
        combatLabel, cr, cg, cb = 'DEAD',     1.0, 0.2, 0.2
    elseif s.combat.combatStart then
        combatLabel, cr, cg, cb = 'FIGHTING', 1.0, 0.4, 0.4
    elseif s.pull.pulling then
        combatLabel, cr, cg, cb = 'PULLING',  1.0, 0.9, 0.1
    else
        combatLabel, cr, cg, cb = 'IDLE',     0.4, 1.0, 0.4
    end

    -- Row 1: role / MA
    ImGui.Text(string.format('Role: %-14s', s.session.role or ''))
    ImGui.SameLine()
    ImGui.Text(string.format('MA: %s', s.session.mainAssist or ''))

    -- Row 2: state / burn
    ImGui.Text('State: ')
    ImGui.SameLine()
    ImGui.TextColored(cr, cg, cb, 1.0, combatLabel)
    ImGui.SameLine()
    ImGui.Text(string.format('   Burn: %s', s.combat.burnOn and 'ON' or 'OFF'))

    -- Row 3: target / mob count
    local targetName = ''
    local aggroID = tonumber(s.combat.aggroTargetID) or 0
    if aggroID > 0 then
        targetName = mq.TLO.Spawn(aggroID).CleanName() or ''
    end
    ImGui.Text(string.format('Target: %-20s  Mobs: %d', targetName, s.combat.mobCount or 0))

    -- Row 4: camp location / radius
    local mv = s.movement
    ImGui.Text(string.format('Camp: (%.0f, %.0f, %.0f)  Radius: %d',
        mv.campY or 0, mv.campX or 0, mv.campZ or 0, mv.campRadius or 0))
end

-- ---------------------------------------------------------------------------
-- Toggle Controls panel
-- ---------------------------------------------------------------------------

local function checkbox(label, value, onChange)
    local newVal = ImGui.Checkbox(label, value)
    if newVal ~= value then onChange(newVal) end
end

local function drawControls()
    local s = _state

    -- Row 1
    checkbox('Heals', s.heal.healsOn ~= 0, function(v)
        s.heal.healsOn = v and 1 or 0
    end)
    ImGui.SameLine(120)
    checkbox('Cures', s.heal.curesOn ~= 0, function(v)
        s.heal.curesOn = v and 1 or 0
    end)

    -- Row 2
    checkbox('Buffs', s.buffs.buffsOn, function(v)
        s.buffs.buffsOn = v
    end)
    ImGui.SameLine(120)
    checkbox('Mez', s.mez.on ~= 0, function(v)
        s.mez.on = v and 1 or 0
    end)

    -- Row 3
    checkbox('Burn', s.combat.burnOn, function(_)
        mq.cmd('/burn')
    end)
    ImGui.SameLine(120)
    checkbox('Pet', s.pet.on, function(v)
        mq.cmd(v and '/peton' or '/petoff')
    end)

    -- Row 4
    checkbox('Loot', s.loot.on ~= 0, function(v)
        mq.cmd(v and '/kalooton' or '/kalootoff')
    end)
    ImGui.SameLine(120)
    checkbox('AFK', s.afk.on ~= 0, function(v)
        s.afk.on = v and 1 or 0
    end)

    -- Row 5
    checkbox('Pull', s.pull.on, function(v)
        s.pull.on = v
        Config.set('Pull', 'PullOn', v and '1' or '0')
        Config.save()
    end)
end

-- ---------------------------------------------------------------------------
-- Live Config Editing panel
-- ---------------------------------------------------------------------------

local function intInput(label, value, min, max, configSection, configKey, stateSet)
    local newVal = ImGui.InputInt(label, value)
    if newVal ~= value then
        newVal = math.max(min, math.min(max, newVal))
        stateSet(newVal)
        Config.set(configSection, configKey, tostring(newVal))
        Config.save()
    end
end

local function drawConfig()
    local s = _state

    intInput('Assist %',    s.combat.assistAt,        1,  100, 'Melee',   'AssistAt',  function(v) s.combat.assistAt        = v end)
    intInput('Camp Radius', s.movement.campRadius,     1, 1000, 'General', 'CampRadius',function(v) s.movement.campRadius    = v end)
    intInput('Pull Range',  s.pull.max,                1, 2000, 'Pull',    'MaxRadius', function(v) s.pull.max               = v end)
    intInput('Melee Dist',  s.combat.meleeDistance,    1,  500, 'Melee',   'MeleeDistance', function(v) s.combat.meleeDistance = v end)
    intInput('Med Start %', s.heal.medStart,           1,  100, 'General', 'MedStart',  function(v) s.heal.medStart          = v end)
    intInput('Med Stop %',  s.heal.medStop,            1,  100, 'General', 'MedStop',   function(v) s.heal.medStop           = v end)
end

-- ---------------------------------------------------------------------------
-- Heal Thresholds panel
-- ---------------------------------------------------------------------------

local function saveHealArray()
    local raw = {}
    for i, slot in ipairs(_state.heal.healsArray) do
        local entry = slot.name or ''
        if slot.condNo and slot.condNo > 0 then
            entry = entry .. string.format('|cond%03d', slot.condNo)
        end
        raw[i] = entry
    end
    Config.set('Heals', 'Heals', raw)
    Config.save()
end

local function drawHealThresholds()
    local arr = _state.heal.healsArray
    if not arr or #arr == 0 then return end

    for i, slot in ipairs(arr) do
        local name      = slot.name or ''
        local spellName = name:match('^([^|]+)') or name
        local pct       = tonumber(name:match('^[^|]+|([^|]+)')) or 0
        local tag       = name:match('^[^|]+|[^|]+|([^|]*)') or ''

        local display = spellName:len() > 20 and spellName:sub(1, 19) .. '~' or spellName
        if tag ~= '' then display = display .. ' [' .. tag .. ']' end

        local newPct = ImGui.InputInt(display .. '##h' .. i, pct)
        if newPct ~= pct then
            newPct = math.max(1, math.min(100, newPct))
            local rebuilt = spellName .. '|' .. tostring(newPct)
            if tag ~= '' then rebuilt = rebuilt .. '|' .. tag end
            slot.name = rebuilt
            saveHealArray()
        end
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
-- Draw callback — registered with mq.imgui.init
-- ---------------------------------------------------------------------------

local function draw()
    if not _open then return end
    if ImGui.Begin('KissAssist') then
        drawStatus()
        ImGui.Separator()
        if ImGui.BeginTabBar('KATabs') then
            if ImGui.BeginTabItem('Controls') then
                drawControls()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Config') then
                drawConfig()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Heals') then
                drawHealThresholds()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Spells') then
                drawSpellSlots()
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
