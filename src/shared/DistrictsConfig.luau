-- CITY GRIND: district layout and subway stations (spec sections 4-11).
-- Shared so the server (Districts.luau), the phone map and the subway UI agree.
--
-- Top-down layout (+x east, +z south). Every district is an axis-aligned
-- rectangle on the XZ plane; they touch but never overlap.
--
--                 x -760   -300        300           900
--      z -730     +--------+-----------+-------------+
--                 | Luxury | Downtown  |             |
--                 | Hills  |           | Industrial  |
--      z -230     +--------+-----------+  (race      |
--                 | Old    | The       |   track N)  |
--                 | Town   | Neighbor- |             |
--      z  230     +--------+-----------+-------------+
--                 |              Beach               |
--      z 1000     +----------------------------------+   (ocean from z 520)

local DistrictsConfig = {}

export type District = {
	id: string,
	name: string, -- display name (phone subtitle, map labels)
	center: Vector3, -- footprint centre at ground level
	size: Vector3, -- footprint size (Y unused)
	color: Color3, -- label colour on the phone map
}

DistrictsConfig.LIST = {
	{ id = "Neighborhood", name = "The Neighborhood", center = Vector3.new(0, 0, 0), size = Vector3.new(600, 0, 460), color = Color3.fromRGB(140, 220, 120) },
	{ id = "Downtown", name = "Downtown", center = Vector3.new(0, 0, -480), size = Vector3.new(600, 0, 500), color = Color3.fromRGB(120, 190, 255) },
	{ id = "Industrial", name = "Industrial", center = Vector3.new(600, 0, -250), size = Vector3.new(600, 0, 960), color = Color3.fromRGB(255, 170, 70) },
	{ id = "Beach", name = "The Beach", center = Vector3.new(70, 0, 615), size = Vector3.new(1660, 0, 770), color = Color3.fromRGB(255, 225, 120) },
	{ id = "Luxury", name = "Luxury Hills", center = Vector3.new(-530, 0, -480), size = Vector3.new(460, 0, 500), color = Color3.fromRGB(230, 190, 255) },
	{ id = "OldTown", name = "Old Town", center = Vector3.new(-530, 0, 0), size = Vector3.new(460, 0, 460), color = Color3.fromRGB(230, 140, 110) },
} :: { District }

-- The whole playable world (used by the phone map and vehicle bounds).
DistrictsConfig.WORLD_MIN = Vector3.new(-760, 0, -730)
DistrictsConfig.WORLD_MAX = Vector3.new(900, 0, 1000)
-- What the phone map shows (the far ocean is left off).
DistrictsConfig.MAP_MIN = Vector3.new(-760, 0, -730)
DistrictsConfig.MAP_MAX = Vector3.new(900, 0, 700)

local byId: { [string]: District } = {}
for _, d in DistrictsConfig.LIST do
	byId[d.id] = d
end

function DistrictsConfig.get(id: string): District?
	return byId[id]
end

-- District id at a world position ("Outskirts" when outside every district).
function DistrictsConfig.at(position: Vector3): string
	for _, d in DistrictsConfig.LIST do
		local half = d.size / 2
		if math.abs(position.X - d.center.X) <= half.X and math.abs(position.Z - d.center.Z) <= half.Z then
			return d.id
		end
	end
	return "Outskirts"
end

-- Display name for a district id (falls back to the id itself).
function DistrictsConfig.displayName(id: string?): string
	local d = id and byId[id]
	return if d then d.name elseif id == "Outskirts" then "Outskirts" else "The Neighborhood"
end

---------------------------------------------------------------------------
-- Subway (section 11)
---------------------------------------------------------------------------
export type Station = {
	id: string, -- same as the district id
	name: string,
	entrance: Vector3, -- centre of the street entrance (ground level)
	exit: CFrame, -- where riders come up, facing the street
	line: Color3,
}

DistrictsConfig.SUBWAY_FARE = 2
DistrictsConfig.SUBWAY_COOLDOWN = 6 -- seconds between rides
DistrictsConfig.SUBWAY_RIDE_TIME = 2.6 -- seconds of fade-to-black travel
DistrictsConfig.SUBWAY_RANGE = 14 -- how close to an entrance you must be

local function exitAt(x: number, z: number, faceX: number, faceZ: number): CFrame
	local p = Vector3.new(x, 0.5, z)
	return CFrame.lookAt(p, p + Vector3.new(faceX, 0, faceZ))
end

DistrictsConfig.STATIONS = {
	{ id = "Neighborhood", name = "Neighborhood", entrance = Vector3.new(40, 0, -45), exit = exitAt(40, -33, 0, 1), line = Color3.fromRGB(30, 140, 70) },
	{ id = "Downtown", name = "Downtown", entrance = Vector3.new(-40, 0, -300), exit = exitAt(-40, -288, 0, 1), line = Color3.fromRGB(40, 120, 230) },
	{ id = "Industrial", name = "Industrial", entrance = Vector3.new(340, 0, -45), exit = exitAt(340, -33, 0, 1), line = Color3.fromRGB(230, 130, 30) },
	{ id = "Beach", name = "Beach", entrance = Vector3.new(-50, 0, 300), exit = exitAt(-50, 312, 0, 1), line = Color3.fromRGB(240, 200, 40) },
	{ id = "Luxury", name = "Luxury Hills", entrance = Vector3.new(-340, 0, -440), exit = exitAt(-340, -428, 0, 1), line = Color3.fromRGB(170, 90, 230) },
	{ id = "OldTown", name = "Old Town", entrance = Vector3.new(-380, 0, -45), exit = exitAt(-380, -33, 0, 1), line = Color3.fromRGB(200, 70, 60) },
} :: { Station }

local stationById: { [string]: Station } = {}
for _, s in DistrictsConfig.STATIONS do
	stationById[s.id] = s
end

function DistrictsConfig.station(id: string): Station?
	return stationById[id]
end

-- The station whose entrance is within range of `position`, if any.
function DistrictsConfig.nearestStation(position: Vector3, range: number?): Station?
	local best, bestDist = nil, range or DistrictsConfig.SUBWAY_RANGE
	for _, s in DistrictsConfig.STATIONS do
		local d = (Vector3.new(position.X, 0, position.Z) - Vector3.new(s.entrance.X, 0, s.entrance.Z)).Magnitude
		if d <= bestDist and math.abs(position.Y - s.entrance.Y) < 20 then
			best, bestDist = s, d
		end
	end
	return best
end

---------------------------------------------------------------------------
-- Luxury Hills private court (section 9)
---------------------------------------------------------------------------
DistrictsConfig.PRIVATE_COURT_REPUTATION = 2500
DistrictsConfig.PRIVATE_COURT_LEVEL = 40

return DistrictsConfig
