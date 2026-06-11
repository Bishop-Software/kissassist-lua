local mq     = require('mq')
local Config = require('modules.config')

local Buffs = {}
local _state, _utils, _cast, _heal, _comms, _cond

-- Dual tag set used in buffToCheck resolution and target-type dispatch.
local DUAL_TAGS = {
    Dual=true, DualMA=true, DualMelee=true, DualCaster=true,
    DualClass=true, ['Dual!Class']=true, DualMgb=true, Dualme=true,
}

-- Class sets for |caster / |Melee filter tags (mac:4538).
local CASTER_CLASSES = { CLR=true, DRU=true, SHM=true, BST=true, ENC=true, MAG=true, NEC=true, PAL=true, SHD=true, RNG=true, WIZ=true }
local MELEE_CLASSES  = { BRD=true, BER=true, BST=true, MNK=true, PAL=true, ROG=true, RNG=true, SHD=true, WAR=true }

-- Tag set that implies single-target filtering; suppresses no-group fallback (mac:4614).
local CLASS_FILTER_TAGS = {
    MA=true, ['!MA']=true, Melee=true, caster=true,
    DualMA=true, DualMelee=true, DualCaster=true,
    ['class']=true, ['!class']=true, DualClass=true, ['Dual!Class']=true,
}

local function classInList(shortName, classList)
    for cls in (classList .. ','):gmatch('([^,]+),') do
        if cls == shortName then return true end
    end
    return false
end

-- Class sets for |Endgroup / |Managroup stat-regen dispatch (mac:5160-5165).
local REGEN_END_CLASSES  = {BER=true,BST=true,MNK=true,PAL=true,RNG=true,ROG=true,SHD=true,WAR=true}
local REGEN_MANA_CLASSES = {BRD=true,BST=true,CLR=true,DRU=true,ENC=true,MAG=true,NEC=true,PAL=true,RNG=true,SHD=true,SHM=true,WIZ=true}

-- Parse pipe-delimited string by 1-based index (mac Arg[n,|] equivalent).
local function getListArg(list, idx)
    local count = 0
    for part in (list .. '|'):gmatch('([^|]*)|') do
        count = count + 1
        if count == idx then return part end
    end
    return ''
end

-- Mirrors Sub RegenOther (mac:5153): find lowest-stat group member and cast regen spell.
-- stat: 'Endurance' or 'Mana'. statPct: skip members above this threshold.
-- Returns true on CAST_SUCCESS.
local function regenOther(spellName, stat, statPct)
    if mq.TLO.Me.Invis() then return false end
    local classSet = (stat == 'Endurance') and REGEN_END_CLASSES or REGEN_MANA_CLASSES
    local groupCount = mq.TLO.Group.Members() or 0
    for j = 1, groupCount do
        local memberID = mq.TLO.Group.Member(j).ID() or 0
        if memberID == 0 then goto rgcontinue end
        local cls = mq.TLO.Group.Member(j).Class.ShortName() or ''
        if not classSet[cls] then goto rgcontinue end
        if (_state.combat.aggroTargetID or '') ~= '' then return false end
        if spellName:find('Rallying Call', 1, true) then
            local maID = (_state.session.mainAssist ~= '')
                     and (mq.TLO.Spawn('PC ' .. _state.session.mainAssist).ID() or 0) or 0
            if memberID == maID then goto rgcontinue end
        end
        if cls == 'BRD' and (spellName == 'Dichotomic Psalm' or spellName == 'Quiet Miracle') then
            goto rgcontinue
        end
        local curStat = (stat == 'Endurance')
            and (tonumber(mq.TLO.Group.Member(j).CurrentEndurance()) or 0)
            or  (tonumber(mq.TLO.Group.Member(j).CurrentMana())      or 0)
        if curStat <= statPct and curStat >= 1 then
            local result = _cast.castWhat(spellName, memberID, 'Regenother')
            if result == 'CAST_SUCCESS' then
                printf('\awCasting \at%s\aw on \at%s\aw for %s.',
                    spellName, mq.TLO.Group.Member(j).CleanName() or '', stat)
                return true
            end
        end
        ::rgcontinue::
    end
    return false
end

-- Mirrors Sub CheckAura (mac:4742): cast aura spell if the aura slot doesn't match.
local function checkAura(spellName)
    if mq.TLO.Me.Invis() then return end
    local auraName = spellName
    local rkPos = spellName:find(' Rk.', 1, true)
    if rkPos then auraName = spellName:sub(1, rkPos - 1) end
    local tempAura = ''
    if     spellName:find("Disciple's Aura",       1, true) then auraName  = 'Disciples Aura'
    elseif mq.TLO.Me.Class.Name() == 'Cleric'
       and spellName:find('Reverent',               1, true) then auraName  = 'Reverent Aura'
    elseif spellName:find('Mana Reiteration',       1, true) then auraName  = 'Mana Recursion Aura'
    elseif spellName:find('Mana Reiterate',         1, true) then auraName  = 'Mana Reiterate Aura'
    elseif spellName:find('Mana Reverberation',     1, true) then auraName  = 'Mana Rev.'
    elseif spellName:find('Mana Resurgence',        1, true) then auraName  = 'Mana Resurgence Aura'
    elseif spellName:find('Mana Repercussion Aura', 1, true) then auraName  = 'Mana Rep. Aura'
    elseif spellName:find('Runic Radiance Aura',    1, true) then auraName  = 'Runic Rad. Aura'
    elseif spellName:find('Arcane Distillect',      1, true) then tempAura  = 'Arcane Distillect'
    elseif spellName:find('Earthen Strength',       1, true) then tempAura  = 'Earthen Strength Effect'
    elseif spellName:find("Rathe's Strength",       1, true) then tempAura  = "Rathe's Strength Effect"
    end
    local cls   = mq.TLO.Me.Class.ShortName() or ''
    local aura1 = mq.TLO.Me.Aura(1).Name() or ''
    local aura2 = mq.TLO.Me.Aura(2).Name() or ''
    if cls == 'MAG' and tempAura ~= '' then
        if aura1:find(tempAura, 1, true) then return end
        if (mq.TLO.Me.Pet.ID() or 0) ~= 0 and (mq.TLO.Me.Pet.Distance() or 999) < 175 then
            for k = 1, 50 do
                if (mq.TLO.Me.PetBuff(k).Name() or ''):find(tempAura, 1, true) then return end
            end
        end
    elseif cls == 'CLR' or cls == 'ENC' then
        if aura1:find(auraName, 1, true) or aura2:find(auraName, 1, true) then return end
    else
        if aura1:find(auraName, 1, true) then return end
    end
    local DISC_AURA = {BER=true, MNK=true, ROG=true, WAR=true}
    if DISC_AURA[cls] and (mq.TLO.Me.CurrentEndurance() or 0) > 500 then
        mq.cmd(string.format('/disc "%s"', spellName))
        mq.delay(1000)
        while (mq.TLO.Me.Casting.ID() or 0) ~= 0 do mq.delay(250) end
    else
        _cast.castWhat(spellName, mq.TLO.Me.ID(), 'CheckAura')
    end
end

-- Mirrors Sub BuffOnce (mac:4727): cast once; returns true on CAST_SUCCESS so caller
-- can set the entry to spellName|0.
local function buffOnce(spellName)
    if mq.TLO.Me.Invis() then return false end
    return _cast.castWhat(spellName, mq.TLO.Me.ID(), 'BuffOnce') == 'CAST_SUCCESS'
end

-- Mirrors Sub SummonStuff (mac:4839): cast a summon spell until itemName count >= minCount.
-- INI format: Spell|summon|ItemName|MinCount
local function summonStuff(spellName, itemName, minCount)
    if mq.TLO.Me.Invis() then return 'CAST_CANCELLED' end
    if (mq.TLO.FindItemCount('=' .. itemName)() or 0) >= minCount then return 'CAST_SUCCESS' end
    local attempts = 0
    while (mq.TLO.FindItemCount('=' .. itemName)() or 0) < minCount do
        if (mq.TLO.Me.FreeInventory() or 0) == 0 then
            printf('\aw[KA] No free inventory — skipping summon of %s', itemName)
            break
        end
        -- If spellName is itself an item clicky, check its recast timer
        if (mq.TLO.FindItemCount('=' .. spellName)() or 0) > 0
                and (mq.TLO.FindItem('=' .. spellName).Timer() or 0) ~= 0 then
            return 'CAST_NOT_READY'
        end
        if (mq.TLO.Cursor.ID() or 0) ~= 0 then mq.cmd('/autoinventory') end
        local result = _cast.castWhat(spellName, mq.TLO.Me.ID(), 'buffs-nomem')
        if result == 'CAST_SUCCESS' then
            local t = os.clock() + 5
            while os.clock() < t and (mq.TLO.Cursor.ID() or 0) == 0 do mq.delay(100) end
            if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                mq.cmd('/autoinventory')
                attempts = attempts + 1
            elseif attempts > 0 then
                printf('\aw[KA] Summon %s failed — check reagents/timer', itemName)
                return 'CAST_COMPONENTS'
            end
        elseif result == 'CAST_COMPONENTS' then
            return 'CAST_COMPONENTS'
        else
            break
        end
        if attempts > 5 then break end
    end
    return 'CAST_SUCCESS'
end

-- Mirrors Sub CheckEndurance (mac:4820): cast endurance disc/AA on self.
local function checkEndurance(spellName)
    if mq.TLO.Me.Invis() then return end
    if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    local result = _cast.castWhat(spellName, mq.TLO.Me.ID(), 'CheckEndurance')
    if result == 'CAST_SUCCESS' then
        printf('\awCasting \at%s\aw for endurance.', spellName)
    end
end

local BUFFS_FILE  = 'KissAssist_Buffs.ini'
local PET_ROLES   = { pettank=true, pullerpettank=true, hunterpettank=true }

-- Mirrors Sub CleanBuffsFile (mac:12425).
-- Removes entries from KissAssist_Buffs.ini that are from a different day or hour.
local function cleanBuffsFile()
    if _state.timers.cleanBuffs > os.clock() then return end
    local sectionStr = mq.TLO.Ini(BUFFS_FILE)() or ''
    local t = os.date('*t')
    local today = tostring(t.day)
    local hour  = tostring(t.hour)
    for section in sectionStr:gmatch('([^|]+)') do
        local entryDay = mq.TLO.Ini(BUFFS_FILE, section, 'Day')() or ''
        if entryDay ~= '' and entryDay ~= today then
            mq.cmd(string.format('/ini "%s" %s NULL NULL', BUFFS_FILE, section))
        elseif entryDay ~= '' then
            local entryHour = mq.TLO.Ini(BUFFS_FILE, section, 'Hour')() or ''
            if entryHour ~= '' and entryHour ~= hour then
                mq.cmd(string.format('/ini "%s" %s NULL NULL', BUFFS_FILE, section))
            end
        end
    end
    _state.timers.cleanBuffs = os.clock() + 600
end

-- Mirrors Sub WriteBuffs (mac:17072).
-- Broadcasts buff list via actors every 30s OOC so Lua chars sync without the INI file.
-- When danNetOn=true (mixed Lua/.mac group), also writes KissAssist_Buffs.ini for .mac chars.
function Buffs.writeBuffs()
    if _state.timers.writeBuffs > os.clock() then return end
    if not _state.misc.redguides then return end
    if (_state.combat.aggroTargetID or '') ~= '' then return end
    -- danNetOn guard removed: actors broadcast replaces INI for all-Lua groups;
    -- INI write is gated on danNetOn below for the mixed migration window.
    if mq.TLO.EverQuest.GameState() ~= 'INGAME' then return end

    -- blockedBuffsCount: state.lua defaults to 30 (emu); live servers use 40 (mac:17083-17087)

    local id   = tostring(mq.TLO.Me.ID() or 0)
    local zone = tostring(mq.TLO.Zone.ID() or 0)

    -- Collect buff list: slots 1..41, strip ':Permanent' suffix (mac:17098-17105)
    local bufflist  = ''
    local buffCount = 0
    for i = 1, 41 do
        local name = mq.TLO.Me.Buff(i).Name() or ''
        if name ~= '' and name ~= 'null' then
            local perm = name:find(':Permanent', 1, true)
            if perm and perm > 1 then name = name:sub(1, perm - 1) end
            bufflist  = bufflist .. name .. '|'
            buffCount = buffCount + 1
        end
    end

    -- Collect blocked buff list (mac:17109-17115)
    local blockedlist  = ''
    local blockedCount = 0
    for k = 1, _state.buffs.blockedBuffsCount do
        local name = mq.TLO.Me.BlockedBuff(k).Name() or ''
        if name ~= '' and name ~= 'null' then
            blockedlist  = blockedlist .. name .. '|'
            blockedCount = blockedCount + 1
        end
    end

    -- Actors broadcast: received by other Lua chars and stored in state.buffs.remote[charName]
    if _comms then
        _comms.broadcast('BUFFS', {
            charName    = mq.TLO.Me.CleanName() or '',
            role        = _state.session.role,
            buffList    = bufflist,
            blockedList = blockedlist,
            zone        = zone,
        })
        _comms.broadcastBuffState()
    end

    -- INI write: only when DanNet shim is active so .mac chars can still read it
    if _state.session.danNetOn then
        cleanBuffsFile()
        local t    = os.date('*t')
        local day  = tostring(t.day)
        local hour = tostring(t.hour)
        if not mq.TLO.Ini(BUFFS_FILE, id, 'Day')()  then mq.cmd(string.format('/ini "%s" %s Day %s',  BUFFS_FILE, id, day))  end
        if not mq.TLO.Ini(BUFFS_FILE, id, 'Hour')() then mq.cmd(string.format('/ini "%s" %s Hour %s', BUFFS_FILE, id, hour)) end
        if not mq.TLO.Ini(BUFFS_FILE, id, 'Zone')() then
            mq.cmd(string.format('/ini "%s" %s Zone %s', BUFFS_FILE, id, zone))
        end
        if not mq.TLO.Ini(BUFFS_FILE, id, 'Buffs')()        then mq.cmd(string.format('/ini "%s" %s Buffs ""',        BUFFS_FILE, id)) end
        if not mq.TLO.Ini(BUFFS_FILE, id, 'Blockedbuffs')() then mq.cmd(string.format('/ini "%s" %s Blockedbuffs ""', BUFFS_FILE, id)) end
        mq.cmd(string.format('/ini "%s" %s AmILooting 0', BUFFS_FILE, id))
        mq.cmd(string.format('/ini "%s" %s MyRole %s',    BUFFS_FILE, id, _state.session.role))
        mq.cmd(string.format('/ini "%s" %s Buffs "%s"', BUFFS_FILE, id, bufflist))
        if blockedlist ~= '' then
            mq.cmd(string.format('/ini "%s" %s Blockedbuffs "%s"', BUFFS_FILE, id, blockedlist))
        end
    end

    _state.timers.writeBuffs = os.clock() + 30
    _utils.debug('buffs', 'Buffs.writeBuffs: id=%s buffs=%d blocked=%d', id, buffCount, blockedCount)
end

-- Mirrors Sub WriteBuffsPet (mac:12364).
-- Writes pet's buff list to KissAssist_Buffs.ini; pettank roles only.
function Buffs.writeBuffsPet()
    if (mq.TLO.Me.Pet.ID() or 0) == 0 then return end
    if not PET_ROLES[_state.session.role] then return end
    if (_state.combat.aggroTargetID or '') ~= '' then return end
    if _state.timers.writeBuffsPet > os.clock() then return end
    if _state.session.danNetOn then return end
    if not _state.misc.redguides then return end

    cleanBuffsFile()

    local id  = tostring(mq.TLO.Me.Pet.ID())
    local t   = os.date('*t')
    local day = tostring(t.day)
    local hr  = tostring(t.hour)

    if not mq.TLO.Ini(BUFFS_FILE, id, 'Day')()  then mq.cmd(string.format('/ini "%s" %s Day %s',  BUFFS_FILE, id, day)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Hour')() then mq.cmd(string.format('/ini "%s" %s Hour %s', BUFFS_FILE, id, hr))  end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Zone')() then
        mq.cmd(string.format('/ini "%s" %s Zone %s', BUFFS_FILE, id, tostring(mq.TLO.Zone.ID() or 0)))
    end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Buffs')() then mq.cmd(string.format('/ini "%s" %s Buffs ""', BUFFS_FILE, id)) end

    -- Pet buffs via Me.PetBuff (no targeting needed; mac:12395-12406)
    local bufflist = ''
    local buffCount = 0
    for i = 1, 50 do
        local name = mq.TLO.Me.PetBuff(i).Name() or ''
        if name ~= '' then
            bufflist  = bufflist .. name .. '|'
            buffCount = buffCount + 1
        end
    end
    mq.cmd(string.format('/ini "%s" %s Buffs "%s"', BUFFS_FILE, id, bufflist))

    -- Blocked pet buffs: slots 0..39 (mac:12410-12416)
    local blockedlist = ''
    for k = 0, 39 do
        local name = mq.TLO.Me.BlockedPetBuff(k).Name() or ''
        if name ~= '' and name ~= 'null' then
            blockedlist = blockedlist .. name .. '|'
        end
    end
    if blockedlist ~= '' then
        mq.cmd(string.format('/ini "%s" %s Blockedbuffs "%s"', BUFFS_FILE, id, blockedlist))
    end

    _state.timers.writeBuffsPet = os.clock() + 30
    _utils.debug('buffs', 'Buffs.writeBuffsPet: id=%s buffs=%d', id, buffCount)
end

-- Mirrors Sub WriteBuffsMerc (mac:12318).
-- Writes mercenary's buff list to KissAssist_Buffs.ini.
function Buffs.writeBuffsMerc()
    if mq.TLO.Mercenary.State() ~= 'Active' then return end
    if (_state.combat.aggroTargetID or '') ~= '' then return end
    if _state.timers.writeBuffsMerc > os.clock() then return end
    if _state.session.danNetOn then return end
    if not _state.misc.redguides then return end
    if mq.TLO.EverQuest.GameState() ~= 'INGAME' then return end

    cleanBuffsFile()

    local id  = tostring(mq.TLO.Mercenary.ID() or 0)
    local t   = os.date('*t')
    local day = tostring(t.day)
    local hr  = tostring(t.hour)

    if not mq.TLO.Ini(BUFFS_FILE, id, 'Day')()  then mq.cmd(string.format('/ini "%s" %s Day %s',  BUFFS_FILE, id, day)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Hour')() then mq.cmd(string.format('/ini "%s" %s Hour %s', BUFFS_FILE, id, hr))  end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Zone')() then
        mq.cmd(string.format('/ini "%s" %s Zone %s', BUFFS_FILE, id, tostring(mq.TLO.Zone.ID() or 0)))
    end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Buffs')() then mq.cmd(string.format('/ini "%s" %s Buffs ""', BUFFS_FILE, id)) end

    -- Merc buffs: slots 1..15 via Mercenary.Buff (mac:12343-12355)
    -- Note: mac targets merc first to populate buffs; Mercenary.Buff TLO may not require it in Lua
    local bufflist = ''
    local buffCount = 0
    for i = 1, 15 do
        local name = mq.TLO.Mercenary.Buff(i).Name() or ''
        if name ~= '' then
            bufflist  = bufflist .. name .. '|'
            buffCount = buffCount + 1
        end
    end
    mq.cmd(string.format('/ini "%s" %s Buffs "%s"', BUFFS_FILE, id, bufflist))

    _state.timers.writeBuffsMerc = os.clock() + 30
    _utils.debug('buffs', 'Buffs.writeBuffsMerc: id=%s buffs=%d', id, buffCount)
end

-- Mirrors Sub CastMount (mac:13875). Scans buffsArray for |Mount entries and casts on self.
-- Public so init.lua can call it after rez (mac:6906/6968).
function Buffs.castMount()
    if not _state.misc.mountOn then return end
    if (mq.TLO.Me.Mount.ID() or 0) ~= 0 then return end
    if mq.TLO.Me.CombatState() == 'COMBAT' then return end
    local zType = mq.TLO.Zone.Type()
    if not mq.TLO.Zone.Outdoor() and zType ~= 1 and zType ~= 2 and zType ~= 5 then return end
    for _, slot in ipairs(_state.buffs.buffsArray) do
        if (mq.TLO.Me.Mount.ID() or 0) ~= 0 then break end
        if not slot then goto mcontinue end
        local entry = slot.name or ''
        if entry:find('|0', 1, true) then goto mcontinue end
        local parts = {}
        for part in (entry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = part end
        if (parts[2] or '') ~= 'mount' then goto mcontinue end
        local spellName = parts[1] or ''
        if spellName == '' then goto mcontinue end
        if mq.TLO.Me.FeetWet() then goto mcontinue end
        local condNo = slot.condNo or 0
        if condNo > 0 and _cond and not _cond.eval(condNo) then goto mcontinue end
        _cast.castWhat(spellName, mq.TLO.Me.ID(), 'CastMount')
        ::mcontinue::
    end
end

-- Mirrors Sub CastMana (mac:13892). Scans buffsArray for |mana entries and casts on self.
-- Called from combat loop and OOC main loop independently of the full checkBuffs cycle.
function Buffs.castMana()
    if mq.TLO.Me.Invis() then return end
    if _state.timers.justZoned > os.clock() then return end
    if (mq.TLO.Me.Buff('Revival Sickness').ID() or 0) ~= 0 then return end

    for i, slot in ipairs(_state.buffs.buffsArray) do
        if not slot then goto mncontinue end
        local entry = slot.name or ''
        if entry:find('|0', 1, true) then goto mncontinue end

        local parts = {}
        for part in (entry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = part end
        if (parts[2] or '') ~= 'mana' then goto mncontinue end

        local spellName  = parts[1] or ''
        if spellName == '' then goto mncontinue end

        local manaThresh = tonumber(parts[3]) or 0
        local hpFloor    = tonumber(parts[4]) or 0
        local pctMana    = tonumber(mq.TLO.Me.PctMana()) or 100
        local pctHPs     = tonumber(mq.TLO.Me.PctHPs())  or 100
        if pctMana > manaThresh or pctHPs <= hpFloor then goto mncontinue end

        -- Bard: skip Dichotomic Psalm when endurance is sufficient (mac:13916)
        if spellName:find('Dichotomic Psalm', 1, true) then
            if (tonumber(mq.TLO.Me.CurrentEndurance()) or 0) >= 6600 then goto mncontinue end
        end

        -- Per-slot cooldown: skip if Druid Growth timer still active (mac:13919 BufXGM0 check)
        if _state.buffs.slotTimers[i] and (_state.buffs.slotTimers[i][0] or 0) > os.clock() then
            goto mncontinue
        end

        local result = _cast.castWhat(spellName, mq.TLO.Me.ID(), 'CastMana')
        if result == 'CAST_SUCCESS' then
            -- Druid Growth: set per-slot cooldown to spell duration + 5s (mac:13926)
            if mq.TLO.Me.Class.ShortName() == 'DRU'
                and spellName:find('Growth', 1, true)
                and (mq.TLO.Spell(spellName).Skill() or '') == 'Conjuration' then
                if not _state.buffs.slotTimers[i] then
                    _state.buffs.slotTimers[i] = {}
                    for j = 0, 5 do _state.buffs.slotTimers[i][j] = 0 end
                end
                local dur = tonumber(mq.TLO.Spell(spellName).Duration.TotalSeconds()) or 0
                _state.buffs.slotTimers[i][0] = os.clock() + dur + 5
            end
            -- Stop scanning if aggro fires mid-cast (mac:13929)
            local ag = _state.combat.aggroTargetID or ''
            if ag ~= '' and ag ~= '0' then break end
        elseif result == 'CAST_COMPONENTS' then
            mq.cmd(string.format('/echo Missing components for %s — disabling.', spellName))
            _state.buffs.buffsArray[i].name = 'NULL'
        end

        ::mncontinue::
    end
end

-- Mirrors PowerSource refuel block (mac:4192-4198).
-- If the PowerSource item has no charges, clicks it to cursor then destroys it to refill.
local function refuelPowerSource()
    local ps = _state.buffs.powerSource
    if ps == '' then return end
    local item = mq.TLO.Me.Inventory('powersource')
    if not item.Name() or item.Name() == '' then return end
    if item.Power() and item.Power() ~= 0 then return end
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then mq.cmd('/autoinventory') end
    mq.cmd(string.format('/itemnotify "%s" leftmouseup', ps))
    mq.delay(5000, function() return (mq.TLO.Cursor.ID() or 0) ~= 0 end)
    if mq.TLO.Cursor.Name() == ps then
        mq.cmd('/destroy')
        mq.delay(5000, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
end

-- Mirrors Sub CheckBuffs (mac:4170-4660).
-- Guards → PowerSource refuel → mount cast → per-entry loop.
-- Step 6.3: entry parsing + group-v + self target-type dispatch.
-- Steps 6.4/6.5: single-target group iteration and special tags — stubs only here.
function Buffs.checkBuffs(forceGroup)
    forceGroup = forceGroup or false

    -- Guards (mac:4171)
    if not _state.buffs.buffsOn then return end
    if _state.misc.iAmDead then return end
    if mq.TLO.Me.Hovering() then return end
    if (mq.TLO.Me.Casting.ID() or 0) ~= 0 or mq.TLO.Window('CastingWindow').Open() then return end
    if mq.TLO.Me.Invis() and mq.TLO.Me.Class.Name() ~= 'Rogue' then return end
    if _state.movement.chaseAssist and mq.TLO.Me.Moving() then return end
    if mq.TLO.Me.Moving() and _state.movement.whoToChase == mq.TLO.Me.Name() then return end

    -- PowerSource refuel (mac:4192)
    refuelPowerSource()

    -- Mount cast (mac:4200)
    Buffs.castMount()

    local savedTargetID = mq.TLO.Target.ID() or 0

    -- Per-entry loop (mac:4207)
    for i, slot in ipairs(_state.buffs.buffsArray) do
        if not slot then goto continue end
        local entry = slot.name or ''
        if mq.TLO.Me.Invis() then return end

        -- Drain events (mac:4208-4211)
        mq.doevents()

        -- CalledTargetID sync deferred (mac:4212 CombatTargetCheck call — M7+)

        -- Aggro bail (mac:4213)
        local aggroID = _state.combat.aggroTargetID
        if aggroID ~= '' and aggroID ~= '0' then
            local aggroNum = tonumber(aggroID) or 0
            if aggroNum ~= 0 then
                local aggroSpawn = mq.TLO.Spawn(aggroNum)
                if aggroSpawn and (aggroSpawn.Distance() or 999) < 200 then return end
            end
        end

        -- |0 skip (mac:4214)
        if entry:find('|0', 1, true) then goto continue end

        -- Interleaved cure / heal / rez (mac:4218-4227)
        if _state.heal.curesOn > 0 then
            _heal.checkCures('Combat')
        elseif _state.heal.healsOn > 0 then
            if _state.timers.lastHealCheck <= os.clock() then
                _heal.checkHealth('CheckBuffs')
                if _state.heal.healInterval > 0 then
                    _state.timers.lastHealCheck = os.clock() + _state.heal.healInterval
                end
            end
        elseif _state.heal.autoRezOn > 0 then
            _heal.rezCheck('group')
        end

        -- Null skip (mac:4228)
        if entry == 'null' or entry == 'NULL' then goto continue end

        -- Entry parsing: |pipe-split, Dual normalization, alias/cond skip (mac:4233-4272)
        local spellToCast, p2, p3, p4, p5 = entry, '', '', '', ''
        local parts = {}
        for part in (entry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = part end

        if #parts >= 2 and (parts[2] or '') ~= '' then
            spellToCast = parts[1] or ''
            p2          = parts[2] or ''
            p3          = parts[3] or ''
            p4          = parts[4] or ''
            p5          = parts[5] or ''

            if p2 == 'Dual' then
                if     p4 == 'MA'     then p2 = 'DualMA'
                elseif p4 == 'melee'  then p2 = 'DualMelee'
                elseif p4 == 'caster' then p2 = 'DualCaster'
                elseif p4 == 'class'  then p2 = 'DualClass'
                elseif p4 == '!class' then p2 = 'Dual!Class'
                elseif p4 == 'mgb'    then p2 = 'DualMgb'
                elseif p4 == 'me'     then p2 = 'Dualme'
                end
            elseif p2 == 'class' or p2 == '!class' then
                p5 = p3
            elseif p2 == 'alias' then
                goto continue
            elseif p2:sub(1, 4) == 'cond' then
                p2 = ''
            end
        end

        -- buffToCheck resolution: non-gold strips " Rk." suffix (mac:4273-4293)
        local buffToCheck
        if not _state.misc.redguides then
            if not DUAL_TAGS[p2] then
                local rkPos = spellToCast:find(' Rk%.', 1)
                buffToCheck = rkPos and spellToCast:sub(1, rkPos - 1) or spellToCast
            else
                local rkPos = p3:find(' Rk%.', 1)
                buffToCheck = rkPos and p3:sub(1, rkPos - 1) or p3
            end
        else
            buffToCheck = DUAL_TAGS[p2] and p3 or spellToCast
        end

        -- bookSpellTT: TargetType from spellbook entry; '0' when not in book (mac:4295-4305)
        local bookSpellTT = '0'
        local bookSlot = mq.TLO.Me.Book(spellToCast)()
        if bookSlot and bookSlot ~= 0 then
            local bookID = mq.TLO.Me.Book(bookSlot).ID()
            if bookID and bookID ~= 0 then
                bookSpellTT = mq.TLO.Spell(bookID).TargetType() or '0'
            end
        end

        local spellRange = tonumber(mq.TLO.Spell(spellToCast).Range()) or 0
        local aeRange    = tonumber(mq.TLO.Spell(spellToCast).AERange()) or 0
        if aeRange > spellRange then spellRange = aeRange end
        if spellRange == 0 then spellRange = 100 end

        -- Combat / invis / readBuffs timer bail (mac:4308-4309)
        if _state.combat.combatStart or (aggroID ~= '' and aggroID ~= '0') then return end
        if _state.misc.iAmDead or mq.TLO.Me.Invis() then return end
        if _state.timers.readBuffs > os.clock() then return end

        local condNo = slot.condNo or 0
        if condNo > 0 and _cond and not _cond.eval(condNo) then goto continue end

        -- Target-type resolution: prefer book TT, fall back to direct spell TT (mac:4491, 4640)
        -- MQ2 returns capitalized strings ("Self", "Single", "Group v2") so lowercase before comparing.
        local spellTT     = (mq.TLO.Spell(spellToCast).TargetType() or ''):lower()
        local bookIs0     = (bookSpellTT == '0')
        local bookTTLower = bookSpellTT:lower()
        local isGroupV = (bookIs0 and spellTT:find('group v', 1, true) ~= nil)
                      or (not bookIs0 and bookTTLower:find('group v', 1, true) ~= nil)
        local isSelf   = (bookIs0 and spellTT:find('self', 1, true) ~= nil)
                      or (not bookIs0 and bookTTLower:find('self', 1, true) ~= nil)

        -- Ensure per-slot timer row exists for out-of-range indices
        if not _state.buffs.slotTimers[i] then
            _state.buffs.slotTimers[i] = {}
            for j = 0, 5 do _state.buffs.slotTimers[i][j] = 0 end
        end
        local timers_i = _state.buffs.slotTimers[i]

        -- Special action tag chain (mac:4319-4403).
        -- Mirrors the mac's big if-elseif in CheckBuffs; each branch ends with goto continue
        -- so special-tag entries never fall through to the group/self/single cast loops.
        if p2 == 'Endgroup' or p2 == 'Managroup' then
            -- |Endgroup / |Managroup: regen on lowest-stat group member (mac:4319-4328)
            if (mq.TLO.Group.Members() or 0) > 0 then
                local stat    = (p2 == 'Endgroup') and 'Endurance' or 'Mana'
                local didCast = regenOther(spellToCast, stat, tonumber(p3) or 0)
                if didCast then
                    local dur = tonumber(mq.TLO.Spell(spellToCast).Duration.TotalSeconds()) or 0
                    timers_i[0] = os.clock() + dur * 10
                end
            end
            goto continue
        elseif p2 == 'mana' then
            -- |mana: cast mana-regen on self when thresholds met (mac:4329-4338)
            local pctMana    = tonumber(mq.TLO.Me.PctMana()) or 100
            local pctHPs     = tonumber(mq.TLO.Me.PctHPs())  or 100
            local manaThresh = tonumber(p3) or 0
            local hpThresh   = tonumber(p4) or 0
            if not (pctMana > manaThresh or pctHPs < hpThresh) then
                local result = _cast.castWhat(spellToCast, mq.TLO.Me.ID(), 'Mana')
                if result == 'CAST_COMPONENTS' then
                    mq.cmd(string.format('/echo You are missing components. Turning off %s.', spellToCast))
                    _state.buffs.buffsArray[i].name = 'NULL'
                end
            end
            goto continue
        elseif p2 == 'End' then
            -- |End: endurance disc/AA when below threshold (mac:4341-4342)
            local pctEnd = tonumber(mq.TLO.Me.PctEndurance()) or 100
            local thresh = tonumber(p3) or 0
            if pctEnd <= thresh then
                local caReady = mq.TLO.Me.CombatAbilityReady(spellToCast)()
                local aaReady = mq.TLO.Me.AltAbilityReady(spellToCast)()
                if caReady or aaReady then checkEndurance(spellToCast) end
            end
            goto continue
        elseif p2 == 'Remove' then
            -- |Remove: /removebuff if buff/song slot active (mac:4344-4348)
            local buffID = mq.TLO.Me.Buff(spellToCast).ID() or 0
            local songID = mq.TLO.Me.Song(spellToCast).ID() or 0
            if buffID ~= 0 or songID ~= 0 then
                mq.cmd(string.format('/echo Removing Buff: %s', spellToCast))
                mq.cmd(string.format('/removebuff "%s"', spellToCast))
            end
            goto continue
        elseif p2 == 'mount' then
            -- |mount: handled by the pre-loop castMount() block; skip here (mac:13880)
            goto continue
        elseif p2 ~= 'begfor'
            and (tonumber(mq.TLO.Spell(spellToCast).Mana()) or 0) > 0
            and (tonumber(mq.TLO.Spell(spellToCast).Mana()) or 0) > (mq.TLO.Me.CurrentMana() or 0) then
            -- Global mana bail: inside elseif chain so it only fires for entries not caught
            -- by the branches above (Endgroup, mana, End, Remove, Mount) (mac:4350).
            goto continue
        elseif p2 == 'Aura' then
            -- |Aura: cast aura if slot not already matching (mac:4353-4354)
            checkAura(spellToCast)
            goto continue
        elseif p2 == 'Once' then
            -- |Once: cast once; disable entry on success (mac:4356-4361)
            if buffOnce(spellToCast) then
                _state.buffs.buffsArray[i].name = spellToCast .. '|0'
                mq.cmd(string.format('/echo Buffing Once with %s.', spellToCast))
            end
            goto continue
        elseif p2:lower() == 'summon' then
            -- |summon: cast summon spell until itemName count >= minCount (mac:4363-4369)
            local itemName = p3 or ''
            local minCount = tonumber(p4) or 1
            if itemName ~= '' and (mq.TLO.FindItemCount('=' .. itemName)() or 0) < minCount then
                local result = summonStuff(spellToCast, itemName, minCount)
                if result == 'CAST_COMPONENTS' then
                    mq.cmd(string.format('/echo You are missing components. Turning off %s.', spellToCast))
                    _state.buffs.buffsArray[i].name = 'NULL'
                end
            end
            goto continue
        elseif p2 == 'mgb' or p2 == 'DualMgb' or p2:lower() == 'dualmgb' then
            -- |mgb / |dualmgb: mass group buff via MGB AA (mac:4370-4371)
            local passes  = (p2 == 'DualMgb' or p2:lower() == 'dualmgb') and 2 or 1
            local needBuff = false
            for m = 0, (mq.TLO.Group.Members() or 0) do
                local member = m == 0 and mq.TLO.Me or mq.TLO.Group.Member(m)
                if member and (member.ID() or 0) ~= 0 then
                    if (member.Buff(buffToCheck).ID() or 0) == 0 then
                        needBuff = true
                        break
                    end
                end
            end
            if needBuff then
                mq.cmd('/keypress MGB hold')
                mq.delay(200)
                for _ = 1, passes do
                    _cast.castWhat(spellToCast, mq.TLO.Me.ID(), 'buffs-nomem')
                    if passes > 1 then mq.delay(100) end
                end
                mq.cmd('/keypress MGB')
            end
            goto continue
        elseif p2 == 'begfor' then
            -- |begfor: broadcast beg request if item/buff count below threshold (mac:4372-4393)
            if (timers_i[0] or 0) <= os.clock() then
                local count = tonumber(p3) or 0
                if count > 0 and p4 == 'alias' then
                    if p5 == 'BEGFORITEMS' then
                        if (mq.TLO.FindItemCount('=' .. spellToCast)() or 0) < count then
                            mq.cmd(string.format('/bc KABeg for %s %s 0',
                                mq.TLO.Me.CleanName() or '', p5))
                            timers_i[0] = os.clock() + 900
                        end
                    elseif p5 == 'BEGFORBUFFS' then
                        if (mq.TLO.Me.Buff(spellToCast).ID() or 0) == 0 then
                            mq.cmd(string.format('/bc KABeg for %s %s 0',
                                mq.TLO.Me.CleanName() or '', p5))
                            timers_i[0] = os.clock() + 900
                        end
                    else
                        mq.cmd(string.format('/echo Invalid Option %s for Alias. Turning Option off.', p5))
                        _state.buffs.buffsArray[i].name = 'NULL'
                    end
                end
            end
            goto continue
        elseif spellToCast:find('command:', 1, true) then
            -- |command:: resolve |pet/|me/|ma tag then execute command (mac:4395-4399, TargetTag mac:4710-4723)
            local targetID
            if entry:find('|pet', 1, true) then
                targetID = mq.TLO.Me.Pet.ID() or 0
            elseif entry:find('|me', 1, true) then
                targetID = mq.TLO.Me.ID() or 0
            elseif entry:find('|ma', 1, true) then
                local maName = _state.session.mainAssist or ''
                targetID = (maName ~= '' and mq.TLO.Spawn('PC ' .. maName).ID()) or 0
            else
                targetID = mq.TLO.Target.ID() or 0
            end
            _cast.castWhat(spellToCast, targetID, 'Buffs')
            goto continue
        end

        -- group v branch: cast group buff on self (mac:4491-4521)
        if isGroupV then
            mq.doevents()  -- drain WornOff
            if timers_i[0] > os.clock() then goto continue end

            local result = _cast.castWhat(spellToCast, mq.TLO.Me.ID(), 'buffs-nomem')
            if result == 'CAST_SUCCESS' then
                mq.doevents()
                _state.timers.writeBuffs = 0
                Buffs.writeBuffs()
            elseif result == 'CAST_COMPONENTS' then
                mq.cmd(string.format('/echo You are missing components. Turning off %s.', spellToCast))
                _state.buffs.buffsArray[i].name = 'NULL'
                goto continue
            elseif result == 'CAST_TAKEHOLD' then
                local dur = tonumber(mq.TLO.Spell(buffToCheck).MyDuration.TotalSeconds()) or 0
                timers_i[0] = os.clock() + dur
            end
            if forceGroup then
                mq.delay(6000, function() return not mq.TLO.Me.SpellInCooldown() end)
            end
            goto continue

        -- self branch: check active buff/song then cast on self (mac:4640-4647)
        elseif isSelf then
            local buffID   = mq.TLO.Me.Buff(buffToCheck).ID() or 0
            local songID   = mq.TLO.Me.Song(buffToCheck).ID() or 0
            local willLand = mq.TLO.Spell(buffToCheck).WillLand()
            if buffID ~= 0 or songID ~= 0 or willLand ~= true then goto continue end

            if timers_i[0] > os.clock() then goto continue end

            local result = _cast.castWhat(spellToCast, mq.TLO.Me.ID(), 'buffs-nomem')
            if result == 'CAST_COMPONENTS' then
                mq.cmd(string.format('/echo You are missing components. Turning off %s.', spellToCast))
                _state.buffs.buffsArray[i].name = 'NULL'
            elseif result == 'CAST_TAKEHOLD' then
                timers_i[0] = os.clock() + 60
            end
            goto continue
        end

        -- single-target branch: buff each group member individually (mac:4523-4638)
        local isSingle = (bookIs0 and spellTT:find('single', 1, true) ~= nil)
                      or (not bookIs0 and bookTTLower:find('single', 1, true) ~= nil)

        if isSingle then
            local groupCount = mq.TLO.Group.Members() or 0
            if groupCount > 0 then
                local spellMana = tonumber(mq.TLO.Spell(spellToCast).Mana()) or 0

                for j = groupCount, 0, -1 do
                    if mq.TLO.Me.Invis() then break end

                    local memberID = mq.TLO.Group.Member(j).ID() or 0
                    if memberID == 0 then goto jcontinue end

                    local memberDist = mq.TLO.Spawn(memberID).Distance() or 999
                    if memberDist >= spellRange then goto jcontinue end

                    if (timers_i[j] or 0) > os.clock() then goto jcontinue end

                    -- Skip if member already has this buff per actors BUFFSTATE data
                    do
                        local received = _state.buffs.memberBuffs[memberID]
                        local bsExpiry = _state.buffs.memberBuffsExpiry[memberID] or 0
                        if received and bsExpiry > os.clock() then
                            local buffExpiry = received[buffToCheck] or 0
                            if buffExpiry > os.clock() then
                                timers_i[j] = buffExpiry
                                goto jcontinue
                            end
                        end
                    end

                    -- |me / |Dualme: self only (mac:4535)
                    if (p2 == 'me' or p2 == 'Dualme') and j > 0 then goto jcontinue end

                    -- Per-cast mana check; break entire j loop if insufficient (mac:4536)
                    if mq.TLO.Me.CurrentMana() < spellMana then break end

                    -- Class and role filters (mac:4538-4542)
                    local memberClass = mq.TLO.Group.Member(j).Class.ShortName() or ''
                    if (p2 == 'caster'  or p2 == 'DualCaster') and not CASTER_CLASSES[memberClass] then goto jcontinue end
                    if (p2 == 'Melee'   or p2 == 'DualMelee')  and not MELEE_CLASSES[memberClass]  then goto jcontinue end
                    if (p2 == 'class'   or p2 == 'DualClass')  and not classInList(memberClass, p5) then goto jcontinue end
                    if (p2 == '!class'  or p2 == 'Dual!Class') and     classInList(memberClass, p5) then goto jcontinue end
                    if p2 == 'MA' or p2 == 'DualMA' then
                        local maID = (_state.session.mainAssist ~= '')
                                 and (mq.TLO.Spawn('PC ' .. _state.session.mainAssist).ID() or 0) or 0
                        if memberID ~= maID then goto jcontinue end
                    end
                    if p2 == '!MA' then
                        local maID = (_state.session.mainAssist ~= '')
                                 and (mq.TLO.Spawn('PC ' .. _state.session.mainAssist).ID() or 0) or 0
                        if memberID == maID then goto jcontinue end
                    end

                    -- Self pre-cast buff check: for me/Dualme, buffToCheck may differ from
                    -- spellToCast (e.g. AA grants a different buff name), so check directly
                    -- rather than relying on castBuffsSpellCheck inside castWhat (mac:4535)
                    if j == 0 and buffToCheck ~= '' then
                        local bID = mq.TLO.Me.Buff(buffToCheck).ID() or 0
                        local sID = mq.TLO.Me.Song(buffToCheck).ID() or 0
                        if bID ~= 0 or sID ~= 0 then goto jcontinue end
                    end

                    -- Aggro bail mid-loop (mac:4544)
                    do
                        local agID = _state.combat.aggroTargetID
                        if agID ~= '' and agID ~= '0' then
                            local agNum = tonumber(agID) or 0
                            if agNum ~= 0 and (mq.TLO.Spawn(agNum).Distance() or 999) < 200 then return end
                        end
                    end

                    -- Gem timer wait: skip if > 6s cooldown; wait up to 6s if memed (mac:4546-4552)
                    local gemSlot = mq.TLO.Me.Gem(spellToCast)()
                    if gemSlot and gemSlot ~= 0 then
                        if (mq.TLO.Me.GemTimer(gemSlot).TotalSeconds() or 0) > 6 then goto jcontinue end
                        local deadline = os.clock() + 6
                        while not mq.TLO.Me.SpellReady(spellToCast)() and os.clock() < deadline do
                            local agID2 = _state.combat.aggroTargetID
                            if agID2 ~= '' and agID2 ~= '0' then
                                local agNum2 = tonumber(agID2) or 0
                                if agNum2 ~= 0 and (mq.TLO.Spawn(agNum2).Distance() or 999) < 200 then return end
                            end
                            mq.delay(250)
                        end
                    end

                    -- WornOff drain (mac:4553-4557)
                    mq.doevents()

                    local result = _cast.castWhat(spellToCast, memberID, 'buffs-nomem')
                    if result == 'CAST_SUCCESS' then
                        printf('\awBuffing \at%s\aw on \at%s', spellToCast,
                            mq.TLO.Group.Member(j).CleanName() or '')
                        local dur = tonumber(mq.TLO.Spell(buffToCheck).MyDuration.TotalSeconds()) or 0
                        timers_i[j] = os.clock() + dur
                        mq.doevents()
                        if j == 0 then
                            _state.timers.writeBuffs = 0
                            Buffs.writeBuffs()
                        end
                    elseif result == 'CAST_HASBUFF' then
                        local dur = tonumber(mq.TLO.Spell(buffToCheck).MyDuration.TotalSeconds()) or 0
                        timers_i[j] = os.clock() + dur
                    elseif result == 'CAST_COMPONENTS' then
                        mq.cmd(string.format('/echo You are missing components. Turning off %s.', spellToCast))
                        _state.buffs.buffsArray[i].name = 'NULL'
                        goto jcontinue
                    elseif result == 'CAST_TAKEHOLD' then
                        local dur = tonumber(mq.TLO.Spell(buffToCheck).MyDuration.TotalSeconds()) or 0
                        timers_i[j] = os.clock() + dur
                    end

                    -- Pet buff via DanNet: deferred to M9

                    ::jcontinue::
                end

            else
                -- No group: cast on self unless a class-filter tag is present (mac:4614-4638)
                if not CLASS_FILTER_TAGS[p2] then
                    mq.doevents()
                    local result = _cast.castWhat(spellToCast, mq.TLO.Me.ID(), 'buffs-nomem')
                    if result == 'CAST_SUCCESS' then
                        local dur = tonumber(mq.TLO.Spell(buffToCheck).MyDuration.TotalSeconds()) or 0
                        timers_i[0] = os.clock() + dur
                        mq.doevents()
                        _state.timers.writeBuffs = 0
                        Buffs.writeBuffs()
                    elseif result == 'CAST_HASBUFF' then
                        local dur = tonumber(mq.TLO.Spell(buffToCheck).MyDuration.TotalSeconds()) or 0
                        timers_i[0] = os.clock() + dur
                    elseif result == 'CAST_COMPONENTS' then
                        mq.cmd(string.format('/echo You are missing components. Turning off %s.', spellToCast))
                        _state.buffs.buffsArray[i].name = 'NULL'
                    end
                end
            end
        end

        if savedTargetID ~= 0 then
            mq.cmdf('/squelch /target id %d', savedTargetID)
        end

        ::continue::
    end

    -- Restore misc gem after buff pass (mac:4701-4705)
    if (_state.cast.miscGemRemem or 0) ~= 0 then
        local miscGem   = _state.cast.miscGem or 0
        local reMemSpell = _state.cast.reMemMiscSpell or ''
        if miscGem > 0 and reMemSpell ~= '' then
            local currentName = (mq.TLO.Me.Gem(miscGem).Name() or ''):lower()
            if currentName ~= reMemSpell:lower() or _state.cast.reMemCastLW then
                _state.cast.reMemCast       = true
                _state.movement.dontMoveMe  = true
                _cast.castReMem(reMemSpell, true, 'buffs')
                _state.movement.dontMoveMe  = false
            end
        end
    end
end

-- Mirrors Sub RemoveFromBegList (mac:13249): remove entry from kaBegForList string;
-- dedup AE-item entries (same alias+slot) and single-type duplicates.
local function removeFromBegList(entry, spellType)
    local entries = {}
    for e in (_state.buffs.kaBegForList .. '|'):gmatch('([^|]+)|') do
        entries[#entries + 1] = e
    end
    local part1 = entry:match('^([^:]*):') or ''
    local part3 = entry:match(':([^:]*)$') or ''
    -- Remove primary entry
    for k = 1, #entries do
        if entries[k] == entry then table.remove(entries, k) break end
    end
    -- AE-items or self: remove all entries with same alias+slot
    if part1 == 'BEGFORAEITEMS' or spellType == 'self' then
        local k = 1
        while k <= #entries do
            local ep1 = entries[k]:match('^([^:]*):') or ''
            local ep3 = entries[k]:match(':([^:]*)$') or ''
            if ep1 == part1 and ep3 == part3 then table.remove(entries, k)
            else k = k + 1 end
        end
    elseif spellType == 'single' then
        local k = 1
        while k <= #entries do
            if entries[k] == entry then table.remove(entries, k)
            else k = k + 1 end
        end
    end
    _state.buffs.kaBegForList = table.concat(entries, '|')
    if _state.buffs.kaBegForList == '' then _state.buffs.kaBegActive = false end
end

-- Mirrors Sub CheckBegforBuffs (mac:13199): process the cross-character buff-request queue.
-- Each entry format: alias:charName:buffArrayIdx (pipe-delimited list in kaBegForList).
function Buffs.checkBegforBuffs()
    if mq.TLO.Me.Invis() then return end
    if _state.buffs.kaBegForList == '' then return end

    local idx = 1
    while true do
        local entry = getListArg(_state.buffs.kaBegForList, idx)
        if entry == '' or entry == 'null' then
            if _state.buffs.kaBegForList == '' then _state.buffs.kaBegActive = false end
            break
        end
        if mq.TLO.Me.Invis() then break end

        local part2 = entry:match('^[^:]*:([^:]*):') or ''
        local part3 = entry:match(':([^:]*)$')        or ''

        -- Resolve buffToCast from buffsArray[part3]
        local buffIdx    = tonumber(part3) or 0
        local _bslot     = buffIdx > 0 and _state.buffs.buffsArray[buffIdx] or nil
        local buffEntry  = _bslot and _bslot.name or ''
        local buffToCast = buffEntry:match('^([^|]*)') or buffEntry

        -- Determine spell type (mac:13222-13228)
        local spellType = 'self'
        if buffToCast ~= '' then
            if mq.TLO.Me.Book(buffToCast)() then
                spellType = mq.TLO.Spell(buffToCast).TargetType() or 'self'
            elseif (mq.TLO.Me.AltAbility(buffToCast).ID() or 0) ~= 0 then
                local aaSpell = mq.TLO.Me.AltAbility(buffToCast).Spell
                spellType = (aaSpell and aaSpell.TargetType() or 'self')
            end
        end

        if spellType ~= 'self' then
            local targetID = mq.TLO.Spawn('PC ' .. part2).ID() or 0

            -- memberBuffs check: skip cast if requester already has the buff (replaces INI read)
            if targetID ~= 0 then
                local received = _state.buffs.memberBuffs[targetID]
                local bsExpiry = _state.buffs.memberBuffsExpiry[targetID] or 0
                if received and bsExpiry > os.clock() then
                    if (received[buffToCast] or 0) > os.clock() then
                        removeFromBegList(entry, spellType)
                        goto begcontinue
                    end
                end
            end

            local result   = _cast.castWhat(buffToCast, targetID, 'Buffs')
            if result == 'CAST_SUCCESS' or result == 'CAST_RECOVER' then
                removeFromBegList(entry, spellType)
            elseif result == 'CAST_CANCELLED' then
                break
            else
                idx = idx + 1
            end
        else
            removeFromBegList(entry, 'self')
        end
        ::begcontinue::
    end
end

-- Per-entry pettoys|begfor timers (mac: PetBuff${i} timer outer 900).
local _petBegTimers = {}

-- Mirrors Sub CheckPetBuffs (mac:5402): apply pet buffs from petBuffsArray.
function Buffs.checkPetBuffs()
    if (mq.TLO.Me.Pet.ID() or 0) == 0 then return end
    if not _state.pet.on then return end
    if not _state.buffs.petBuffsOn then return end
    if _state.session.combatStart then return end
    if _state.combat.pulling then return end
    if os.clock() < (_state.timers.petBuffCheck or 0) then return end
    if mq.TLO.Me.Invis() then return end

    _state.timers.petBuffCheck = os.clock() + 60

    for i = 1, #_state.buffs.petBuffsArray do
        mq.doevents()
        if (tonumber(_state.combat.aggroTargetID) or 0) ~= 0 then return end

        local pslot  = _state.buffs.petBuffsArray[i]
        if not pslot then goto petcontinue end
        local pcondNo = pslot.condNo or 0
        if pcondNo > 0 and _cond and not _cond.eval(pcondNo) then goto petcontinue end
        local entry = pslot.name or ''
        if entry:upper() == 'NULL' then goto petcontinue end

        local part1 = getListArg(entry, 1)
        local part2 = getListArg(entry, 2)
        local part3 = getListArg(entry, 3)

        if part2 ~= 'dual' then part3 = part1 end

        local pTempBuff = part3:match('^(.-)%s+Rk%.') or part3

        local foundPetBuff = false

        if mq.TLO.Me.Book(part1)() or (mq.TLO.Me.AltAbility(part1).ID() or 0) ~= 0 then
            for j = 1, 50 do
                if (mq.TLO.Me.PetBuff(j).Name() or ''):find(pTempBuff, 1, true) then
                    foundPetBuff = true
                    break
                end
            end
            if not foundPetBuff then
                local result = _cast.castWhat(part1, mq.TLO.Me.Pet.ID(), 'Pet-nomem')
                mq.delay(200)
                if result == 'CAST_SUCCESS' then
                    mq.cmd(string.format('/echo Buffing %s, my pet, with %s',
                        mq.TLO.Me.Pet.CleanName() or 'pet', part1))
                elseif result == 'CAST_COMPONENTS' then
                    mq.cmd(string.format('/echo You are missing components. Turning off %s.', part1))
                    _state.buffs.petBuffsArray[i].name = 'NULL'
                end
            end
        elseif (mq.TLO.FindItem('=' .. part1).ID() or 0) ~= 0 then
            for j = 1, 50 do
                if (mq.TLO.Me.PetBuff(j).Name() or ''):find(pTempBuff, 1, true) then
                    foundPetBuff = true
                    break
                end
            end
            if not foundPetBuff then
                local result = _cast.castWhat(part1, mq.TLO.Me.Pet.ID(), 'Pet')
                mq.delay(200)
                if result == 'CAST_SUCCESS' then
                    mq.cmd(string.format('/echo Buffing %s, my pet, with (%s)',
                        mq.TLO.Me.Pet.CleanName() or 'pet', part3))
                elseif result == 'CAST_COMPONENTS' then
                    mq.cmd(string.format('/echo You are missing components. Turning off %s.', part1))
                    _state.buffs.petBuffsArray[i].name = 'NULL'
                end
            end
        elseif part1 == 'pettoys' and part2 == 'begfor' then
            if (_petBegTimers[i] or 0) <= os.clock() then
                mq.cmd(string.format('/bc PetToysPlease %s', mq.TLO.Me.Pet.Name() or ''))
                _petBegTimers[i] = os.clock() + 90
                _state.buffs.kaPetBegActive = true
            end
        end

        ::petcontinue::
    end

    -- Shrink pet if too tall (mac:5510-5514)
    local petHeight = tonumber(mq.TLO.Me.Pet.Height()) or 0
    if petHeight > 1.35 and _state.pet.shrinkOn and (_state.pet.shrinkSpell or '') ~= '' then
        _cast.castWhat(_state.pet.shrinkSpell, mq.TLO.Me.Pet.ID(), 'Pet')
        mq.delay(200)
    end

    -- Clear pet target (mac:5515)
    if (mq.TLO.Target.ID() or 0) == (mq.TLO.Me.Pet.ID() or -1) then
        mq.cmd('/squelch /target clear')
    end
end

-- Mirrors Sub CheckBegforPetBuffs (mac:13307): process cross-character pet toy requests.
-- Each entry in kaBegForPetList is a pet name or "group" (pipe-delimited).
function Buffs.checkBegforPetBuffs()
    if not _state.pet.toysOn then return end
    if mq.TLO.Me.Invis() then return end
    if _state.buffs.kaBegForPetList == '' then return end

    local PET_CLASSES = {shm=true, nec=true, mag=true, bst=true, dru=true, enc=true, shd=true}
    local toySpell = _state.pet.toysArray[1] or ''

    local idx = 1
    while true do
        local entry = getListArg(_state.buffs.kaBegForPetList, idx)
        if entry == '' or entry:lower() == 'null' then
            if _state.buffs.kaBegForPetList == '' then _state.buffs.kaPetBegActive = false end
            break
        end
        if mq.TLO.Me.Invis() then break end

        local result = 'CAST_FAILURE'

        if entry == 'group' then
            mq.cmd('/echo I am giving pet toys to every Pet in Group except mine.')
            for i = 1, 5 do
                local memberID = mq.TLO.Group.Member(i).ID() or 0
                local petID    = mq.TLO.Group.Member(i).Pet.ID() or 0
                local cls      = (mq.TLO.Group.Member(i).Class.ShortName() or ''):lower()
                local petName  = mq.TLO.Group.Member(i).Pet.Name() or ''
                if memberID ~= 0 and petID ~= 0 and PET_CLASSES[cls]
                    and (mq.TLO.Spawn('pet ' .. petName).Type() or '') == 'Pet' then
                    if mq.TLO.Me.Invis() then break end
                    result = _cast.castWhat(toySpell, petID, 'Pet')
                end
            end
        else
            local petID = mq.TLO.Spawn('pet ' .. entry).ID() or 0
            if petID ~= 0 then
                mq.cmd(string.format('/echo Giving pet toys to (%s).', entry))
                result = _cast.castWhat(toySpell, petID, 'Pet')
            end
        end

        if result == 'CAST_SUCCESS' then
            local entries = {}
            for e in (_state.buffs.kaBegForPetList .. '|'):gmatch('([^|]+)|') do
                entries[#entries + 1] = e
            end
            for k = 1, #entries do
                if entries[k] == entry then table.remove(entries, k) break end
            end
            _state.buffs.kaBegForPetList = table.concat(entries, '|')
            if _state.buffs.kaBegForPetList == '' then
                _state.buffs.kaPetBegActive = false
                break
            end
        elseif result == 'CAST_CANCELLED' then
            break
        else
            idx = idx + 1
        end
    end
end

-- Mirrors Bind_Settings buff loading (kissassist.mac:14657-14671) and
-- Pet buff loading from [Pet] INI section.
function Buffs.init(state, utils, cast, heal, comms, cond)
    _state = state
    _utils = utils
    _cast  = cast
    _heal  = heal
    _comms = comms  -- nil when Comms not yet init'd; writeBuffs guards with `if _comms`
    _cond  = cond

    -- Cross-char comms flag (guards all write functions)
    _state.session.danNetOn = Config.get('General', 'DanNetOn', '0') == '1'

    -- [Buffs] section
    _state.buffs.buffsOn         = Config.get('Buffs', 'BuffsOn',        '0') == '1'
    _state.buffs.rebuffOn        = Config.get('Buffs', 'RebuffOn',       '1') == '1'
    _state.buffs.checkBuffsTimer = tonumber(Config.get('Buffs', 'CheckBuffsTimer', '15')) or 15
    _state.buffs.powerSource     = Config.get('Buffs', 'PowerSource',    '') or ''

    local buffsArr = Config.get('Buffs', 'Buffs', nil)
    if type(buffsArr) == 'table' then
        for _, slot in ipairs(Config.parseCondArray(buffsArr)) do
            if slot and slot.name and slot.name ~= '' then
                _state.buffs.buffsArray[#_state.buffs.buffsArray + 1] = slot
            end
        end
    end

    -- Mount toggle from [General] (mac:4200); mount spell comes from |Mount entry in buffsArray
    local mountOnRaw = Config.get('General', 'MountOn', nil)
    if mountOnRaw ~= nil then
        _state.misc.mountOn = mountOnRaw == '1'
    end

    -- [Pet] buff list
    _state.buffs.petBuffsOn = Config.get('Pet', 'PetBuffsOn', '0') == '1'
    local petBuffsArr = Config.get('Pet', 'PetBuffs', nil)
    if type(petBuffsArr) == 'table' then
        for _, slot in ipairs(Config.parseCondArray(petBuffsArr)) do
            if slot and slot.name and slot.name ~= '' then
                _state.buffs.petBuffsArray[#_state.buffs.petBuffsArray + 1] = slot
            end
        end
    end

    -- [Pet] on / shrink / toys fields
    _state.pet.on          = Config.get('Pet', 'PetOn',          '0') == '1'
    _state.pet.shrinkOn    = Config.get('Pet', 'PetShrinkOn',    '0') == '1'
    _state.pet.shrinkSpell = Config.get('Pet', 'PetShrinkSpell', '') or ''
    _state.pet.toysOn      = Config.get('Pet', 'PetToysOn',      '0') == '1'
    local petToysArr = Config.get('Pet', 'PetToys', nil)
    if type(petToysArr) == 'table' then
        for _, v in ipairs(petToysArr) do
            if v and v ~= '' then
                _state.pet.toysArray[#_state.pet.toysArray + 1] = v
            end
        end
    end

    utils.debug('buffs',
        'Buffs.init: buffsOn=%s buffs#=%d petBuffsOn=%s petBuffs#=%d rebuffOn=%s checkBuffsTimer=%d mountOn=%s danNetOn=%s',
        tostring(_state.buffs.buffsOn),
        #_state.buffs.buffsArray,
        tostring(_state.buffs.petBuffsOn),
        #_state.buffs.petBuffsArray,
        tostring(_state.buffs.rebuffOn),
        _state.buffs.checkBuffsTimer,
        tostring(_state.misc.mountOn),
        tostring(_state.session.danNetOn))
end

return Buffs
