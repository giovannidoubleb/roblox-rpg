-- CITY GRIND: the living world (spec 65, 66, 81, 82, 89). Server side.
--
-- * Collectibles (81): four sets hidden around every district at hand-picked
--   spots (WorldConfig.SPOTS). Each spot is checked at build time with a
--   raycast (a floor below) and an overlap test (nothing solid where you'd
--   stand); bad spots are skipped. Items are server parts under City.World.
--   Collectibles; each client hides the ones it already owns. The server
--   validates every pickup (touch or client proximity remote) by distance.
-- * Secrets (82): parts tagged "SecretArea" (attribute SecretId, DisplayName,
--   built by Districts). Once a second the server checks whether each player
--   stands inside one; the first visit pays once. Secrets are never on the map.
-- * Weather (66): server state machine. Workspace attributes Weather (id),
--   WeatherEnds (server time), WeatherGrip (vehicle grip multiplier).
-- * NPC pedestrians (65, 89): ~24 server-owned rigs walking a sidewalk graph
--   built from the map, following daily schedules, sleeping (anchored) when no
--   player is within 250 studs, and recognising famous players (turn, wave,
--   speech bubble) with cooldowns. Tag "CityNPC" (the client animates legs).
--
-- Remotes: WorldRequest (RemoteFunction, client -> server: "Get") -> state?
--          WorldCollect (RemoteEvent, client -> server: id)
--          WorldEvent   (RemoteEvent, server -> client):
--            ("State", state) | ("Collected", id) | ("Secret", id, name)
-- Player attributes: Collectibles (number found), SecretsFound (number found).
-- Saved section "world": { c = {[spotId]=true}, sets = {[setId]=true}, all = bool,
--                          secrets = {[secretId]=unix time} }
--
-- Public API:
--   World.weather() -> string                 current weather id
--   World.collectedCount(player) -> number
--   World.secretsFound(player) -> number

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local WC = require(shared:WaitForChild("WorldConfig"))
local DC = require(shared:WaitForChild("DistrictsConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local AntiCheat = require(script.Parent:WaitForChild("AntiCheat"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local World = {}

local SECTION = "world"

PlayerData.registerSection(SECTION, function()
	return { c = {}, sets = {}, all = false, secrets = {} }
end)

local function sec(player: Player): any
	return PlayerData.section(player, SECTION)
end

local V = Vector3.new

local root: Folder
local WorldEvent: RemoteEvent

-- Lazily required sibling (Quests is optional; never error if it is missing).
local function sibling(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, result = pcall(require, mod)
	return if ok then result else nil
end

-- Unlocks an achievement through Quests when it exists there.
local function unlock(player: Player, id: string)
	local Quests = sibling("Quests")
	if Quests and Quests.unlock then
		pcall(Quests.unlock, player, id)
	end
end

local function rootPart(player: Player): BasePart?
	local character = player.Character
	local r = character and character:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

---------------------------------------------------------------------------
-- Geometry checks shared by collectibles and the NPC sidewalk graph
---------------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.RespectCanCollide = true

local probe: BasePart -- invisible box used for exact overlap tests at build time

local function setFilters(extra: { Instance })
	local list: { Instance } = { root }
	for _, i in extra do
		table.insert(list, i)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	rayParams.FilterDescendantsInstances = list
	overlapParams.FilterDescendantsInstances = list
end

-- True when a box of `size` centred at `center` touches nothing solid.
local function clear(center: Vector3, size: Vector3): boolean
	probe.Size = size
	probe.CFrame = CFrame.new(center)
	return #Workspace:GetPartsInPart(probe, overlapParams) == 0
end

---------------------------------------------------------------------------
-- Collectibles (81)
---------------------------------------------------------------------------
type Item = { id: string, set: string, district: string, center: Vector3, model: Model }
local items: { [string]: Item } = {}
local secretNames: { [string]: string } = {} -- SecretId -> DisplayName (filled from the tagged parts)
local itemList: { Item } = {}
local setTotals: { [string]: number } = {}

local function visualPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p:SetAttribute("Spin", true)
	p.Parent = parent
	return p
end

-- The look of one item of each set, built around `c`.
local function buildLook(model: Model, set: string, c: CFrame)
	local color = (WC.SET_BY_ID[set] :: WC.CollectibleSet).color
	if set == "Balls" then
		local ball = visualPart(model, "Ball", V(1.9, 1.9, 1.9), c, Color3.fromRGB(255, 190, 40), Enum.Material.Metal, Enum.PartType.Ball)
		ball.Reflectance = 0.25
		for _, a in { 0, math.pi / 2 } do
			visualPart(model, "Seam", V(0.08, 1.95, 1.95), c * CFrame.Angles(0, a, 0), Color3.fromRGB(60, 40, 20), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		end
	elseif set == "Tags" then
		visualPart(model, "Can", V(1.7, 0.85, 0.85), c * CFrame.Angles(0, 0, math.pi / 2), color, Enum.Material.Metal, Enum.PartType.Cylinder)
		visualPart(model, "Cap", V(0.7, 0.7, 0.7), c * CFrame.new(0, 1.05, 0), Color3.fromRGB(240, 240, 245), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		visualPart(model, "Label", V(0.9, 0.6, 0.9), c * CFrame.new(0, -0.1, 0), Color3.fromRGB(30, 30, 35), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	elseif set == "Sneakers" then
		visualPart(model, "Sole", V(0.9, 0.35, 2), c * CFrame.new(0, -0.45, 0), Color3.fromRGB(245, 245, 245))
		visualPart(model, "Upper", V(0.85, 0.75, 1.35), c * CFrame.new(0, 0.1, 0.3), color)
		visualPart(model, "Toe", V(0.85, 0.5, 0.7), c * CFrame.new(0, -0.03, -0.65), color)
		visualPart(model, "Swoosh", V(0.88, 0.18, 1), c * CFrame.new(0, 0, 0.15), Color3.fromRGB(255, 90, 60))
	else
		visualPart(model, "Shell", V(2, 1.25, 0.3), c, Color3.fromRGB(25, 25, 30))
		visualPart(model, "Label", V(1.6, 0.55, 0.34), c * CFrame.new(0, 0.2, 0), color)
		for _, x in { -0.45, 0.45 } do
			visualPart(model, "Reel", V(0.36, 0.36, 0.36), c * CFrame.new(x, -0.25, 0) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(240, 240, 240), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		end
	end
end

local function buildCollectibles()
	local folder = Instance.new("Folder")
	folder.Name = "Collectibles"
	folder.Parent = root
	local skipped = {}
	for _, spot in WC.SPOTS do
		if not WC.SET_BY_ID[spot.set] or items[spot.id] then
			continue
		end
		local hit = Workspace:Raycast(spot.pos, V(0, -30, 0), rayParams)
		if not hit or hit.Normal.Y < 0.7 then
			table.insert(skipped, spot.id)
			continue
		end
		local floorY = hit.Position.Y
		-- room to stand: nothing solid from just above the floor to head height
		if not clear(V(spot.pos.X, floorY + 3.1, spot.pos.Z), V(2.4, 5, 2.4)) then
			table.insert(skipped, spot.id)
			continue
		end
		local center = V(spot.pos.X, floorY + 2.2, spot.pos.Z)
		local model = Instance.new("Model")
		model.Name = spot.id
		model:SetAttribute("Id", spot.id)
		model:SetAttribute("Set", spot.set)
		model:SetAttribute("Center", center)
		local hitbox = Instance.new("Part")
		hitbox.Name = "Hitbox"
		hitbox.Anchored = true
		hitbox.CanCollide = false
		hitbox.CanQuery = false
		hitbox.CanTouch = true
		hitbox.Transparency = 1
		hitbox.Size = V(4, 5, 4)
		hitbox.CFrame = CFrame.new(center + V(0, 0.3, 0))
		hitbox.Parent = model
		buildLook(model, spot.set, CFrame.new(center))
		local glow = Instance.new("PointLight")
		glow.Range = 9
		glow.Brightness = 1.2
		glow.Shadows = false
		glow.Color = (WC.SET_BY_ID[spot.set] :: WC.CollectibleSet).color
		glow.Parent = hitbox
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Rate = 3
		sparkle.Lifetime = NumberRange.new(0.8, 1.4)
		sparkle.Speed = NumberRange.new(1, 2)
		sparkle.SpreadAngle = Vector2.new(180, 180)
		sparkle.Size = NumberSequence.new(0.25, 0)
		sparkle.LightEmission = 1
		sparkle.Color = ColorSequence.new(glow.Color)
		sparkle.Parent = hitbox
		model.PrimaryPart = hitbox
		model.Parent = folder
		CollectionService:AddTag(model, "Collectible")

		local item: Item = { id = spot.id, set = spot.set, district = DC.at(center), center = center, model = model }
		items[spot.id] = item
		table.insert(itemList, item)
		setTotals[spot.set] = (setTotals[spot.set] or 0) + 1

		hitbox.Touched:Connect(function(other)
			local character = other.Parent
			local player = character and Players:GetPlayerFromCharacter(character)
			if player then
				World.collect(player, spot.id)
			end
		end)
	end
	if #skipped > 0 then
		warn("[CityGrind] World: skipped collectible spots (blocked or no floor): " .. table.concat(skipped, ", "))
	end
	print(string.format("[CityGrind] World: %d collectibles placed", #itemList))
end

-- Collected ids that still exist on this map.
local function validCollected(w: any): number
	local n = 0
	for id in w.c do
		if items[id] then
			n += 1
		end
	end
	return n
end

local function setGot(w: any, set: string): number
	local n = 0
	for id in w.c do
		local item = items[id]
		if item and item.set == set then
			n += 1
		end
	end
	return n
end

local function stateFor(player: Player): any
	local w = sec(player)
	if not w then
		return nil
	end
	local list = {}
	for _, item in itemList do
		table.insert(list, { id = item.id, set = item.set, district = item.district })
	end
	local collected = {}
	for id in w.c do
		if items[id] then
			table.insert(collected, id)
		end
	end
	local found = {}
	for id, t in w.secrets do
		table.insert(found, { id = id, name = secretNames[id] or id, t = t })
	end
	return {
		items = list,
		collected = collected,
		sets = w.sets,
		secrets = found,
		secretTotal = math.max(#WC.SECRET_IDS, count(secretNames)),
	}
end

local function pushState(player: Player)
	local state = stateFor(player)
	if state and player.Parent then
		WorldEvent:FireClient(player, "State", state)
	end
end

local function grant(player: Player, r: { cash: number?, xp: number?, rep: number?, fame: number? }, label: string)
	if r.cash and r.cash > 0 then
		PlayerData.addCash(player, r.cash, label)
	end
	if r.xp and r.xp > 0 then
		PlayerData.addXP(player, r.xp)
	end
	if r.rep and r.rep > 0 then
		PlayerData.addReputation(player, r.rep)
	end
	if r.fame and r.fame > 0 then
		PlayerData.addFame(player, r.fame)
	end
end

function World.collect(player: Player, id: string)
	local item = items[id]
	if not item or not Net.alive(player) then
		return
	end
	local w = sec(player)
	if not w or w.c[id] then
		return
	end
	if Net.distance(player, item.center) > WC.COLLECT_RANGE or not AntiCheat.positionOk(player) then
		return -- [Security] out of reach, or got there faster than anyone can run
	end
	if not Net.allow(player, "WorldCollect:" .. id, 1) then
		return
	end
	w.c[id] = true
	local set = WC.SET_BY_ID[item.set] :: WC.CollectibleSet
	PlayerData.markChanged(player)
	grant(player, WC.ITEM_REWARD, "Collectible: " .. set.name)
	WorldEvent:FireClient(player, "Collected", id)

	local got, total = setGot(w, item.set), setTotals[item.set] or 0
	Net.notify(player, "COLLECTIBLE FOUND", string.format("%s %s · %d/%d", set.icon, set.name, got, total))
	unlock(player, "collect_first")

	if got >= total and total > 0 and not w.sets[item.set] then
		w.sets[item.set] = true
		PlayerData.markChanged(player)
		grant(player, WC.SET_REWARD, "Set complete: " .. set.name)
		Net.notify(player, "SET COMPLETE", string.format("%s You found every %s! +$%d", set.icon, set.name, WC.SET_REWARD.cash))
		unlock(player, "collect_set")
		pushState(player) -- the app shows the set as complete
	end
	if not w.all then
		local everything = true
		for _, s in WC.SETS do
			if (setTotals[s.id] or 0) > 0 and not w.sets[s.id] then
				everything = false
			end
		end
		if everything then
			w.all = true
			PlayerData.markChanged(player)
			grant(player, WC.ALL_SETS_REWARD, "Every collectible found")
			Net.notify(player, "MASTER COLLECTOR", "You found every collectible in the city!")
			unlock(player, "collect_all")
		end
	end
end

function World.collectedCount(player: Player): number
	local w = sec(player)
	return if w then validCollected(w) else 0
end

---------------------------------------------------------------------------
-- Secrets (82)
---------------------------------------------------------------------------
local secretParts: { BasePart } = {}

local function refreshSecrets()
	table.clear(secretParts)
	for _, inst in CollectionService:GetTagged("SecretArea") do
		if inst:IsA("BasePart") and inst:IsDescendantOf(Workspace) then
			local id = inst:GetAttribute("SecretId")
			if type(id) == "string" and id ~= "" then
				table.insert(secretParts, inst)
				local name = inst:GetAttribute("DisplayName")
				secretNames[id] = if type(name) == "string" and name ~= "" then name else id
			end
		end
	end
end

local function discover(player: Player, id: string)
	local w = sec(player)
	if not w or w.secrets[id] then
		return
	end
	w.secrets[id] = os.time()
	PlayerData.markChanged(player)
	local name = secretNames[id] or id
	grant(player, WC.SECRET_REWARD, "Secret found: " .. name)
	local found = count(w.secrets)
	local total = math.max(#WC.SECRET_IDS, count(secretNames))
	Net.notify(player, "SECRET FOUND", string.format("%s · %d/%d secrets", name, found, total))
	WorldEvent:FireClient(player, "Secret", id, name)
	unlock(player, "secret_first")
	if found >= total then
		unlock(player, "secret_all")
	end
end

local function checkSecrets()
	for _, player in Players:GetPlayers() do
		local r = rootPart(player)
		local w = r and sec(player)
		if r and w and Net.alive(player) and AntiCheat.positionOk(player) then
			local pos = r.Position
			for _, part in secretParts do
				local id = part:GetAttribute("SecretId") :: string
				if not w.secrets[id] and part.Parent then
					local rel = part.CFrame:PointToObjectSpace(pos)
					local half = part.Size / 2
					if math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y and math.abs(rel.Z) <= half.Z then
						discover(player, id)
					end
				end
			end
		end
	end
end

function World.secretsFound(player: Player): number
	local w = sec(player)
	return if w then count(w.secrets) else 0
end

---------------------------------------------------------------------------
-- Weather (66)
---------------------------------------------------------------------------
local weatherId = "Clear"

function World.weather(): string
	return weatherId
end

local function setWeather(w: WC.Weather)
	weatherId = w.id
	local minutes = w.minMinutes + math.random() * (w.maxMinutes - w.minMinutes)
	Workspace:SetAttribute("Weather", w.id)
	Workspace:SetAttribute("WeatherEnds", Workspace:GetServerTimeNow() + minutes * 60)
	Workspace:SetAttribute("WeatherGrip", w.grip)
	return minutes * 60
end

local function nextWeather(): WC.Weather
	local t = Lighting.ClockTime
	local daytime = t >= 8 and t < 16
	local pool = {}
	local total = 0
	for _, w in WC.WEATHER do
		if w.id ~= weatherId and (daytime or not w.dayOnly) then
			-- storms only roll in after rain or clouds so the sky builds up
			local weight = w.weight
			if w.id == "Storm" and weatherId ~= "Rain" and weatherId ~= "Cloudy" then
				weight = 0
			end
			if weight > 0 then
				table.insert(pool, { w = w, weight = weight })
				total += weight
			end
		end
	end
	local roll = math.random() * total
	for _, entry in pool do
		roll -= entry.weight
		if roll <= 0 then
			return entry.w
		end
	end
	return WC.WEATHER_BY_ID.Clear
end

local function runWeather()
	local endsAt = os.clock() + setWeather(WC.WEATHER_BY_ID.Clear)
	while true do
		task.wait(5)
		local t = Lighting.ClockTime
		-- a heatwave breaks when evening comes
		local heatOver = weatherId == "Heatwave" and (t < 8 or t >= 17)
		if os.clock() >= endsAt or heatOver then
			endsAt = os.clock() + setWeather(nextWeather())
		end
	end
end

---------------------------------------------------------------------------
-- NPC pedestrians (65) and recognition (89)
---------------------------------------------------------------------------
type Node = { pos: Vector3, district: string, links: { number } }
local nodes: { Node } = {}
local nodesByDistrict: { [string]: { number } } = {}

local WALK_NAMES = { Sidewalk = true, Boardwalk = true, Path = true, PierDeck = true }
local NODE_SPACING = 24
local LINK_RANGE = 34

type Box = { center: Vector3, half: Vector3 }

local function courtBoxes(): { Box }
	local boxes = {}
	for _, court in CollectionService:GetTagged("Court") do
		local c = court:GetAttribute("CourtCenter")
		local s = court:GetAttribute("CourtSize")
		if typeof(c) == "Vector3" and typeof(s) == "Vector3" then
			table.insert(boxes, { center = c, half = V(s.X / 2 + 8, 0, s.Z / 2 + 8) })
		elseif court:IsA("Model") then
			local cf, size = court:GetBoundingBox()
			table.insert(boxes, { center = cf.Position, half = V(size.X / 2 + 8, 0, size.Z / 2 + 8) })
		end
	end
	return boxes
end

local function inBoxes(p: Vector3, boxes: { Box }): boolean
	for _, b in boxes do
		if math.abs(p.X - b.center.X) <= b.half.X and math.abs(p.Z - b.center.Z) <= b.half.Z and math.abs(p.Y - b.center.Y) < 30 then
			return true
		end
	end
	return false
end

local function buildGraph(city: Instance)
	local boxes = courtBoxes()
	local doors: { Vector3 } = {}
	local walks: { BasePart } = {}
	for _, d in city:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Name == "Door" then
				table.insert(doors, d.Position)
			elseif WALK_NAMES[d.Name] and d.Size.Y <= 1.5 and math.abs(d.CFrame.UpVector.Y) > 0.99 and d.Position.Y < 300 then
				table.insert(walks, d)
			end
		end
	end
	local function nearDoor(p: Vector3): boolean
		for _, door in doors do
			if math.abs(door.X - p.X) < 9 and math.abs(door.Z - p.Z) < 9 and math.abs(door.Y - p.Y) < 12 then
				return true
			end
		end
		return false
	end

	for _, walk in walks do
		local cf = walk.CFrame
		local alongX = walk.Size.X >= walk.Size.Z
		local len = if alongX then walk.Size.X else walk.Size.Z
		local axis = if alongX then cf.RightVector else cf.LookVector
		local n = math.max(1, math.floor(len / NODE_SPACING))
		local top = cf.Position + cf.UpVector * (walk.Size.Y / 2)
		for i = 1, n do
			local p = top + axis * (-len / 2 + (i - 0.5) * len / n)
			if inBoxes(p, boxes) or nearDoor(p) then
				continue
			end
			-- the walkway itself must be what you stand on here, with room above it
			local hit = Workspace:Raycast(p + V(0, 4, 0), V(0, -6, 0), rayParams)
			if not hit or hit.Instance ~= walk then
				continue
			end
			if not clear(p + V(0, 2.8, 0), V(2.2, 4.4, 2.2)) then
				continue
			end
			local district = DC.at(p)
			if district ~= "Outskirts" then
				table.insert(nodes, { pos = V(p.X, hit.Position.Y, p.Z), district = district, links = {} })
			end
		end
	end

	-- link neighbours that can see each other at waist height and don't cross a court
	for i = 1, #nodes do
		local a = nodes[i]
		for j = i + 1, #nodes do
			local b = nodes[j]
			local delta = b.pos - a.pos
			if math.abs(delta.Y) < 2 and math.abs(delta.X) <= LINK_RANGE and math.abs(delta.Z) <= LINK_RANGE and delta.Magnitude <= LINK_RANGE then
				local blocked = inBoxes((a.pos + b.pos) / 2, boxes)
				if not blocked then
					blocked = Workspace:Raycast(a.pos + V(0, 2.5, 0), delta, rayParams) ~= nil
				end
				if not blocked then
					table.insert(a.links, j)
					table.insert(b.links, i)
				end
			end
		end
	end
	for i, node in nodes do
		if #node.links > 0 then
			nodesByDistrict[node.district] = nodesByDistrict[node.district] or {}
			table.insert(nodesByDistrict[node.district], i)
		end
	end
	local summary = {}
	for id, list in nodesByDistrict do
		table.insert(summary, id .. "=" .. #list)
	end
	print("[CityGrind] World: sidewalk graph " .. table.concat(summary, " "))
end

type NPC = {
	model: Model,
	hum: Humanoid,
	root: BasePart,
	schedule: { string },
	district: string,
	node: number,
	prev: number?,
	target: number?,
	asleep: boolean,
	pauseUntil: number,
	movedAt: number,
	lastPos: Vector3,
	lastProgress: number,
	busyUntil: number,
	cooldownUntil: number,
	seen: { [Player]: number },
	shoulder: Motor6D?,
	shoulderC0: CFrame?,
	standHeight: number,
}
local npcs: { NPC } = {}
local playerReactedAt: { [Player]: number } = {}

local SKIN = { Color3.fromRGB(255, 220, 190), Color3.fromRGB(234, 184, 146), Color3.fromRGB(196, 140, 100), Color3.fromRGB(150, 100, 70), Color3.fromRGB(105, 70, 50), Color3.fromRGB(70, 48, 36) }
local SHIRT = { Color3.fromRGB(200, 60, 60), Color3.fromRGB(60, 110, 200), Color3.fromRGB(240, 240, 240), Color3.fromRGB(40, 40, 46), Color3.fromRGB(240, 190, 50), Color3.fromRGB(80, 160, 90), Color3.fromRGB(150, 80, 170), Color3.fromRGB(230, 120, 60) }
local PANTS = { Color3.fromRGB(40, 50, 80), Color3.fromRGB(30, 30, 34), Color3.fromRGB(110, 100, 85), Color3.fromRGB(70, 80, 95), Color3.fromRGB(150, 140, 120) }

-- Simple block rig (fallback when Roblox can't build an R15 body here).
local function blockRig(): Model
	local model = Instance.new("Model")
	local function bp(name: string, size: Vector3, cf: CFrame): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.CanCollide = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end
	local hrp = bp("HumanoidRootPart", V(2, 2, 1), CFrame.new(0, 3, 0))
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.Massless = false
	local torso = bp("UpperTorso", V(2, 2, 1), CFrame.new(0, 3, 0))
	local head = bp("Head", V(1.2, 1.2, 1.2), CFrame.new(0, 4.6, 0))
	local function motor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame)
		local m = Instance.new("Motor6D")
		m.Name = name
		m.Part0 = part0
		m.Part1 = part1
		m.C0 = c0
		m.C1 = c1
		m.Parent = part1
	end
	motor("Root", hrp, torso, CFrame.new(), CFrame.new())
	motor("Neck", torso, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.6, 0))
	for _, side in { -1, 1 } do
		local prefix = if side > 0 then "Right" else "Left"
		local arm = bp(prefix .. "UpperArm", V(0.9, 2, 0.9), CFrame.new(side * 1.45, 3, 0))
		motor(prefix .. "Shoulder", torso, arm, CFrame.new(side * 1.45, 0.8, 0), CFrame.new(0, 0.8, 0))
		local leg = bp(prefix .. "UpperLeg", V(0.95, 2, 0.95), CFrame.new(side * 0.5, 1, 0))
		motor(prefix .. "Hip", torso, leg, CFrame.new(side * 0.5, -1, 0), CFrame.new(0, 1, 0))
	end
	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.HipHeight = 2
	hum.Parent = model
	model.PrimaryPart = hrp
	return model
end

local function makeTemplate(): Model
	local ok, rig = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if ok and typeof(rig) == "Instance" and rig:IsA("Model") and rig:FindFirstChild("HumanoidRootPart") and rig:FindFirstChildOfClass("Humanoid") then
		local animate = rig:FindFirstChild("Animate")
		if animate then
			animate:Destroy()
		end
		return rig
	end
	return blockRig()
end

local function paint(model: Model, rng: Random)
	local skin = SKIN[rng:NextInteger(1, #SKIN)]
	local shirt = SHIRT[rng:NextInteger(1, #SHIRT)]
	local pants = PANTS[rng:NextInteger(1, #PANTS)]
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
			local n = p.Name
			if n == "Head" or n:find("Hand") then
				p.Color = skin
			elseif n:find("Torso") or n:find("Arm") then
				p.Color = shirt
			elseif n:find("Foot") then
				p.Color = Color3.fromRGB(30, 30, 30)
			elseif n:find("Leg") then
				p.Color = pants
			end
		elseif p:IsA("BodyColors") then
			p:Destroy()
		end
	end
end

local function randomNode(district: string, rng: Random, awayFromPlayers: boolean): number?
	local list = nodesByDistrict[district]
	if not list or #list == 0 then
		return nil
	end
	for _ = 1, 8 do
		local idx = list[rng:NextInteger(1, #list)]
		if not awayFromPlayers then
			return idx
		end
		local ok = true
		for _, player in Players:GetPlayers() do
			local r = rootPart(player)
			if r and (r.Position - nodes[idx].pos).Magnitude < WC.NPC_WAKE_RANGE then
				ok = false
				break
			end
		end
		if ok then
			return idx
		end
	end
	return nil
end

local function place(npc: NPC, idx: number)
	npc.node = idx
	npc.prev = nil
	npc.target = nil
	npc.district = nodes[idx].district
	local p = nodes[idx].pos + V(0, npc.standHeight, 0)
	npc.model:PivotTo(CFrame.new(p) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
	npc.lastPos = p
end

local function sleep(npc: NPC)
	npc.asleep = true
	npc.target = nil
	npc.hum:MoveTo(npc.root.Position)
	npc.root.Anchored = true
end

local function wake(npc: NPC)
	npc.asleep = false
	npc.root.Anchored = false
	pcall(function()
		npc.root:SetNetworkOwner(nil)
	end)
	npc.lastProgress = os.clock()
	npc.lastPos = npc.root.Position
end

local function spawnNPCs(rng: Random)
	local folder = Instance.new("Folder")
	folder.Name = "NPCs"
	folder.Parent = root
	local template = makeTemplate()
	local kinds = {}
	for kind, n in WC.SCHEDULE_MIX do
		for _ = 1, n do
			table.insert(kinds, kind)
		end
	end
	table.sort(kinds) -- deterministic order, then a seeded shuffle
	for i = #kinds, 2, -1 do
		local j = rng:NextInteger(1, i)
		kinds[i], kinds[j] = kinds[j], kinds[i]
	end
	local slot = WC.timeSlot(Lighting.ClockTime)
	for i = 1, math.min(WC.NPC_COUNT, #kinds) do
		local kind = kinds[i]
		local schedule = WC.SCHEDULES[kind]
		local idx = randomNode(schedule[slot], rng, false) or randomNode("Neighborhood", rng, false)
		if not idx then
			break
		end
		local model = template:Clone()
		model.Name = "Pedestrian"
		local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
		local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		hum.BreakJointsOnDeath = false
		hum.WalkSpeed = rng:NextNumber(6.5, 9)
		hum.UseJumpPower = true
		hum.JumpPower = 30
		-- never sit down on benches / seats along the sidewalk (would strand the NPC)
		hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
		paint(model, rng)
		local shoulder = model:FindFirstChild("RightShoulder", true)
		local npc: NPC = {
			model = model,
			hum = hum,
			root = hrp,
			schedule = schedule,
			district = nodes[idx].district,
			node = idx,
			asleep = true,
			pauseUntil = 0,
			movedAt = 0,
			lastPos = Vector3.zero,
			lastProgress = 0,
			busyUntil = 0,
			cooldownUntil = 0,
			seen = {},
			shoulder = if shoulder and shoulder:IsA("Motor6D") then shoulder else nil,
			shoulderC0 = if shoulder and shoulder:IsA("Motor6D") then shoulder.C0 else nil,
			standHeight = hum.HipHeight + hrp.Size.Y / 2 + 0.1,
		}
		hrp.Anchored = true
		model:SetAttribute("Schedule", kind)
		model.Parent = folder
		CollectionService:AddTag(model, "CityNPC")
		place(npc, idx)
		table.insert(npcs, npc)
		if i % 6 == 0 then
			task.wait() -- spread the cloning out over a few frames
		end
	end
	template:Destroy()
	print(string.format("[CityGrind] World: %d pedestrians", #npcs))
end

local function bubble(npc: NPC, text: string)
	local head = npc.model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "NPCBubble"
	gui.Size = UDim2.fromOffset(230, 46)
	gui.StudsOffset = V(0, 2.6, 0)
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(250, 250, 252)
	label.TextColor3 = Color3.fromRGB(20, 20, 26)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = text
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = label
	gui.Parent = head
	task.delay(4, function()
		gui:Destroy()
	end)
end

local function wave(npc: NPC)
	local motor, base = npc.shoulder, npc.shoulderC0
	if not motor or not base then
		return
	end
	npc.model:SetAttribute("Waving", true)
	local info = TweenInfo.new(0.22, Enum.EasingStyle.Sine)
	task.spawn(function()
		local up = base * CFrame.Angles(0, 0, math.rad(150))
		TweenService:Create(motor, info, { C0 = up }):Play()
		task.wait(0.25)
		for _ = 1, 3 do
			TweenService:Create(motor, info, { C0 = base * CFrame.Angles(0, 0, math.rad(125)) }):Play()
			task.wait(0.24)
			TweenService:Create(motor, info, { C0 = up }):Play()
			task.wait(0.24)
		end
		TweenService:Create(motor, TweenInfo.new(0.3, Enum.EasingStyle.Sine), { C0 = base }):Play()
		task.wait(0.32)
		if npc.model.Parent then
			npc.model:SetAttribute("Waving", false)
		end
	end)
end

local function react(npc: NPC, player: Player, tier: number, ppos: Vector3, now: number)
	npc.busyUntil = now + 3.4
	npc.cooldownUntil = now + WC.NPC_COOLDOWN
	npc.seen[player] = now
	playerReactedAt[player] = now
	npc.target = nil
	npc.hum:MoveTo(npc.root.Position)
	local pos = npc.root.Position
	local look = V(ppos.X, pos.Y, ppos.Z)
	if (look - pos).Magnitude > 0.5 then
		npc.root.CFrame = CFrame.lookAt(pos, look)
	end
	local lines = WC.RECOGNIZE_LINES[tier]
	local line = lines[math.random(1, #lines)]
	bubble(npc, string.format(line, player.DisplayName))
	wave(npc)
end

local function pickNext(npc: NPC, now: number)
	local links = nodes[npc.node].links
	if #links == 0 then
		return
	end
	local choices = {}
	for _, j in links do
		if j ~= npc.prev then
			table.insert(choices, j)
		end
	end
	if #choices == 0 then
		choices = links
	end
	npc.target = choices[math.random(1, #choices)]
	npc.hum:MoveTo(nodes[npc.target :: number].pos)
	npc.movedAt = now
	npc.lastProgress = now
	npc.lastPos = npc.root.Position
end

local function stepNPC(npc: NPC, now: number, positions: { { player: Player, pos: Vector3 } }, slot: number)
	if not npc.model.Parent or not npc.root.Parent then
		return
	end
	local pos = npc.root.Position
	local nearest = math.huge
	for _, entry in positions do
		local d = (entry.pos - pos).Magnitude
		if d < nearest then
			nearest = d
		end
	end

	if nearest > WC.NPC_WAKE_RANGE then
		if not npc.asleep then
			sleep(npc)
		end
		-- follow the daily schedule while nobody is watching
		local want = npc.schedule[slot]
		if npc.district ~= want and nodesByDistrict[want] then
			local idx = randomNode(want, Random.new(), true)
			if idx then
				place(npc, idx)
			end
		end
		return
	end
	if npc.asleep then
		wake(npc)
	end
	if pos.Y < -60 then
		place(npc, npc.node) -- fell through something: put back on the sidewalk
		return
	end
	if now < npc.busyUntil then
		return
	end

	-- recognition (89)
	if now >= npc.cooldownUntil then
		for _, entry in positions do
			local player = entry.player
			local offset = entry.pos - pos
			if offset.Magnitude <= WC.RECOGNIZE_RANGE and math.abs(offset.Y) < 8 then
				local rep = player:GetAttribute("Reputation")
				local fame = player:GetAttribute("Fame")
				local tier = WC.recognitionTier(if type(rep) == "number" then rep else 0, if type(fame) == "number" then fame else 0)
				local lastPlayer = playerReactedAt[player] or -math.huge
				local lastPair = npc.seen[player] or -math.huge
				if tier > 0 and now - lastPlayer >= WC.PLAYER_COOLDOWN and now - lastPair >= WC.PAIR_COOLDOWN and (player:GetAttribute("Interior") or "") == "" then
					-- one roll per pass: a failed roll still counts as "seen" for a while
					npc.seen[player] = now - WC.PAIR_COOLDOWN + 20
					if math.random() < WC.RECOGNIZE_CHANCE[tier] then
						react(npc, player, tier, entry.pos, now)
						return
					end
				end
			end
		end
	end

	-- walking
	local target = npc.target
	if target then
		local tpos = nodes[target].pos
		local flat = V(tpos.X - pos.X, 0, tpos.Z - pos.Z).Magnitude
		if flat < 3 then
			npc.prev = npc.node
			npc.node = target
			npc.target = nil
			if math.random() < 0.2 then
				npc.pauseUntil = now + 2 + math.random() * 4
			end
			return
		end
		if (pos - npc.lastPos).Magnitude > 1 then
			npc.lastPos = pos
			npc.lastProgress = now
		else
			local stuck = now - npc.lastProgress
			if stuck > 10 and nearest > 60 then
				place(npc, target)
				return
			elseif stuck > 5 then
				-- give up on this leg and head back the other way
				npc.target = nil
				npc.prev = target
				return
			elseif stuck > 2 then
				npc.hum.Jump = true
			end
		end
		if now - npc.movedAt > 6 then
			npc.hum:MoveTo(tpos) -- MoveTo gives up after 8 seconds
			npc.movedAt = now
		end
	elseif now >= npc.pauseUntil then
		pickNext(npc, now)
	end
end

local function runNPCs()
	while true do
		local now = os.clock()
		local positions = {}
		for _, player in Players:GetPlayers() do
			local r = rootPart(player)
			if r then
				table.insert(positions, { player = player, pos = r.Position })
			end
		end
		local slot = WC.timeSlot(Lighting.ClockTime)
		for _, npc in npcs do
			local ok, err = pcall(stepNPC, npc, now, positions, slot)
			if not ok then
				warn("[CityGrind] World NPC step failed:", err)
			end
		end
		task.wait(WC.NPC_TICK)
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function World.start(city: Instance)
	root = Instance.new("Folder")
	root.Name = "World"
	root.Parent = city

	probe = Instance.new("Part")
	probe.Name = "Probe"
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.Transparency = 1
	probe.Parent = root

	WorldEvent = Net.remote("RemoteEvent", "WorldEvent")
	local WorldRequest = Net.remote("RemoteFunction", "WorldRequest")
	local WorldCollect = Net.remote("RemoteEvent", "WorldCollect")

	setFilters({})
	refreshSecrets()
	CollectionService:GetInstanceAddedSignal("SecretArea"):Connect(refreshSecrets)
	CollectionService:GetInstanceRemovedSignal("SecretArea"):Connect(refreshSecrets)

	local ok, err = pcall(buildCollectibles)
	if not ok then
		warn("[CityGrind] World collectibles failed:", err)
	end

	WorldRequest.OnServerInvoke = function(player: Player, action: any)
		if action == "Get" and Net.allow(player, "WorldGet", 0.5) then
			return stateFor(player)
		end
		return nil
	end
	WorldCollect.OnServerEvent:Connect(function(player: Player, id: any)
		if type(id) == "string" and #id <= 16 then
			World.collect(player, id)
		end
	end)

	PlayerData.onPublish(function(player: Player, data: any)
		local w = data.sections and data.sections[SECTION]
		if w then
			player:SetAttribute("Collectibles", validCollected(w))
			player:SetAttribute("SecretsFound", count(w.secrets))
		end
	end)
	PlayerData.onLoaded(function(player: Player)
		pushState(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		playerReactedAt[player] = nil
		for _, npc in npcs do
			npc.seen[player] = nil
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			local okSecrets, errSecrets = pcall(checkSecrets)
			if not okSecrets then
				warn("[CityGrind] World secrets check failed:", errSecrets)
			end
		end
	end)

	task.spawn(runWeather)

	-- the sidewalk graph and pedestrians build after everything else has started
	task.spawn(function()
		task.wait(1)
		setFilters({})
		local okGraph, errGraph = pcall(buildGraph, city)
		if not okGraph then
			warn("[CityGrind] World sidewalk graph failed:", errGraph)
			return
		end
		local okSpawn, errSpawn = pcall(spawnNPCs, Random.new(2024))
		if not okSpawn then
			warn("[CityGrind] World pedestrians failed:", errSpawn)
		end
		runNPCs()
	end)
end

return World
