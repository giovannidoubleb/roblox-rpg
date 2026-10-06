-- CITY GRIND: original procedural music (spec section 42).
-- No audio can be uploaded, so the Music app is a step sequencer that plays
-- these original note patterns on sounds that ship inside the Roblox client
-- (rbxasset://sounds/...). The client checks which samples actually load and
-- only uses those.
--
-- Pattern notation (one character per 16th note, 16 per bar):
--   drums: x = hit, X = accent, g = ghost (soft), . = rest
--   lead / bass: 1-9 = scale degree (8 = the octave), A-E = degrees 10-14,
--                - = hold the previous note, . = rest
--   lead degrees are counted from the key; bass degrees from the bar's chord root.
-- A drum line may be one string (every bar) or a list with one string per bar.

local MusicConfig = {}

export type Sample = { id: string, speed: number, volume: number, maxLength: number? }

-- Candidate samples per instrument role, best first. The exact set of built-in
-- sounds varies by client version; the first one that loads is used.
MusicConfig.SAMPLES = {
	tone = {
		{ id = "rbxasset://sounds/electronicpingshort.wav", speed = 1, volume = 0.5 },
		{ id = "rbxasset://sounds/button.wav", speed = 1, volume = 0.5 },
		{ id = "rbxasset://sounds/switch.wav", speed = 1, volume = 0.5 },
	},
	kick = {
		{ id = "rbxasset://sounds/action_jump_land.mp3", speed = 0.55, volume = 1.4, maxLength = 0.35 },
		{ id = "rbxasset://sounds/hit.wav", speed = 0.45, volume = 1, maxLength = 0.3 },
		{ id = "rbxasset://sounds/collide.wav", speed = 0.5, volume = 1, maxLength = 0.3 },
	},
	snare = {
		{ id = "rbxasset://sounds/snap.mp3", speed = 0.9, volume = 0.9, maxLength = 0.3 },
		{ id = "rbxasset://sounds/splat.wav", speed = 1.3, volume = 0.7, maxLength = 0.25 },
		{ id = "rbxasset://sounds/paintball.wav", speed = 1.1, volume = 0.7, maxLength = 0.25 },
	},
	hat = {
		{ id = "rbxasset://sounds/clickfast.wav", speed = 1.7, volume = 0.45, maxLength = 0.08 },
		{ id = "rbxasset://sounds/button.wav", speed = 2.4, volume = 0.3, maxLength = 0.06 },
		{ id = "rbxasset://sounds/switch.wav", speed = 2.2, volume = 0.3, maxLength = 0.06 },
	},
	fx = {
		{ id = "rbxasset://sounds/swordlunge.wav", speed = 0.7, volume = 0.25, maxLength = 1.2 },
		{ id = "rbxasset://sounds/swoosh.wav", speed = 0.7, volume = 0.25, maxLength = 1.2 },
	},
} :: { [string]: { Sample } }

MusicConfig.ROLE_NAMES = { tone = "Synth", kick = "Kick", snare = "Snare", hat = "Hi-hat", fx = "FX" }
MusicConfig.ROLE_ORDER = { "tone", "kick", "snare", "hat", "fx" }

MusicConfig.SCALES = {
	major = { 0, 2, 4, 5, 7, 9, 11 },
	minor = { 0, 2, 3, 5, 7, 8, 10 },
	dorian = { 0, 2, 3, 5, 7, 9, 10 },
	mixolydian = { 0, 2, 4, 5, 7, 9, 10 },
}

export type Track = {
	id: string,
	name: string,
	style: string,
	bpm: number,
	swing: number, -- 0..0.33, delays every off-beat 16th
	scale: string,
	key: number, -- semitones from the tone sample's natural pitch
	chords: { number }, -- chord root degree per bar
	kick: string | { string },
	snare: string | { string },
	hat: string | { string },
	bass: string | { string },
	lead: { string },
	arp: boolean,
	targetSeconds: number, -- rough length; whole 4-bar loops
}

MusicConfig.TRACKS = {
	{
		id = "cornerstore",
		name = "Corner Store Lo-Fi",
		style = "Lo-fi",
		bpm = 76,
		swing = 0.22,
		scale = "dorian",
		key = -10,
		chords = { 1, 6, 4, 5 },
		kick = "x......x..x.....",
		snare = "....x.......x..g",
		hat = "x.g.x.g.x.g.x.gx",
		bass = "1.....1...5.....",
		lead = {
			"5---3---2-1-----",
			"........3-4-5---",
			"6---5---4-3-----",
			"2-3-5-------....",
		},
		arp = false,
		targetSeconds = 90,
	},
	{
		id = "concrete",
		name = "Concrete Trap",
		style = "Trap",
		bpm = 140,
		swing = 0,
		scale = "minor",
		key = -12,
		chords = { 1, 6, 3, 7 },
		kick = { "x......x.x......", "x......x..x.....", "x......x.x......", "x..x...x..x....." },
		snare = { "........x.......", "........x.......", "........x.......", "........x...x.x." },
		hat = { "x.x.x.x.x.xxx.x.", "x.x.x.x.x.x.x.x.", "x.x.x.x.x.xxx.x.", "x.x.x.x.xxxxxxxx" },
		bass = "1-------......5-",
		lead = {
			"8...7...5...3...",
			"........5.6.5...",
			"8...7...5...6...",
			"5.......3...2...",
		},
		arp = false,
		targetSeconds = 80,
	},
	{
		id = "rooftop",
		name = "Rooftop Sunset",
		style = "Chill",
		bpm = 92,
		swing = 0.12,
		scale = "major",
		key = -8,
		chords = { 1, 5, 6, 4 },
		kick = "x.......x..x....",
		snare = "....x.......x...",
		hat = "..x...x...x...x.",
		bass = "1...1...5...1...",
		lead = {
			"3-5-6-5-3---2-1-",
			"........1-2-3---",
			"6-5-3-5-6---8---",
			"5---3---2-------",
		},
		arp = true,
		targetSeconds = 90,
	},
	{
		id = "fullcourt",
		name = "Full Court Press",
		style = "Upbeat",
		bpm = 124,
		swing = 0,
		scale = "mixolydian",
		key = -5,
		chords = { 1, 4, 1, 5 },
		kick = "X...x...x...x...",
		snare = "....x.......x...",
		hat = "g.x.g.x.g.x.g.xx",
		bass = "1.1.8.1.1.1.8.5.",
		lead = {
			"5.5.6.5.3...1...",
			"4.4.5.4.2.......",
			"5.5.6.5.8...6...",
			"5.4.3.2.1.......",
		},
		arp = false,
		targetSeconds = 85,
	},
	{
		id = "neonave",
		name = "Neon Avenue",
		style = "Synthwave",
		bpm = 108,
		swing = 0,
		scale = "minor",
		key = -9,
		chords = { 1, 6, 3, 7 },
		kick = "x.......x.......",
		snare = "....X.......X...",
		hat = "x.x.x.x.x.x.x.x.",
		bass = "1.1.1.1.1.1.1.1.",
		lead = {
			"5-------4---3---",
			"3-------2---1---",
			"3-------4---5---",
			"6-------5-------",
		},
		arp = true,
		targetSeconds = 90,
	},
	{
		id = "nightshift",
		name = "Night Shift",
		style = "Late-night lo-fi",
		bpm = 68,
		swing = 0.25,
		scale = "minor",
		key = -12,
		chords = { 1, 4, 6, 5 },
		kick = "x.........x.....",
		snare = "........x.......",
		hat = "x...g...x...g...",
		bass = "1-------5-------",
		lead = {
			"........5---3---",
			"4-------........",
			"........3---2---",
			"1-------........",
		},
		arp = true,
		targetSeconds = 95,
	},
} :: { Track }

return MusicConfig
