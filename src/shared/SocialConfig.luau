-- CITY GRIND: social tuning shared by server and client (spec 21, 28, 29, 44-47, 96, 97).
-- Lives in ReplicatedStorage.CityGrind.SocialConfig.

local SocialConfig = {}

SocialConfig.DATASTORE_NAME = "CityGrind_Social_v1" -- offline friend-request inboxes
SocialConfig.TOPIC = "CityGrindSocial" -- MessagingService topic for live cross-server delivery

SocialConfig.MAX_FRIENDS = 200
SocialConfig.MAX_INCOMING = 100
SocialConfig.MAX_BLOCKED = 300
SocialConfig.REQUESTS_PER_MINUTE = 10
SocialConfig.INTERACT_RANGE = 10 -- studs: interaction prompt over other players
SocialConfig.EMOTE_RANGE = 12 -- studs: two-person emotes (server check)
SocialConfig.EMOTE_REQUEST_SECONDS = 15
SocialConfig.BIO_MAX = 120

-- Privacy (spec 44). Each kind is checked against the RECEIVER's setting.
SocialConfig.PRIVACY_KINDS = {
	{ id = "message", label = "Messages" },
	{ id = "invite", label = "Invites" },
	{ id = "call", label = "Calls" },
	{ id = "visit", label = "Home visits" },
	{ id = "follow", label = "Follows" },
	{ id = "interact", label = "Interactions" },
}
SocialConfig.PRIVACY_VALUES = { "Everyone", "Friends", "Crew", "Nobody" }
SocialConfig.PROFILE_VISIBILITY = { "Public", "Friends Only", "Private" }
SocialConfig.DEFAULT_PRIVACY = {
	message = "Everyone",
	invite = "Everyone",
	call = "Friends",
	visit = "Friends",
	follow = "Everyone",
	interact = "Everyone",
	profile = "Public",
	showStatus = true, -- others see your status / activity
	shareLocation = true, -- friends in your server can GPS to you
}

-- Player status (spec 47). "Auto" derives it from what you're doing.
SocialConfig.STATUSES = {
	{ id = "Auto", label = "Auto", icon = "✨" },
	{ id = "None", label = "No status", icon = "" },
	{ id = "At Gym", label = "At Gym", icon = "🏋️" },
	{ id = "Playing Basketball", label = "Playing Basketball", icon = "🏀" },
	{ id = "Working", label = "Working", icon = "💼" },
	{ id = "Driving", label = "Driving", icon = "🚗" },
	{ id = "Busy", label = "Busy", icon = "⏳" },
	{ id = "Do Not Disturb", label = "Do Not Disturb", icon = "⛔" },
	{ id = "Hanging Out", label = "Hanging Out", icon = "😎" },
}
SocialConfig.STATUS_ICONS = {}
for _, s in SocialConfig.STATUSES do
	SocialConfig.STATUS_ICONS[s.id] = s.icon
end
SocialConfig.STATUS_ICONS.Online = "🟢"

-- Nametag / profile colour per reputation rank (names match Config.REPUTATION_RANKS).
SocialConfig.RANK_COLORS = {
	Nobody = Color3.fromRGB(200, 200, 210),
	Known = Color3.fromRGB(120, 220, 140),
	Respected = Color3.fromRGB(90, 170, 255),
	["Local Star"] = Color3.fromRGB(190, 120, 255),
	["City Famous"] = Color3.fromRGB(255, 160, 60),
	Celebrity = Color3.fromRGB(255, 90, 140),
	Legend = Color3.fromRGB(255, 215, 70),
}

-- Profile customization (spec 97).
SocialConfig.BANNERS = {
	Color3.fromRGB(255, 120, 60),
	Color3.fromRGB(90, 110, 240),
	Color3.fromRGB(40, 160, 90),
	Color3.fromRGB(230, 70, 80),
	Color3.fromRGB(150, 70, 220),
	Color3.fromRGB(30, 170, 200),
	Color3.fromRGB(240, 190, 40),
	Color3.fromRGB(45, 45, 58),
}

SocialConfig.FAVORITES = { "None", "Basketball", "Gym", "Driving", "Working", "Shopping", "Hanging Out", "Exploring" }

SocialConfig.FEATURED = {
	{ id = "Level", label = "Level" },
	{ id = "Reputation", label = "Reputation" },
	{ id = "Fame", label = "Fame" },
	{ id = "Wins", label = "Hoop Wins" },
	{ id = "Points", label = "Career Points" },
	{ id = "Threes", label = "3PT Made" },
	{ id = "Dunks", label = "Dunks" },
	{ id = "Strength", label = "Strength" },
	{ id = "Speed", label = "Speed" },
	{ id = "Shooting", label = "Shooting" },
	{ id = "Vertical", label = "Vertical" },
}
SocialConfig.FEATURED_BY_ID = {}
for _, f in SocialConfig.FEATURED do
	SocialConfig.FEATURED_BY_ID[f.id] = f
end

-- Titles (spec 97) unlock from level, reputation and basketball career.
-- stat: "level" | "rep" | "wins" | "points"
SocialConfig.TITLES = {
	{ id = "Newcomer", stat = "level", min = 1 },
	{ id = "Grinder", stat = "level", min = 5 },
	{ id = "Hustler", stat = "level", min = 10 },
	{ id = "Veteran", stat = "level", min = 25 },
	{ id = "City Elite", stat = "level", min = 50 },
	{ id = "Living Legend", stat = "level", min = 100 },
	{ id = "Known Face", stat = "rep", min = 100 },
	{ id = "Respected", stat = "rep", min = 500 },
	{ id = "Local Star", stat = "rep", min = 1000 },
	{ id = "City Famous", stat = "rep", min = 2500 },
	{ id = "Celebrity", stat = "rep", min = 5000 },
	{ id = "Legend", stat = "rep", min = 10000 },
	{ id = "Hooper", stat = "wins", min = 5 },
	{ id = "Court King", stat = "wins", min = 50 },
	{ id = "Bucket Getter", stat = "points", min = 250 },
}

local STAT_LABEL = { level = "Reach level", rep = "Reach reputation", wins = "Win games:", points = "Score points:" }

function SocialConfig.titleRequirement(title): string
	return (STAT_LABEL[title.stat] or "") .. " " .. title.min
end

-- Title ids unlocked for these numbers.
function SocialConfig.unlockedTitles(level: number, rep: number, wins: number, points: number): { string }
	local values = { level = level, rep = rep, wins = wins, points = points }
	local list = {}
	for _, t in SocialConfig.TITLES do
		if (values[t.stat] or 0) >= t.min then
			table.insert(list, t.id)
		end
	end
	return list
end

-- Two-person emotes need the other player to accept (spec 21, 96).
SocialConfig.EMOTES = {
	Wave = { label = "WAVE", solo = true },
	HighFive = { label = "HIGH FIVE" },
	FistBump = { label = "FIST BUMP" },
	Handshake = { label = "HANDSHAKE" },
}

return SocialConfig
