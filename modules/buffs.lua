local mq     = require('mq')
local Config = require('modules.config')

local Buffs = {}
local _state, _utils, _cast, _heal

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
-- Writes character's current buff list + metadata to KissAssist_Buffs.ini every 30s OOC.
function Buffs.writeBuffs()
    if _state.timers.writeBuffs > os.clock() then return end
    if not _state.misc.redguides then return end
    if (_state.combat.aggroTargetID or '') ~= '' then return end
    if _state.session.danNetOn then return end
    if mq.TLO.EverQuest.GameState() ~= 'INGAME' then return end

    -- blockedBuffsCount: state.lua defaults to 30 (emu); live servers use 40 (mac:17083-17087)
    -- Dynamic build detection deferred — override via state.buffs.blockedBuffsCount if needed

    cleanBuffsFile()

    local id   = tostring(mq.TLO.Me.ID() or 0)
    local t    = os.date('*t')
    local day  = tostring(t.day)
    local hour = tostring(t.hour)

    -- Write metadata keys only if absent (mac:17090-17096)
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Day')()  then mq.cmd(string.format('/ini "%s" %s Day %s',  BUFFS_FILE, id, day))  end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Hour')() then mq.cmd(string.format('/ini "%s" %s Hour %s', BUFFS_FILE, id, hour)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Zone')() then
        mq.cmd(string.format('/ini "%s" %s Zone %s', BUFFS_FILE, id, tostring(mq.TLO.Zone.ID() or 0)))
    end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Buffs')()        then mq.cmd(string.format('/ini "%s" %s Buffs ""',        BUFFS_FILE, id)) end
    if not mq.TLO.Ini(BUFFS_FILE, id, 'Blockedbuffs')() then mq.cmd(string.format('/ini "%s" %s Blockedbuffs ""', BUFFS_FILE, id)) end
    mq.cmd(string.format('/ini "%s" %s AmILooting 0', BUFFS_FILE, id))  -- LootOn: M8
    mq.cmd(string.format('/ini "%s" %s MyRole %s',    BUFFS_FILE, id, _state.session.role))

    -- Collect buff list: slots 1..41, strip ':Permanent' suffix (mac:17098-17105)
    local bufflist = ''
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
    mq.cmd(string.format('/ini "%s" %s Buffs "%s"', BUFFS_FILE, id, bufflist))

    -- Collect blocked buff list (mac:17109-17115)
    local blockedlist = ''
    local blockedCount = 0
    for k = 1, _state.buffs.blockedBuffsCount do
        local name = mq.TLO.Me.BlockedBuff(k).Name() or ''
        if name ~= '' and name ~= 'null' then
            blockedlist  = blockedlist .. name .. '|'
            blockedCount = blockedCount + 1
        end
    end
    if blockedlist ~= '' then
        mq.cmd(string.format('/ini "%s" %s Blockedbuffs "%s"', BUFFS_FILE, id, blockedlist))
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

-- Mirrors Sub CastMount (mac:4200 call site). Casts the configured mount spell on self.
local function castMount()
    if _state.buffs.mountSpell == '' then return end
    _cast.castWhat(_state.buffs.mountSpell, mq.TLO.Me.ID(), 'Buffs')
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
    if mq.TLO.Me.Invis() and mq.TLO.Me.Class.Name() ~= 'Rogue' then return end
    if _state.movement.chaseAssist and mq.TLO.Me.Moving() then return end
    if mq.TLO.Me.Moving() and _state.movement.whoToChase == mq.TLO.Me.Name() then return end

    -- PowerSource refuel (mac:4192)
    refuelPowerSource()

    -- Mount cast (mac:4200)
    if _state.misc.mountOn and not mq.TLO.Me.Mount.ID() then
        local zType = mq.TLO.Zone.Type()
        if mq.TLO.Zone.Outdoor() or zType == 1 or zType == 2 or zType == 5 then
            if mq.TLO.Me.CombatState() ~= 'COMBAT' then
                castMount()
            end
        end
    end

    -- Per-entry loop (mac:4207)
    for i, entry in ipairs(_state.buffs.buffsArray) do
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

        -- Condition check: ConOn deferred to M10 — condNo always 0 (mac:4311-4315)
        local condNo = 0  -- luacheck: ignore (used when ConOn implemented)

        -- Target-type resolution: prefer book TT, fall back to direct spell TT (mac:4491, 4640)
        local spellTT  = mq.TLO.Spell(spellToCast).TargetType() or ''
        local bookIs0  = (bookSpellTT == '0')
        local isGroupV = (bookIs0 and spellTT:find('group v', 1, true) ~= nil)
                      or (not bookIs0 and bookSpellTT:find('group v', 1, true) ~= nil)
        local isSelf   = (bookIs0 and spellTT:find('self', 1, true) ~= nil)
                      or (not bookIs0 and bookSpellTT:find('self', 1, true) ~= nil)

        -- Ensure per-slot timer row exists for out-of-range indices
        if not _state.buffs.slotTimers[i] then
            _state.buffs.slotTimers[i] = {}
            for j = 0, 5 do _state.buffs.slotTimers[i][j] = 0 end
        end
        local timers_i = _state.buffs.slotTimers[i]

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
                _state.buffs.buffsArray[i] = 'NULL'
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
            if buffID ~= 0 or songID ~= 0 or willLand == false then goto continue end

            local result = _cast.castWhat(spellToCast, mq.TLO.Me.ID(), 'buffs-nomem')
            if result == 'CAST_COMPONENTS' then
                mq.cmd(string.format('/echo You are missing components. Turning off %s.', spellToCast))
                _state.buffs.buffsArray[i] = 'NULL'
            end
            goto continue
        end

        -- single-target branch: buff each group member individually (mac:4523-4638)
        local isSingle = (bookIs0 and spellTT:find('single', 1, true) ~= nil)
                      or (not bookIs0 and bookSpellTT:find('single', 1, true) ~= nil)

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
                        _state.buffs.buffsArray[i] = 'NULL'
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
                        _state.buffs.buffsArray[i] = 'NULL'
                    end
                end
            end
        end

        -- special action tags (Endgroup, Managroup, Aura, Once, mana, command:, mgb): deferred to Step 6.5

        ::continue::
    end
end

-- Mirrors Bind_Settings buff loading (kissassist.mac:14657-14671) and
-- Pet buff loading from [Pet] INI section.
function Buffs.init(state, utils, cast, heal)
    _state = state
    _utils = utils
    _cast  = cast
    _heal  = heal

    -- Cross-char comms flag (guards all write functions)
    _state.session.danNetOn = Config.get('General', 'DanNetOn', '0') == '1'

    -- [Buffs] section
    _state.buffs.buffsOn         = Config.get('Buffs', 'BuffsOn',        '0') == '1'
    _state.buffs.rebuffOn        = Config.get('Buffs', 'RebuffOn',       '1') == '1'
    _state.buffs.checkBuffsTimer = tonumber(Config.get('Buffs', 'CheckBuffsTimer', '15')) or 15
    _state.buffs.powerSource     = Config.get('Buffs', 'PowerSource',    '') or ''

    local buffsArr = Config.get('Buffs', 'Buffs', nil)
    if type(buffsArr) == 'table' then
        for _, v in ipairs(buffsArr) do
            if v and v ~= '' then
                _state.buffs.buffsArray[#_state.buffs.buffsArray + 1] = v
            end
        end
    end

    -- Mount fields from [General] (mac:4200)
    local mountOnRaw = Config.get('General', 'MountOn', nil)
    if mountOnRaw ~= nil then
        _state.misc.mountOn = mountOnRaw == '1'
    end
    _state.buffs.mountSpell = Config.get('General', 'MountSpell', '') or ''

    -- [Pet] buff list
    _state.buffs.petBuffsOn = Config.get('Pet', 'PetBuffsOn', '0') == '1'
    local petBuffsArr = Config.get('Pet', 'PetBuffs', nil)
    if type(petBuffsArr) == 'table' then
        for _, v in ipairs(petBuffsArr) do
            if v and v ~= '' then
                _state.buffs.petBuffsArray[#_state.buffs.petBuffsArray + 1] = v
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
