local mq = require('mq')

local Config = {}

Config.VERSION = '1.0.0'

-- Loaded config table (populated by Config.load, consumed by modules at startup).
local _cfg = nil
-- Path to the pickle file on disk; set by migrateIni so save() knows where to write.
local _picklePath = nil

local ROLES = {
    assist=true, manual=true, petassist=true, tank=true, pettank=true,
    puller=true, pullertank=true, pullerpettank=true,
    hunter=true, hunterpettank=true, offtank=true,
}

-- Step 1.4a: Parse CLI args into State.
-- Mirrors PParse() from kissassist.mac.
-- Arg forms:  role [MAname] [assistAt%]  |  ma <name>  |  assistat <n>  |  debug/debugall
--             ini <file>  |  forcealias  |  autoload  |  parse <seconds>
function Config.parseArgs(state, args)
    local i = 1
    while i <= #args do
        local a = args[i]:lower()
        if a == 'debug' then
            state.debug.general = true
        elseif a == 'debugall' then
            for k in pairs(state.debug) do state.debug[k] = true end
        elseif a == 'ini' and args[i+1] then
            state.session.iniFileName = args[i+1]
            state.session.iniSet = true
            i = i + 1
        elseif a == 'forcealias' then
            state.session.forceAlias = true
        elseif a == 'autoload' then
            state.session.loadFromIni = true
        elseif a == 'ma' and args[i+1] then
            state.session.mainAssist = args[i+1]
            i = i + 1
        elseif a == 'assistat' and args[i+1] then
            state.session.assistAt = tonumber(args[i+1]) or 95
            i = i + 1
        elseif a == 'parse' then
            state.session.parseDPSTimer = args[i+1] and (tonumber(args[i+1]) or 60) or 60
            if args[i+1] then i = i + 1 end
        elseif ROLES[a] then
            state.session.role = a
        else
            local n = tonumber(args[i])
            if n and n >= 1 and n <= 100 then
                state.session.assistAt = n
            elseif not n then
                -- bare string with no role match = MA name (.mac fallback)
                state.session.mainAssist = args[i]
            end
        end
        i = i + 1
    end
end

-- Step 1.4b: Resolve INI filename from character identity if not set by CLI.
-- Mirrors the INI detection block in Sub Main.
function Config.resolveIniName(state)
    if state.session.iniSet then return end
    local name     = mq.TLO.Me.CleanName()
    local class    = mq.TLO.Me.Class.ShortName()
    local server   = mq.TLO.EverQuest.Server()
    local macroName = state.session.macroName

    local serverIni   = string.format('%s_%s_%s_%s.ini', macroName, server, name, class)
    local fallbackIni = string.format('%s_%s_%s.ini', macroName, name, class)

    -- Prefer server-specific INI if it has a KissAssistVer entry.
    if mq.TLO.Ini(serverIni, 'General', 'KissAssistVer')() ~= nil then
        state.session.iniFileName = serverIni
    else
        state.session.iniFileName = fallbackIni
    end
end

-- Bard-only migration: convert MQ2Twist gem-slot lists (TwistWhat / MeleeTwistWhat)
-- to named MQ2Medley sections written into the MQ2 character config INI.
-- Called during migrateIni before the pickle is written; readFn is the local r() helper.
local function migrateBardMedley(readFn, cfg)
    if mq.TLO.Me.Class.ShortName() ~= 'BRD' then return end

    local twistWhat = cfg.General.TwistWhat
    local meleeWhat = cfg.Melee and cfg.Melee.MeleeTwistWhat
    if not twistWhat and not meleeWhat then return end

    -- Read memorised gem names from [SpellSets] Gem1..Gem13.
    local gemNames = {}
    for i = 1, 13 do
        local name = readFn('SpellS', 'Gem' .. i)
        if name and name ~= '' then gemNames[i] = name end
    end

    local function slotsToSongs(slotStr)
        local songs = {}
        if not slotStr then return songs end
        for slot in slotStr:gmatch('%d+') do
            local n = tonumber(slot)
            if n and gemNames[n] then songs[#songs + 1] = gemNames[n] end
        end
        return songs
    end

    -- Locate the MQ2 character config INI (ServerShortName_CharName.ini).
    local charName  = mq.TLO.Me.CleanName()
    local configWin = mq.configDir:gsub('/', '\\')
    local mqIniPath, mqIniFile
    local handle = io.popen(string.format('dir /b "%s\\*_%s.ini" 2>nul', configWin, charName))
    if handle then
        for line in handle:lines() do
            line = line:match('^%s*(.-)%s*$')
            if line ~= '' and not line:lower():find('kissassist') then
                mqIniPath = mq.configDir .. '/' .. line
                mqIniFile = line
                break
            end
        end
        handle:close()
    end

    if not mqIniPath then
        printf('\ayKissAssist: \awCould not find MQ2 character config for %s — add [MQ2Medley-oor] and [MQ2Medley-melee] manually.', charName)
    else
        local function writeMedleySection(setName, songs)
            if #songs == 0 then return end
            -- Skip if section already populated.
            if mq.TLO.Ini(mqIniFile, 'MQ2Medley-' .. setName, 'song1')() ~= nil then
                printf('\ayKissAssist: [MQ2Medley-%s] already exists in %s — skipping', setName, mqIniFile)
                return
            end
            local f = io.open(mqIniPath, 'a')
            if not f then
                printf('\arKissAssist: could not open %s for writing', mqIniFile)
                return
            end
            f:write(string.format('\n[MQ2Medley-%s]\n', setName))
            for i, name in ipairs(songs) do
                f:write(string.format('song%d=%s\n', i, name))
            end
            f:close()
            printf('\agKissAssist: \awWrote [MQ2Medley-%s] (%d songs) to \at%s', setName, #songs, mqIniFile)
        end
        writeMedleySection('oor',   slotsToSongs(twistWhat))
        writeMedleySection('melee', slotsToSongs(meleeWhat))
    end

    -- Replace old slot-list keys with medley set names; nil removes them from pickle.
    cfg.General.OORMedley    = cfg.General.OORMedley   or 'oor'
    cfg.General.MeleeMedley  = cfg.General.MeleeMedley or 'melee'
    cfg.General.BurnMedley   = cfg.General.BurnMedley  or 'burn'
    cfg.General.GoMMedley    = cfg.General.GoMMedley   or 'gomSong'
    cfg.General.TwistWhat    = nil
    cfg.General.TwistMed     = nil
    if cfg.Melee then cfg.Melee.MeleeTwistWhat = nil end
end

-- Purge any section or key not present in the defaultCfg schema.
-- Keeps pickles clean after migration without needing a manual orphan list.
local function purgeOrphanedFields(cfg)
    local schema = Config.defaultCfg()
    for section in pairs(cfg) do
        if not schema[section] then
            cfg[section] = nil
        else
            for key in pairs(cfg[section] or {}) do
                if schema[section][key] == nil then
                    cfg[section][key] = nil
                end
            end
        end
    end
end

-- Step 1.4b: Migrate an existing .ini to mq.pickle() on first run.
-- KissAssist_Buffs.ini and KissAssist_Info.ini stay as .ini — they are shared
-- cross-character files; pickle conversion is unsafe while chars still run .mac.
-- Returns the loaded config table, or nil if no INI and no pickle exists.
function Config.migrateIni(state)
    local iniFile   = state.session.iniFileName
    local pickleDir = mq.configDir .. '/kissassist-lua'
    local pickleName = iniFile:gsub('%.ini$', '') .. '.lua'
    local picklePath = pickleDir .. '/' .. pickleName

    -- 1. If pickle already exists, load and return it.
    local pf = io.open(picklePath, 'r')
    if pf then
        pf:close()
        local ok, cfg = pcall(dofile, picklePath)
        if ok and type(cfg) == 'table' then
            _picklePath = picklePath
            local dirty = false
            -- One-time rename: SpellS → SpellSets
            if cfg.SpellS and not cfg.SpellSets then
                cfg.SpellSets = cfg.SpellS
                cfg.SpellS    = nil
                dirty = true
            end
            -- One-time: migrate Spells.GemN individual keys → Spells.Gems array
            if cfg.Spells and not cfg.Spells.Gems then
                local gems = {}
                for i = 1, 13 do
                    local v = cfg.Spells['Gem' .. i]
                    if v then gems[i] = v; cfg.Spells['Gem' .. i] = nil end
                end
                cfg.Spells.Gems = gems
                dirty = true
            end
            if dirty then mq.pickle(picklePath, cfg) end
            printf('\agKissAssist: \awLoaded config from \at%s', pickleName)
            return cfg
        end
        printf('\arKissAssist: \awPickle found but failed to load — re-migrating from INI.')
    end

    -- 2. Check INI exists via TLO (handles path resolution automatically).
    local ver = mq.TLO.Ini(iniFile, 'General', 'KissAssistVer')()
    if not ver then
        local cfg = Config.defaultCfg()
        local dir = pickleDir:gsub('/', '\\')
        os.execute(string.format('if not exist "%s" mkdir "%s"', dir, dir))
        _picklePath = picklePath
        mq.pickle(picklePath, cfg)
        printf('\agKissAssist: \awNo INI found — created starter config at \at%s', pickleName)
        printf('\awEdit %s to configure spells, heals, and buffs for this character.', pickleName)
        return cfg
    end

    printf('\agKissAssist: \awMigrating \at%s\aw to pickle...', iniFile)

    -- Helpers: read a single key or a numbered array (key1, key2 ...) from the INI.
    local function r(section, key)
        return mq.TLO.Ini(iniFile, section, key)()
    end
    local function ra(section, key, n)
        local arr = {}
        for i = 1, n do
            local v = mq.TLO.Ini(iniFile, section, key .. i)()
            if v then arr[i] = v end
        end
        return arr
    end

    local cfg = {}

    -- [General] — role, camp, movement, comms, misc toggles
    cfg.General = {
        KissAssistVer    = Config.VERSION,
        Role             = r('General','Role'),
        CampRadius       = r('General','CampRadius'),
        CampRadiusExceed = r('General','CampRadiusExceed'),
        ReturnToCamp     = r('General','ReturnToCamp'),
        ChaseAssist      = r('General','ChaseAssist'),
        ChaseDistance    = r('General','ChaseDistance'),
        MedOn            = r('General','MedOn'),
        MedStart         = r('General','MedStart'),
        MedStop          = r('General','MedStop'),
        MedCombat        = r('General','MedCombat'),
        LootOn           = r('General','LootOn'),
        RezAcceptOn      = r('General','RezAcceptOn'),
        AcceptInvitesOn  = r('General','AcceptInvitesOn'),
        GroupWatchOn     = r('General','GroupWatchOn'),
        GroupWatchCheck  = r('General','GroupWatchCheck'),
        CorpseRecoveryOn = r('General','CorpseRecoveryOn'),
        EQBCOn           = r('General','EQBCOn'),
        DanNetOn         = r('General','DanNetOn'),
        DanNetDelay      = r('General','DanNetDelay'),
        IRCOn            = r('General','IRCOn'),
        CampfireOn       = r('General','CampfireOn'),
        GroupEscapeOn    = r('General','GroupEscapeOn'),
        DPSMeter         = r('General','DPSMeter'),
        ScatterOn        = r('General','ScatterOn'),
        LOSBeforeCombat  = r('General','LOSBeforeCombat'),
        UseSpawnMaster   = r('General','UseSpawnMaster'),
        TwistOn          = r('General','TwistOn'),
        TwistMed         = r('General','TwistMed'),
        TwistWhat        = r('General','TwistWhat'),
        OORMedley        = r('General','OORMedley') or 'oor',
        MeleeMedley      = r('General','MeleeMedley') or 'melee',
        BurnMedley       = r('General','BurnMedley') or 'burn',
        GoMMedley        = r('General','GoMMedley') or 'gomSong',
        MountOn          = r('General','MountOn'),
    }

    -- [SpellSets] — spell set settings (INI source section was [SpellS])
    cfg.SpellSets = {
        MiscGem          = r('SpellS','MiscGem'),
        MiscGemLW        = r('SpellS','MiscGemLW'),
        MiscGemRemem     = r('SpellS','MiscGemRemem'),
        LoadSpellSet     = r('SpellS','LoadSpellSet'),
        SpellSetName     = r('SpellS','SpellSetName'),
    }
    local gemsArr = {}
    for i = 1, 13 do
        local v = r('Spells', 'Gem' .. i)
        if v then gemsArr[i] = v end
    end
    cfg.Spells = {
        CastingInterruptOn = r('Spells','CastingInterruptOn'),
        CheckStuckGem      = r('Spells','CheckStuckGem'),
        Gems               = gemsArr,
    }

    -- [Buffs] — self/group buff list (numbered array: Buffs1..BuffsN)
    local buffsSize = tonumber(r('Buffs','BuffsSize')) or 20
    cfg.Buffs = {
        BuffsOn         = r('Buffs','BuffsOn'),
        BuffsSize       = buffsSize,
        RebuffOn        = r('Buffs','RebuffOn'),
        CheckBuffsTimer = r('Buffs','CheckBuffsTimer'),
        PowerSource     = r('Buffs','PowerSource'),
        Buffs           = ra('Buffs','Buffs', buffsSize),
    }

    -- [Melee] — melee engagement settings
    cfg.Melee = {
        AssistAt          = r('Melee','AssistAt'),
        MeleeOn           = r('Melee','MeleeOn'),
        FaceMobOn         = r('Melee','FaceMobOn'),
        MeleeDistance     = r('Melee','MeleeDistance'),
        StickHow          = r('Melee','StickHow'),
        AutoFireOn        = r('Melee','AutoFireOn'),
        UseMQ2Melee       = r('Melee','UseMQ2Melee'),
        TargetSwitchingOn = r('Melee','TargetSwitchingOn'),
        AutoHide          = r('Melee','AutoHide'),
        MeleeTwistOn      = r('Melee','MeleeTwistOn'),
        MeleeTwistWhat    = r('Melee','MeleeTwistWhat'),
    }

    -- [GoM] — Gift of Mana / proc spells (numbered array)
    local gomSize = tonumber(r('GoM','GoMSize')) or 3
    cfg.GoM = {
        GoMSize  = gomSize,
        GoMSpell = ra('GoM','GoMSpell', gomSize),
    }

    -- [AE] — AE spell list (numbered array)
    local aeSize = tonumber(r('AE','AESize')) or 10
    cfg.AE = {
        AEOn     = r('AE','AEOn'),
        AESize   = aeSize,
        AERadius = r('AE','AERadius'),
        AE       = ra('AE','AE', aeSize),
    }

    -- [DPS] — DPS spell/disc list (numbered array, sorted by priority)
    local dpsSize = tonumber(r('DPS','DPSSize')) or 20
    cfg.DPS = {
        DPSOn       = r('DPS','DPSOn'),
        DPSSize     = dpsSize,
        DPSSkip     = r('DPS','DPSSkip'),
        DPSInterval = r('DPS','DPSInterval'),
        DebuffAllOn = r('DPS','DebuffAllOn'),
        DPS         = ra('DPS','DPS', dpsSize),
    }

    -- [Aggro] — aggro/taunt spell list (numbered array)
    local aggroSize = tonumber(r('Aggro','AggroSize')) or 10
    cfg.Aggro = {
        AggroOn   = r('Aggro','AggroOn'),
        AggroSize = aggroSize,
        Aggro     = ra('Aggro','Aggro', aggroSize),
    }

    -- [Heals] — heal spell list; format "SpellName|pct" (numbered array)
    local healsSize = tonumber(r('Heals','HealsSize')) or 15
    cfg.Heals = {
        HealsOn         = r('Heals','HealsOn'),
        HealsSize       = healsSize,
        HealInterval    = r('Heals','HealInterval'),
        AutoRezOn       = r('Heals','AutoRezOn'),
        XTarHeal        = r('Heals','XTarHeal'),
        XTarHealList    = r('Heals','XTarHealList'),
        HealGroupPetsOn = r('Heals','HealGroupPetsOn'),
        RezMeLast       = r('Heals','RezMeLast'),
        Heals           = ra('Heals','Heals', healsSize),
    }

    -- [Cures] — cure spell list (numbered array)
    local curesSize = tonumber(r('Cures','CuresSize')) or 5
    cfg.Cures = {
        CuresOn   = r('Cures','CuresOn'),
        CuresSize = curesSize,
        Cures     = ra('Cures','Cures', curesSize),
    }

    -- [Pet] — pet management and buff list
    local petBuffsSize = tonumber(r('Pet','PetBuffsSize')) or 8
    local petToysSize  = tonumber(r('Pet','PetToysSize'))  or 6
    cfg.Pet = {
        PetOn              = r('Pet','PetOn'),
        PetSpell           = r('Pet','PetSpell'),
        PetFocus           = r('Pet','PetFocus'),
        PetShrinkOn        = r('Pet','PetShrinkOn'),
        PetShrinkSpell     = r('Pet','PetShrinkSpell'),
        PetBuffsOn         = r('Pet','PetBuffsOn'),
        PetBuffsSize       = petBuffsSize,
        PetBuffs           = ra('Pet','PetBuffs', petBuffsSize),
        PetCombatOn        = r('Pet','PetCombatOn'),
        PetAssistAt        = r('Pet','PetAssistAt'),
        PetAttackDistance  = r('Pet','PetAttackDistance'),
        PetToysSize        = petToysSize,
        PetToysOn          = r('Pet','PetToysOn'),
        PetToysGave        = r('Pet','PetToysGave'),
        PetToys            = ra('Pet','PetToys', petToysSize),
        PetBreakMezSpell   = r('Pet','PetBreakMezSpell'),
        PetRampPullWait    = r('Pet','PetRampPullWait'),
        PetSuspend         = r('Pet','PetSuspend'),
        MoveWhenHit        = r('Pet','MoveWhenHit'),
        PetHoldOn          = r('Pet','PetHoldOn'),
        PetForceHealOnMed  = r('Pet','PetForceHealOnMed'),
        PetTauntOverride   = r('Melee','PetTauntOverride'),  -- .mac stored under [Melee]; Lua port uses [Pet]
    }

    -- [Merc] — mercenary assist settings
    cfg.Merc = {
        MercOn       = r('Merc','MercOn'),
        MercAssistAt = r('Merc','MercAssistAt'),
    }

    -- [Mez] — mez spell assignments (BRD/ENC/NEC only)
    cfg.Mez = {
        MezOn             = r('Mez','MezOn'),
        MezRadius         = r('Mez','MezRadius'),
        MezMinLevel       = r('Mez','MezMinLevel'),
        MezMaxLevel       = r('Mez','MezMaxLevel'),
        MezStopHPs        = r('Mez','MezStopHPs'),
        MezSpell          = r('Mez','MezSpell'),
        MezDebuffOnResist = r('Mez','MezDebuffOnResist'),
        MezDebuffSpell    = r('Mez','MezDebuffSpell'),
        MezAESpell        = r('Mez','MezAESpell'),
    }

    -- [Charm] — charm settings (DRU/ENC/NEC/BRD only)
    cfg.Charm = {
        CharmOn       = r('Charm','CharmOn'),
        CharmSpell    = r('Charm','CharmSpell'),
        CharmMinLevel = r('Charm','CharmMinLevel'),
        CharmMaxLevel = r('Charm','CharmMaxLevel'),
        CharmRadius   = r('Charm','CharmRadius'),
        CharmKeep     = r('Charm','CharmKeep'),
    }

    -- [Burn] — burn phase spell/disc list (numbered array, sorted by priority)
    local burnSize = tonumber(r('Burn','BurnSize')) or 15
    cfg.Burn = {
        BurnAllNamed = r('Burn','BurnAllNamed'),
        UseTribute   = r('Burn','UseTribute'),
        BurnSize     = burnSize,
        Burn         = ra('Burn','Burn', burnSize),
    }

    -- [Pull] — pull settings and mob lists; zone-specific lists live in KissAssist_Info.ini
    cfg.Pull = {
        PullWith        = r('Pull','PullWith'),
        PullMeleeStick  = r('Pull','PullMeleeStick'),
        MaxRadius       = r('Pull','MaxRadius'),
        MaxZRange       = r('Pull','MaxZRange'),
        UseWayPointZ    = r('Pull','UseWayPointZ'),
        PullWait        = r('Pull','PullWait'),
        PullRadiusToUse = r('Pull','PullRadiusToUse'),
        PullRoleToggle  = r('Pull','PullRoleToggle'),
        ChainPull       = r('Pull','ChainPull'),
        ChainPullHP     = r('Pull','ChainPullHP'),
        PullPause       = r('Pull','PullPause'),
        PullLevel       = r('Pull','PullLevel'),
        PullArcWidth    = r('Pull','PullArcWidth'),
        PullTwistOn     = r('Pull','PullTwistOn'),
        PullOnReturn    = r('Pull','PullOnReturn'),
    }

    -- [PullAdvanced] — waypoint pull locations (numbered array)
    cfg.PullAdvanced = {
        PullLocsOn = r('PullAdvanced','PullLocsOn'),
        PullLocs   = ra('PullAdvanced','PullLocs', 5),
    }

    -- [AFKTools] — GM detection and death handling
    cfg.AFKTools = {
        AFKToolsOn      = r('AFKTools','AFKToolsOn'),
        AFKGMAction     = r('AFKTools','AFKGMAction'),
        AFKPCRadius     = r('AFKTools','AFKPCRadius'),
        CampOnDeath     = r('AFKTools','CampOnDeath'),
        ClickBacktoCamp = r('AFKTools','ClickBacktoCamp'),
    }

    -- [KConditions] — conditional expressions for pull hold and other logic
    local condSize = tonumber(r('KConditions','CondSize')) or 5
    cfg.KConditions = {
        ConOn    = r('KConditions','ConOn'),
        CondSize = condSize,
        Cond     = ra('KConditions','Cond', condSize),
    }

    -- 3. Bard: convert MQ2Twist slot lists → MQ2Medley sections (one-time migration).
    migrateBardMedley(r, cfg)

    -- 3b. Purge any fields not in the schema (covers all .mac orphans generically).
    purgeOrphanedFields(cfg)

    -- 4. Ensure output directory exists and write pickle.
    local dir = pickleDir:gsub('/', '\\')
    os.execute(string.format('if not exist "%s" mkdir "%s"', dir, dir))
    _picklePath = picklePath
    mq.pickle(picklePath, cfg)

    -- 4. Rename original INI to .bak (INI lives in mq.configDir alongside other MQ2 configs).
    local iniFullPath = mq.configDir .. '/' .. iniFile
    local renamed = os.rename(iniFullPath, iniFullPath .. '.bak')
    if renamed then
        printf('\agKissAssist: \awMigration complete. Backup: \at%s.bak', iniFile)
    else
        printf('\ayKissAssist: \awPickle written to \at%s\aw — could not rename INI (may be in a different path). Rename \at%s\aw to \at%s.bak\aw manually to avoid re-migration.', pickleName, iniFile, iniFile)
    end

    return cfg
end

-- Returns a role-neutral starter config table with empty/zero values for all sections.
-- Used when no INI and no pickle exist so the character gets a persistent file on first run.
function Config.defaultCfg()
    local function emptyArr(n) local t = {} for i = 1, n do t[i] = 'null' end return t end
    return {
        General = {
            KissAssistVer    = Config.VERSION,
            Role             = '', CampRadius = '40', CampRadiusExceed = '0',
            ReturnToCamp     = '0', ChaseAssist = '0', ChaseDistance = '40',
            MedOn            = '1', MedStart = '40', MedStop = '90', MedCombat = '0',
            LootOn           = '1', RezAcceptOn = '1', AcceptInvitesOn = '0',
            GroupWatchOn     = '0', GroupWatchCheck = '20', CorpseRecoveryOn = '0',
            EQBCOn           = '0', DanNetOn = '1', DanNetDelay = '25',
            IRCOn            = '0', CampfireOn = '0', GroupEscapeOn = '0',
            DPSMeter         = '0', ScatterOn = '0', LOSBeforeCombat = '0',
            UseSpawnMaster   = '0', TwistOn = '0',
            OORMedley = 'oor', MeleeMedley = 'melee', BurnMedley = 'burn', GoMMedley = 'gomSong',
            MountOn          = '0',
        },
        SpellSets = {
            MiscGem = '0', MiscGemLW = '0', MiscGemRemem = '0',
            LoadSpellSet = '0', SpellSetName = '',
        },
        Spells = {
            CastingInterruptOn = '0', CheckStuckGem = '0',
            Gems = {},
        },
        Melee = {
            AssistAt = '95', MeleeOn = '1', FaceMobOn = '0', MeleeDistance = '20',
            StickHow = 'behind', AutoFireOn = '0', UseMQ2Melee = '0',
            TargetSwitchingOn = '0', AutoHide = '0', MeleeTwistOn = '0',
        },
        DPS = {
            DPSOn = '1', DPSSize = '5', DPSSkip = '0', DPSInterval = '0',
            DebuffAllOn = '0', DPS = emptyArr(5),
        },
        Buffs = {
            BuffsOn = '1', BuffsSize = '5', RebuffOn = '1', CheckBuffsTimer = '60',
            PowerSource = '', Buffs = emptyArr(5),
        },
        Heals = {
            HealsOn = '0', HealsSize = '5', HealInterval = '0', AutoRezOn = '0',
            XTarHeal = '0', XTarHealList = '', HealGroupPetsOn = '0',
            RezMeLast = '0', Heals = emptyArr(5),
        },
        Cures = {
            CuresOn = '0', CuresSize = '5', Cures = emptyArr(5),
        },
        Pet = {
            PetOn = '0', PetSpell = '', PetFocus = '', PetShrinkOn = '0',
            PetShrinkSpell = '', PetBuffsOn = '0', PetBuffsSize = '5',
            PetBuffs = emptyArr(5), PetCombatOn = '0', PetAssistAt = '100',
            PetAttackDistance = '60', PetToysSize = '5', PetToysOn = '0',
            PetToysGave = '0', PetToys = emptyArr(5), PetBreakMezSpell = '',
            PetRampPullWait = '0', PetSuspend = '0', MoveWhenHit = '0',
            PetHoldOn = '0', PetForceHealOnMed = '0', PetTauntOverride = '0',
        },
        Mez = {
            MezOn = '0', MezRadius = '40', MezMinLevel = '1', MezMaxLevel = '115',
            MezStopHPs = '50', MezSpell = '', MezDebuffOnResist = '0',
            MezDebuffSpell = '', MezAESpell = '',
        },
        Charm = {
            CharmOn = '0', CharmSpell = '', CharmMinLevel = '5', CharmMaxLevel = '0',
            CharmRadius = '50', CharmKeep = '0',
        },
        Burn = {
            BurnOn = '1', BurnAllNamed = '0', UseTribute = '0', BurnSize = '5', Burn = emptyArr(5),
        },
        Aggro = {
            AggroOn = '0', AggroSize = '5', Aggro = emptyArr(5),
        },
        GoM = {
            GoMSize = '3', GoMSpell = emptyArr(3),
        },
        AE = {
            AEOn = '0', AESize = '5', AERadius = '40', AE = emptyArr(5),
        },
        Pull = {
            PullWith = 'Melee', PullRange = '15', PullMeleeStick = '0', MaxRadius = '200', MaxZRange = '75',
            UseWayPointZ = '0', PullWait = '5', PullRadiusToUse = '1',
            PullRoleToggle = '0', ChainPull = '0', ChainPullHP = '80',
            PullPause = '0', PullLevel = '0', PullArcWidth = '0',
            PullTwistOn = '0', PullOnReturn = '0',
        },
        PullAdvanced = {
            PullLocsOn = '0', PullLocs = emptyArr(5),
        },
        Merc = {
            MercOn = '0', MercAssistAt = '95',
        },
        AFKTools = {
            AFKToolsOn = '0', AFKGMAction = '1', AFKPCRadius = '30',
            CampOnDeath = '0', ClickBacktoCamp = '0',
        },
        KConditions = {
            ConOn = '1', CondSize = '5', Cond = emptyArr(5),
        },
    }
end

-- Parse a single INI entry that may carry a |condNNN suffix.
-- Returns stripped name and condition slot number (0 = no condition).
-- e.g. "Harm Touch|cond001" → "Harm Touch", 1
local function extractCond(entry)
    local pos = entry:find('|cond')
    if not pos then return entry, 0 end
    local condNo = tonumber(entry:sub(pos + 5, pos + 7)) or 0
    return entry:sub(1, pos - 1), condNo
end

-- Convert a raw string array (as loaded from the pickle) into an array of
-- { name, condNo } slot tables.  Nil/absent entries are preserved as
-- { name = entry, condNo = 0 } so index positions stay stable.
-- Used by combat, buffs, healing, and cast modules at init time.
function Config.parseCondArray(arr)
    if not arr then return {} end
    local out = {}
    for i, v in ipairs(arr) do
        if v then
            local name, condNo = extractCond(v)
            out[i] = { name = name, condNo = condNo }
        end
    end
    return out
end

-- Read a value from the loaded config. Returns default if section/key absent.
-- All values are stored as strings (matching INI); callers convert types as needed.
function Config.get(section, key, default)
    if not _cfg then return default end
    local sec = _cfg[section]
    if not sec then return default end
    local val = sec[key]
    if val == nil then return default end
    return val
end

-- Mutate a single key in the live config table (does not write to disk).
function Config.set(section, key, value)
    if not _cfg then return end
    if not _cfg[section] then _cfg[section] = {} end
    _cfg[section][key] = value
end

-- Flush the current in-memory config table back to its pickle file.
-- No-op if the pickle path was never resolved (e.g. no INI and no pickle on first run).
function Config.save()
    if not _cfg or not _picklePath then return end
    mq.pickle(_picklePath, _cfg)
end

-- Write the character's current memorised gem loadout into [Spells] and save.
-- Mirrors Bind_WriteMySpells from kissassist.mac.
function Config.writeSpells(state)
    local gemSlots = state.cast.gemSlots or 8
    local gems = {}
    for i = 1, gemSlots do
        gems[i] = mq.TLO.Me.Gem(i).Name() or 'null'
    end
    Config.set('Spells', 'Gems', gems)
    Config.save()
end

-- Load config: resolve INI name, migrate if needed, store for Config.get().
function Config.load(state)
    Config.resolveIniName(state)
    _cfg = Config.migrateIni(state)
end

-- Load and validate required plugins.
local REQUIRED_PLUGINS = {
    'MQ2Exchange', 'MQ2MoveUtils', 'MQ2Posse', 'MQ2Rez', 'MQ2AutoLoot',
}

function Config.checkPlugins()
    local failed = {}
    for _, plugin in ipairs(REQUIRED_PLUGINS) do
        if not mq.TLO.Plugin(plugin)() then
            printf('\ayKissAssist: loading missing plugin \aw%s', plugin)
            mq.cmdf('/plugin %s load', plugin)
            mq.delay(500)
            if not mq.TLO.Plugin(plugin)() then
                failed[#failed+1] = plugin
            end
        end
    end
    if #failed > 0 then
        printf('\arKissAssist: failed to load required plugins: \aw%s', table.concat(failed, ', '))
        return false
    end
    return true
end

return Config
