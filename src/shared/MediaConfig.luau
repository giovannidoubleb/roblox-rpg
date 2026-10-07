-- CITY GRIND: tuning for the Camera, Gallery and CityGram (sections 27, 28, 30-33, 59).
-- Shared by server and client so both agree on limits, filters and poses.

local MediaConfig = {}

---------------------------------------------------------------------------
-- Photos (scene snapshots)
---------------------------------------------------------------------------
MediaConfig.MAX_PHOTOS = 60 -- saved photos per player
MediaConfig.MAX_PEOPLE = 8 -- people captured in one photo
MediaConfig.MAX_VEHICLES = 3
MediaConfig.PERSON_PARTS = 28 -- parts kept per person (largest first)
MediaConfig.VEHICLE_PARTS = 48 -- parts kept per vehicle
MediaConfig.MAX_SNAPSHOT_BYTES = 30000 -- JSON size limit (fits easily in a DataStore key)
MediaConfig.CAMERA_RANGE = 90 -- camera may be at most this far from the photographer
MediaConfig.SUBJECT_RANGE = 160 -- people / vehicles further than this from the camera are left out
MediaConfig.POSE_TOLERANCE = 4 -- client-reported pose may differ this much (studs) from the server's view
MediaConfig.ROOT_TOLERANCE = 8 -- client-reported root position tolerance (latency)
MediaConfig.FOV_MIN = 15
MediaConfig.FOV_MAX = 100
MediaConfig.FOV_DEFAULT = 70
MediaConfig.CAPTURE_COOLDOWN = 2.5

-- Static city parts drawn when a photo is rendered.
MediaConfig.RENDER_PARTS = 1500 -- full view
MediaConfig.THUMB_PARTS = 220 -- gallery thumbnails
MediaConfig.FEED_PARTS = 600 -- CityGram cards
MediaConfig.RENDER_RADIUS = 260

---------------------------------------------------------------------------
-- Filters. The same numbers drive the live ColorCorrectionEffect in camera
-- mode and the colour transform used when a snapshot is re-rendered, so a
-- photo looks the way it did through the lens.
---------------------------------------------------------------------------
export type Filter = {
	id: string,
	label: string,
	saturation: number, -- -1 (B&W) .. 1
	contrast: number,
	brightness: number,
	tint: Color3,
	vignette: number, -- 0..1 edge darkness
	grain: boolean,
	overlay: Color3?, -- extra colour wash over the render
	overlayAlpha: number?,
}

MediaConfig.FILTERS = {
	{ id = "None", label = "Natural", saturation = 0, contrast = 0, brightness = 0, tint = Color3.new(1, 1, 1), vignette = 0, grain = false },
	{ id = "Warm", label = "Warm", saturation = 0.1, contrast = 0.05, brightness = 0.02, tint = Color3.fromRGB(255, 226, 190), vignette = 0.25, grain = false },
	{ id = "Cool", label = "Cool", saturation = -0.05, contrast = 0.05, brightness = 0, tint = Color3.fromRGB(200, 222, 255), vignette = 0.2, grain = false },
	{ id = "Noir", label = "Noir", saturation = -1, contrast = 0.35, brightness = -0.03, tint = Color3.new(1, 1, 1), vignette = 0.55, grain = true },
	{ id = "Vintage", label = "Vintage", saturation = -0.45, contrast = -0.05, brightness = 0.03, tint = Color3.fromRGB(255, 232, 196), vignette = 0.4, grain = true, overlay = Color3.fromRGB(120, 90, 40), overlayAlpha = 0.9 },
	{ id = "Vivid", label = "Vivid", saturation = 0.55, contrast = 0.18, brightness = 0.02, tint = Color3.new(1, 1, 1), vignette = 0.1, grain = false },
	{ id = "Dusk", label = "Dusk", saturation = 0.15, contrast = 0.1, brightness = -0.04, tint = Color3.fromRGB(255, 200, 220), vignette = 0.35, grain = false, overlay = Color3.fromRGB(90, 40, 120), overlayAlpha = 0.88 },
} :: { Filter }

local FILTER_BY_ID: { [string]: Filter } = {}
for _, f in MediaConfig.FILTERS do
	FILTER_BY_ID[f.id] = f
end

function MediaConfig.filter(id: any): Filter
	return (type(id) == "string" and FILTER_BY_ID[id]) or MediaConfig.FILTERS[1]
end

function MediaConfig.isFilter(id: any): boolean
	return type(id) == "string" and FILTER_BY_ID[id] ~= nil
end

---------------------------------------------------------------------------
-- Poses (Emotes ids). "ColdBlooded" is the basketball pose.
---------------------------------------------------------------------------
MediaConfig.POSES = { "Flex", "Point", "Celebrate", "Sit", "Wave", "ColdBlooded", "RaiseRoof" }
MediaConfig.GROUP_POSE_RANGE = 30
MediaConfig.POSE_REQUEST_SECONDS = 15

---------------------------------------------------------------------------
-- CityGram
---------------------------------------------------------------------------
MediaConfig.CAPTION_MAX = 150
MediaConfig.COMMENT_MAX = 120
MediaConfig.COMMENTS_STORED = 50 -- newest comments kept on a post
MediaConfig.FEED_SIZE = 12
MediaConfig.POPULAR_HOURS = 48
MediaConfig.POST_COOLDOWN = 30
MediaConfig.POSTS_PER_DAY = 20
MediaConfig.LIKES_PER_FAME = 5 -- +1 fame for every 5 likes from distinct players
MediaConfig.REP_PER_LIKE = 1
MediaConfig.REP_DAILY_CAP = 20 -- section 35: social never replaces skill
MediaConfig.LIKER_IDS_CAP = 3000
MediaConfig.INBOX_CAP = 30

-- Follows
MediaConfig.FAME_PER_FOLLOWER = 5 -- once per follower, ever
MediaConfig.FOLLOW_ID_CAP = 500 -- follower ids stored per user (the count keeps going)
MediaConfig.MAX_FOLLOWING = 500
MediaConfig.FOLLOW_CHANGES_PER_HOUR = 60

return MediaConfig
