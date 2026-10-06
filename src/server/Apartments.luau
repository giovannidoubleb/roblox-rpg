-- CITY GRIND: apartments, real estate and furniture (spec sections 48, 73, 77, 110).
--
-- Every player owns a Studio at Maple Court from the start. Bigger homes are
-- bought from Maple Realty (kiosk outside the building, or the phone's Home app).
-- A player's home is built on demand in its own slot high above the city
-- (Places.apartmentSlot) the first time they walk through the front door, and
-- destroyed when they leave the server.
--
-- Furniture is bought into an inventory and placed on a 1-stud grid. The
-- client only proposes (item, x, z, floor, rotation); this module checks
-- ownership, counts, bounds, blocked fixtures and overlaps with
-- ApartmentsConfig's own size table before anything is saved or built.
--
-- Remotes:  ApartmentsRequest (RemoteFunction, client -> server)
--           ApartmentsEvent   (RemoteEvent, server -> client)
-- Player attributes: HomeTier (active home's display name),
--           HomeUnit (UserId of the unit's owner while inside a unit, else 0)

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Cfg = require(shared:WaitForChild("ApartmentsConfig"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Places = require(script.Parent:WaitForChild("Places"))
local Net = require(script.Parent:WaitForChild("Net"))

local Apartments = {}

local INTERIOR = "Apartment"
local MAX_SLOTS = 60

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
PlayerData.registerSection("apartments", function()
	return {
		ownedTiers = { Studio = true },
		activeTier = "Studio",
		inventory = { basic_bed = 1, floor_lamp = 1 },
		-- placements[tierId] = { { u = uid, id = itemId, x, z, f = floor, r = degrees } }
		placements = {
			Studio = {
				{ u = 1, id = "basic_bed", x = 10, z = -7, f = 1, r = 0 },
				{ u = 2, id = "floor_lamp", x = 6, z = -11, f = 1, r = 0 },
			},
		},
		nextUid = 3,
		onboarded = false,
	}
end)

---------------------------------------------------------------------------
-- Runtime state
---------------------------------------------------------------------------
type Unit = {
	owner: Player,
	slot: number,
	origin: Vector3,
	tierId: string,
	model: Model?,
	furniture: Folder?,
	pieces: { [number]: Model },
	allowedGuests: { [number]: boolean }, -- UserIds the owner lets in (Phase 4 invites)
}

local units: { [Player]: Unit } = {}
local slotOwner: { [number]: Player } = {}
local inside: { [Player]: Unit } = {} -- which unit each player is standing in

local root: Folder
local unitsFolder: Folder
local Event: RemoteEvent
local StaminaRefill: RemoteEvent

local function data(player: Player): any
	return PlayerData.section(player, "apartments")
end

local function placementsFor(sec: any, tierId: string): { any }
	local list = sec.placements[tierId]
	if type(list) ~= "table" then
		list = {}
		sec.placements[tierId] = list
	end
	return list
end

local function placedCount(list: { any }, itemId: string): number
	local n = 0
	for _, p in list do
		if p.id == itemId then
			n += 1
		end
	end
	return n
end

-- Repairs a save: unknown tiers/items dropped, impossible placements removed.
local function sanitize(sec: any)
	if type(sec.ownedTiers) ~= "table" then
		sec.ownedTiers = {}
	end
	for id in sec.ownedTiers do
		if not Cfg.TIER_BY_ID[id] then
			sec.ownedTiers[id] = nil
		end
	end
	sec.ownedTiers.Studio = true
	if type(sec.activeTier) ~= "string" or not sec.ownedTiers[sec.activeTier] then
		sec.activeTier = "Studio"
	end
	if type(sec.inventory) ~= "table" then
		sec.inventory = {}
	end
	for id, count in sec.inventory do
		if not Cfg.ITEM_BY_ID[id] or type(count) ~= "number" or count < 0 then
			sec.inventory[id] = nil
		else
			sec.inventory[id] = math.min(math.floor(count), Cfg.MAX_PER_ITEM)
		end
	end
	if type(sec.placements) ~= "table" then
		sec.placements = {}
	end
	if type(sec.nextUid) ~= "number" then
		sec.nextUid = 1
	end
	for tierId, list in sec.placements do
		local tier = Cfg.TIER_BY_ID[tierId]
		if not tier or type(list) ~= "table" then
			sec.placements[tierId] = nil
			continue
		end
		local kept = {}
		local seen = {}
		for _, p in list do
			if type(p) == "table" and type(p.u) == "number" and not seen[p.u] and #kept < tier.maxItems then
				local owned = sec.inventory[p.id] or 0
				local ok = Cfg.validatePlacement(tierId, p.id, p.x, p.z, p.f, p.r, kept, nil)
				if ok and placedCount(kept, p.id) < owned then
					seen[p.u] = true
					table.insert(kept, { u = p.u, id = p.id, x = p.x, z = p.z, f = p.f, r = p.r })
					sec.nextUid = math.max(sec.nextUid, p.u + 1)
				end
			end
		end
		sec.placements[tierId] = kept
	end
	sec.onboarded = sec.onboarded == true
end

-- What the client is allowed to see about its home.
local function stateFor(player: Player): any
	local sec = data(player)
	if not sec then
		return nil
	end
	local placed = {}
	for _, p in placementsFor(sec, sec.activeTier) do
		table.insert(placed, { u = p.u, id = p.id, x = p.x, z = p.z, f = p.f, r = p.r })
	end
	return {
		ownedTiers = table.clone(sec.ownedTiers),
		activeTier = sec.activeTier,
		inventory = table.clone(sec.inventory),
		placements = placed,
		onboarded = sec.onboarded,
	}
end

local function pushState(player: Player)
	local state = stateFor(player)
	if state and player.Parent then
		Event:FireClient(player, "State", state)
	end
end

---------------------------------------------------------------------------
-- Guests (owner-only for now; Phase 4 fills allowedGuests through invites)
---------------------------------------------------------------------------
function Apartments.canEnterUnit(visitor: Player, unit: Unit): boolean
	return visitor == unit.owner or unit.allowedGuests[visitor.UserId] == true
end

function Apartments.setGuestAllowed(owner: Player, userId: number, allowed: boolean)
	local unit = units[owner]
	if unit then
		unit.allowedGuests[userId] = if allowed then true else nil
	end
end

local function setInside(player: Player, unit: Unit?)
	inside[player] = unit
	player:SetAttribute("HomeUnit", if unit then unit.owner.UserId else 0)
end

local function sendOutside(player: Player)
	setInside(player, nil)
	if player:GetAttribute("Interior") == INTERIOR then
		Places.leave(player, Cfg.OUTSIDE)
	end
end

---------------------------------------------------------------------------
-- Room shells
---------------------------------------------------------------------------
local part = Cfg.part
local V = Vector3.new
local rgb = Color3.fromRGB

local function ceilingLight(parent: Instance, pos: Vector3, range: number)
	local lamp = part(parent, "CeilingLight", V(3, 0.2, 3), CFrame.new(pos), rgb(255, 250, 235), Enum.Material.Neon, { CanCollide = false })
	local light = Instance.new("PointLight")
	light.Range = range
	light.Brightness = 1.1
	light.Color = rgb(255, 244, 225)
	light.Parent = lamp
end

-- One wall running from (x0,z0) to (x1,z1) (axis aligned), y from y0 to y1.
-- mode: solid | accent | window (sill + window band) | tall (floor-to-ceiling
-- window with a low sill) | glass (a full glass wall with thin mullions).
local function wall(parent: Instance, O: Vector3, x0: number, z0: number, x1: number, z1: number, y0: number, y1: number, mode: string, style: any)
	local alongX = math.abs(x1 - x0) > math.abs(z1 - z0)
	local length = if alongX then math.abs(x1 - x0) else math.abs(z1 - z0)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local function slab(name: string, from: number, to: number, color: Color3, material: Enum.Material, props: any?)
		local h = to - from
		local size = if alongX then V(length, h, 1) else V(1, h, length)
		return part(parent, name, size, CFrame.new(O + V(cx, from + h / 2, cz)), color, material, props)
	end
	local wallColor, wallMat = style.wallColor, style.wallMat
	if mode == "accent" then
		slab("Wall", y0, y1, style.accentColor, style.accentMat)
		return
	elseif mode == "solid" then
		slab("Wall", y0, y1, wallColor, wallMat)
		return
	end
	local sill, top
	if mode == "window" then
		sill, top = y0 + 3.5, y1 - 2.5
	elseif mode == "tall" then
		sill, top = y0 + 1, y1 - 1.5
	else
		sill, top = y0 + 0.4, y1 - 0.4
	end
	slab("Wall", y0, sill, wallColor, wallMat)
	slab("Wall", top, y1, wallColor, wallMat)
	slab("Window", sill, top, rgb(170, 210, 240), Enum.Material.Glass, { Transparency = if mode == "glass" then 0.75 else 0.55 })
	-- mullions
	local spacing = if mode == "glass" then 12 else 8
	local count = math.floor(length / spacing)
	for i = 1, count - 1 do
		local t = -length / 2 + i * length / count
		local pos = if alongX then V(cx + t, (sill + top) / 2, cz) else V(cx, (sill + top) / 2, cz + t)
		local size = if alongX then V(0.4, top - sill, 1.1) else V(1.1, top - sill, 0.4)
		part(parent, "Mullion", size, CFrame.new(O + pos), if mode == "glass" then rgb(30, 30, 34) else rgb(240, 240, 240), Enum.Material.Metal)
	end
end

local function floorPart(parent: Instance, O: Vector3, x0: number, z0: number, x1: number, z1: number, topY: number, f: number, color: Color3, material: Enum.Material, thickness: number?)
	local t = thickness or 1
	local p = part(parent, "Floor", V(x1 - x0, t, z1 - z0), CFrame.new(O + V((x0 + x1) / 2, topY - t / 2, (z0 + z1) / 2)), color, material)
	p:SetAttribute("FloorIndex", f)
	return p
end

-- Built-in fixtures, one per blocked rect kind.
local function fixture(parent: Instance, O: Vector3, tier: any, rect: any)
	local style = tier.style
	local y = Cfg.floorY(tier, rect.f) or 0
	local x0, z0, x1, z1 = rect.x0, rect.z0, rect.x1, rect.z1
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local w, d = x1 - x0, z1 - z0
	local function at(x: number, py: number, z: number): CFrame
		return CFrame.new(O + V(x, y + py, z))
	end
	local kind = rect.kind
	if kind == "wall" then
		part(parent, "Partition", V(w, tier.height, d), at(cx, tier.height / 2, cz), style.wallColor, style.wallMat)
	elseif kind == "kitchen" or kind == "island" then
		local overhang = if kind == "island" then 0.4 else 0
		part(parent, "Cabinets", V(w - 0.2, 3.2, d - 0.2), at(cx, 1.6, cz), style.cabinet, Enum.Material.Wood)
		part(parent, "Countertop", V(w + overhang, 0.3, d + overhang), at(cx, 3.35, cz), style.counter, Enum.Material.Marble)
		local alongX = w >= d
		local function along(t: number): (number, number)
			if alongX then
				return cx + t * w, cz
			end
			return cx, cz + t * d
		end
		local sx, sz = along(-0.25)
		part(parent, "Sink", V(if alongX then 2.2 else 1.4, 0.1, if alongX then 1.4 else 2.2), at(sx, 3.55, sz), rgb(170, 170, 178), Enum.Material.Metal)
		local fx, fz = along(-0.25)
		part(parent, "Faucet", V(0.2, 1, 0.2), at(fx + (if alongX then 0 else -0.6), 4, fz + (if alongX then -0.6 else 0)), rgb(170, 170, 178), Enum.Material.Metal)
		local hx, hz = along(0.22)
		part(parent, "Cooktop", V(if alongX then 2.6 else 1.8, 0.08, if alongX then 1.8 else 2.6), at(hx, 3.54, hz), rgb(20, 20, 22), Enum.Material.Glass)
		if kind == "island" then
			for _, t in { -0.3, 0, 0.3 } do
				local px, pz = along(t)
				part(parent, "PendantCord", V(0.08, 4, 0.08), at(px, tier.height - 2, pz), rgb(30, 30, 30), Enum.Material.Metal, { CanCollide = false })
				local bulb = part(parent, "Pendant", V(1, 1, 1), at(px, tier.height - 4.2, pz), rgb(255, 225, 170), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CanCollide = false })
				local light = Instance.new("PointLight")
				light.Range = 12
				light.Brightness = 0.8
				light.Color = rgb(255, 215, 160)
				light.Parent = bulb
			end
		end
	elseif kind == "fireplace" then
		-- chimney against the west wall, hearth and fire facing east
		part(parent, "Chimney", V(w - 1, tier.height, d), at(x0 + (w - 1) / 2, tier.height / 2, cz), rgb(120, 115, 110), Enum.Material.Cobblestone)
		part(parent, "Hearth", V(1, 0.4, d), at(x1 - 0.5, 0.2, cz), rgb(70, 70, 75), Enum.Material.Slate)
		local box = part(parent, "Firebox", V(0.2, 3, d - 3), at(x1 - 0.95, 2, cz), rgb(15, 12, 10), Enum.Material.SmoothPlastic)
		part(parent, "Mantel", V(1, 0.4, d), at(x1 - 0.5, 4.6, cz), rgb(90, 60, 40), Enum.Material.Wood)
		local logs = part(parent, "Logs", V(0.6, 0.5, d - 4), at(x1 - 0.5, 0.65, cz), rgb(90, 55, 30), Enum.Material.Wood, { CanCollide = false })
		local fire = Instance.new("Fire")
		fire.Size = 3
		fire.Heat = 4
		fire.Parent = logs
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 150, 60)
		light.Range = 16
		light.Brightness = 1.5
		light.Parent = box
	elseif kind == "hottub" then
		part(parent, "TubRim", V(w, 2.6, d), at(cx, 1.3, cz), rgb(235, 235, 240), Enum.Material.Marble)
		local water = part(parent, "TubWater", V(w - 1.6, 0.3, d - 1.6), at(cx, 2.5, cz), rgb(60, 190, 230), Enum.Material.Glass, { Transparency = 0.25, CanCollide = false })
		for i = 1, 4 do
			-- jets: small glowing discs in the water
			local a = i / 4 * math.pi * 2
			part(parent, "Jet", V(0.1, 0.6, 0.6), at(cx + math.cos(a) * (w / 2 - 1.6), 2.55, cz + math.sin(a) * (d / 2 - 1.6)) * CFrame.Angles(0, 0, math.pi / 2), rgb(200, 240, 255), Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, CanCollide = false })
		end
		local light = Instance.new("PointLight")
		light.Color = rgb(80, 200, 255)
		light.Range = 12
		light.Parent = water
	elseif kind == "pool" then
		part(parent, "PoolDeck", V(w, 0.2, d), at(cx, 0.1, cz), rgb(225, 220, 205), Enum.Material.Slate)
		local px0, pz0, px1, pz1 = x0 + 2, z0 + 2, x1 - 2, z1 - 2
		local pw, pd = px1 - px0, pz1 - pz0
		local pcx, pcz = (px0 + px1) / 2, (pz0 + pz1) / 2
		local rimH = 3
		part(parent, "PoolRim", V(pw + 2, rimH, 1), at(pcx, rimH / 2, pz0 - 0.5), rgb(245, 245, 245), Enum.Material.Marble)
		part(parent, "PoolRim", V(pw + 2, rimH, 1), at(pcx, rimH / 2, pz1 + 0.5), rgb(245, 245, 245), Enum.Material.Marble)
		part(parent, "PoolRim", V(1, rimH, pd), at(px0 - 0.5, rimH / 2, pcz), rgb(245, 245, 245), Enum.Material.Marble)
		part(parent, "PoolRim", V(1, rimH, pd), at(px1 + 0.5, rimH / 2, pcz), rgb(245, 245, 245), Enum.Material.Marble)
		part(parent, "PoolTiles", V(pw, 0.1, pd), at(pcx, 0.25, pcz), rgb(120, 200, 230), Enum.Material.Glass)
		part(parent, "PoolWater", V(pw, rimH - 0.4, pd), at(pcx, 0.2 + (rimH - 0.4) / 2, pcz), rgb(40, 150, 230), Enum.Material.Glass, { Transparency = 0.4, CanCollide = false })
		part(parent, "PoolStep", V(6, 1.5, 1), at(pcx, 0.75, pz1 + 1.5), rgb(245, 245, 245), Enum.Material.Marble)
		for _, t in { -0.3, 0.3 } do
			local light = Instance.new("PointLight")
			light.Color = rgb(90, 200, 255)
			light.Range = 18
			light.Parent = part(parent, "PoolLight", V(1, 0.2, 1), at(pcx + t * pw, 0.35, pcz), rgb(170, 230, 255), Enum.Material.Neon, { CanCollide = false })
		end
	elseif kind == "court" then
		local cx0, cx1, cz0, cz1 = x0 + 1, x1 - 1, z0 + 1, z1 - 1
		local ccx, ccz = (cx0 + cx1) / 2, (cz0 + cz1) / 2
		local cw, cd = cx1 - cx0, cz1 - cz0
		part(parent, "CourtFloor", V(cw, 0.1, cd), at(ccx, 0.05, ccz), rgb(205, 150, 95), Enum.Material.WoodPlanks)
		local lineColor = Color3.new(1, 1, 1)
		local function line(lx: number, lz: number, sx: number, sz: number)
			part(parent, "CourtLine", V(sx, 0.12, sz), at(lx, 0.06, lz), lineColor, Enum.Material.SmoothPlastic, { CanCollide = false })
		end
		line(ccx, cz0 + 0.15, cw, 0.3) -- baseline
		line(ccx, cz1 - 0.15, cw, 0.3) -- half-court line
		line(cx0 + 0.15, ccz, 0.3, cd)
		line(cx1 - 0.15, ccz, 0.3, cd)
		-- the paint
		part(parent, "Paint", V(12, 0.11, 15), at(ccx, 0.055, cz0 + 7.5), rgb(40, 90, 160), Enum.Material.SmoothPlastic, { CanCollide = false })
		local rimZ = cz0 + 4
		-- three-point arc
		local radius = 15
		local segments = 18
		for i = 0, segments - 1 do
			local a0 = math.rad(-85 + 170 * i / segments)
			local a1 = math.rad(-85 + 170 * (i + 1) / segments)
			local p0 = V(ccx + math.sin(a0) * radius, 0, rimZ + math.cos(a0) * radius)
			local p1 = V(ccx + math.sin(a1) * radius, 0, rimZ + math.cos(a1) * radius)
			local mid = (p0 + p1) / 2
			local seg = (p1 - p0).Magnitude
			part(parent, "ThreeLine", V(0.3, 0.12, seg + 0.1), CFrame.lookAt(O + V(mid.X, y + 0.06, mid.Z), O + V(p1.X, y + 0.06, p1.Z)), lineColor, Enum.Material.SmoothPlastic, { CanCollide = false })
		end
		-- hoop
		part(parent, "HoopPole", V(0.8, 12, 0.8), at(ccx, 6, cz0 + 0.6), rgb(40, 40, 46), Enum.Material.Metal)
		part(parent, "HoopArm", V(0.5, 0.5, 2.2), at(ccx, 11.5, cz0 + 1.7), rgb(40, 40, 46), Enum.Material.Metal)
		part(parent, "Backboard", V(6, 3.5, 0.2), at(ccx, 11.5, cz0 + 2.9), Color3.new(1, 1, 1), Enum.Material.Glass, { Transparency = 0.3 })
		part(parent, "BoardSquare", V(2, 1.5, 0.22), at(ccx, 11, cz0 + 2.9), rgb(220, 60, 40), Enum.Material.SmoothPlastic, { Transparency = 0.2 })
		for i = 0, 11 do
			local a = i / 12 * math.pi * 2
			part(parent, "Rim", V(0.15, 0.12, 0.5), CFrame.new(O + V(ccx + math.cos(a) * 0.9, y + 10, rimZ + math.sin(a) * 0.9)) * CFrame.Angles(0, -a, 0), rgb(255, 100, 30), Enum.Material.Metal)
		end
		part(parent, "Net", V(1.3, 1.6, 1.6), at(ccx, 9.3, rimZ) * CFrame.Angles(0, 0, math.pi / 2), Color3.new(1, 1, 1), Enum.Material.Fabric, { Shape = Enum.PartType.Cylinder, Transparency = 0.5, CanCollide = false })
		part(parent, "Ball", V(1.5, 1.5, 1.5), at(ccx + 4, 0.85, cz1 - 3), rgb(230, 110, 40), Enum.Material.Plastic, { Shape = Enum.PartType.Ball })
	elseif kind == "stairs" then
		-- 17 one-stud steps climbing west to the upper floor (surface y = 17)
		local steps = 17
		local run = 1.5
		local startX = 47.25
		for i = 1, steps do
			local xc = startX - run * (i - 0.5)
			part(parent, "Step", V(run, i, 6), at(xc, i / 2, 26), style.accentColor, style.accentMat)
		end
	elseif kind == "stairwell" then
		-- glass railings around the opening on the upper floor
		for _, rz in { 22.85, 29.15 } do
			part(parent, "Railing", V(26.25, 3.5, 0.3), at(34.875, 1.75, rz), rgb(200, 230, 255), Enum.Material.Glass, { Transparency = 0.5 })
			part(parent, "RailTop", V(26.25, 0.2, 0.4), at(34.875, 3.6, rz), rgb(40, 40, 46), Enum.Material.Metal)
		end
	elseif kind == "door" then
		part(parent, "Doormat", V(5, 0.08, 2.5), at(cx, 0.04, z1 - 1.5), rgb(80, 60, 45), Enum.Material.Fabric, { CanCollide = false })
	end
end

local function buildShell(model: Model, tier: any, O: Vector3)
	local style = tier.style
	local hw, hd, H = tier.width / 2, tier.depth / 2, tier.height
	local shell = Instance.new("Folder")
	shell.Name = "Shell"
	shell.Parent = model

	floorPart(shell, O, -hw - 1, -hd - 1, hw + 1, hd + 1, 0, 1, style.floorColor, style.floorMat)
	part(shell, "Ceiling", V(tier.width + 2, 1, tier.depth + 2), CFrame.new(O + V(0, H + 0.5, 0)), rgb(245, 245, 245), Enum.Material.SmoothPlastic)
	-- outer walls: north, east, west by style; south is solid with the door
	wall(shell, O, -hw - 1, -hd - 0.5, hw + 1, -hd - 0.5, 0, H, style.north, style)
	wall(shell, O, hw + 0.5, -hd, hw + 0.5, hd, 0, H, style.east, style)
	wall(shell, O, -hw - 0.5, -hd, -hw - 0.5, hd, 0, H, style.west, style)
	wall(shell, O, -hw - 1, hd + 0.5, hw + 1, hd + 0.5, 0, H, "solid", style)
	-- baseboards
	part(shell, "Baseboard", V(tier.width, 0.5, 0.2), CFrame.new(O + V(0, 0.25, hd - 0.1)), rgb(250, 250, 250), Enum.Material.Wood, { CanCollide = false })

	if style.neon then
		for _, z in { -hd + 0.15, hd - 0.15 } do
			part(shell, "NeonTrim", V(tier.width, 0.25, 0.25), CFrame.new(O + V(0, H - 0.3, z)), style.neon, Enum.Material.Neon, { CanCollide = false })
		end
		for _, x in { -hw + 0.15, hw - 0.15 } do
			part(shell, "NeonTrim", V(0.25, 0.25, tier.depth), CFrame.new(O + V(x, H - 0.3, 0)), style.neon, Enum.Material.Neon, { CanCollide = false })
		end
	end

	if tier.id == "Mansion" then
		-- upper floor slab over the south half, with an opening for the stairs
		local slabTop = 17
		local up, upMat = style.upperColor, style.upperMat
		floorPart(shell, O, -hw, 0, 21.75, hd, slabTop, 2, up, upMat)
		floorPart(shell, O, 21.75, 0, hw, 23, slabTop, 2, up, upMat)
		floorPart(shell, O, 21.75, 29, hw, hd, slabTop, 2, up, upMat)
		-- glass balcony rail along the atrium edge
		part(shell, "BalconyRail", V(tier.width, 3.5, 0.3), CFrame.new(O + V(0, slabTop + 1.75, 0.25)), rgb(200, 230, 255), Enum.Material.Glass, { Transparency = 0.5 })
		part(shell, "BalconyTop", V(tier.width, 0.2, 0.4), CFrame.new(O + V(0, slabTop + 3.6, 0.25)), rgb(40, 40, 46), Enum.Material.Metal)
		-- lights: under the slab, in the tall atrium, and upstairs
		for x = -hw + 12, hw - 12, 24 do
			for _, z in { 8, 32 } do
				ceilingLight(shell, O + V(x, 15.85, z), 26) -- under the slab, clear of the stairwell
			end
			for _, z in { 9, 27 } do
				ceilingLight(shell, O + V(x, H - 0.1, z), 26)
			end
			for _, z in { -27, -9 } do
				ceilingLight(shell, O + V(x, H - 0.1, z), 40)
			end
		end
		-- chandelier over the atrium
		local chandelier = part(shell, "Chandelier", V(3, 3, 3), CFrame.new(O + V(-10, H - 6, -18)), rgb(255, 240, 200), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CanCollide = false })
		part(shell, "ChandelierChain", V(0.15, 5, 0.15), CFrame.new(O + V(-10, H - 2.5, -18)), rgb(200, 170, 80), Enum.Material.Metal, { CanCollide = false })
		local light = Instance.new("PointLight")
		light.Range = 40
		light.Brightness = 1.2
		light.Color = rgb(255, 230, 180)
		light.Parent = chandelier
	else
		local nx = math.max(1, math.floor(tier.width / 20))
		local nz = math.max(1, math.floor(tier.depth / 20))
		for i = 1, nx do
			for j = 1, nz do
				local x = -hw + (i - 0.5) * tier.width / nx
				local z = -hd + (j - 0.5) * tier.depth / nz
				ceilingLight(shell, O + V(x, H - 0.1, z), 26)
			end
		end
	end

	for _, rect in tier.blocked do
		fixture(shell, O, tier, rect)
	end

	-- a nameplate over the door
	local plate = part(shell, "Nameplate", V(8, 1.4, 0.2), CFrame.new(O + V(0, 10.2, hd - 0.15)), rgb(20, 20, 24), Enum.Material.SmoothPlastic)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = plate
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = "EXIT  ·  MAPLE COURT"
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = rgb(255, 230, 180)
	label.Parent = gui
end

---------------------------------------------------------------------------
-- Furniture pieces
---------------------------------------------------------------------------
local function prompt(parent: Instance, action: string, object: string, hold: number?): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.ActionText = action
	p.ObjectText = object
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.MaxActivationDistance = 8
	p.RequiresLineOfSight = false
	p.HoldDuration = hold or 0
	p.Parent = parent
	return p
end

local function inUnit(player: Player, unit: Unit): boolean
	return inside[player] == unit and player:GetAttribute("Interior") == INTERIOR
end

local function setTV(model: Model, on: boolean)
	model:SetAttribute("On", on)
	local screen = model:FindFirstChild("Screen") :: BasePart?
	local gui = screen and screen:FindFirstChild("TVGui") :: SurfaceGui?
	if gui then
		gui.Enabled = on
	end
end

local function setLamp(model: Model, on: boolean)
	model:SetAttribute("On", on)
	local bulb = model:FindFirstChild("Bulb") :: BasePart?
	if bulb then
		bulb.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
		bulb.Color = if on then rgb(255, 235, 190) else rgb(120, 120, 120)
		local light = bulb:FindFirstChild("Light") :: PointLight?
		if light then
			light.Enabled = on
		end
	end
end

-- Adds the working parts of functional furniture (beds, TVs, lamps).
local function wireFunctions(unit: Unit, model: Model, item: any)
	if item.kind == "bed" then
		local mattress = model:FindFirstChild("Mattress")
		if not mattress then
			return
		end
		local p = prompt(mattress, "Sleep", item.name, 0.6)
		p.Triggered:Connect(function(player)
			if not inUnit(player, unit) or not Net.alive(player) or not Net.allow(player, "AptSleep", 8) then
				return
			end
			Event:FireClient(player, "Sleep")
			task.delay(1.4, function()
				if player.Parent and inside[player] == unit then
					StaminaRefill:FireClient(player)
					Net.notify(player, "WELL RESTED", "Stamina fully restored.")
				end
			end)
		end)
	elseif item.kind == "tv" then
		local bezel = model:FindFirstChild("Bezel")
		if not bezel then
			return
		end
		local screen = model:FindFirstChild("Screen")
		if screen then
			CollectionService:AddTag(screen, "CityGrindTV")
		end
		setTV(model, true)
		local p = prompt(bezel, "Turn Off", "TV")
		p.Triggered:Connect(function(player)
			if not inUnit(player, unit) or not Net.allow(player, "AptTV", 0.4) then
				return
			end
			local on = not model:GetAttribute("On")
			setTV(model, on)
			p.ActionText = if on then "Turn Off" else "Turn On"
		end)
	elseif item.kind == "lamp" then
		local pole = model:FindFirstChild("Pole")
		if not pole then
			return
		end
		setLamp(model, true)
		local p = prompt(pole, "Turn Off", "Lamp")
		p.Triggered:Connect(function(player)
			if not inUnit(player, unit) or not Net.allow(player, "AptLamp", 0.3) then
				return
			end
			local on = not model:GetAttribute("On")
			setLamp(model, on)
			p.ActionText = if on then "Turn Off" else "Turn On"
		end)
	end
end

local function spawnPiece(unit: Unit, placement: any)
	local item = Cfg.ITEM_BY_ID[placement.id]
	local tier = Cfg.TIER_BY_ID[unit.tierId]
	if not item or not tier or not unit.furniture then
		return
	end
	local model = Cfg.buildItem(placement.id)
	if not model then
		return
	end
	model:SetAttribute("PlacementId", placement.u)
	model:SetAttribute("ItemId", placement.id)
	model:PivotTo(Cfg.pieceCFrame(unit.origin, tier, item, placement.x, placement.z, placement.f, placement.r))
	wireFunctions(unit, model, item)
	model.Parent = unit.furniture
	unit.pieces[placement.u] = model
end

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------
local function spawnCFrame(unit: Unit): CFrame
	local tier = Cfg.TIER_BY_ID[unit.tierId]
	local pos = unit.origin + Cfg.spawnOffset(tier)
	return CFrame.lookAt(pos, pos - Vector3.zAxis)
end

local function buildUnitModel(unit: Unit)
	if unit.model then
		unit.model:Destroy()
	end
	table.clear(unit.pieces)
	local tier = Cfg.TIER_BY_ID[unit.tierId]
	local O = unit.origin
	local model = Instance.new("Model")
	model.Name = "Unit_" .. unit.owner.UserId
	model:SetAttribute("OwnerId", unit.owner.UserId)
	model:SetAttribute("Tier", unit.tierId)
	model:SetAttribute("Origin", O)
	model:SetAttribute("Slot", unit.slot)
	buildShell(model, tier, O)

	-- exit door in the south wall
	local door = part(model, "ExitDoor", V(6, 9, 0.4), CFrame.new(O + V(0, 4.5, tier.depth / 2 - 0.2)), rgb(45, 35, 30), Enum.Material.Wood)
	part(model, "DoorKnob", V(0.4, 0.4, 0.3), CFrame.new(O + V(2.2, 4.3, tier.depth / 2 - 0.5)), rgb(220, 180, 60), Enum.Material.Metal)
	local exitPrompt = prompt(door, "Leave", "Maple Court")
	exitPrompt.MaxActivationDistance = 10
	exitPrompt.Triggered:Connect(function(player)
		if inside[player] == unit then
			sendOutside(player)
		end
	end)

	local furniture = Instance.new("Folder")
	furniture.Name = "Furniture"
	furniture.Parent = model
	unit.furniture = furniture
	unit.model = model

	local sec = data(unit.owner)
	if sec then
		for _, placement in placementsFor(sec, unit.tierId) do
			spawnPiece(unit, placement)
		end
	end
	model.Parent = unitsFolder
end

-- The player's unit, built (in a free slot) if it doesn't exist yet.
local function ensureUnit(player: Player): Unit?
	local sec = data(player)
	if not sec then
		return nil
	end
	local unit = units[player]
	if unit then
		if unit.tierId ~= sec.activeTier or not unit.model or not unit.model.Parent then
			unit.tierId = sec.activeTier
			buildUnitModel(unit)
		end
		return unit
	end
	local slot
	for i = 1, MAX_SLOTS do
		if not slotOwner[i] then
			slot = i
			break
		end
	end
	if not slot then
		return nil
	end
	slotOwner[slot] = player
	unit = {
		owner = player,
		slot = slot,
		origin = Places.apartmentSlot(slot),
		tierId = sec.activeTier,
		model = nil,
		furniture = nil,
		pieces = {},
		allowedGuests = {},
	}
	units[player] = unit
	buildUnitModel(unit :: Unit)
	return unit
end

-- Rebuilds a unit after moving to another tier; anyone inside moves with it.
local function rebuildUnit(unit: Unit, tierId: string)
	unit.tierId = tierId
	buildUnitModel(unit)
	local target = spawnCFrame(unit)
	for player, u in inside do
		if u == unit then
			if player == unit.owner or Apartments.canEnterUnit(player, unit) then
				task.spawn(Places.teleport, player, target)
			else
				sendOutside(player)
			end
		end
	end
end

local function destroyUnit(owner: Player)
	local unit = units[owner]
	if not unit then
		return
	end
	for player, u in inside do
		if u == unit and player ~= owner then
			sendOutside(player)
		end
	end
	if unit.model then
		unit.model:Destroy()
	end
	units[owner] = nil
	if slotOwner[unit.slot] == owner then
		slotOwner[unit.slot] = nil
	end
end

local function onEnteredHome(player: Player, unit: Unit)
	setInside(player, unit)
	local sec = data(player)
	if player == unit.owner and sec and not sec.onboarded then
		sec.onboarded = true
		PlayerData.markChanged(player)
		Event:FireClient(player, "Welcome", Cfg.TIER_BY_ID[unit.tierId].name)
		Net.notify(player, "WELCOME HOME", "This " .. Cfg.TIER_BY_ID[unit.tierId].name .. " is yours. Tap FURNITURE to decorate.")
	end
end

---------------------------------------------------------------------------
-- Requests from the client
---------------------------------------------------------------------------
local function standingInOwnUnit(player: Player): Unit?
	local unit = units[player]
	if not unit or inside[player] ~= unit or player:GetAttribute("Interior") ~= INTERIOR or not Net.alive(player) then
		return nil
	end
	local tier = Cfg.TIER_BY_ID[unit.tierId]
	local reach = math.max(tier.width, tier.depth) / 2 + 10
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end
	local offset = hrp.Position - unit.origin
	if math.abs(offset.X) > reach or math.abs(offset.Z) > reach or offset.Y < -10 or offset.Y > tier.height + 10 then
		return nil
	end
	return unit
end

local function readPlacementPayload(payload: any): (boolean, any)
	if type(payload) ~= "table" then
		return false, nil
	end
	local x, z, f, r = payload.x, payload.z, payload.f, payload.r
	if type(x) ~= "number" or type(z) ~= "number" or type(f) ~= "number" or type(r) ~= "number" then
		return false, nil
	end
	return true, { x = x, z = z, f = f, r = r }
end

local handlers: { [string]: (Player, any, any) -> (boolean, string?) } = {}

handlers.GetState = function()
	return true, nil
end

handlers.BuyTier = function(player, sec, tierId)
	local tier = type(tierId) == "string" and Cfg.TIER_BY_ID[tierId]
	if not tier then
		return false, "That home doesn't exist."
	end
	if sec.ownedTiers[tier.id] then
		return false, "You already own the " .. tier.name .. "."
	end
	local profile = PlayerData.get(player)
	if not profile then
		return false, "Your save is still loading."
	end
	if profile.level < tier.level then
		return false, "The " .. tier.name .. " needs Level " .. tier.level .. "."
	end
	if profile.reputation < tier.reputation then
		return false, "The " .. tier.name .. " needs " .. tier.reputation .. " reputation."
	end
	if not PlayerData.spendCash(player, tier.price, "Home: " .. tier.name) then
		return false, "You need $" .. tier.price .. " for the " .. tier.name .. "."
	end
	sec.ownedTiers[tier.id] = true
	sec.activeTier = tier.id
	PlayerData.markChanged(player)
	local unit = units[player]
	if unit then
		rebuildUnit(unit, tier.id)
	end
	return true, "The " .. tier.name .. " is yours. You moved in!"
end

handlers.MoveIn = function(player, sec, tierId)
	local tier = type(tierId) == "string" and Cfg.TIER_BY_ID[tierId]
	if not tier or not sec.ownedTiers[tier.id] then
		return false, "You don't own that home."
	end
	if sec.activeTier == tier.id then
		return false, "You already live in the " .. tier.name .. "."
	end
	sec.activeTier = tier.id
	PlayerData.markChanged(player)
	local unit = units[player]
	if unit then
		rebuildUnit(unit, tier.id)
	end
	return true, "Moved into the " .. tier.name .. "."
end

handlers.BuyFurniture = function(player, sec, itemId)
	local item = type(itemId) == "string" and Cfg.ITEM_BY_ID[itemId]
	if not item then
		return false, "That item isn't sold here."
	end
	local owned = sec.inventory[item.id] or 0
	if owned >= Cfg.MAX_PER_ITEM then
		return false, "You own the maximum of " .. Cfg.MAX_PER_ITEM .. "."
	end
	if not PlayerData.spendCash(player, item.price, "Furniture: " .. item.name) then
		return false, "You need $" .. item.price .. " for the " .. item.name .. "."
	end
	sec.inventory[item.id] = owned + 1
	PlayerData.markChanged(player)
	return true, item.name .. " delivered. Place it from FURNITURE at home."
end

handlers.Place = function(player, sec, payload)
	local unit = standingInOwnUnit(player)
	if not unit then
		return false, "Go inside your home to place furniture."
	end
	local ok, pos = readPlacementPayload(payload)
	local itemId = type(payload) == "table" and payload.id
	local item = type(itemId) == "string" and Cfg.ITEM_BY_ID[itemId]
	if not ok or not item then
		return false, "Bad placement."
	end
	local tier = Cfg.TIER_BY_ID[unit.tierId]
	local list = placementsFor(sec, unit.tierId)
	if #list >= tier.maxItems then
		return false, "The " .. tier.name .. " holds " .. tier.maxItems .. " pieces. Store something first."
	end
	if placedCount(list, item.id) >= (sec.inventory[item.id] or 0) then
		return false, "You don't have another " .. item.name .. ". Buy one in the Store."
	end
	local valid, reason = Cfg.validatePlacement(unit.tierId, item.id, pos.x, pos.z, pos.f, pos.r, list, nil)
	if not valid then
		return false, reason
	end
	local placement = { u = sec.nextUid, id = item.id, x = pos.x, z = pos.z, f = pos.f, r = pos.r }
	sec.nextUid += 1
	table.insert(list, placement)
	PlayerData.markChanged(player)
	spawnPiece(unit, placement)
	return true, nil
end

local function findPlacement(list: { any }, uid: any): (number?, any)
	if type(uid) ~= "number" then
		return nil, nil
	end
	for i, p in list do
		if p.u == uid then
			return i, p
		end
	end
	return nil, nil
end

handlers.Move = function(player, sec, payload)
	local unit = standingInOwnUnit(player)
	if not unit then
		return false, "Go inside your home to move furniture."
	end
	local ok, pos = readPlacementPayload(payload)
	if not ok then
		return false, "Bad placement."
	end
	local list = placementsFor(sec, unit.tierId)
	local _, placement = findPlacement(list, payload.u)
	if not placement then
		return false, "That piece isn't here."
	end
	local valid, reason = Cfg.validatePlacement(unit.tierId, placement.id, pos.x, pos.z, pos.f, pos.r, list, placement.u)
	if not valid then
		return false, reason
	end
	placement.x, placement.z, placement.f, placement.r = pos.x, pos.z, pos.f, pos.r
	PlayerData.markChanged(player)
	local model = unit.pieces[placement.u]
	local tier = Cfg.TIER_BY_ID[unit.tierId]
	local item = Cfg.ITEM_BY_ID[placement.id]
	if model and model.Parent then
		model:PivotTo(Cfg.pieceCFrame(unit.origin, tier, item, pos.x, pos.z, pos.f, pos.r))
	else
		spawnPiece(unit, placement)
	end
	return true, nil
end

handlers.Store = function(player, sec, uid)
	local unit = standingInOwnUnit(player)
	if not unit then
		return false, "Go inside your home to store furniture."
	end
	local list = placementsFor(sec, unit.tierId)
	local index, placement = findPlacement(list, uid)
	if not index then
		return false, "That piece isn't here."
	end
	table.remove(list, index)
	PlayerData.markChanged(player)
	local model = unit.pieces[placement.u]
	if model then
		model:Destroy()
		unit.pieces[placement.u] = nil
	end
	local item = Cfg.ITEM_BY_ID[placement.id]
	return true, (if item then item.name else "Item") .. " stored."
end

local COOLDOWNS = {
	GetState = 0.2,
	BuyTier = 1,
	MoveIn = 2,
	BuyFurniture = 0.35,
	Place = 0.2,
	Move = 0.2,
	Store = 0.2,
}

---------------------------------------------------------------------------
-- Outdoor: Maple Realty kiosk
---------------------------------------------------------------------------
local function formatCash(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return "$" .. formatted
end

local function buildRealty(city: Instance)
	local pos = Cfg.REALTY_POS
	local m = Instance.new("Model")
	m.Name = "MapleRealty"
	m.Parent = root
	local function at(x: number, y: number, z: number): CFrame
		return CFrame.new(pos + V(x, y, z))
	end
	part(m, "Pad", V(14, 0.3, 9), at(0, 0.15, 0), rgb(200, 195, 185), Enum.Material.Concrete)
	local desk = part(m, "Desk", V(7, 3.5, 2.5), at(0, 1.9, 0), rgb(150, 105, 70), Enum.Material.Wood)
	part(m, "DeskTop", V(7.4, 0.3, 2.9), at(0, 3.8, 0), rgb(240, 240, 240), Enum.Material.Marble)
	part(m, "Brochures", V(1.2, 0.2, 0.9), at(-2, 4.05, -0.3), rgb(255, 120, 60), Enum.Material.SmoothPlastic)
	part(m, "Laptop", V(1.6, 0.1, 1.1), at(1.6, 4.0, 0), rgb(40, 40, 46), Enum.Material.Metal)
	part(m, "LaptopScreen", V(1.6, 1, 0.08), at(1.6, 4.5, 0.55), rgb(80, 170, 255), Enum.Material.Neon)
	for _, x in { -6.5, 6.5 } do
		part(m, "AwningPost", V(0.4, 9, 0.4), at(x, 4.5, -3.9), rgb(40, 40, 46), Enum.Material.Metal)
	end
	part(m, "Awning", V(14, 0.4, 9), at(0, 9.2, 0), rgb(40, 120, 90), Enum.Material.Fabric)

	-- price board behind the desk, facing the street (+z)
	local board = part(m, "Board", V(12, 5.5, 0.4), at(0, 6.1, -3.6), rgb(20, 22, 28), Enum.Material.SmoothPlastic)
	board.CFrame *= CFrame.Angles(0, math.pi, 0)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = board
	local list = Instance.new("Frame")
	list.BackgroundTransparency = 1
	list.Size = UDim2.fromScale(1, 1)
	list.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local function row(text: string, color: Color3, height: number, order: number)
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, height)
		label.Text = text
		label.TextScaled = true
		label.Font = Enum.Font.GothamBlack
		label.TextColor3 = color
		label.LayoutOrder = order
		label.Parent = list
	end
	row("MAPLE REALTY", rgb(120, 230, 170), 0.24, 0)
	for i, tier in Cfg.TIERS do
		local req = ""
		if tier.level > 1 then
			req = "  ·  LV " .. tier.level
		end
		if tier.reputation > 0 then
			req ..= " · " .. tier.reputation .. " REP"
		end
		local price = if tier.price == 0 then "FREE" else formatCash(tier.price)
		row(tier.name .. "  " .. price .. req, Color3.new(1, 1, 1), 0.15, i)
	end

	local browse = prompt(desk, "Browse Homes", "Maple Realty")
	browse.MaxActivationDistance = 10
	browse.Triggered:Connect(function(player)
		if Net.allow(player, "AptRealty", 0.5) then
			Event:FireClient(player, "OpenRealty")
		end
	end)
	Places.mapPoint(city, "Maple Realty", "Home", pos + V(0, 3, 6))
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Apartments.start(city: Instance)
	root = Instance.new("Folder")
	root.Name = "Apartments"
	root.Parent = city
	unitsFolder = Instance.new("Folder")
	unitsFolder.Name = "Units"
	unitsFolder.Parent = root

	Event = Net.remote("RemoteEvent", "ApartmentsEvent")
	StaminaRefill = Net.remote("RemoteEvent", "StaminaRefill")
	local Request = Net.remote("RemoteFunction", "ApartmentsRequest")

	Request.OnServerInvoke = function(player: Player, action: any, payload: any)
		if type(action) ~= "string" or not handlers[action] then
			return false, "Unknown request.", nil
		end
		if not Net.allow(player, "Apt" .. action, COOLDOWNS[action] or 0.3) then
			return false, nil, stateFor(player) -- silently ignore spam
		end
		local sec = data(player)
		if not sec then
			return false, "Your save is still loading.", nil
		end
		local ok, message = handlers[action](player, sec, payload)
		local state = stateFor(player)
		if ok and action ~= "GetState" then
			pushState(player)
		end
		return ok, message, state
	end

	-- Front door of Maple Court -> the player's own unit.
	local door = Places.buildingDoor(city, "Starter Apartments")
	if not door then
		door = part(root, "MapleCourtDoor", V(6, 9, 0.4), CFrame.new(-100, 4.5, -64.8), rgb(45, 35, 30), Enum.Material.Wood)
	end
	local doorOpts: any
	doorOpts = {
		name = INTERIOR,
		door = door :: BasePart,
		inside = Cfg.OUTSIDE, -- replaced with the player's own unit in canEnter
		exitAt = Vector3.new(0, -500, 0),
		outside = Cfg.OUTSIDE,
		actionText = "Go Home",
		parent = root,
		canEnter = function(player: Player): (boolean, string?)
			if not PlayerData.isLoaded(player) or not data(player) then
				return false, "Your save is still loading."
			end
			if not Net.alive(player) then
				return false, nil
			end
			local unit = ensureUnit(player)
			if not unit then
				return false, "Maple Court is full right now. Try again soon."
			end
			if not Apartments.canEnterUnit(player, unit) then
				return false, "That isn't your unit."
			end
			-- Places.door teleports to opts.inside right after this returns.
			doorOpts.inside = spawnCFrame(unit)
			return true, nil
		end,
		onEnter = function(player: Player)
			local unit = units[player]
			if unit then
				onEnteredHome(player, unit)
			end
		end,
		onExit = function(player: Player)
			setInside(player, nil)
		end,
	}
	local placesExit = Places.door(doorOpts)
	-- Each unit has its own exit door, so the shared one Places built is not needed.
	placesExit:Destroy()
	local enterPrompt = door:FindFirstChild("Enter" .. INTERIOR)
	if enterPrompt and enterPrompt:IsA("ProximityPrompt") then
		enterPrompt.ObjectText = "Maple Court"
	end

	buildRealty(city)

	PlayerData.onLoaded(function(player)
		local sec = data(player)
		if sec then
			sanitize(sec)
			PlayerData.markChanged(player)
			pushState(player)
		end
	end)
	PlayerData.onPublish(function(player, profile)
		local sec = profile.sections and profile.sections.apartments
		local tier = sec and Cfg.TIER_BY_ID[sec.activeTier]
		player:SetAttribute("HomeTier", if tier then tier.name else "Studio")
	end)

	local function track(player: Player)
		player:SetAttribute("HomeUnit", 0)
		player.CharacterAdded:Connect(function()
			setInside(player, nil) -- respawning always puts you outside
		end)
		player:GetAttributeChangedSignal("Interior"):Connect(function()
			if player:GetAttribute("Interior") ~= INTERIOR and inside[player] then
				setInside(player, nil)
			end
		end)
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		inside[player] = nil
		destroyUnit(player)
	end)
end

return Apartments
