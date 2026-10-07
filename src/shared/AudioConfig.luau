-- CITY GRIND: audio tuning (Phase 8). Read by src/client/Audio.luau.
-- Only sounds that ship inside the Roblox client (rbxasset://sounds/...) are
-- used — nothing is uploaded. The exact set of built-in files differs between
-- client versions, so every role lists candidates, best first; the client
-- preloads them all (pcall) and uses the first one that actually loads. A
-- role with no loadable candidate is silently skipped.
--
-- Built-in files referenced below and what they are used for:
--   action_footsteps_plastic.mp3  fallback footsteps (only if Roblox's RbxCharacterSounds isn't running)
--   action_jump_land.mp3          ball bounce thud, dribble, subway thump, thunder body (pitched way down)
--   action_falling.mp3            wind loop: pitched-down city bed / industrial hum / subway rumble,
--                                 pitched-up rain hiss, crowd roar swell, engine fallback
--   action_swim.mp3               slow wash for beach waves
--   impact_water.mp3              wave break one-shot at the beach
--   hit.wav                       rim clang (pitched up), distant industrial clank (pitched down)
--   collide.wav                   rim clang fallback, thunder crack (pitched down)
--   unsheath.wav                  metallic ring layered on rim hits
--   swoosh.wav                    swish through the net, phone open/close
--   snap.mp3                      net snap
--   button.wav / clickfast.wav    UI clicks on the phone
--   uuhhh.mp3                     crowd "ooh" (several voices pitched apart)
--   Rocket whoosh.wav             engine loop candidate (pitched down; skipped if missing)
--   electronicpingshort.wav       distant car horn / chime one-shot in the city bed (pitched down)
--   switch.wav                    phone click fallback

local AudioConfig = {}

export type Sample = { id: string, speed: number, volume: number }

-- Default setting values (match PlayerData defaults) used until attributes arrive.
AudioConfig.DEFAULT_VOLUME = { Music = 0.6, SFX = 0.8, Ambient = 0.5 }

-- role -> candidate samples (first that loads wins). `group` is the SoundGroup.
AudioConfig.ROLES = {
	footstep = { group = "SFX", list = {
		{ id = "rbxasset://sounds/action_footsteps_plastic.mp3", speed = 1, volume = 0.35 },
	} },
	bounce = { group = "SFX", list = {
		{ id = "rbxasset://sounds/action_jump_land.mp3", speed = 1.7, volume = 0.8 },
		{ id = "rbxasset://sounds/hit.wav", speed = 0.7, volume = 0.5 },
		{ id = "rbxasset://sounds/collide.wav", speed = 0.9, volume = 0.6 },
	} },
	rim = { group = "SFX", list = {
		{ id = "rbxasset://sounds/hit.wav", speed = 1.6, volume = 0.6 },
		{ id = "rbxasset://sounds/collide.wav", speed = 1.8, volume = 0.6 },
	} },
	rimRing = { group = "SFX", list = {
		{ id = "rbxasset://sounds/unsheath.wav", speed = 1.4, volume = 0.18 },
		{ id = "rbxasset://sounds/electronicpingshort.wav", speed = 0.5, volume = 0.15 },
	} },
	swish = { group = "SFX", list = {
		{ id = "rbxasset://sounds/swoosh.wav", speed = 1.5, volume = 0.45 },
	} },
	net = { group = "SFX", list = {
		{ id = "rbxasset://sounds/snap.mp3", speed = 1.6, volume = 0.35 },
		{ id = "rbxasset://sounds/clickfast.wav", speed = 0.6, volume = 0.3 },
	} },
	crowdRoar = { group = "SFX", list = {
		{ id = "rbxasset://sounds/action_falling.mp3", speed = 0.75, volume = 0.5 },
	} },
	crowdOoh = { group = "SFX", list = {
		{ id = "rbxasset://sounds/uuhhh.mp3", speed = 0.8, volume = 0.35 },
	} },
	engine = { group = "SFX", list = {
		{ id = "rbxasset://sounds/Rocket whoosh.wav", speed = 0.32, volume = 0.35 },
		{ id = "rbxasset://sounds/action_falling.mp3", speed = 0.3, volume = 0.45 },
	} },
	rumble = { group = "SFX", list = {
		{ id = "rbxasset://sounds/action_falling.mp3", speed = 0.25, volume = 0.9 },
	} },
	thump = { group = "SFX", list = {
		{ id = "rbxasset://sounds/action_jump_land.mp3", speed = 0.5, volume = 0.6 },
	} },
	click = { group = "SFX", list = {
		{ id = "rbxasset://sounds/button.wav", speed = 1.3, volume = 0.25 },
		{ id = "rbxasset://sounds/clickfast.wav", speed = 1, volume = 0.3 },
		{ id = "rbxasset://sounds/switch.wav", speed = 1.4, volume = 0.25 },
	} },
	phoneSwoosh = { group = "SFX", list = {
		{ id = "rbxasset://sounds/swoosh.wav", speed = 2, volume = 0.25 },
	} },
	-- ambience
	cityBed = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/action_falling.mp3", speed = 0.45, volume = 0.18 },
	} },
	waves = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/action_swim.mp3", speed = 0.45, volume = 0.35 },
		{ id = "rbxasset://sounds/action_falling.mp3", speed = 0.6, volume = 0.22 },
	} },
	waveBreak = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/impact_water.mp3", speed = 0.45, volume = 0.3 },
	} },
	hum = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/action_falling.mp3", speed = 0.2, volume = 0.3 },
	} },
	clank = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/hit.wav", speed = 0.35, volume = 0.25 },
		{ id = "rbxasset://sounds/collide.wav", speed = 0.4, volume = 0.25 },
	} },
	horn = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/electronicpingshort.wav", speed = 0.35, volume = 0.08 },
	} },
	rain = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/action_falling.mp3", speed = 1.7, volume = 0.3 },
	} },
	thunder = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/collide.wav", speed = 0.18, volume = 1 },
		{ id = "rbxasset://sounds/action_jump_land.mp3", speed = 0.2, volume = 1 },
	} },
	thunderBody = { group = "Ambient", list = {
		{ id = "rbxasset://sounds/action_jump_land.mp3", speed = 0.15, volume = 1 },
	} },
}

-- Per-district ambience: the looping bed role, its volume multiplier, and
-- occasional one-shots { role, minGap, maxGap } heard at a random spot nearby.
AudioConfig.DISTRICTS = {
	Neighborhood = { bed = "cityBed", gain = 0.8, oneShots = { { role = "horn", min = 25, max = 60 } } },
	Downtown = { bed = "cityBed", gain = 1.2, oneShots = { { role = "horn", min = 12, max = 30 } } },
	Industrial = { bed = "hum", gain = 1, oneShots = { { role = "clank", min = 10, max = 26 } } },
	Beach = { bed = "waves", gain = 1, oneShots = { { role = "waveBreak", min = 6, max = 14 } } },
	Luxury = { bed = "cityBed", gain = 0.45, oneShots = {} },
	OldTown = { bed = "cityBed", gain = 0.7, oneShots = { { role = "horn", min = 35, max = 80 } } },
	Outskirts = { bed = "cityBed", gain = 0.35, oneShots = {} },
}

-- Footstep pitch / volume by floor material (fallback footsteps only).
AudioConfig.MATERIAL_STEP = {
	[Enum.Material.Grass] = { speed = 0.75, volume = 0.6 },
	[Enum.Material.Sand] = { speed = 0.6, volume = 0.5 },
	[Enum.Material.Wood] = { speed = 1.05, volume = 0.9 },
	[Enum.Material.WoodPlanks] = { speed = 1.05, volume = 0.9 },
	[Enum.Material.Metal] = { speed = 1.35, volume = 0.9 },
	[Enum.Material.DiamondPlate] = { speed = 1.35, volume = 0.9 },
	[Enum.Material.Concrete] = { speed = 1.1, volume = 0.8 },
	[Enum.Material.Asphalt] = { speed = 1, volume = 0.8 },
	[Enum.Material.Brick] = { speed = 1.15, volume = 0.8 },
	[Enum.Material.Fabric] = { speed = 0.8, volume = 0.5 },
}

AudioConfig.MAX_ENGINES = 6
AudioConfig.ENGINE_RANGE = 140
AudioConfig.BALL_RANGE = 90
AudioConfig.CROWD_RANGE = 140
AudioConfig.ONESHOT_POOL = 16

return AudioConfig
