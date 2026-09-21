# roblox-rpg

Roblox RPG project, built with [Rojo](https://rojo.space/).

## Structure

- `src/server` — server-only code, synced into `ServerScriptService`
- `src/client` — client-only code, synced into `StarterPlayerScripts`
- `src/shared` — code required by both sides, synced into `ReplicatedStorage`

## Getting started

1. Install [Aftman](https://github.com/LPGhatguy/aftman) if you don't have it, then run `aftman install` in this directory to get the pinned Rojo version.
2. Open Roblox Studio and install the [Rojo plugin](https://create.roblox.com/store/asset/13916111004/Rojo).
3. Run `rojo serve` in this directory.
4. In Studio, click "Connect" in the Rojo plugin.

## Current state

Bare scaffold: a `PlayerDataService` hands each player starting stats on join
and pushes them to the client over a `PlayerDataUpdated` RemoteEvent. No UI,
persistence, or actual RPG systems yet.
