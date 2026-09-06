-- ui/cc.lua — CC tab: Mez + Charm sub-tabs (class-gated).

local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local intInput = Helpers.intInput

local MEZ_MODE_LABELS = { 'Off', 'Single + AE', 'Single only', 'AE only' }

local CC = {}
local _state

function CC.drawCC()
    local s = _state

    if ImGui.BeginTabBar('KACCTabs') then
        if s.session.iAmAMezClass and ImGui.BeginTabItem('Mez') then
            ImGui.Spacing()
            ImGui.PushItemWidth(200)
            local newMode, modeChanged = ImGui.Combo('Mode##mezmode', s.mez.on + 1, MEZ_MODE_LABELS)
            if modeChanged then
                s.mez.on = newMode - 1
                Config.set('Mez', 'MezOn', tostring(s.mez.on))
                Config.save()
            end
            ImGui.PopItemWidth()

            ImGui.Spacing()
            intInput('Mez Radius##mez', s.mez.radius,   1, 500, 'Mez', 'MezRadius',   function(v) s.mez.radius   = v end)
            intInput('Stop HP%##mez',   s.mez.stopHPs,  1, 100, 'Mez', 'MezStopHPs',  function(v) s.mez.stopHPs  = v end)
            intInput('Min Level##mez',  s.mez.minLevel, 1, 999, 'Mez', 'MezMinLevel', function(v) s.mez.minLevel = v end)
            intInput('Max Level##mez',  s.mez.maxLevel, 1, 999, 'Mez', 'MezMaxLevel', function(v) s.mez.maxLevel = v end)

            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Text(string.format(
                'Haters on XTarget: %d total  /  %d within Mez Radius',
                s.mez.mobCount or 0, s.mez.mobAECount or 0))
            ImGui.Spacing()

            -- Spell + mob-count columns
            if ImGui.BeginTable('##mezspells', 3, 0) then
                ImGui.TableSetupColumn('Spell',     ImGuiTableColumnFlags.WidthStretch, 0)
                ImGui.TableSetupColumn('Min Mobs',  ImGuiTableColumnFlags.WidthFixed,  100)
                ImGui.TableSetupColumn('Label',     ImGuiTableColumnFlags.WidthFixed,  90)
                ImGui.TableHeadersRow()

                -- Mez Spell row
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.PushItemWidth(-1)
                local mezSpell, msc = ImGui.InputText('##mezspell', s.mez.spell, 0)
                ImGui.PopItemWidth()
                if msc and mezSpell ~= s.mez.spell then
                    s.mez.spell = mezSpell
                    Config.set('Mez', 'MezSpell', mezSpell .. '|' .. (s.mez.singleCount or 2))
                    Config.save()
                end
                ImGui.TableSetColumnIndex(1)
                ImGui.PushItemWidth(-1)
                local sc, scc = ImGui.InputInt('##singlecount', s.mez.singleCount or 2, 1, 1)
                ImGui.PopItemWidth()
                if scc then
                    sc = math.max(2, sc)
                    s.mez.singleCount = sc
                    Config.set('Mez', 'MezSpell', s.mez.spell .. '|' .. sc)
                    Config.save()
                end
                ImGui.TableSetColumnIndex(2)
                ImGui.Text('Mez Spell')

                -- AE Mez Spell row
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.PushItemWidth(-1)
                local aeMezSpell, asc = ImGui.InputText('##aespell', s.mez.aeSpell, 0)
                ImGui.PopItemWidth()
                if asc and aeMezSpell ~= s.mez.aeSpell then
                    s.mez.aeSpell = aeMezSpell
                    Config.set('Mez', 'MezAESpell', aeMezSpell .. '|' .. (s.mez.aeCount or 0))
                    Config.save()
                end
                ImGui.TableSetColumnIndex(1)
                ImGui.PushItemWidth(-1)
                local ac, acc = ImGui.InputInt('##aecount', s.mez.aeCount or 0, 1, 1)
                ImGui.PopItemWidth()
                if acc then
                    ac = math.max(0, ac)
                    s.mez.aeCount = ac
                    Config.set('Mez', 'MezAESpell', s.mez.aeSpell .. '|' .. ac)
                    Config.save()
                end
                ImGui.TableSetColumnIndex(2)
                ImGui.Text('AE Mez Spell')

                -- Debuff Spell row (no mob count)
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.PushItemWidth(-1)
                local debuffSpell, dsc = ImGui.InputText('##mezDebuff', s.mez.mezDebuffSpell, 0)
                ImGui.PopItemWidth()
                if dsc and debuffSpell ~= s.mez.mezDebuffSpell then
                    s.mez.mezDebuffSpell = debuffSpell
                    Config.set('Mez', 'MezDebuffSpell', debuffSpell)
                    Config.save()
                end
                ImGui.TableSetColumnIndex(1)
                ImGui.TextDisabled('—')
                ImGui.TableSetColumnIndex(2)
                ImGui.Text('Debuff Spell')

                ImGui.EndTable()
            end
            ImGui.EndTabItem()
        end

        if s.session.iAmACharmClass then
            if ImGui.BeginTabItem('Charm') then
                ImGui.Spacing()
                checkbox('Charm Keep', s.charm.keep, function(v)
                    s.charm.keep = v
                    Config.set('Charm', 'CharmKeep', v and '1' or '0')
                    Config.save()
                end)

                ImGui.Spacing()
                intInput('Charm Radius##charm', s.charm.radius,   1, 500, 'Charm', 'CharmRadius',   function(v) s.charm.radius   = v end)
                intInput('Min Level##charm',    s.charm.minLevel, 1, 999, 'Charm', 'CharmMinLevel', function(v) s.charm.minLevel = v end)
                intInput('Max Level##charm',    s.charm.maxLevel, 0, 999, 'Charm', 'CharmMaxLevel', function(v) s.charm.maxLevel = v end)

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.PushItemWidth(220)
                local charmSpell, csc = ImGui.InputText('Charm Spell##charmspell', s.charm.spell, 0)
                if csc and charmSpell ~= s.charm.spell then
                    s.charm.spell = charmSpell
                    Config.set('Charm', 'CharmSpell', charmSpell)
                    Config.save()
                end
                ImGui.PopItemWidth()
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    end
end

function CC.init(state)
    _state = state
end

return CC
