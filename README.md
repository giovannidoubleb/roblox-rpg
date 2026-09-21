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
4. In Studio, click "Connect" in the Rojo plugin. A hub/corridor/dungeon layout and spawn point are built at runtime (`MapService`), so you can hit Play immediately.

## Controls

- **Mouse1 / Touch / Right Trigger** — basic attack
- **1 / Gamepad X** — Cleave (frontal AoE)
- **2 / Gamepad Y** — Power Strike (single-target burst)
- **R / Gamepad B** — Ultimate, once the meter is full
- **I** — inventory (equip loot)
- **J** — daily quests, streak, and login bonus claim
- Touch the purple portal at the edge of the hub to spend a key and start the daily dungeon run

## What's implemented

- **Persistence** (`PlayerProfileStore`, `PlayerDataService`) — DataStore-backed
  player profiles with retry/backoff and a per-profile session lock (keyed by
  `game.JobId`) so two servers can't load/save the same player at once.
- **Leveling** — the design doc's curve, `XP_to_next(L) = 50 * L^1.5`, level
  cap 50, +10 base max HP per level (plus equipment bonuses, see Inventory).
- **Combat** (`CombatService`, `EnemyService`) — server-authoritative basic
  attack, Cleave (frontal AoE), Power Strike (single-target burst), and an
  ultimate (radius nova, fueled by a meter that fills from basic attacks) —
  all range/facing/cooldown-checked server-side against trash/elite/boss NPCs
  with a simple chase-and-melee AI.
- **Loot** (`ItemDatabase`, `LootTable`, `LootService`) — the design doc's
  per-kill rarity table and the better-weighted boss/chest table, the
  15-boss-kill pity counter, and an actual item catalog (weapons add attack
  damage, armor/trinkets add max health) instead of just a name.
- **Inventory/equipment** (`PlayerDataService`, `InventoryController`) — loot
  is added to a real per-player inventory (capped, expandable via the
  Backpack Expansion pass) and can be equipped; equipped stats apply to
  combat damage and max health immediately. No unequip yet — re-equip a
  different item into the same slot to swap.
- **Daily structure** (`Config.Daily`, `PlayerDataService`,
  `DailyController`) — 3 keys/day (8h regen), 3 daily quests re-rolled from a
  pool each calendar day, and a login streak (1-7, escalating gem reward,
  cycles) claimed via a button in the daily panel.
- **Dungeon gate** (`DungeonService`, the portal in the hub) — touching the
  portal spends a key and spawns a small trash-then-boss wave in the dungeon
  room; killing the boss reports the "complete the dungeon" quest. This is
  scaled down from the design doc's full 15-25 mob run, and the dungeon room
  is shared rather than a private instance per player (see code comments in
  `DungeonService`) — real instancing needs TeleportService/reserved
  servers, a bigger feature for later.
- **Level geometry** (`LevelLayout`, `MapService`) — a connected hub (open
  field grinding), corridor, and dungeon room built from parts at runtime.
  Still code-built blockout geometry, not Studio-authored art — no assets
  exist yet.
- **Monetization plumbing** (`Config.Monetization`, `MonetizationService`) —
  Game Pass ownership checks and idempotent Developer Product purchase
  granting (every granted receipt is recorded in the player's profile so a
  retried `ProcessReceipt` never double-grants). Every pass/product ID in
  `Config.Monetization` starts at `0` ("not created yet") and is skipped
  until filled in — **see "Before this can sell anything" below.**
- **HUD** — health/XP/ultimate-meter bars, level, gems, and key count
  (`HudController`), loot and generic toasts (`LootController`,
  `NotifyController`, `ToastController`), and an input bridge
  (`CombatController`) that works with mouse, touch, and gamepad.

## Before this can sell anything

Monetization code is wired up but inert until you:

1. In the Roblox Creator Dashboard, create the Game Passes and Developer
   Products from the "Ledger & Loot" plan (or however many you want to
   launch with first — the plan's own phased rollout suggests starting with
   just Founder's Pass, Backpack Expansion, Gem Pouches, and the Respec
   Token).
2. Paste each one's asset ID into `Config.Monetization.GamePasses` /
   `DeveloperProducts` in `src/shared/Modules/Config.luau`, replacing the
   `0` placeholder.
3. Push/republish — `MonetizationService` picks up any non-zero ID
   automatically, no other code changes needed.

Only Gem Pouches and the passes that map onto systems already built here
(Double XP, Backpack Expansion) currently *do* anything when granted. The
rest (Instant Revive, Stat Respec, Mystery Crate, Rename, Zone Skip,
Crafting Rush, Season Pass) are granted (Roblox requires that, or it keeps
retrying/eventually refunds) but have no effect until their underlying
systems exist — see the comment in `MonetizationService.grantProduct`.

## What's not built yet

- Skill-tree respec, cosmetics, zone system, crafting, and a season track —
  the systems several Developer Products are meant to plug into.
- Private dungeon instancing (currently a shared, tagged room — see above).
- A full 15-25 mob dungeon run; currently a handful of trash + one boss.
- Studio-authored level art; the layout is code-built blockout geometry.
