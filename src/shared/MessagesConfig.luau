-- CITY GRIND: Messages tuning (spec sections 17, 18, 36, 48, 109).
-- Shared by the server (which enforces every limit) and the client (which
-- mirrors them so the UI never offers something the server would reject).

local MessagesConfig = {}

-- Text limits and rate limits (server-enforced; the client only mirrors them).
MessagesConfig.MAX_LENGTH = 200 -- characters per message
MessagesConfig.MIN_GAP = 0.75 -- seconds between two messages
MessagesConfig.MAX_PER_MINUTE = 30

-- History kept per conversation / group.
MessagesConfig.DM_HISTORY = 30
MessagesConfig.GROUP_HISTORY = 50
MessagesConfig.MAX_CONVERSATIONS = 25 -- DMs + system threads per player (oldest dropped)
MessagesConfig.MAILBOX_MAX = 60 -- pending offline items per player

-- Invites (sections 17, 48).
MessagesConfig.INVITE_SECONDS = 10 * 60

-- Groups (section 18).
MessagesConfig.GROUP_MAX_MEMBERS = 20
MessagesConfig.MAX_GROUPS = 10 -- groups one player can be in
MessagesConfig.GROUP_NAME_MAX = 30
MessagesConfig.GROUP_ICONS = { "💬", "🏀", "🔥", "😎", "🎮", "💪", "🎉", "🏙️", "🚗", "💰", "⭐", "👑" }
MessagesConfig.GROUP_COLORS = {
	Color3.fromRGB(255, 120, 60),
	Color3.fromRGB(90, 170, 255),
	Color3.fromRGB(110, 220, 120),
	Color3.fromRGB(200, 100, 255),
	Color3.fromRGB(255, 80, 120),
	Color3.fromRGB(255, 200, 60),
	Color3.fromRGB(60, 210, 200),
	Color3.fromRGB(150, 150, 165),
}

-- Emoji quick-picker (they're inserted into the text box; the server filters the whole message).
MessagesConfig.EMOJI = { "😂", "🔥", "💯", "🏀", "😎", "👍", "🙏", "😭", "❤️", "👀", "💪", "🎉", "😤", "🤝", "💰", "🚗", "🏠", "😴" }

-- Invite card look per kind (labels are fixed game text, never player text).
MessagesConfig.INVITE_STYLE = {
	basketball = { icon = "🏀", title = "Let's run some hoops", color = Color3.fromRGB(255, 140, 50) },
	apartment = { icon = "🏠", title = "Come through to my place", color = Color3.fromRGB(110, 220, 120) },
	crew = { icon = "🛡️", title = "Join my crew", color = Color3.fromRGB(200, 100, 255) },
	party = { icon = "🎉", title = "Join my party", color = Color3.fromRGB(90, 170, 255) },
	event = { icon = "📍", title = "You're invited", color = Color3.fromRGB(255, 200, 60) },
}

-- Coach Ray (section 109): first-join welcome texts.
MessagesConfig.COACH_RAY = "Coach Ray"
MessagesConfig.COACH_RAY_LINES = {
	"You new around here?",
	"Then it's time to make yourself known. Hit the court by the subway, earn some cash at the Job Center, and holler at me if you need anything.",
}
MessagesConfig.SYSTEM_ICONS = { ["Coach Ray"] = "🧢" }

return MessagesConfig
