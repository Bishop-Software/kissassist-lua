-- ui/bard.lua — Bard tab (class-gated): medley controls + song set editor.

local mq = require('mq')

local BardUI = {}
local _state

-- Render an editable song list for one MQ2Medley set.
-- songs: the State.bard.*Songs array; each entry is {name,dur,cond} (mutated in place).
-- setName: the MQ2Medley section name (e.g. 'ooc').
-- entry.cond stores a KCondition reference ('cond001' etc.); bard.saveSongSet
-- resolves it to the actual expression when writing the MQ2 char INI.
local function drawSongSet(songs, setName)
    local bard    = _state.bard
    local changed = false

    -- Build condition labels from KConditions array (same pattern as Buffs/Heals tabs).
    local condLabels = { '(none)' }
    for j = 1, (_state.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('songs_' .. setName, 4, tblFlags) then
        ImGui.TableSetupColumn('Song',      ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Dur (s)',   ImGuiTableColumnFlags.WidthFixed,  90)
        ImGui.TableSetupColumn('Condition', ImGuiTableColumnFlags.WidthFixed, 150)
        ImGui.TableSetupColumn('',          ImGuiTableColumnFlags.WidthFixed,  30)
        ImGui.TableHeadersRow()

        for i = 1, #songs do
            local entry = songs[i]
            -- Upgrade legacy plain-string entries on first render.
            if type(entry) ~= 'table' then
                entry = { name = tostring(entry or ''), dur = '', cond = '' }
                songs[i] = entry
            end

            ImGui.TableNextRow()

            -- Song name (stretches to fill available width)
            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local newName, ne = ImGui.InputText(('##sname_%s_%d'):format(setName, i), entry.name or '', 0)
            ImGui.PopItemWidth()
            if ne and newName ~= entry.name then entry.name = newName; changed = true end

            -- Duration expression hint (e.g. "30" or "${Medley.Tune}+30").
            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local newDur, de = ImGui.InputText(('##sdur_%s_%d'):format(setName, i), entry.dur or '', 0)
            ImGui.PopItemWidth()
            if de and newDur ~= entry.dur then entry.dur = newDur; changed = true end

            -- Condition — same cond001/cond002 dropdown as Buffs/Heals/Aggro tabs.
            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo    = tonumber((entry.cond or ''):lower():match('cond(%d+)')) or 0
            local newCondIdx, cc = ImGui.Combo(('##scond_%s_%d'):format(setName, i), condNo + 1, condLabels)
            ImGui.PopItemWidth()
            if cc then
                entry.cond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
                changed    = true
            end

            -- Remove button
            ImGui.TableNextColumn()
            if ImGui.Button('[-]##songrem_' .. setName .. '_' .. i) then
                if i == #songs and #songs > 1 then
                    songs[i] = nil
                else
                    table.remove(songs, i)
                end
                changed = true
            end
        end

        ImGui.EndTable()
    end

    ImGui.Spacing()
    local maxSongs = mq.TLO.Me.NumGems() or 13
    local atMax = #songs >= maxSongs
    if atMax then ImGui.BeginDisabled() end
    if ImGui.Button('[+ Add]##songadd_' .. setName) then
        songs[#songs + 1] = { name = '', dur = '', cond = '' }
    end
    if atMax then ImGui.EndDisabled() end
    ImGui.SameLine()
    if ImGui.Button('Apply##songapply_' .. setName) then
        changed = true
    end

    if changed and bard.saveSongSet then
        local clean = {}
        for _, s in ipairs(songs) do
            local n = type(s) == 'table' and (s.name or '') or tostring(s or '')
            if n ~= '' then clean[#clean + 1] = s end
        end
        for k in pairs(songs) do songs[k] = nil end
        for i2, s in ipairs(clean) do songs[i2] = s end
        bard.saveSongSet(setName, clean)
    end
end

function BardUI.drawBard()
    ---@diagnostic disable-next-line: undefined-field
    local Medley   = mq.TLO.Medley
    local bard     = _state.bard
    local active    = Medley and (Medley.Active() or false) or false
    local activeSet = Medley and (Medley.Medley() or '—') or '—'

    ImGui.Text(string.format('Active set: %s  (%s)', activeSet, active and 'playing' or 'stopped'))
    ImGui.Separator()

    -- Set switch buttons
    if ImGui.Button(bard.meleeMedley) then mq.cmdf('/medley %s', bard.meleeMedley) end
    ImGui.SameLine()
    if ImGui.Button(bard.burnMedley)  then mq.cmdf('/medley %s', bard.burnMedley)  end
    ImGui.SameLine()
    if ImGui.Button(bard.oocMedley)   then mq.cmdf('/medley %s', bard.oocMedley)   end

    -- Start / Stop
    ImGui.Spacing()
    if ImGui.Button('Start') then
        _state.bard.manualStop  = false
        _state.bard.twisting    = false
        _state.bard.dpsTwisting = false
        mq.cmd('/medley start')
    end
    ImGui.SameLine()
    if ImGui.Button('Stop') then
        _state.bard.manualStop = true
        mq.cmd('/medley stop')
    end

    -- Quiet mode toggle
    ImGui.SameLine()
    local quietVal, quietChanged = ImGui.Checkbox('Quiet##medleyquiet', bard.medleyQuiet)
    if quietChanged then
        mq.cmd('/medley quiet')
        _state.bard.medleyQuiet = quietVal
    end

    -- Song set editor sub-tabs
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    if not bard.mqIniPath then
        ImGui.TextColored(1, 1, 0, 1, 'MQ2 char INI not found — song set editor unavailable.')
        ImGui.TextDisabled('Expected ServerName_CharName.ini in MQ2 config directory.')
        return
    end

    local sets = {
        { label = 'OOC',   songs = bard.oocSongs,   setName = bard.oocMedley   },
        { label = 'Melee', songs = bard.meleeSongs, setName = bard.meleeMedley },
        { label = 'Burn',  songs = bard.burnSongs,  setName = bard.burnMedley  },
        { label = 'GoM',   songs = bard.gomSongs,   setName = bard.gomMedley   },
    }

    if ImGui.BeginTabBar('BardSongSets') then
        for _, set in ipairs(sets) do
            if ImGui.BeginTabItem(set.label) then
                ImGui.Spacing()
                if #set.songs == 0 then
                    ImGui.TextDisabled(string.format('No songs in [MQ2Medley-%s]. Use [+ Add] to add one.', set.setName))
                    ImGui.Spacing()
                    if ImGui.Button('[+ Add]##songadd_' .. set.setName) then
                        set.songs[1] = { name = '', dur = '', cond = '' }
                    end
                else
                    drawSongSet(set.songs, set.setName)
                end
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    end
end

function BardUI.init(state)
    _state = state
end

return BardUI
