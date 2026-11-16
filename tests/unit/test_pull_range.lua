-- tests/unit/test_pull_range.lua
-- Pull.rangeSet (#225): pull range derived from PullWith, mirroring
-- Sub PullRangeSet (mac:8857) and Sub PullVars (mac:8935).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_range')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session = { role = 'puller', infoFileName = '', zoneName = '' },
        pull    = {},
        timers  = {},
        heal    = { medOn = false },
        combat  = { aggroTargetID = '' },
        pet     = { attackRange = 100 },
    }
    Pull.init(state, {
        debug = function() end,
        zoneIniGet = function() return nil end,
        resolveSpellRank = require('modules.utils').resolveSpellRank,
    })
    local p = state.pull

    local function callable(v) return function() return v end end

    -- env = { items = { [name] = {type=, range=, spellRange=, ammo=bool, count=} },
    --         book = { [name]=myRange }, aa = { [name]=range }, disc = { [name]=myRange },
    --         rank = { [baseName]=rankName } }
    local function setEnv(env)
        MockMQ.reset()
        local items = env.items or {}
        MockMQ.set('TLO.FindItemCount', function(q)
            local it = items[q:sub(2)]
            return callable(it and (it.count or 1) or 0)
        end)
        MockMQ.set('TLO.FindItem', function(q)
            local it = items[q:sub(2)] or {}
            return {
                Type     = callable(it.type),
                Range    = callable(it.range),
                WornSlot = function() return callable(it.ammo == true) end,
                Spell    = { Range = callable(it.spellRange) },
            }
        end)
        local book, aa, disc, rank = env.book or {}, env.aa or {}, env.disc or {}, env.rank or {}
        MockMQ.set('TLO.Me.Book', function(n) return callable(book[n] and 1 or nil) end)
        MockMQ.set('TLO.Me.CombatAbility', function(n) return callable(disc[n] and 1 or nil) end)
        MockMQ.set('TLO.Me.AltAbility', function(n)
            return setmetatable({ Spell = { Range = callable(aa[n]) } },
                { __call = function() return aa[n] and 1 or nil end })
        end)
        MockMQ.set('TLO.Spell', function(n)
            return { MyRange = callable(book[n] or disc[n]), RankName = callable(rank[n]) }
        end)
    end

    local function check(with, pct, wantRange, wantWith, label)
        p.withAlt, p.radiusToUse = with, pct
        Pull.rangeSet()
        TH.assert_eq(p.range, wantRange, label .. ': range')
        TH.assert_eq(p.withAlt, wantWith, label .. ': PullWith')
    end

    setEnv({})
    check('Melee', 90, 15, 'Melee', 'Melee')
    check('melee', 90, 15, 'Melee', 'melee (lowercase) normalized')
    check('Pet', 90, 185, 'Pet', 'Pet')
    state.session.role = 'hunterpettank'
    check('Pet', 90, 80, 'Pet', 'Pet as hunterpettank = 80% of PetAttackRange')
    state.session.role = 'puller'

    -- Spell, disc, AA: scaled by PullRadiusToUse.
    setEnv({ book = { Snare = 200 } })
    check('Snare', 90, 180, 'Snare', 'spell MyRange x 90%')
    check('Snare', 50, 100, 'Snare', 'spell MyRange x 50%')
    setEnv({ disc = { Throw = 100 } })
    check('Throw', 90, 90, 'Throw', 'disc MyRange x 90%')
    setEnv({ aa = { ['Dire Charm'] = 250 } })
    check('Dire Charm', 100, 250, 'Dire Charm', 'AA spell range x 100%')

    -- Base name with only a ranked version owned: resolve to that rank.
    setEnv({ book = { ['Terror of Ander Rk. II'] = 200 } })
    check('Terror of Ander', 90, 180, 'Terror of Ander Rk. II', 'spell Rk. II from base name')
    setEnv({ book = { ['Terror of Ander Rk. III'] = 200 } })
    check('Terror of Ander', 90, 180, 'Terror of Ander Rk. III', 'spell Rk. III from base name')
    setEnv({ disc = { ['Throw Rk. II'] = 100 }, rank = { Throw = 'Throw Rk. II' } })
    check('Throw', 90, 90, 'Throw Rk. II', 'disc rank via Spell.RankName')

    -- Bow|Arrow: bow + arrow range, PullWith becomes Ranged.
    setEnv({ items = {
        Longbow = { type = 'Archery', range = 200 },
        Arrow   = { type = 'Ammo', range = 50, ammo = true },
    } })
    p.range = 0
    check('Longbow|Arrow', 100, 250, 'Ranged', 'bow + arrow range')
    TH.assert_eq(p.item, 'Longbow', 'bow stored as PullItem')
    TH.assert_eq(p.ammo, 'Arrow',   'arrow stored as PullAmmo')
    -- 'Ranged' afterwards keeps the range.
    check('Ranged', 100, 250, 'Ranged', 'Ranged keeps derived range')

    -- Throwing item: no ammo bonus; zero range -> 50.
    setEnv({ items = {
        Dagger = { type = 'Throwing', range = 0 },
        Stack  = { type = 'Ammo', range = 99, ammo = true },
    } })
    check('Dagger|Stack', 100, 50, 'Ranged', 'throwing: 0 range -> 50, no ammo bonus')

    -- Bow with no ammo -> Melee.
    setEnv({ items = { Longbow = { type = 'Archery', range = 200 } } })
    check('Longbow|Arrow', 90, 15, 'Melee', 'bow without ammo falls back to Melee')

    -- Clicky item: its spell's range.
    setEnv({ items = { Wand = { type = 'Misc', spellRange = 150 } } })
    check('Wand', 90, 135, 'Wand', 'clicky item spell range x 90%')

    -- Unknown method: range unchanged.
    setEnv({})
    p.range = 42
    check('Nothing', 90, 42, 'Nothing', 'unknown PullWith keeps range')

    package.loaded['modules.pull'] = nil
end

return M
