-- ui/support.lua — Support tab: Pet + Merc sub-tabs.

local mq = require('mq')
local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local intInput = Helpers.intInput

local SupportUI = {}
local _state

-- ---------------------------------------------------------------------------
-- Pet panel
-- ---------------------------------------------------------------------------

function SupportUI.drawPet()
    local s = _state

    if ImGui.BeginTabBar('KAPetTabs') then
        -- Controls sub-tab
        if ImGui.BeginTabItem('Controls##pet') then
            ImGui.Spacing()

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
            ImGui.EndTabItem()
        end

        -- Pet Buffs sub-tab
        if ImGui.BeginTabItem('Pet Buffs##pet') then
            ImGui.Spacing()

            local petBuffsRaw  = Config.get('Pet', 'PetBuffs',     nil) or {}
            local petBuffsSize = tonumber(Config.get('Pet', 'PetBuffsSize', '5')) or 5

            local function syncPetBuffsArray()
                s.buffs.petBuffsArray = {}
                for _, slot in ipairs(Config.parseCondArray(petBuffsRaw)) do
                    if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                        s.buffs.petBuffsArray[#s.buffs.petBuffsArray + 1] = slot
                    end
                end
            end

            local pbTblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
            if ImGui.BeginTable('petbuffs_tbl', 2, pbTblFlags) then
                ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
                ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
                ImGui.TableHeadersRow()

                for i = 1, petBuffsSize do
                    local raw     = petBuffsRaw[i] or 'null'
                    local isEmpty = (raw == 'null' or raw == '')
                    local spell   = isEmpty and '' or raw

                    ImGui.TableNextColumn()
                    ImGui.PushItemWidth(-1)
                    local newSpell, sc = ImGui.InputText('##pbspell' .. i, spell, 0)
                    ImGui.PopItemWidth()

                    ImGui.TableNextColumn()
                    if ImGui.Button('[-]##pbrem' .. i) then
                        if i == petBuffsSize and petBuffsSize > 1 then
                            petBuffsRaw[i] = nil
                            petBuffsSize   = petBuffsSize - 1
                            Config.set('Pet', 'PetBuffsSize', tostring(petBuffsSize))
                        else
                            petBuffsRaw[i] = 'null'
                        end
                        Config.set('Pet', 'PetBuffs', petBuffsRaw)
                        Config.save()
                        syncPetBuffsArray()
                    end

                    if sc then
                        petBuffsRaw[i] = newSpell ~= '' and newSpell or 'null'
                        Config.set('Pet', 'PetBuffs', petBuffsRaw)
                        Config.save()
                        syncPetBuffsArray()
                    end
                end
                ImGui.EndTable()
            end

            ImGui.Spacing()
            if ImGui.Button('[+ Add]##pbuffsadd') then
                petBuffsSize = petBuffsSize + 1
                petBuffsRaw[petBuffsSize] = 'null'
                Config.set('Pet', 'PetBuffsSize', tostring(petBuffsSize))
                Config.set('Pet', 'PetBuffs', petBuffsRaw)
                Config.save()
            end
            ImGui.EndTabItem()
        end

        -- Pet Toys sub-tab
        if ImGui.BeginTabItem('Pet Toys##pet') then
            ImGui.Spacing()

            local petToysRaw  = Config.get('Pet', 'PetToys',     nil) or {}
            local petToysSize = tonumber(Config.get('Pet', 'PetToysSize', '5')) or 5

            local function syncPetToysArray()
                s.pet.toysArray = {}
                for _, v in ipairs(petToysRaw) do
                    if v and v ~= '' and v ~= 'null' then
                        s.pet.toysArray[#s.pet.toysArray + 1] = v
                    end
                end
            end

            local ptTblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
            if ImGui.BeginTable('pettoys_tbl', 2, ptTblFlags) then
                ImGui.TableSetupColumn('Item', ImGuiTableColumnFlags.WidthStretch, 0)
                ImGui.TableSetupColumn('',     ImGuiTableColumnFlags.WidthFixed,    32)
                ImGui.TableHeadersRow()

                for i = 1, petToysSize do
                    local raw     = petToysRaw[i] or 'null'
                    local isEmpty = (raw == 'null' or raw == '')
                    local item    = isEmpty and '' or raw

                    ImGui.TableNextColumn()
                    ImGui.PushItemWidth(-1)
                    local newItem, ic = ImGui.InputText('##ptitem' .. i, item, 0)
                    ImGui.PopItemWidth()

                    ImGui.TableNextColumn()
                    if ImGui.Button('[-]##ptrem' .. i) then
                        if i == petToysSize and petToysSize > 1 then
                            petToysRaw[i] = nil
                            petToysSize   = petToysSize - 1
                            Config.set('Pet', 'PetToysSize', tostring(petToysSize))
                        else
                            petToysRaw[i] = 'null'
                        end
                        Config.set('Pet', 'PetToys', petToysRaw)
                        Config.save()
                        syncPetToysArray()
                    end

                    if ic then
                        petToysRaw[i] = newItem ~= '' and newItem or 'null'
                        Config.set('Pet', 'PetToys', petToysRaw)
                        Config.save()
                        syncPetToysArray()
                    end
                end
                ImGui.EndTable()
            end

            ImGui.Spacing()
            if ImGui.Button('[+ Add]##ptoysadd') then
                petToysSize = petToysSize + 1
                petToysRaw[petToysSize] = 'null'
                Config.set('Pet', 'PetToysSize', tostring(petToysSize))
                Config.set('Pet', 'PetToys', petToysRaw)
                Config.save()
            end
            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end
end

-- ---------------------------------------------------------------------------
-- Merc panel
-- ---------------------------------------------------------------------------

function SupportUI.drawMerc()
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

function SupportUI.init(state)
    _state = state
end

return SupportUI
