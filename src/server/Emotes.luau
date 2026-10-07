-- CITY GRIND: emotes (sections 31, 95). Server side.
-- The server tweens the character's R15 Motor6D C0s (like the gym) so every
-- player sees the emote. Looping emotes run until the player moves or jumps;
-- one-shot emotes return to rest. R6 avatars only get the emote bubble.
-- Paired emotes (High Five, Fist Bump, Handshake) need both players to agree:
-- one sends a request, the other accepts, then both face each other and play.
--
-- Remotes:  EmoteAction (client -> server): ("play", id) ("stop") ("equip", slot, id)
--                  ("pairRequest", target, id) ("pairRespond", requestId, accept)
--           EmoteEvent  (server -> client): ("pairPrompt", {id, fromName, fromUserId, emote, expires})
-- Player attributes: Emote (id playing, "" when idle), EmoteSlots (comma list of the 8 equipped ids)
-- Saved section "emotes" = { slots = { id x8 } }

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local Net = require(script.Parent:WaitForChild("Net"))
local AntiCheat = require(script.Parent:WaitForChild("AntiCheat"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local EmotesConfig = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("EmotesConfig"))

local Emotes = {}

type Emote = EmotesConfig.Emote

local JOINT_NAMES = {
	"Root", "Waist", "Neck",
	"LeftShoulder", "RightShoulder", "LeftElbow", "RightElbow",
	"LeftHip", "RightHip", "LeftKnee", "RightKnee", "LeftAnkle", "RightAnkle",
}

type Playing = {
	emote: Emote,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	motors: { [string]: Motor6D },
	rest: { [Motor6D]: CFrame },
	tweens: { Tween },
	token: number,
	startedAt: number,
	anchoredByUs: boolean,
	bubble: BillboardGui?,
	conns: { RBXScriptConnection },
}

local playing: { [Player]: Playing } = {}
local tokenCounter = 0
-- characters whose pose was interrupted by another posing system (the gym);
-- they get reset to rest once that system lets go.
local needsReset: { [Model]: boolean } = {}

type PairRequest = { id: string, from: Player, to: Player, emote: Emote, expires: number }
local pairRequests: { [string]: PairRequest } = {}

local EmoteAction = Net.remote("RemoteEvent", "EmoteAction")
local EmoteEvent = Net.remote("RemoteEvent", "EmoteEvent")

PlayerData.registerSection("emotes", function()
	return { slots = table.clone(EmotesConfig.DEFAULT_SLOTS) }
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function lazy(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

local function attr(player: Player, name: string): any
	local v = player:GetAttribute(name)
	if v == "" then
		return nil
	end
	return v
end

local function findMotors(character: Model): { [string]: Motor6D }
	local wanted = {}
	for _, name in JOINT_NAMES do
		wanted[name] = true
	end
	local motors = {}
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and wanted[d.Name] and not motors[d.Name] then
			motors[d.Name] = d
		end
	end
	return motors
end

local function isR15(humanoid: Humanoid, motors: { [string]: Motor6D }): boolean
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return false
	end
	for _, name in { "Root", "Waist", "LeftShoulder", "RightShoulder", "LeftElbow", "RightElbow", "LeftHip", "RightHip", "LeftKnee", "RightKnee" } do
		if not motors[name] then
			return false
		end
	end
	return true
end

-- The joint's true rest C0 is the rig attachment it was built from.
local function restC0(motor: Motor6D): CFrame?
	local part0 = motor.Part0
	local att = part0 and part0:FindFirstChild(motor.Name .. "RigAttachment")
	if att and att:IsA("Attachment") then
		return att.CFrame
	end
	return nil
end

local function nearlyEqual(a: CFrame, b: CFrame): boolean
	if (a.Position - b.Position).Magnitude > 0.02 then
		return false
	end
	return a.LookVector:Dot(b.LookVector) > 0.999 and a.UpVector:Dot(b.UpVector) > 0.999
end

local function charParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

-- Why a player can't emote right now (nil = they can).
local function blockReason(player: Player): string?
	if not Net.alive(player) then
		return "You can't emote right now."
	end
	local _, humanoid, root = charParts(player)
	if not humanoid or not root then
		return "You can't emote right now."
	end
	if attr(player, "Training") then
		return "Finish your workout first."
	end
	if attr(player, "Driving") or humanoid.SeatPart then
		return "You can't emote while seated or driving."
	end
	if humanoid.PlatformStand or root.Anchored then
		return "You can't emote right now."
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Climbing or state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.FallingDown then
		return "Land first, then emote."
	end
	return nil
end

-- True when another system (carrying a box at work, etc.) is already posing the arms.
local function posedByOthers(motors: { [string]: Motor6D }): boolean
	for _, name in { "LeftShoulder", "RightShoulder", "Root" } do
		local motor = motors[name]
		local rest = motor and restC0(motor)
		if motor and rest and not nearlyEqual(motor.C0, rest) then
			return true
		end
	end
	return false
end

local function showBubble(character: Model, emote: Emote): BillboardGui?
	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return nil
	end
	local old = head:FindFirstChild("EmoteBubble")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "EmoteBubble"
	gui.Size = UDim2.fromOffset(44, 44)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 90
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	bg.BackgroundTransparency = 0.15
	bg.BorderSizePixel = 0
	bg.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = bg
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = emote.icon
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = bg
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = label
	gui.Parent = head
	return gui
end

---------------------------------------------------------------------------
-- Playback
---------------------------------------------------------------------------
-- Ends the emote. `keepPose` leaves the joints alone (another system just took them over).
local function stopEmote(player: Player, keepPose: boolean?)
	local p = playing[player]
	if not p then
		return
	end
	playing[player] = nil
	p.token = -1
	for _, c in p.conns do
		c:Disconnect()
	end
	for _, t in p.tweens do
		t:Cancel()
	end
	if keepPose then
		needsReset[p.character] = true
	else
		local info = TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		for motor, rest in p.rest do
			if motor.Parent then
				TweenService:Create(motor, info, { C0 = rest }):Play()
			end
		end
	end
	if p.anchoredByUs and p.root.Parent then
		p.root.Anchored = false
	end
	if p.bubble then
		p.bubble:Destroy()
	end
	if player.Parent then
		player:SetAttribute("Emote", "")
	end
end

local function runFrames(player: Player, p: Playing, frames: { EmotesConfig.Frame }, sitDrop: number): boolean
	for _, frame in frames do
		if playing[player] ~= p then
			return false
		end
		local info = TweenInfo.new(frame.t, frame.style or Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		table.clear(p.tweens)
		for name, motor in p.motors do
			local rest = p.rest[motor]
			if rest and motor.Parent then
				local offset = frame.joints[name] or CFrame.identity
				if name == "Root" and sitDrop ~= 0 then
					offset = CFrame.new(0, sitDrop, 0) * offset
				end
				local t = TweenService:Create(motor, info, { C0 = rest * offset })
				t:Play()
				table.insert(p.tweens, t)
			end
		end
		task.wait(frame.t)
	end
	return true
end

-- Starts an emote on one player (validation already done). Returns false for R6.
local function startEmote(player: Player, emote: Emote, holdSeconds: number?): boolean
	stopEmote(player)
	local character, humanoid, root = charParts(player)
	if not character or not humanoid or not root then
		return false
	end
	local motors = findMotors(character)
	local posed = isR15(humanoid, motors)
	tokenCounter += 1
	local p: Playing = {
		emote = emote,
		character = character,
		humanoid = humanoid,
		root = root,
		motors = if posed then motors else {},
		rest = {},
		tweens = {},
		token = tokenCounter,
		startedAt = os.clock(),
		anchoredByUs = false,
		bubble = showBubble(character, emote),
		conns = {},
	}
	for _, motor in p.motors do
		p.rest[motor] = restC0(motor) or motor.C0
	end
	playing[player] = p
	player:SetAttribute("Emote", emote.id)
	needsReset[character] = nil

	table.insert(p.conns, humanoid.Died:Connect(function()
		stopEmote(player, true)
	end))
	table.insert(p.conns, character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			stopEmote(player, true)
		end
	end))

	local sitDrop = 0
	if emote.sit then
		sitDrop = -math.max(0.6, humanoid.HipHeight - 0.55)
	end

	task.spawn(function()
		local myToken = p.token
		if not posed then
			-- R6 / custom rigs: just the bubble for a moment.
			local untilTime = os.clock() + (holdSeconds or 2)
			while p.token == myToken and (emote.loop or os.clock() < untilTime) do
				task.wait(0.25)
			end
		else
			if emote.intro then
				runFrames(player, p, emote.intro, sitDrop)
			end
			repeat
				if not runFrames(player, p, emote.frames, sitDrop) then
					return
				end
			until not emote.loop or p.token ~= myToken
		end
		if p.token == myToken and playing[player] == p then
			stopEmote(player)
		end
	end)
	return true
end

-- Public: play an emote on a player after full validation. Returns (ok, reason).
function Emotes.play(player: Player, name: string): (boolean, string?)
	local emote = EmotesConfig.find(name)
	if not emote then
		return false, "Unknown emote."
	end
	if emote.paired then
		return false, "Find a partner for " .. emote.name .. "."
	end
	local reason = blockReason(player)
	if reason then
		return false, reason
	end
	local character = player.Character
	local current = playing[player]
	if not current and character and posedByOthers(findMotors(character)) then
		return false, "Put down what you're holding first."
	end
	startEmote(player, emote)
	return true
end

function Emotes.stop(player: Player)
	stopEmote(player)
end

function Emotes.isEmoting(player: Player): boolean
	return playing[player] ~= nil
end

-- Public: both players face each other and play the same paired emote.
-- Call only after both agreed (Social's request flow or our own pair request).
function Emotes.playPaired(a: Player, b: Player, name: string): (boolean, string?)
	local emote = EmotesConfig.find(name)
	if not emote or not emote.paired then
		return false, "Unknown paired emote."
	end
	if a == b then
		return false, "You need someone else for that."
	end
	for _, pl in { a, b } do
		local reason = blockReason(pl)
		if reason then
			return false, pl.DisplayName .. ": " .. reason
		end
		local character = pl.Character
		if not playing[pl] and character and posedByOthers(findMotors(character)) then
			return false, pl.DisplayName .. " has their hands full."
		end
	end
	local _, _, rootA = charParts(a)
	local _, _, rootB = charParts(b)
	if not rootA or not rootB then
		return false, "You can't do that right now."
	end
	local flat = Vector3.new(rootB.Position.X - rootA.Position.X, 0, rootB.Position.Z - rootA.Position.Z)
	if flat.Magnitude > EmotesConfig.PAIR_RANGE + 2 or math.abs(rootA.Position.Y - rootB.Position.Y) > 6 then
		return false, "Get closer to each other first."
	end
	local dir = if flat.Magnitude > 0.05 then flat.Unit else rootA.CFrame.LookVector * Vector3.new(1, 0, 1)
	if dir.Magnitude < 0.05 then
		dir = Vector3.new(0, 0, -1)
	end
	dir = dir.Unit
	local mid = (rootA.Position + rootB.Position) / 2
	local gap = emote.gap or 3
	local right = dir:Cross(Vector3.yAxis) -- a's right-hand side
	local shift = emote.sideShift or 0
	local posA = Vector3.new(mid.X, rootA.Position.Y, mid.Z) - dir * gap / 2 - right * shift
	local posB = Vector3.new(mid.X, rootB.Position.Y, mid.Z) + dir * gap / 2 + right * shift

	for _, entry in { { a, rootA, posA, posA + dir }, { b, rootB, posB, posB - dir } } do
		local pl, root, pos, look = entry[1], entry[2], entry[3], entry[4]
		AntiCheat.allowTeleport(pl, 2)
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.lookAt(pos, Vector3.new(look.X, pos.Y, look.Z))
		if startEmote(pl, emote) then
			local p = playing[pl]
			if p and not root.Anchored then
				root.Anchored = true -- hold still for the short animation
				p.anchoredByUs = true
			end
		end
	end
	return true
end

-- Public: one player asks another for a paired emote; the target gets an ACCEPT prompt.
function Emotes.requestPaired(from: Player, to: Player, name: string): (boolean, string?)
	local emote = EmotesConfig.find(name)
	if not emote or not emote.paired then
		return false, "Unknown paired emote."
	end
	if to == from or not to.Parent then
		return false, "Pick someone else."
	end
	local reason = blockReason(from)
	if reason then
		return false, reason
	end
	local _, _, rootTo = charParts(to)
	if not rootTo or Net.distance(from, rootTo.Position) > EmotesConfig.PAIR_RANGE then
		return false, "Get closer to " .. to.DisplayName .. " first."
	end
	local Social = lazy("Social")
	if Social and Social.allows then
		local ok, allowed, why = pcall(Social.allows, from, to, "interact")
		if ok and not allowed then
			return false, why or (to.DisplayName .. " isn't accepting that right now.")
		end
	end
	for id, req in pairRequests do
		if req.from == from and req.to == to and os.clock() < req.expires then
			return false, "You already asked " .. to.DisplayName .. "."
		end
		if os.clock() >= req.expires then
			pairRequests[id] = nil
		end
	end
	local id = HttpService:GenerateGUID(false)
	local req: PairRequest = { id = id, from = from, to = to, emote = emote, expires = os.clock() + EmotesConfig.PAIR_REQUEST_SECONDS }
	pairRequests[id] = req
	EmoteEvent:FireClient(to, "pairPrompt", {
		id = id,
		fromName = from.DisplayName,
		fromUserId = from.UserId,
		emote = emote.id,
		seconds = EmotesConfig.PAIR_REQUEST_SECONDS,
	})
	return true
end

local function respondPair(player: Player, id: any, accept: any)
	if type(id) ~= "string" then
		return
	end
	local req = pairRequests[id]
	if not req or req.to ~= player then
		return
	end
	pairRequests[id] = nil
	if os.clock() > req.expires or not req.from.Parent then
		Net.notify(player, "TOO LATE", "That request expired.")
		return
	end
	if accept ~= true then
		Net.notify(req.from, req.emote.name:upper(), player.DisplayName .. " passed this time.")
		return
	end
	local ok, why = Emotes.playPaired(req.from, player, req.emote.id)
	if not ok then
		Net.notify(player, req.emote.name:upper(), why or "Couldn't do that right now.")
		Net.notify(req.from, req.emote.name:upper(), why or "Couldn't do that right now.")
	end
end

---------------------------------------------------------------------------
-- Equipped slots
---------------------------------------------------------------------------
local function publishSlots(player: Player)
	local section = PlayerData.section(player, "emotes")
	if not section then
		return
	end
	local valid = {}
	for i = 1, EmotesConfig.SLOTS do
		local id = section.slots[i]
		if type(id) ~= "string" or not EmotesConfig.BY_ID[id] then
			id = EmotesConfig.DEFAULT_SLOTS[i]
			section.slots[i] = id
		end
		valid[i] = id
	end
	player:SetAttribute("EmoteSlots", table.concat(valid, ","))
end

local function equip(player: Player, slot: any, id: any)
	if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 1 or slot > EmotesConfig.SLOTS then
		return
	end
	if type(id) ~= "string" or not EmotesConfig.BY_ID[id] then
		return
	end
	local section = PlayerData.section(player, "emotes")
	if not section then
		return
	end
	-- an emote sits in one slot only: swap with wherever it was
	local oldIndex = table.find(section.slots, id)
	if oldIndex and oldIndex ~= slot then
		section.slots[oldIndex] = section.slots[slot]
	end
	section.slots[slot] = id
	PlayerData.markChanged(player)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Emotes.start(_city: Instance?)
	PlayerData.onPublish(function(player)
		publishSlots(player)
	end)

	EmoteAction.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any)
		if action == "play" then
			if not Net.allow(player, "EmotePlay", EmotesConfig.COOLDOWN) then
				return
			end
			local ok, why = Emotes.play(player, a)
			if not ok and why then
				Net.notify(player, "EMOTE", why)
			end
		elseif action == "stop" then
			if Net.allow(player, "EmoteStop", 0.1) then
				local p = playing[player]
				-- paired emotes hold both players still and finish on their own
				if p and not p.emote.paired then
					stopEmote(player)
				end
			end
		elseif action == "equip" then
			if Net.allow(player, "EmoteEquip", 0.15) then
				equip(player, a, b)
			end
		elseif action == "pairRequest" then
			if not Net.allow(player, "EmotePair", 2) then
				return
			end
			if typeof(a) ~= "Instance" or not a:IsA("Player") then
				return
			end
			local ok, why = Emotes.requestPaired(player, a, b)
			if ok then
				local emote = EmotesConfig.find(b)
				Net.notify(player, (emote and emote.name or "EMOTE"):upper(), "Asked " .. a.DisplayName .. ". Waiting for them to accept.")
			else
				Net.notify(player, "EMOTE", why or "Can't do that right now.")
			end
		elseif action == "pairRespond" then
			if Net.allow(player, "EmotePairRespond", 0.3) then
				respondPair(player, a, b)
			end
		end
	end)

	-- Using a prompt (gym machine, job pickup, door...) ends the emote first.
	local function promptStop(_prompt: ProximityPrompt, player: Player)
		local p = playing[player]
		if p and not p.emote.paired then
			stopEmote(player, attr(player, "Training") ~= nil)
		end
	end
	ProximityPromptService.PromptButtonHoldBegan:Connect(promptStop)
	ProximityPromptService.PromptTriggered:Connect(promptStop)

	local function watchPlayer(player: Player)
		for _, name in { "Training", "Driving" } do
			player:GetAttributeChangedSignal(name):Connect(function()
				local value = attr(player, name)
				if value and playing[player] then
					-- another system is posing the body now: don't fight it
					stopEmote(player, name == "Training")
				elseif not value and name == "Training" then
					local character = player.Character
					if character and needsReset[character] then
						needsReset[character] = nil
						task.defer(function()
							if attr(player, "Training") or playing[player] then
								return
							end
							for _, motor in findMotors(character) do
								local rest = restC0(motor)
								if rest then
									motor.C0 = rest
								end
							end
						end)
					end
				end
			end)
		end
		player.CharacterRemoving:Connect(function(character)
			needsReset[character] = nil
			stopEmote(player, true)
		end)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		stopEmote(player, true)
		for id, req in pairRequests do
			if req.from == player or req.to == player then
				pairRequests[id] = nil
			end
		end
	end)

	-- Moving, jumping, sitting or getting knocked over ends an emote.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		for player, p in playing do
			if p.anchoredByUs then
				continue
			end
			local humanoid, root = p.humanoid, p.root
			if not root.Parent or humanoid.Health <= 0 then
				stopEmote(player, true)
				continue
			end
			if os.clock() - p.startedAt < 0.3 then
				continue
			end
			local v = root.AssemblyLinearVelocity
			local state = humanoid:GetState()
			if Vector3.new(v.X, 0, v.Z).Magnitude > 3.5 or v.Y > 6 or humanoid.Jump or humanoid.SeatPart
				or state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
				stopEmote(player)
			end
		end
	end)
end

return Emotes
