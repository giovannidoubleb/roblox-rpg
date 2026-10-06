# CITY GRIND: RISE TO THE TOP — Phase 1 (Foundation)

## Get it into Roblox Studio (pick one)

**A. Open the place file (easiest).** Download `dist/CityGrind.rbxlx`, double-click it (or File > Open in Studio), press **Play**. The Neighborhood builds itself when the server starts.

**B. Add to a place you already have.** Open the place, View > Command Bar, paste all of `dist/CityGrind_Install.luau`, press Enter, then Play.

**Saving between sessions:** publish the place (File > Publish to Roblox) and turn on Game Settings > Security > *Enable Studio Access to API Services*. Without that, everything works but progress resets when you stop (the Output window says so).

**Optional, to edit the city by hand:** in edit mode, run this in the Command Bar once, then save. The server will reuse your edited `Workspace.City` instead of rebuilding it:
`require(game.ServerScriptService.CityGrindServer.CityBuilder).build()`

## Controls
PC: WASD move, Shift sprint, C crouch (C while sprinting = slide), Space jump, E interact, P phone.
Mobile: on-screen Sprint (toggle), Crouch and Phone buttons. Controller: L3 sprint, R3 crouch, D-pad up phone.

## What works in Phase 1
- Server-authoritative DataStore save: cash ($500 start), XP, level 1–100, reputation + rank, fame, the 9 attributes, settings, bank transactions. Session locking, retries, autosave every 2 min, save on leave and shutdown.
- Movement: sprint drains stamina; the Stamina stat raises max stamina and recovery, the Speed stat makes sprinting cheaper; crouch; slide.
- The Neighborhood: roads, sidewalks, crosswalks, street lamps that switch on at night, Maple Court starter apartments (spawn), Iron Box gym, outdoor court with hoops, lines, fence and spectator benches, Corner Mart, Fresh Cuts barber, Threads, Mama's Kitchen, Budget Wheels lot, park with fountain and playground, bus stop, subway entrance, 20-minute day/night cycle.
- Neighborhood run: 5 checkpoint arches around the block. Server checks order and timing. Reward: $25, 40 XP, Stamina/Speed training, +2 rep. 45 s cooldown.
- Vending machine outside Corner Mart: $5 energy drink refills stamina (server checks distance and cash).
- HUD: cash with +/- popups, level badge and XP bar, rank, stamina bar, run timer with the next checkpoint highlighted, notification toasts.
- Phone (P): slides in and puts a visible phone in your character's hand. Status bar with in-game time, signal, battery, unread count; wallpaper; apps:
  - Profile: avatar, level, rank, rep, fame, runs, best time, all 9 attributes.
  - Bank: balance, income/expenses, last 25 transactions.
  - Map: top-down city map with your live position, every place sorted by distance, GPS line + marker that clears on arrival.
  - Alerts: notification history, clear all.
  - Settings: wallpaper, phone size, notification sounds (saved to your account).

Other apps (Messages, Calls, Camera, CityTok, CityGram…) are added to the home screen in later phases when they actually work.

## Layout
`src/shared` → ReplicatedStorage.CityGrind · `src/server` → ServerScriptService.CityGrindServer · `src/client` → StarterPlayerScripts.CityGrindClient. `default.project.json` is a Rojo project if you prefer syncing. Rebuild `dist/` with `python3 tools/build.py` after changing anything in `src/`.

To live-sync with Rojo instead: `aftman install`, then `rojo serve`, and click Connect in Studio's Rojo plugin.
