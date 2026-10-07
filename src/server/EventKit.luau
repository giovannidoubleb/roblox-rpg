-- CITY GRIND: shared helpers for the city event kinds (EventDunk, EventHunt,
-- EventPhoto, EventFashion, EventStreetball).
--   * open-ground finder: raycast for the ground, then check a box above it is
--     empty (no buildings, trees, benches...) so pop-up venues never clip into
--     district buildings
--   * landmark hints from the phone-map points (City.MapPoints)
--   * vote boxes: real players only, one vote each, never for yourself

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DistrictsConfig = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("DistrictsConfig"))

local EventKit = {}

---------------------------------------------------------------------------
-- Ground / open space
---------------------------------------------------------------------------
local function ignoreList(extra: { Instance }?): { Instance }
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	local balls = Workspace:FindFirstChild("Basketballs")
	if balls then
		table.insert(list, balls)
	end
	if extra then
		for _, e in extra do
			table.insert(list, e)
		end
	end
	return list
end

local function isWater(result: RaycastResult): boolean
	if result.Material == Enum.Material.Water then
		return true
	end
	local name = result.Instance.Name:lower()
	return name:find("water") ~= nil or name:find("ocean") ~= nil or name:find("sea") ~= nil
end

-- Top of the walkable ground under (x, z), or nil (no ground / water / a roof).
function EventKit.groundAt(pos: Vector3, extra: { Instance }?): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList(extra)
	params.IgnoreWater = false
	local from = Vector3.new(pos.X, 250, pos.Z)
	local result = Workspace:Raycast(from, Vector3.new(0, -400, 0), params)
	if not result or isWater(result) or result.Normal.Y < 0.85 then
		return nil
	end
	-- ground in this city is around y = 0 (Luxury Hills sits on a plateau at
	-- about y = 14); a hit well above that is a roof
	local y = result.Position.Y
	local onHill = y > 12.5 and y < 15.8 and DistrictsConfig.at(result.Position) == "Luxury"
	if not onHill and (y > 3 or y < -6) then
		return nil
	end
	return result.Position
end

-- True when nothing solid-ish sits in a box of `size` standing on `ground`.
function EventKit.isClear(ground: Vector3, size: Vector3, extra: { Instance }?): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList(extra)
	-- start 0.8 above the ground so roads, sidewalks and the ground itself don't count
	local cf = CFrame.new(ground + Vector3.new(0, 0.8 + size.Y / 2, 0))
	local hits = Workspace:GetPartBoundsInBox(cf, size, params)
	for _, hit in hits do
		if hit.Transparency < 1 or hit.CanCollide then
			return false
		end
	end
	return true
end

-- Ground under the corners of a footprint is roughly level (no slopes / steps).
function EventKit.isLevel(ground: Vector3, size: Vector3, extra: { Instance }?): boolean
	for _, c in { Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, -1) } do
		local g = EventKit.groundAt(ground + Vector3.new(c.X * size.X / 2, 0, c.Z * size.Z / 2), extra)
		if not g or math.abs(g.Y - ground.Y) > 1.2 then
			return false
		end
	end
	return true
end

-- First candidate centre with open, level ground for a footprint of `size`.
-- Also tries a few nudged positions around each candidate.
function EventKit.openSpot(candidates: { Vector3 }, size: Vector3, extra: { Instance }?): Vector3?
	local nudges = { Vector3.zero, Vector3.new(30, 0, 0), Vector3.new(-30, 0, 0), Vector3.new(0, 0, 30), Vector3.new(0, 0, -30), Vector3.new(45, 0, 45), Vector3.new(-45, 0, -45) }
	for _, c in candidates do
		for _, n in nudges do
			local g = EventKit.groundAt(c + n, extra)
			if g and EventKit.isClear(g, size, extra) and EventKit.isLevel(g, size, extra) then
				return g
			end
		end
	end
	return nil
end

-- A random open spot inside an XZ rectangle (centre, size), `tries` attempts.
function EventKit.randomSpot(rng: Random, center: Vector3, size: Vector3, footprint: Vector3, tries: number, avoid: { Vector3 }, minSpacing: number, extra: { Instance }?): Vector3?
	local inset = 25
	for _ = 1, tries do
		local x = center.X + rng:NextNumber(-1, 1) * math.max(0, size.X / 2 - inset)
		local z = center.Z + rng:NextNumber(-1, 1) * math.max(0, size.Z / 2 - inset)
		local g = EventKit.groundAt(Vector3.new(x, 0, z), extra)
		if g and EventKit.isClear(g, footprint, extra) then
			local ok = true
			for _, a in avoid do
				if (Vector3.new(a.X, 0, a.Z) - Vector3.new(g.X, 0, g.Z)).Magnitude < minSpacing then
					ok = false
					break
				end
			end
			if ok then
				return g
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Landmarks
---------------------------------------------------------------------------
local COMPASS = { "east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east" }

-- Compass word for a flat direction (+x east, +z south, like the phone map).
function EventKit.compass(v: Vector3): string
	local angle = math.atan2(v.Z, v.X) -- 0 = east, +pi/2 = south
	local index = math.floor((angle / (math.pi * 2)) * 8 + 0.5) % 8 + 1
	return COMPASS[index]
end

-- Nearest phone-map point (name, flat offset from it to pos) within `range`.
function EventKit.landmark(pos: Vector3, range: number?): (string?, Vector3?)
	local city = Workspace:FindFirstChild("City")
	local points = city and city:FindFirstChild("MapPoints")
	local best, bestDist, bestPos = nil, range or 400, nil
	if points then
		for _, p in points:GetChildren() do
			if p:IsA("BasePart") then
				local d = (Vector3.new(p.Position.X, 0, p.Position.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
				if d < bestDist then
					best, bestDist, bestPos = p.Name, d, p.Position
				end
			end
		end
	end
	if best and bestPos then
		return best, Vector3.new(pos.X - bestPos.X, 0, pos.Z - bestPos.Z)
	end
	return nil, nil
end

---------------------------------------------------------------------------
-- Votes: one per real player, never for yourself, candidates only.
---------------------------------------------------------------------------
export type VoteBox = { votes: { [number]: number }, castAt: { [number]: number } }

function EventKit.newVotes(): VoteBox
	return { votes = {}, castAt = {} }
end

function EventKit.castVote(box: VoteBox, voter: Player, target: any, isCandidate: (number) -> boolean): (boolean, string)
	if type(target) ~= "number" or target % 1 ~= 0 then
		return false, "Bad vote."
	end
	if box.votes[voter.UserId] then
		return false, "You already voted. One vote per player."
	end
	if target == voter.UserId then
		return false, "You can't vote for yourself."
	end
	if not isCandidate(target) then
		return false, "That entry isn't in the running."
	end
	box.votes[voter.UserId] = target
	box.castAt[voter.UserId] = os.clock()
	return true, "Vote locked in."
end

-- Votes per candidate userId (self-votes can't exist; voters must be real players).
function EventKit.tally(box: VoteBox): { [number]: number }
	local tally: { [number]: number } = {}
	for voterId, target in box.votes do
		if voterId ~= target then
			tally[target] = (tally[target] or 0) + 1
		end
	end
	return tally
end

function EventKit.voteCount(box: VoteBox): number
	local n = 0
	for _ in box.votes do
		n += 1
	end
	return n
end

return EventKit
