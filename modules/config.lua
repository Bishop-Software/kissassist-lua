local mq = require('mq')

local Config = {}

-- Loaded config table (populated by Config.load, consumed by modules at startup).
local _cfg = nil

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
            printf('\agKissAssist: \awLoaded config from \at%s', pickleName)
            return cfg
        end
        printf('\arKissAssist: \awPickle found but failed to load — re-migrating from INI.')
    end

    -- 2. Check INI exists via TLO (handles path resolution automatically).
    local ver = mq.TLO.Ini(iniFile, 'General', 'KissAssistVer')()
    if not ver then
        printf('\ayKissAssist: \awNo INI found (%s) — using defaults.', iniFile)
        return nil
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
        KissAssistVer    = ver,
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
        MountOn          = r('General','MountOn'),
        MountSpell       = r('General','MountSpell'),
    }

    -- [SpellS] / [Spells] — gem assignments and casting options
    cfg.SpellS = {
        MiscGem          = r('SpellS','MiscGem'),
        MiscGemLW        = r('SpellS','MiscGemLW'),
        MiscGemRemem     = r('SpellS','MiscGemRemem'),
        LoadSpellSet     = r('SpellS','LoadSpellSet'),
        SpellSetName     = r('SpellS','SpellSetName'),
    }
    cfg.Spells = {
        CastingInterruptOn = r('Spells','CastingInterruptOn'),
        CheckStuckGem      = r('Spells','CheckStuckGem'),
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
        PetTauntOverride  = r('Melee','PetTauntOverride'),
    }

    -- [GoM] — Gift of Mana / proc spells (numbered array)
    local gomSize = tonumber(r('GoM','GoMSize')) or 3
    cfg.GoM = {
        GoMSHelp = r('GoM','GoMSHelp'),
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

    -- 3. Ensure output directory exists and write pickle.
    os.execute('if not exist "' .. pickleDir:gsub('/','\\') .. '" mkdir "' .. pickleDir:gsub('/','\\') .. '"')
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

-- Load config: resolve INI name, migrate if needed, store for Config.get().
function Config.load(state)
    Config.resolveIniName(state)
    _cfg = Config.migrateIni(state)
end

-- Validate required plugins. Mirrors InitPlugins() from kissassist.mac.
local REQUIRED_PLUGINS = {
    'MQ2Exchange', 'MQ2MoveUtils', 'MQ2Posse', 'MQ2Rez',
}

function Config.checkPlugins()
    local missing = {}
    for _, plugin in ipairs(REQUIRED_PLUGINS) do
        if not mq.TLO.Plugin(plugin)() then
            missing[#missing+1] = plugin
        end
    end
    if #missing > 0 then
        printf('\arKissAssist: missing required plugins: \aw%s', table.concat(missing, ', '))
    end
    return #missing == 0
end

return Config
