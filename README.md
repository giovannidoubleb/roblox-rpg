# roblox-rpg

Roblox RPG project, built with [Rojo](https://rojo.space/). Numbers and
systems below follow the project's "Core RPG Loop Design" and "Ledger &
Loot" (monetization) design docs.

## Structure

- `src/server` — server-only code, synced into `ServerScriptService`
- `src/client` — client-only code, synced into `StarterPlayerScripts`
- `src/shared` — code required by both sides, synced into `ReplicatedStorage`

## Getting started

1. Install [Aftman](https://github.com/LPGhatguy/aftman) if you don't have it, then run `aftman install` in this directory to get the pinned Rojo version.
2. Open Roblox Studio and install the [Rojo plugin](https://create.roblox.com/store/asset/13916111004/Rojo).
3. Run `rojo serve` in this directory.
4. In Studio, click "Connect" in the Rojo plugin. The hub, corridor, dungeon room, and Wilds zone are all built at runtime (`MapService`), so you can hit Play immediately.

## Controls

- **Mouse1 / Touch / Right Trigger** — basic attack
- **1 / Gamepad X** — Cleave (frontal AoE)
- **2 / Gamepad Y** — Power Strike (single-target burst)
- **R / Gamepad B** — Ultimate, once the meter is full
- **I** — inventory (equip loot)
- **J** — daily quests, streak, and login bonus claim
- **K** — skill points (allocate on level-up, respec with a token)
- **C** — crafting (combine loot into a guaranteed upgrade)
- **B** — merchant shop (cosmetics and companions, gems)
- **M** — zone travel menu
- **N** — set a nickname (consumes a Character Rename Token)
- **P** — season pass track
- Touch the purple portal at the edge of the hub to spend a key and start the daily dungeon run (a private instance, not shared with other players)
- Touch the glowing pillar (shrine) in the hub or the Wilds to travel between zones on foot
- Talk to the Quest Giver or Merchant NPCs near spawn to open their panels directly

## What's implemented

- **Persistence** (`PlayerProfileStore`, `PlayerDataService`) — DataStore-backed
  player profiles with retry/backoff and a per-profile session lock (keyed by
  `game.JobId`) so two servers can't load/save the same player at once. If
  DataStore access isn't available (e.g. an unpublished place opened
  directly in Studio), the profile degrades to in-memory-only for that
  session instead of erroring or blocking the player.
- **Leveling & skills** — the design doc's XP curve, level cap 50, +10 base
  max HP per level, plus one skill point per level spent into Damage/Max
  Health/Crit Chance (`SkillController`); a Stat Respec Token refunds
  everything.
- **Combat** (`CombatService`, `EnemyService`) — server-authoritative basic
  attack, Cleave, Power Strike, and an ultimate, all range/facing/cooldown-
  checked server-side, plus crit chance and floating damage numbers. Seven
  enemy kinds (Slime, Skeleton, Bandit, Dire Wolf, Warlock, Stone Golem,
  Ancient Treant) share three power tiers (Trash/Elite/Boss); some are
  ranged and lob a visible bolt instead of needing to close to melee.
- **Loot & crafting** (`ItemDatabase`, `LootTable`, `LootService`,
  `CraftingService`) — the design doc's rarity tables, 15-boss pity counter,
  a 15-item catalog, and a crafting ladder (4 unequipped items of a rarity →
  1 guaranteed item of the next rarity up, on a timer a Crafting Rush charge
  shortens).
- **Inventory/equipment** (`PlayerDataService`, `InventoryController`) — loot
  goes into a real per-player inventory (capped, expandable via Backpack
  Expansion), can be equipped, and sorts by rarity automatically for AutoSort
  pass owners.
- **Daily structure** (`Config.Daily`, `PlayerDataService`,
  `DailyController`) — 3 keys/day (8h regen), 3 daily quests re-rolled from a
  pool each calendar day, and a login streak (1-7, escalating gem reward).
- **Dungeon** (`DungeonService`) — the portal spends a key and teleports you
  into a private instance of the dungeon room (a fresh copy built per run,
  torn down after), with three waves of trash before the boss — concurrent
  runs never collide or aggro each other.
- **A second zone** (`LevelLayout`, `ZoneService`) — the Wilds, reached via
  shrines in the hub or the zone travel menu ("M"), with its own tougher
  enemies and a respawning field boss. Fast Travel (pass) and Zone Skip Key
  (product) unlock instant travel from anywhere once a zone's been reached
  on foot at least once.
- **NPCs** (`NpcService`) — a Quest Giver and a Merchant near spawn, each
  with a name tag and a proximity prompt that opens their panel.
- **Companions & cosmetics** (`CompanionService`, `CosmeticController`,
  `MerchantController`) — cosmetic follower pets and character color/material
  re-skins, bought from the merchant with gems (slots/unlocks also granted by
  the Companion Slot Expansion pass and Mystery Cosmetic Crate product).
  Both replicate to everyone via Player attributes, not just the owner.
- **Nicknames** (`NicknameController`) — a settable, TextService-filtered
  display nickname (consumes a Character Rename Token) shown as a name tag
  above the character for every player.
- **Season pass** (`SeasonController`) — a level-gated reward track (9 tiers
  to level 50); claiming a reached tier requires owning the Season Pass.
- **Instant Revive** — dying with a token drops you back at your death spot
  at full health a few seconds later instead of the full respawn walk-back.
- **Founder's Pass & AutoSort** — Founder's Pass grants a one-time gem bonus
  plus a permanent XP boost; AutoSort sorts the inventory panel by rarity.
- **Feedback** (`FeedbackController`, `DeathController`, `Sfx`) — floating
  damage numbers, a red flash on taking damage, a level-up flash/sound, hit/
  loot/quest/ultimate-ready sounds (built-in `rbxasset://` sounds, no owned
  asset IDs needed), and a real "You Died" screen instead of just watching
  the ragdoll.
- **Level geometry** (`LevelLayout`, `MapService`) — a connected hub, corridor,
  dungeon room, and the separate Wilds zone, all built from parts at runtime.
  Still code-built blockout geometry, not Studio-authored art — no assets
  exist yet.
- **Monetization** (`Config.Monetization`, `MonetizationService`) — every
  Game Pass and Developer Product in the "Ledger & Loot" plan now has a real
  effect when granted (see below); purchases are idempotent (every granted
  receipt is recorded in the player's profile, so a retried `ProcessReceipt`
  never double-grants). Every ID in `Config.Monetization` still starts at `0`
  ("not created yet") and is skipped until filled in.
- **HUD & UI polish** — health/XP/ultimate-meter bars, level, gems, and key
  count, all panels (Inventory, Daily, Skills, Crafting, Merchant, Zones,
  Season, Nickname) sharing a common rounded-panel/rounded-button look
  (`UiKit`), and an input bridge (`CombatController`) that works with mouse,
  touch, and gamepad.

## Before this can sell anything

Monetization code is fully wired up but inert until you:

1. In the Roblox Creator Dashboard, create the Game Passes and Developer
   Products from the "Ledger & Loot" plan (or however many you want to
   launch with first).
2. Paste each one's asset ID into `Config.Monetization.GamePasses` /
   `DeveloperProducts` in `src/shared/Modules/Config.luau`, replacing the
   `0` placeholder.
3. Push/republish — `MonetizationService` picks up any non-zero ID
   automatically, no other code changes needed.

Every pass and product now has a real underlying system to grant into — see
`MonetizationService.grantProduct` and the pass checks throughout
`PlayerDataService`/`CombatService`/`ZoneService` for what each one does.

## What's not built yet

- Studio-authored level/character art and real sound effects — geometry is
  still code-built blockout, characters are recolored defaults, and audio
  is Roblox's built-in placeholder sounds. None of this needs asset IDs to
  *work*, just to look/sound like a finished game.
- A skill tree with branching choices — currently three flat stats
  (Damage/Health/Crit Chance), not a tree with meaningful build paths.
- Companion combat stats — companions are purely cosmetic followers.
