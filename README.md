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
4. In Studio, click "Connect" in the Rojo plugin. A placeholder ground plane and spawn point are created at runtime (`MapService`), so you can hit Play immediately.

## What's implemented

- **Persistence** (`PlayerProfileStore`, `PlayerDataService`) — DataStore-backed
  player profiles with retry/backoff and a per-profile session lock (keyed by
  `game.JobId`) so two servers can't load/save the same player at once.
- **Leveling** (`Config`, `PlayerDataService.AddExperience`) — the design
  doc's curve, `XP_to_next(L) = 50 * L^1.5`, level cap 50, +10 max HP per
  level.
- **Combat** (`CombatService`, `EnemyService`) — server-authoritative basic
  attack (range + facing check, cooldown-gated) against trash/elite/boss NPCs
  built at runtime with a simple chase-and-melee AI. Kills report back to
  `PlayerDataService`/`LootService` for XP and loot.
- **Loot** (`LootTable`, `LootService`) — the design doc's per-kill rarity
  table and the better-weighted boss/chest table, plus the 15-boss-kill pity
  counter that guarantees an Epic-or-better drop.
- **Daily keys** — `Config.Daily` (3 keys/day, 8h regen) and
  `PlayerDataService.SpendKey`/key regen-on-load exist, but nothing gates the
  daily dungeon on them yet (see below).
- **HUD** — health/XP bars, level, and key count, built entirely from code
  (`HudController`), plus loot toasts (`LootController`) and an
  input-to-attack bridge (`CombatController`) that works with mouse, touch,
  and gamepad.

## What's not built yet

- **Active skills & ultimate** from the combat design (only the basic attack
  is wired up).
- **Daily structure**: streaks, daily quests, and gating the featured
  dungeon run behind keys.
- **Real level geometry**: `MapService` and `EnemyService`'s spawn list are
  placeholder positions, not an authored dungeon.
- **Monetization** ("Ledger & Loot"): no Game Passes or Developer Products
  are wired up yet — that needs real product/pass IDs created in the Roblox
  Creator Dashboard first, then idempotent `MarketplaceService` purchase
  handling.
- **Equipment/inventory UI**: loot rolls a name + rarity but isn't stored as
  a real item the player can equip yet.
