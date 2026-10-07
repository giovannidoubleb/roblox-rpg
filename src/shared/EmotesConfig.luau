-- CITY GRIND: emote definitions (sections 31, 95), shared by server and client.
-- Every emote is procedural: a list of keyframes, each one an offset applied to
-- the R15 joint's rest C0 (rest = the joint's rig attachment). Joints not named
-- in a frame tween back to rest. The server plays them so everyone sees them.
--
-- Sign conventions (same as the gym): +X on a shoulder/hip swings the limb
-- forward, +X on an elbow folds the forearm forward, -X on a knee bends it,
-- -X on Waist leans forward, +X on Neck looks up. Right arm out to the side is
-- +Z, left is -Z; an elbow turned the same way as its shoulder keeps folding
-- in that direction. "Root" moves the whole body (a CFrame offset).

local EmotesConfig = {}

local function A(x: number, y: number?, z: number?): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y or 0), math.rad(z or 0))
end
local function D(y: number): CFrame
	return CFrame.new(0, y, 0)
end

export type Frame = { t: number, joints: { [string]: CFrame }, style: Enum.EasingStyle? }
export type Emote = {
	id: string,
	name: string,
	icon: string,
	category: string, -- "Social" | "Dance" | "Hoops" | "Paired"
	loop: boolean, -- loops until the player moves or jumps
	frames: { Frame },
	intro: { Frame }?, -- played once before the looping frames
	sit: boolean?, -- drops the body to the ground (Root offset worked out from HipHeight)
	paired: boolean?, -- needs a partner (both must accept)
	gap: number?, -- paired: distance between the two players (studs)
	sideShift: number?, -- paired: each player steps this far to their own left so right hands meet
}

EmotesConfig.SLOTS = 8
EmotesConfig.COOLDOWN = 0.6
EmotesConfig.PAIR_RANGE = 12 -- studs between players to request a paired emote
EmotesConfig.PAIR_REQUEST_SECONDS = 15
EmotesConfig.DEFAULT_SLOTS = { "Wave", "Dance", "Sit", "Flex", "Celebrate", "Laugh", "HighFive", "FistBump" }

EmotesConfig.LIST = {
	{
		id = "Wave",
		name = "Wave",
		icon = "👋",
		category = "Social",
		loop = false,
		frames = {
			{ t = 0.25, joints = { RightShoulder = A(0, 0, 145), RightElbow = A(0, 0, 15), Neck = A(0, -10, 0) } },
			{ t = 0.22, joints = { RightShoulder = A(0, 0, 120), RightElbow = A(0, 0, 35), Neck = A(0, -10, 0) } },
			{ t = 0.22, joints = { RightShoulder = A(0, 0, 160), RightElbow = A(0, 0, 0), Neck = A(0, -10, 0) } },
			{ t = 0.22, joints = { RightShoulder = A(0, 0, 120), RightElbow = A(0, 0, 35), Neck = A(0, -10, 0) } },
			{ t = 0.22, joints = { RightShoulder = A(0, 0, 160), RightElbow = A(0, 0, 0), Neck = A(0, -10, 0) } },
			{ t = 0.22, joints = { RightShoulder = A(0, 0, 130), RightElbow = A(0, 0, 25), Neck = A(0, -10, 0) } },
		},
	},
	{
		id = "Dance",
		name = "Two-Step",
		icon = "🕺",
		category = "Dance",
		loop = true,
		frames = {
			{
				t = 0.32,
				joints = {
					Root = D(-0.2), Waist = A(0, 14, 0), Neck = A(0, -10, 0),
					LeftShoulder = A(35, 0, -15), RightShoulder = A(-20, 0, 15), LeftElbow = A(75), RightElbow = A(60),
					LeftHip = A(25), LeftKnee = A(-35), RightKnee = A(-10),
				},
			},
			{
				t = 0.32,
				joints = {
					Root = D(-0.2), Waist = A(0, -14, 0), Neck = A(0, 10, 0),
					LeftShoulder = A(-20, 0, -15), RightShoulder = A(35, 0, 15), LeftElbow = A(60), RightElbow = A(75),
					RightHip = A(25), RightKnee = A(-35), LeftKnee = A(-10),
				},
			},
		},
	},
	{
		id = "Bounce",
		name = "Bounce",
		icon = "🎶",
		category = "Dance",
		loop = true,
		frames = {
			{
				t = 0.26,
				joints = {
					Root = D(-0.4), Neck = A(-12),
					LeftHip = A(18), RightHip = A(18), LeftKnee = A(-30), RightKnee = A(-30), LeftAnkle = A(12), RightAnkle = A(12),
					LeftShoulder = A(0, 0, -150), RightShoulder = A(0, 0, 150), LeftElbow = A(0, 0, -30), RightElbow = A(0, 0, 30),
				},
			},
			{
				t = 0.26,
				joints = {
					Root = D(0), Neck = A(10),
					LeftShoulder = A(0, 0, -115), RightShoulder = A(0, 0, 115), LeftElbow = A(0, 0, -60), RightElbow = A(0, 0, 60),
				},
			},
		},
	},
	{
		id = "Robot",
		name = "Robot",
		icon = "🤖",
		category = "Dance",
		loop = true,
		frames = {
			{
				t = 0.3,
				style = Enum.EasingStyle.Linear,
				joints = {
					Waist = A(0, 25, 0), Neck = A(0, -25, 0),
					RightShoulder = A(90), RightElbow = A(90), LeftShoulder = A(0, 0, -15), LeftElbow = A(90),
				},
			},
			{
				t = 0.3,
				style = Enum.EasingStyle.Linear,
				joints = {
					Waist = A(0, -25, 0), Neck = A(0, 25, 0),
					LeftShoulder = A(90), LeftElbow = A(90), RightShoulder = A(0, 0, 15), RightElbow = A(90),
				},
			},
			{
				t = 0.3,
				style = Enum.EasingStyle.Linear,
				joints = {
					Neck = A(12), LeftShoulder = A(90), RightShoulder = A(90), LeftElbow = A(0), RightElbow = A(0),
					LeftKnee = A(-20), RightKnee = A(-20), Root = D(-0.25),
				},
			},
		},
	},
	{
		id = "Sit",
		name = "Sit",
		icon = "🧘",
		category = "Social",
		loop = true,
		sit = true,
		frames = {
			{
				t = 0.45,
				joints = {
					Waist = A(12), Neck = A(-6),
					LeftHip = A(80), RightHip = A(80), LeftKnee = A(-45), RightKnee = A(-45), LeftAnkle = A(20), RightAnkle = A(20),
					LeftShoulder = A(-30, 0, -12), RightShoulder = A(-30, 0, 12), LeftElbow = A(10), RightElbow = A(10),
				},
			},
		},
	},
	{
		id = "Flex",
		name = "Flex",
		icon = "💪",
		category = "Social",
		loop = false,
		frames = {
			{ t = 0.3, joints = { LeftShoulder = A(0, 0, -90), RightShoulder = A(0, 0, 90), LeftElbow = A(0, 0, -100), RightElbow = A(0, 0, 100), Neck = A(8) } },
			{ t = 0.25, joints = { LeftShoulder = A(0, 0, -80), RightShoulder = A(0, 0, 80), LeftElbow = A(0, 0, -125), RightElbow = A(0, 0, 125), Waist = A(-6), Neck = A(8) } },
			{ t = 0.25, joints = { LeftShoulder = A(0, 0, -90), RightShoulder = A(0, 0, 90), LeftElbow = A(0, 0, -100), RightElbow = A(0, 0, 100), Neck = A(8) } },
			{ t = 0.25, joints = { LeftShoulder = A(0, 0, -80), RightShoulder = A(0, 0, 80), LeftElbow = A(0, 0, -125), RightElbow = A(0, 0, 125), Waist = A(-6), Neck = A(8) } },
			{ t = 0.5, joints = { LeftShoulder = A(0, 0, -90), RightShoulder = A(0, 0, 90), LeftElbow = A(0, 0, -110), RightElbow = A(0, 0, 110), Neck = A(10) } },
		},
	},
	{
		id = "Point",
		name = "Point",
		icon = "👉",
		category = "Social",
		loop = false,
		frames = {
			{ t = 0.22, joints = { RightShoulder = A(92, 0, 4), RightElbow = A(4), Neck = A(2) } },
			{ t = 1.2, joints = { RightShoulder = A(90, 0, 4), RightElbow = A(2), Neck = A(2) } },
		},
	},
	{
		id = "Laugh",
		name = "Laugh",
		icon = "😂",
		category = "Social",
		loop = false,
		frames = {
			{ t = 0.2, joints = { Waist = A(-12), Neck = A(18), LeftShoulder = A(25, 0, -5), RightShoulder = A(25, 0, 5), LeftElbow = A(85), RightElbow = A(85) } },
			{ t = 0.14, joints = { Waist = A(-18), Neck = A(6), LeftShoulder = A(30, 0, -5), RightShoulder = A(30, 0, 5), LeftElbow = A(90), RightElbow = A(90) } },
			{ t = 0.14, joints = { Waist = A(-10), Neck = A(20), LeftShoulder = A(25, 0, -5), RightShoulder = A(25, 0, 5), LeftElbow = A(85), RightElbow = A(85) } },
			{ t = 0.14, joints = { Waist = A(-18), Neck = A(6), LeftShoulder = A(30, 0, -5), RightShoulder = A(30, 0, 5), LeftElbow = A(90), RightElbow = A(90) } },
			{ t = 0.14, joints = { Waist = A(-10), Neck = A(20), LeftShoulder = A(25, 0, -5), RightShoulder = A(25, 0, 5), LeftElbow = A(85), RightElbow = A(85) } },
			{ t = 0.14, joints = { Waist = A(-20), Neck = A(4), LeftShoulder = A(30, 0, -5), RightShoulder = A(30, 0, 5), LeftElbow = A(90), RightElbow = A(90) } },
			{ t = 0.3, joints = { Waist = A(-6), Neck = A(14), LeftShoulder = A(20, 0, -5), RightShoulder = A(20, 0, 5), LeftElbow = A(80), RightElbow = A(80) } },
		},
	},
	{
		id = "Celebrate",
		name = "Celebrate",
		icon = "🎉",
		category = "Social",
		loop = false,
		frames = {
			{ t = 0.2, joints = { Root = D(-0.4), LeftKnee = A(-30), RightKnee = A(-30), LeftHip = A(18), RightHip = A(18), LeftShoulder = A(20, 0, -20), RightShoulder = A(20, 0, 20), LeftElbow = A(70), RightElbow = A(70) } },
			{ t = 0.2, joints = { Root = D(0.5), Neck = A(20), LeftShoulder = A(0, 0, -160), RightShoulder = A(0, 0, 160), LeftAnkle = A(-25), RightAnkle = A(-25) } },
			{ t = 0.2, joints = { Root = D(-0.3), LeftKnee = A(-25), RightKnee = A(-25), LeftHip = A(15), RightHip = A(15), LeftShoulder = A(0, 0, -140), RightShoulder = A(0, 0, 140), LeftElbow = A(0, 0, -40), RightElbow = A(0, 0, 40) } },
			{ t = 0.2, joints = { Root = D(0.5), Neck = A(20), LeftShoulder = A(0, 0, -165), RightShoulder = A(0, 0, 165), LeftAnkle = A(-25), RightAnkle = A(-25) } },
			{ t = 0.5, joints = { Neck = A(15), LeftShoulder = A(0, 0, -150), RightShoulder = A(0, 0, 150) } },
		},
	},
	{
		id = "Shimmy",
		name = "Shoulder Shimmy",
		icon = "🔥",
		category = "Hoops",
		loop = true,
		frames = {
			{ t = 0.12, joints = { Waist = A(-4, 7, 0), LeftShoulder = A(18, 0, -12), RightShoulder = A(-14, 0, 12), LeftElbow = A(60), RightElbow = A(60), LeftKnee = A(-15), RightKnee = A(-15), Root = D(-0.15) } },
			{ t = 0.12, joints = { Waist = A(-4, -7, 0), LeftShoulder = A(-14, 0, -12), RightShoulder = A(18, 0, 12), LeftElbow = A(60), RightElbow = A(60), LeftKnee = A(-15), RightKnee = A(-15), Root = D(-0.15) } },
		},
	},
	{
		id = "LilBro",
		name = "Lil Bro",
		icon = "🤏",
		category = "Hoops",
		loop = false,
		frames = {
			{ t = 0.25, joints = { Root = D(-0.45), Waist = A(-14), Neck = A(-12), LeftKnee = A(-35), RightKnee = A(-35), LeftHip = A(22), RightHip = A(22), RightShoulder = A(35, 0, 25), RightElbow = A(15), LeftShoulder = A(0, 0, -10) } },
			{ t = 0.18, joints = { Root = D(-0.45), Waist = A(-14), Neck = A(-12), LeftKnee = A(-35), RightKnee = A(-35), LeftHip = A(22), RightHip = A(22), RightShoulder = A(18, 0, 25), RightElbow = A(10), LeftShoulder = A(0, 0, -10) } },
			{ t = 0.18, joints = { Root = D(-0.45), Waist = A(-14), Neck = A(-12), LeftKnee = A(-35), RightKnee = A(-35), LeftHip = A(22), RightHip = A(22), RightShoulder = A(35, 0, 25), RightElbow = A(15), LeftShoulder = A(0, 0, -10) } },
			{ t = 0.18, joints = { Root = D(-0.45), Waist = A(-14), Neck = A(-12), LeftKnee = A(-35), RightKnee = A(-35), LeftHip = A(22), RightHip = A(22), RightShoulder = A(18, 0, 25), RightElbow = A(10), LeftShoulder = A(0, 0, -10) } },
			{ t = 0.5, joints = { Root = D(-0.45), Waist = A(-10), Neck = A(10), LeftKnee = A(-35), RightKnee = A(-35), LeftHip = A(22), RightHip = A(22), RightShoulder = A(30, 0, 25), RightElbow = A(12), LeftShoulder = A(0, 0, -10) } },
		},
	},
	{
		id = "ColdBlooded",
		name = "Cold Blooded",
		icon = "🧊",
		category = "Hoops",
		loop = false,
		frames = {
			{ t = 0.3, joints = { Neck = A(-5, -15, 0), RightShoulder = A(55, 0, 10), RightElbow = A(70), LeftShoulder = A(55, 0, 25), LeftElbow = A(80) } },
			{ t = 0.16, joints = { Neck = A(-5, -15, 0), RightShoulder = A(55, 0, 10), RightElbow = A(70), LeftShoulder = A(55, 0, 25), LeftElbow = A(95) } },
			{ t = 0.16, joints = { Neck = A(-5, -15, 0), RightShoulder = A(55, 0, 10), RightElbow = A(70), LeftShoulder = A(55, 0, 25), LeftElbow = A(78) } },
			{ t = 0.16, joints = { Neck = A(-5, -15, 0), RightShoulder = A(55, 0, 10), RightElbow = A(70), LeftShoulder = A(55, 0, 25), LeftElbow = A(95) } },
			{ t = 0.6, joints = { Neck = A(6, 0, 0), RightShoulder = A(55, 0, 10), RightElbow = A(70), LeftShoulder = A(55, 0, 25), LeftElbow = A(80) } },
		},
	},
	{
		id = "RaiseRoof",
		name = "Raise the Roof",
		icon = "🙌",
		category = "Hoops",
		loop = true,
		frames = {
			{ t = 0.28, joints = { Root = D(-0.25), LeftKnee = A(-20), RightKnee = A(-20), LeftHip = A(12), RightHip = A(12), LeftShoulder = A(0, 0, -100), RightShoulder = A(0, 0, 100), LeftElbow = A(0, 0, -80), RightElbow = A(0, 0, 80), Neck = A(10) } },
			{ t = 0.28, joints = { Root = D(0), LeftShoulder = A(0, 0, -150), RightShoulder = A(0, 0, 150), LeftElbow = A(0, 0, -40), RightElbow = A(0, 0, 40), Neck = A(18) } },
		},
	},
	-- Paired emotes: both players face each other and play the same frames.
	{
		id = "HighFive",
		name = "High Five",
		icon = "🖐️",
		category = "Paired",
		loop = false,
		paired = true,
		gap = 3.2,
		sideShift = 0.55,
		frames = {
			{ t = 0.35, joints = { RightShoulder = A(150, 0, 12), RightElbow = A(35), Neck = A(8) } },
			{ t = 0.14, joints = { RightShoulder = A(125, 0, 6), RightElbow = A(0), Neck = A(8) } },
			{ t = 0.45, joints = { RightShoulder = A(120, 0, 6), RightElbow = A(5), Neck = A(4) } },
		},
	},
	{
		id = "FistBump",
		name = "Fist Bump",
		icon = "👊",
		category = "Paired",
		loop = false,
		paired = true,
		gap = 3.4,
		sideShift = 0.6,
		frames = {
			{ t = 0.3, joints = { RightShoulder = A(65, 0, 6), RightElbow = A(75), Neck = A(-4) } },
			{ t = 0.16, joints = { RightShoulder = A(85, 0, 2), RightElbow = A(8), Waist = A(-6), Neck = A(-4) } },
			{ t = 0.5, joints = { RightShoulder = A(82, 0, 2), RightElbow = A(12), Waist = A(-4), Neck = A(2) } },
		},
	},
	{
		id = "Handshake",
		name = "Handshake",
		icon = "🤝",
		category = "Paired",
		loop = false,
		paired = true,
		gap = 2.9,
		sideShift = 0.6,
		frames = {
			{ t = 0.35, joints = { RightShoulder = A(45, 0, 6), RightElbow = A(35), Neck = A(-4) } },
			{ t = 0.18, joints = { RightShoulder = A(55, 0, 6), RightElbow = A(30), Neck = A(-4) } },
			{ t = 0.18, joints = { RightShoulder = A(38, 0, 6), RightElbow = A(38), Neck = A(-4) } },
			{ t = 0.18, joints = { RightShoulder = A(55, 0, 6), RightElbow = A(30), Neck = A(-4) } },
			{ t = 0.18, joints = { RightShoulder = A(38, 0, 6), RightElbow = A(38), Neck = A(-4) } },
			{ t = 0.3, joints = { RightShoulder = A(45, 0, 6), RightElbow = A(35), Neck = A(2) } },
		},
	},
} :: { Emote }

EmotesConfig.BY_ID = {} :: { [string]: Emote }
for _, emote in EmotesConfig.LIST do
	EmotesConfig.BY_ID[emote.id] = emote
end

-- "high five", "High Five", "HighFive", "highfive" all resolve to the same emote.
local function normalize(text: string): string
	return (string.lower(text):gsub("[^%w]", ""))
end

local LOOKUP: { [string]: Emote } = {}
for _, emote in EmotesConfig.LIST do
	LOOKUP[normalize(emote.id)] = emote
	LOOKUP[normalize(emote.name)] = emote
end
LOOKUP.dance1 = EmotesConfig.BY_ID.Dance
LOOKUP.twostep = EmotesConfig.BY_ID.Dance
LOOKUP.dance2 = EmotesConfig.BY_ID.Bounce
LOOKUP.dance3 = EmotesConfig.BY_ID.Robot
LOOKUP.cheer = EmotesConfig.BY_ID.Celebrate
LOOKUP.hi = EmotesConfig.BY_ID.Wave
LOOKUP.hello = EmotesConfig.BY_ID.Wave

function EmotesConfig.find(name: any): Emote?
	if type(name) ~= "string" or #name > 40 then
		return nil
	end
	return LOOKUP[normalize(name)]
end

return EmotesConfig
