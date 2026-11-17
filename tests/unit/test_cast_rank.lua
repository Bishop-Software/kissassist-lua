-- tests/unit/test_cast_rank.lua
-- Utils.resolveCastRank (castWhat) and Utils.resolveSpellRank (buffs, pull).
-- A disc entry like 'Fyrthek Mantle' must resolve to the owned 'Fyrthek Mantle Rk. II';
-- discs are not in the spellbook, so a book/gem-only lookup left the base name and
-- castWhat reported "not found" (and buff |End readiness checks never passed).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_cast_rank')
    local Utils = require('modules.utils')

    local function callable(v) return function() return v end end

    -- env = { book = {[name]=true}, gem = {[name]=true}, disc = {[name]=true} }
    local function setEnv(env)
        MockMQ.reset()
        local book, gem, disc = env.book or {}, env.gem or {}, env.disc or {}
        MockMQ.set('TLO.Me.Book',          function(n) return callable(book[n] and 1 or nil) end)
        MockMQ.set('TLO.Me.Gem',           function(n) return callable(gem[n] and n or nil) end)
        MockMQ.set('TLO.Me.CombatAbility', function(n) return callable(disc[n] and 1 or nil) end)
    end

    -- Disc owned only at Rk. II: base name resolves to the ranked name.
    setEnv({ disc = { ['Fyrthek Mantle Rk. II'] = true } })
    TH.assert_eq(Utils.resolveCastRank('Fyrthek Mantle'), 'Fyrthek Mantle Rk. II',
        'disc base name -> Rk. II')

    -- Disc owned only at Rk. III.
    setEnv({ disc = { ['Ignominious Influence Rk. III'] = true } })
    TH.assert_eq(Utils.resolveCastRank('Ignominious Influence'), 'Ignominious Influence Rk. III',
        'disc base name -> Rk. III')

    -- Disc with no rank (e.g. Spite of Mirenilla): unchanged.
    setEnv({ disc = { ['Spite of Mirenilla'] = true } })
    TH.assert_eq(Utils.resolveCastRank('Spite of Mirenilla'), 'Spite of Mirenilla',
        'unranked disc unchanged')

    -- Already-ranked entry is left alone.
    setEnv({ disc = { ['Fyrthek Mantle Rk. II'] = true } })
    TH.assert_eq(Utils.resolveCastRank('Fyrthek Mantle Rk. II'), 'Fyrthek Mantle Rk. II',
        'ranked disc name unchanged')

    -- Spell in the book at Rk. II (existing behavior).
    setEnv({ book = { ['Touch of Txiki Rk. II'] = true } })
    TH.assert_eq(Utils.resolveCastRank('Touch of Txiki'), 'Touch of Txiki Rk. II',
        'book spell base name -> Rk. II')

    -- Spell memorized at Rk. II but checked by exact gem name (existing behavior).
    setEnv({ gem = { ['Dire Censure Rk. II'] = true } })
    TH.assert_eq(Utils.resolveCastRank('Dire Censure'), 'Dire Censure Rk. II',
        'gem spell base name -> Rk. II')

    -- Not owned anywhere (AA, item, skill, typo): unchanged.
    setEnv({})
    TH.assert_eq(Utils.resolveCastRank('Harm Touch'), 'Harm Touch', 'unowned name unchanged')

    -- Utils.resolveSpellRank (buffs, pull): book and combat abilities, no gem check.
    -- A buff entry like "Night's Calming|End|25" feeds Me.CombatAbilityReady, which
    -- needs the exact ranked name.
    setEnv({ disc = { ["Night's Calming Rk. II"] = true } })
    TH.assert_eq(Utils.resolveSpellRank("Night's Calming"), "Night's Calming Rk. II",
        'resolveSpellRank: disc base name -> Rk. II')

    setEnv({ disc = { ['Spite of Mirenilla'] = true } })
    TH.assert_eq(Utils.resolveSpellRank('Spite of Mirenilla'), 'Spite of Mirenilla',
        'resolveSpellRank: unranked disc unchanged')

    setEnv({ book = { ['Xenacious\' Skin Rk. III'] = true } })
    TH.assert_eq(Utils.resolveSpellRank('Xenacious\' Skin'), 'Xenacious\' Skin Rk. III',
        'resolveSpellRank: book spell base name -> Rk. III')

    -- Gem-only match is deliberately not used here (buff target-type lookup reads the book).
    setEnv({ gem = { ['Dire Censure Rk. II'] = true } })
    TH.assert_eq(Utils.resolveSpellRank('Dire Censure'), 'Dire Censure',
        'resolveSpellRank: gem-only spell unchanged')

    setEnv({})
    TH.assert_eq(Utils.resolveSpellRank('Harm Touch'), 'Harm Touch',
        'resolveSpellRank: unowned name unchanged')
end

return M
