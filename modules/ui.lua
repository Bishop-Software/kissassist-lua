-- ui.lua — ImGui status and control panel.
-- Registered with mq.imgui.init; drawn each frame by the MQ2Lua runtime.
-- Reads State.* for display; writes go through existing bind toggle functions
-- so UI and /ka* chat commands stay in sync.
--
-- Tab content lives in modules/ui/*.lua (one file per tab group); this file
-- only wires them together and draws the top-level window/tab-bar shell.

local mq = require('mq')

local Config   = require('modules.config')
local StatusUI = require('modules.ui.status')
local Combat   = require('modules.ui.combat')
local Healing  = require('modules.ui.healing')
local Spells   = require('modules.ui.spells')
local Support  = require('modules.ui.support')
local PullUI   = require('modules.ui.pull')
local CC       = require('modules.ui.cc')
local Settings = require('modules.ui.settings')
local BardUI   = require('modules.ui.bard')

local UI = {}
local _state
local _open = true
local _savedFullW, _savedFullH = 0, 0  -- window size saved before entering mini mode
local _pendingW,   _pendingH   = 0, 0  -- next-frame SetNextWindowSize values (0 = no pending)
local MINI_W, MINI_H           = 465, 0

-- ---------------------------------------------------------------------------
-- Draw callback — registered with mq.imgui.init
-- ---------------------------------------------------------------------------

local function draw()
    if not _open then return end
    local miniMode = _state.ui.miniMode
    if _pendingW > 0 then
        ImGui.SetNextWindowSize(_pendingW, _pendingH, 1)  -- 1 = ImGuiCond_Always
        _pendingW, _pendingH = 0, 0
    end
    local winFlags = miniMode and ImGuiWindowFlags.NoResize or 0
    local shouldDraw
    _open, shouldDraw = ImGui.Begin('KissAssist Lua', _open, winFlags)
    if not _open then _state.terminate = true end
    if shouldDraw then
        -- mini-mode toggle button, right-aligned on the first status row
        local btnLabel = miniMode and '[+]' or '[-]'
        local savedY = ImGui.GetCursorPosY()
        ImGui.SetCursorPosX(ImGui.GetWindowWidth() - 32)
        if ImGui.SmallButton(btnLabel) then
            if not miniMode then
                -- entering mini: save current size, schedule shrink to fixed mini dimensions
                _savedFullW, _savedFullH = ImGui.GetWindowSize()
                _pendingW, _pendingH = MINI_W, MINI_H
            else
                -- exiting mini: schedule restore to saved (or default) size
                _pendingW = _savedFullW > 0 and _savedFullW or 640
                _pendingH = _savedFullH > 0 and _savedFullH or 500
            end
            _state.ui.miniMode = not miniMode
            Config.set('UI', 'MiniMode', _state.ui.miniMode and '1' or '0')
            Config.save()
        end
        ImGui.SetCursorPosY(savedY)

        StatusUI.drawStatus()
        ImGui.Separator()
        StatusUI.drawCampButtons()
        if miniMode then
            ImGui.End()
            return
        end
        ImGui.Separator()
        if ImGui.BeginTabBar('KATabs') then
            if ImGui.BeginTabItem('Combat') then
                if ImGui.BeginTabBar('KACombatTabs') then
                    if ImGui.BeginTabItem('Melee') then
                        Combat.drawMelee()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('DPS') then
                        Combat.drawDPS()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Debuff') then
                        Combat.drawDebuffs()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Burn') then
                        Combat.drawBurn()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Aggro') then
                        Combat.drawAggro()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('AE') then
                        Combat.drawAE()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Healing') then
                if ImGui.BeginTabBar('KAHealingTabs') then
                    if ImGui.BeginTabItem('Heals') then
                        Healing.drawHealThresholds()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Cures') then
                        Healing.drawCures()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Spells') then
                if ImGui.BeginTabBar('KASpellsTabs') then
                    if ImGui.BeginTabItem('Spells') then
                        Spells.drawSpellSlots()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Buffs') then
                        Spells.drawBuffs()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('GoM') then
                        Spells.drawGoM()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Support') then
                if ImGui.BeginTabBar('KASupportTabs') then
                    if ImGui.BeginTabItem('Pet') then
                        Support.drawPet()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Merc') then
                        Support.drawMerc()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Pull') then
                PullUI.drawPull()
                ImGui.EndTabItem()
            end
            if _state.session.iAmAMezClass or _state.session.iAmACharmClass then
                if ImGui.BeginTabItem('CC') then
                    CC.drawCC()
                    ImGui.EndTabItem()
                end
            end
            if ImGui.BeginTabItem('Config') then
                if ImGui.BeginTabBar('KAConfigTabs') then
                    if ImGui.BeginTabItem('Settings') then
                        Settings.drawControls()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Conditions') then
                        Settings.drawConditions()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('AFK Tools') then
                        Settings.drawAfkTools()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if _state.session.iAmABard then
                if ImGui.BeginTabItem('Bard') then
                    BardUI.drawBard()
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

    StatusUI.init(state)
    Combat.init(state)
    Healing.init(state)
    Spells.init(state)
    Support.init(state)
    PullUI.init(state)
    CC.init(state)
    Settings.init(state)
    BardUI.init(state)

    _state.ui.miniMode = Config.get('UI', 'MiniMode', '0') == '1'
    mq.imgui.init('KissAssist Lua', draw)
    mq.bind('/kaui', function(arg)
        if arg == 'mini' then
            _state.ui.miniMode = not _state.ui.miniMode
            Config.set('UI', 'MiniMode', _state.ui.miniMode and '1' or '0')
            Config.save()
        else
            _open = not _open
        end
    end)
end

return UI
