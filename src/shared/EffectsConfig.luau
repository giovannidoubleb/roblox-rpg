-- CITY GRIND: lighting + effects tuning (Phase 8). Read by client/Effects.luau.
--   * TIME_KEYS: the look across the day cycle (keyed by Lighting.ClockTime),
--     blended between neighbouring keys: night blue, dawn pink, golden hour,
--     sunset, dusk.
--   * MOODS: per-district grading layered on top (Player attribute "District"),
--     with a separate night version (Downtown cooler/brighter, Beach warm,
--     Old Town amber...).
--   * LEVELS: what each Graphics setting ("Low" | "Medium" | "High") turns on.

local EffectsConfig = {}

local rgb = Color3.fromRGB

export type TimeKey = {
	t: number, -- ClockTime
	tint: Color3, -- ColorCorrection.TintColor
	bright: number,
	sat: number,
	contrast: number,
	bloom: number, -- Bloom.Intensity
	threshold: number, -- Bloom.Threshold (low at night so Neon glows)
	sun: number, -- SunRays.Intensity
	ambient: Color3, -- Lighting.OutdoorAmbient
	atmo: Color3, -- Atmosphere.Color
	decay: Color3, -- Atmosphere.Decay
	exposure: number, -- Lighting.ExposureCompensation
}

local NIGHT: TimeKey = {
	t = 0,
	tint = rgb(178, 192, 255),
	bright = -0.02,
	sat = -0.14,
	contrast = 0.06,
	bloom = 1.1,
	threshold = 0.85,
	sun = 0,
	ambient = rgb(62, 66, 98),
	atmo = rgb(70, 80, 112),
	decay = rgb(40, 40, 76),
	exposure = 0.15,
}

local function at(t: number, k: TimeKey): TimeKey
	local c = table.clone(k)
	c.t = t
	return c
end

-- Sorted by t; the last key wraps to the first.
EffectsConfig.TIME_KEYS = {
	NIGHT,
	at(4.9, NIGHT),
	{ t = 6.3, tint = rgb(255, 208, 192), bright = 0, sat = 0, contrast = 0.03, bloom = 0.75, threshold = 1.15, sun = 0.22, ambient = rgb(132, 110, 122), atmo = rgb(255, 192, 172), decay = rgb(150, 100, 122), exposure = 0.05 },
	{ t = 8, tint = rgb(255, 247, 236), bright = 0, sat = 0.04, contrast = 0.02, bloom = 0.5, threshold = 1.5, sun = 0.12, ambient = rgb(124, 122, 130), atmo = rgb(205, 198, 190), decay = rgb(112, 104, 124), exposure = 0 },
	{ t = 12, tint = rgb(255, 255, 255), bright = 0, sat = 0.06, contrast = 0.03, bloom = 0.45, threshold = 1.7, sun = 0.08, ambient = rgb(124, 124, 134), atmo = rgb(200, 192, 182), decay = rgb(110, 100, 120), exposure = 0 },
	{ t = 15.6, tint = rgb(255, 246, 230), bright = 0, sat = 0.07, contrast = 0.03, bloom = 0.5, threshold = 1.6, sun = 0.13, ambient = rgb(130, 124, 124), atmo = rgb(225, 200, 175), decay = rgb(130, 105, 110), exposure = 0 },
	{ t = 17.2, tint = rgb(255, 210, 162), bright = 0.02, sat = 0.14, contrast = 0.05, bloom = 0.7, threshold = 1.3, sun = 0.3, ambient = rgb(152, 122, 104), atmo = rgb(255, 188, 140), decay = rgb(200, 110, 88), exposure = 0.02 },
	{ t = 18.2, tint = rgb(255, 178, 172), bright = 0, sat = 0.1, contrast = 0.05, bloom = 0.85, threshold = 1.1, sun = 0.22, ambient = rgb(128, 94, 114), atmo = rgb(238, 150, 150), decay = rgb(120, 70, 112), exposure = 0.05 },
	{ t = 19.3, tint = rgb(188, 190, 255), bright = -0.02, sat = -0.08, contrast = 0.05, bloom = 1.0, threshold = 0.95, sun = 0, ambient = rgb(72, 72, 106), atmo = rgb(92, 90, 132), decay = rgb(52, 46, 86), exposure = 0.1 },
	at(24, NIGHT),
} :: { TimeKey }

export type Mood = {
	tint: Color3,
	sat: number,
	contrast: number,
	bright: number,
	bloom: number, -- added to Bloom.Intensity
	nightTint: Color3,
	nightSat: number,
	nightBright: number,
	nightBloom: number,
}

local function mood(m: { [string]: any }): Mood
	m.sat = m.sat or 0
	m.contrast = m.contrast or 0
	m.bright = m.bright or 0
	m.bloom = m.bloom or 0
	m.nightTint = m.nightTint or m.tint
	m.nightSat = m.nightSat or m.sat
	m.nightBright = m.nightBright or m.bright
	m.nightBloom = m.nightBloom or m.bloom
	return m :: any
end

EffectsConfig.NEUTRAL = mood({ tint = rgb(255, 255, 255) })

-- Keys are DistrictsConfig ids (Player attribute "District").
EffectsConfig.MOODS = {
	Neighborhood = EffectsConfig.NEUTRAL,
	Downtown = mood({ tint = rgb(244, 249, 255), contrast = 0.04, nightTint = rgb(198, 220, 255), nightBright = 0.05, nightBloom = 0.35 }),
	Beach = mood({ tint = rgb(255, 242, 218), sat = 0.12, bright = 0.02, nightTint = rgb(255, 232, 222), nightSat = 0.04 }),
	OldTown = mood({ tint = rgb(255, 232, 196), sat = -0.02, contrast = 0.03, nightTint = rgb(255, 206, 150), nightBloom = 0.15 }),
	Luxury = mood({ tint = rgb(252, 248, 255), sat = 0.05, contrast = 0.02, nightTint = rgb(236, 226, 255), nightBloom = 0.2 }),
	Industrial = mood({ tint = rgb(240, 240, 228), sat = -0.12, contrast = 0.06, nightTint = rgb(226, 236, 230), nightSat = -0.1 }),
} :: { [string]: Mood }

-- How much of the sun rays each weather lets through (Workspace attribute "Weather").
EffectsConfig.WEATHER_SUN = { Clear = 1, Heatwave = 1.2, Cloudy = 0.4, Fog = 0.15, Rain = 0, Storm = 0 } :: { [string]: number }

export type Level = {
	bloom: boolean,
	sunRays: boolean,
	shadows: boolean, -- Lighting.GlobalShadows
	particles: number, -- multiplier on every burst
	motion: boolean, -- camera shake, FOV kick, speed lines (reduced-motion rule: off on Low)
	skidMarks: number, -- pooled skid mark segments (0 = none)
	lampHalos: number, -- extra warm PointLights on the nearest street lamps at night
	exhaust: boolean,
	underglowPulse: boolean,
	netRipple: boolean,
}

EffectsConfig.LEVELS = {
	Low = { bloom = false, sunRays = false, shadows = false, particles = 0.35, motion = false, skidMarks = 0, lampHalos = 0, exhaust = false, underglowPulse = false, netRipple = false },
	Medium = { bloom = true, sunRays = true, shadows = true, particles = 0.7, motion = true, skidMarks = 60, lampHalos = 4, exhaust = true, underglowPulse = true, netRipple = true },
	High = { bloom = true, sunRays = true, shadows = true, particles = 1, motion = true, skidMarks = 140, lampHalos = 8, exhaust = true, underglowPulse = true, netRipple = true },
} :: { [string]: Level }

-- Gameplay effect tuning.
EffectsConfig.MAKE_SPARKS = 26
EffectsConfig.DUNK_SPARKS = 60
EffectsConfig.CONFETTI = 90
EffectsConfig.LANDING_MIN_FALL = 58 -- studs/s downward at landing (a normal jump lands at ~50)
EffectsConfig.SKID_LIFETIME = 9 -- seconds before a skid mark has faded out
EffectsConfig.DRIFT_SLIP = 9 -- sideways studs/s that count as a drift
EffectsConfig.DRIFT_MIN_SPEED = 22
EffectsConfig.SPRINT_FOV = 5 -- extra degrees while sprinting
EffectsConfig.DRIVE_FOV = 9 -- extra degrees at a vehicle's top speed
EffectsConfig.VEHICLE_FX_RANGE = 160 -- exhaust / smoke / skids / underglow only near the camera
EffectsConfig.HOOP_RANGE = 140 -- make detection only for hoops near the camera

return EffectsConfig
