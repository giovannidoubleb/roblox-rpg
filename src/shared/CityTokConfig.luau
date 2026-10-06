-- CITY GRIND: shared tuning for highlights and the CityTok app (spec 22-26, 34, 35, 85).
-- A clip is replay data (see shared/Replay), never a video file.

local CityTokConfig = {}

-- Recording
CityTokConfig.HZ = 12 -- samples per second
CityTokConfig.BUFFER_SECONDS = 10.5 -- rolling buffer kept on the server
CityTokConfig.PRE_SECONDS = 6 -- seconds kept before a highlight
CityTokConfig.POST_SECONDS = 2 -- seconds kept after it
CityTokConfig.MAX_CLIP_SECONDS = 10
CityTokConfig.ACTION_RADIUS = 60 -- players / balls this close to the star are in the clip
CityTokConfig.VEHICLE_RADIUS = 120
CityTokConfig.MAX_ACTORS = 8
CityTokConfig.MAX_VEHICLES = 6
CityTokConfig.MAX_BALLS = 4

-- Storage
CityTokConfig.MAX_CLIPS = 20 -- saved clips per player
CityTokConfig.MAX_CLIP_BYTES = 25000 -- JSON size of one clip
CityTokConfig.MAX_POSTS_KEPT = 40 -- own post ids remembered in the save
CityTokConfig.MAX_FAVS = 50
CityTokConfig.MAX_INBOX = 30
CityTokConfig.MAX_COMMENTS = 60 -- newest comments kept per post
CityTokConfig.RECENT_INDEX = 300 -- newest posts kept in the shared index

-- Text
CityTokConfig.CAPTION_MAX = 100
CityTokConfig.OVERLAY_MAX = 40
CityTokConfig.COMMENT_MAX = 120

-- Feed
CityTokConfig.CATEGORIES = { "Basketball", "Racing", "Fitness", "Fashion", "Funny", "City Life" }
CityTokConfig.TABS = { "Recommended", "Following", "Trending", "Basketball", "Racing", "Fitness", "Fashion", "Funny", "City Life" }
CityTokConfig.KIND_CATEGORY = { basketball = "Basketball", driving = "Racing", gym = "Fitness", city = "City Life" }
CityTokConfig.KIND_ICON = { basketball = "🏀", driving = "🏎️", gym = "💪", city = "🏙️" }
CityTokConfig.PAGE_SIZE = 20

-- Popularity (spec 26, 35). Engagement only counts distinct real players, never the creator.
CityTokConfig.WEIGHTS = { like = 3, comment = 4, share = 5, view = 1 }
CityTokConfig.TRENDING_AT = 20 -- engagement points
CityTokConfig.VIRAL_AT = 60
CityTokConfig.TRENDING_REWARD = { rep = 25, fame = 40 }
CityTokConfig.VIRAL_REWARD = { rep = 75, fame = 120 }
CityTokConfig.DAILY_REP_CAP = 150 -- reputation CityTok can give one player per day
CityTokConfig.MIN_WATCH_FOR_VIEW = 1.5 -- seconds a viewer must have had the post open

-- Trending score = engagement / (age in hours + 2) ^ 1.5
function CityTokConfig.engagement(likes: number, commenters: number, shares: number, views: number): number
	local w = CityTokConfig.WEIGHTS
	return likes * w.like + commenters * w.comment + shares * w.share + views * w.view
end

function CityTokConfig.trendScore(engagement: number, ageSeconds: number): number
	local hours = math.max(0, ageSeconds) / 3600
	return engagement / (hours + 2) ^ 1.5
end

-- Highlight tags: title, priority (higher wins when several merge into one clip)
CityTokConfig.TAGS = {
	gamewinner = { title = "GAME WINNER", priority = 100, kind = "basketball" },
	tenpoints = { title = "10-POINT GAME", priority = 80, kind = "basketball" },
	logo = { title = "LOGO SHOT", priority = 70, kind = "basketball" },
	dunk = { title = "DUNK", priority = 60, kind = "basketball" },
	perfect = { title = "PERFECT RELEASE", priority = 50, kind = "basketball" },
	block = { title = "BIG BLOCK", priority = 45, kind = "basketball" },
	three = { title = "THREE POINTER", priority = 40, kind = "basketball" },
	steal = { title = "STEAL", priority = 30, kind = "basketball" },
	bigair = { title = "BIG AIR", priority = 50, kind = "driving" },
	topspeed = { title = "TOP SPEED", priority = 40, kind = "driving" },
	manual = { title = "CLIP", priority = 10, kind = "city" },
}
CityTokConfig.LONG_SHOT = 26 -- studs
CityTokConfig.TOP_SPEED_FRACTION = 0.9
CityTokConfig.TOP_SPEED_SECONDS = 3
CityTokConfig.AIR_SECONDS = 0.8
CityTokConfig.TAG_COOLDOWN = 20 -- same auto tag for the same player
CityTokConfig.MANUAL_COOLDOWN = 10

-- Editor
CityTokConfig.CAMERAS = { "broadcast", "ball", "player" }
CityTokConfig.CAMERA_NAMES = {
	basketball = { broadcast = "Broadcast", ball = "Follow Ball", player = "Player View" },
	driving = { broadcast = "Broadcast", ball = "Chase", player = "Driver View" },
	default = { broadcast = "Broadcast", ball = "Follow", player = "Player View" },
}
CityTokConfig.SLOWMO_RATES = { 0.5, 0.25 }
CityTokConfig.FOV_MIN, CityTokConfig.FOV_MAX, CityTokConfig.FOV_DEFAULT = 30, 85, 55
CityTokConfig.MAX_STICKERS = 6
CityTokConfig.STICKERS = { "🔥", "💯", "🏀", "🚗", "💪", "😂", "👑", "⚡", "😱", "🎯", "🏆", "👀" }
-- Filters change the viewport tint / lighting and lay a gradient over the frame.
CityTokConfig.FILTERS = {
	{ id = "none", name = "Original" },
	{ id = "golden", name = "Golden Hour", tint = Color3.fromRGB(255, 225, 175), light = Color3.fromRGB(255, 200, 140), overlay = Color3.fromRGB(255, 150, 40), overlayAlpha = 0.85 },
	{ id = "night", name = "Night Run", tint = Color3.fromRGB(150, 175, 255), light = Color3.fromRGB(120, 140, 220), ambient = Color3.fromRGB(40, 50, 90), overlay = Color3.fromRGB(10, 20, 70), overlayAlpha = 0.7 },
	{ id = "retro", name = "Retro", tint = Color3.fromRGB(235, 205, 160), ambient = Color3.fromRGB(150, 120, 90), overlay = Color3.fromRGB(110, 70, 30), overlayAlpha = 0.8, vignette = true },
	{ id = "neon", name = "Neon", tint = Color3.fromRGB(255, 190, 255), light = Color3.fromRGB(255, 120, 255), ambient = Color3.fromRGB(90, 40, 140), overlay = Color3.fromRGB(150, 0, 255), overlayAlpha = 0.8 },
	{ id = "vignette", name = "Spotlight", vignette = true },
	{ id = "broadcast", name = "Live TV", broadcastBug = true },
}
CityTokConfig.FILTER_BY_ID = {}
for _, f in CityTokConfig.FILTERS do
	CityTokConfig.FILTER_BY_ID[f.id] = f
end

return CityTokConfig
