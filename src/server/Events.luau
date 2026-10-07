-- CITY GRIND: city events (spec sections 41, 57, 58, 63, 92, 114).
-- A scheduler rotates real events every 12-20 minutes of server time. Each one
-- is announced city-wide 5 minutes ahead and again when it starts, has a
-- location, a start time, rewards (cash / XP / reputation, never Robux), a
-- player cap and a live participant list. Built in this file:
--   * 3-Point Contest at the Neighborhood Court (only while the court is Idle)
--   * City 5K Run on the sidewalks, checkpoints validated here
--   * Car Meet at the Car Meet Lot: park in a bay, then everyone votes
-- More kinds live in their own modules and plug in through the kind registry
-- (Events.registerKind): EventDunk, EventHunt, EventPhoto, EventFashion and
-- EventStreetball. Each gets the shared helpers in `ctx` and provides
-- goLive / tick / live / cleanup / leave / request handlers.
-- Plus an hourly community goal counted from every real basket in the city.
--
-- Remotes: EventsRequest (RemoteFunction, client -> server: action, ...)
--          EventsUpdate  (RemoteEvent, server -> client: kind, ...)
-- Player attribute: Event = event id while taking part in a live event.
-- Court attribute (any Court): Event = true / EventName while a court event runs.
-- Saved section "events": { best5k, best3pt, joined, podiums, wins, carAwards,
--   dunkBest?, caches?, photoWins?, fashionWins?, streetballWins? } (the ? fields are
--   added lazily, so older saves without them read as 0).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local EC = require(shared:WaitForChild("EventsConfig"))
local VC = require(shared:WaitForChild("VehiclesConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Places = require(script.Parent:WaitForChild("Places"))
local Basketball = require(script.Parent:WaitForChild("Basketball"))

local Events = {}

PlayerData.registerSection("events", function()
	return { best5k = 0, best3pt = 0, joined = 0, podiums = 0, wins = 0, carAwards = 0 }
end)

local THREE = EC.THREE
local RUN = EC.RUN
local MEET = EC.MEET

local rng = Random.new()
local root: Folder -- Events folder under the City
local Request: RemoteFunction
local Update: RemoteEvent

local function now(): number
	return Workspace:GetServerTimeNow()
end

---------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------
type Event = {
	id: string,
	kind: string,
	name: string,
	icon: string,
	location: string,
	pos: Vector3,
	startsAt: number,
	state: string, -- Upcoming | Checkin | Running | Voting
	phase: string, -- label shown in the app / HUD
	phaseEndsAt: number,
	registered: { Player },
	reminders: { [Player]: boolean },
	watchers: { [Player]: boolean },
	announced: boolean,
	reminded: boolean,
	postpones: number,
	venue: any, -- picked at schedule time by registry kinds (court model, spot...)
	data: any,
}

type Spot = { pos: Vector3, left: number, balls: { BasePart }, marker: BasePart }
type Turn = {
	player: Player,
	name: string,
	readyAt: number,
	endsAt: number,
	endClock: number,
	score: number,
	made: number,
	shots: number,
	awaySince: number?,
	timeUsed: number,
	ended: boolean,
}
type Lane = { side: string, rim: Vector3, spots: { Spot }, turn: Turn? }
type BallInfo = { lane: Lane, turn: Turn, player: Player, money: boolean, releasedAt: number?, scoredAt: number? }

type Racer = {
	player: Player,
	name: string,
	nextIndex: number,
	passed: number,
	legStart: number,
	samples: { { t: number, pos: Vector3 } },
	lastSample: number,
	finished: boolean,
	time: number,
	out: string?, -- DQ / DNF reason
}

type Bay = { index: number, center: Vector3, glow: BasePart, plate: TextLabel? }

local events: { Event } = {}
local results: { any } = {}
local nextId = 0
local lastScheduledAt = 0
local kindBag: { string } = {}
local lastKind: string? = nil
local listDirty = true

local eventBalls: { [any]: BallInfo } = {} -- Basketball.Ball -> info
local court: Model? = nil
local meetBays: { Bay } = {}

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function part(p: {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	collide: boolean?,
	shape: Enum.PartType?,
	parent: Instance,
}): Part
	local b = Instance.new("Part")
	b.Name = p.name or "Part"
	b.Anchored = true
	b.Size = p.size
	b.CFrame = p.cframe
	b.Color = p.color or Color3.fromRGB(160, 160, 160)
	b.Material = p.material or Enum.Material.SmoothPlastic
	b.Transparency = p.transparency or 0
	b.CanCollide = if p.collide == nil then true else p.collide
	if p.shape then
		b.Shape = p.shape
	end
	if not b.CanCollide then
		b.CanQuery = false
		b.CanTouch = false
	end
	b.TopSurface = Enum.SurfaceType.Smooth
	b.BottomSurface = Enum.SurfaceType.Smooth
	b.Parent = p.parent
	return b
end

local function surfaceText(target: BasePart, face: Enum.NormalId, text: string, color: Color3, ppsOverride: number?): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppsOverride or 40
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.Parent = gui
	return label
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local r = character and character:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDist(a: Vector3, b: Vector3): number
	return flat(a - b).Magnitude
end

local function notifyAll(title: string, body: string)
	for _, p in Players:GetPlayers() do
		Net.notify(p, title, body)
	end
end

local function section(player: Player): any
	return PlayerData.section(player, "events")
end

local function give(player: Player, reward: EC.Reward, label: string)
	if not player.Parent then
		return
	end
	if reward.cash > 0 then
		PlayerData.addCash(player, reward.cash, label)
	end
	if reward.xp > 0 then
		PlayerData.addXP(player, reward.xp)
	end
	if reward.rep > 0 then
		PlayerData.addReputation(player, reward.rep)
	end
end

local function isRegistered(ev: Event, player: Player): boolean
	return table.find(ev.registered, player) ~= nil
end

local function isLive(ev: Event): boolean
	return ev.state ~= "Upcoming"
end

local function findEvent(id: any): Event?
	if type(id) ~= "string" then
		return nil
	end
	for _, ev in events do
		if ev.id == id then
			return ev
		end
	end
	return nil
end

-- The (upcoming or live) event this player signed up for.
local function registrationOf(player: Player): Event?
	for _, ev in events do
		if isRegistered(ev, player) then
			return ev
		end
	end
	return nil
end

local function setEventAttr(player: Player, id: string?)
	if player.Parent then
		player:SetAttribute("Event", id)
	end
end

local function fireTo(players: { Player }, ...)
	for _, p in players do
		if p.Parent then
			Update:FireClient(p, ...)
		end
	end
end

local function markDirty()
	listDirty = true
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------
local function pushResult(ev: Event, lines: { string }, winner: string?)
	table.insert(results, 1, {
		id = ev.id,
		name = ev.name,
		icon = ev.icon,
		kind = ev.kind,
		at = now(),
		lines = lines,
		winner = winner,
	})
	while #results > EC.RESULTS_KEPT do
		table.remove(results)
	end
end

-- Removes a finished / cancelled event and frees everyone in it.
local cleanupByKind: { [string]: (Event) -> () } = {}
local function closeEvent(ev: Event)
	local i = table.find(events, ev)
	if i then
		table.remove(events, i)
	end
	for _, p in ev.registered do
		if p.Parent and p:GetAttribute("Event") == ev.id then
			setEventAttr(p, nil)
		end
	end
	local audience = table.clone(ev.registered)
	for p in ev.watchers do
		if not table.find(audience, p) then
			table.insert(audience, p)
		end
	end
	fireTo(audience, "Closed", ev.id)
	local cleanup = cleanupByKind[ev.kind]
	if cleanup then
		pcall(cleanup, ev)
	end
	markDirty()
end

local function cancelEvent(ev: Event, reason: string)
	for _, p in ev.registered do
		Net.notify(p, ev.name:upper() .. " CANCELLED", reason)
	end
	pushResult(ev, { "Cancelled: " .. reason }, nil)
	closeEvent(ev)
end

---------------------------------------------------------------------------
-- Rewards ranking shared by the contest and the race. A podium place is only
-- paid when someone finished below you, so a solo entry can't farm 1st place.
---------------------------------------------------------------------------
local function payPlace(ev: Event, p: Player, place: number, entrants: number, eligible: boolean)
	local kind = EC.KINDS[ev.kind]
	do
		local reward = kind.podium[place]
		if reward and entrants > place and eligible then
			give(p, reward, string.format("%s: #%d", ev.name, place))
			local sec = section(p)
			if sec then
				sec.podiums += 1
				if place == 1 then
					sec.wins += 1
				end
				PlayerData.markChanged(p)
			end
			Net.notify(p, place == 1 and "YOU WON!" or "PODIUM FINISH", string.format("#%d in the %s. %s", place, ev.name, EC.rewardText(reward)))
		else
			give(p, kind.finisher, ev.name .. " entry")
			Net.notify(p, ev.name:upper() .. " DONE", string.format("You placed #%d. %s", place, EC.rewardText(kind.finisher)))
		end
	end
end

local function payPodium(ev: Event, ranked: { Player }, entrants: number, eligible: (Player, number) -> boolean)
	for place, p in ranked do
		payPlace(ev, p, place, entrants, eligible(p, place))
	end
end

-- Takes a player out of an event before it really starts (missed check-in etc.).
local function dropEntrant(ev: Event, p: Player, title: string, body: string)
	local i = table.find(ev.registered, p)
	if i then
		table.remove(ev.registered, i)
	end
	if p.Parent and p:GetAttribute("Event") == ev.id then
		setEventAttr(p, nil)
	end
	if p.Parent then
		Net.notify(p, title, body)
		Update:FireClient(p, "Closed", ev.id)
	end
	markDirty()
end

---------------------------------------------------------------------------
-- Kind registry. Kinds in other modules register these handlers:
--   available()            -> boolean      can it run on this server right now
--   pickVenue()            -> (Vector3, string?, any?)  position, location text, venue
--   goLive(ev)             -> (string, string?)  "live" | "postpone" | "cancel", message
--   tick(ev)               10 Hz while live
--   live(ev, viewer)       -> table for the live panel
--   cleanup(ev)?           when the event closes for any reason
--   leave(ev, player)?     a player left (quit, LEAVE, server exit)
--   request(ev, player, action, b, c)? -> { ok, msg, ... }   Vote / Submit / Entry
--   tip: string?           shown after joining
---------------------------------------------------------------------------
export type KindHandlers = {
	available: (() -> boolean)?,
	pickVenue: (() -> (Vector3, string?, any))?,
	goLive: (any) -> (string, string?),
	tick: (any) -> (),
	live: (any, Player) -> any,
	cleanup: ((any) -> ())?,
	leave: ((any, Player) -> ())?,
	request: ((any, Player, string, any, any) -> any)?,
	tip: string?,
}
local registry: { [string]: KindHandlers } = {}

function Events.registerKind(kindId: string, handlers: KindHandlers)
	registry[kindId] = handlers
	if handlers.cleanup then
		cleanupByKind[kindId] = handlers.cleanup
	end
end

---------------------------------------------------------------------------
-- 3-POINT CONTEST
---------------------------------------------------------------------------
local function findCourt(): Model?
	local fallback = nil
	for _, m in CollectionService:GetTagged("Court") do
		if m:IsA("Model") then
			if m.Name == "NeighborhoodCourt" then
				return m
			end
			fallback = fallback or m
		end
	end
	return fallback
end

local function courtCenter(m: Model): Vector3
	local c = m:GetAttribute("CourtCenter")
	return if typeof(c) == "Vector3" then c else m:GetPivot().Position
end

local function courtSize(m: Model): Vector3
	local s = m:GetAttribute("CourtSize")
	return if typeof(s) == "Vector3" then s else Vector3.new(44, 0, 76)
end

local function courtIdle(m: Model): boolean
	local state = m:GetAttribute("State")
	return state == nil or state == "Idle"
end

local function onCourt(m: Model, player: Player, margin: number): boolean
	local r = rootOf(player)
	if not r then
		return false
	end
	local offset = r.Position - courtCenter(m)
	local size = courtSize(m)
	return math.abs(offset.X) <= size.X / 2 + margin and math.abs(offset.Z) <= size.Z / 2 + margin and math.abs(offset.Y) < 15
end

local function rimOf(m: Model, side: string): Vector3?
	local hoop = m:FindFirstChild("Hoop" .. side)
	local marker = hoop and hoop:FindFirstChild("RimCenter", true)
	if marker and marker:IsA("Attachment") then
		return marker.WorldPosition
	end
	return nil
end

local function refillSpots(lane: Lane)
	for _, spot in lane.spots do
		spot.left = THREE.BALLS_PER_RACK
		for _, b in spot.balls do
			b.Transparency = 0
		end
	end
end

local function buildThreeVenue(ev: Event, m: Model)
	local folder = Instance.new("Folder")
	folder.Name = "ThreePointContest"
	folder.Parent = root
	local center = courtCenter(m)
	local floorY = center.Y + 0.45
	local lanes: { Lane } = {}
	for _, side in { "North", "South" } do
		local rim = rimOf(m, side)
		if rim then
			local dz = if center.Z > rim.Z then 1 else -1
			local lane: Lane = { side = side, rim = rim, spots = {}, turn = nil }
			for i, deg in THREE.SPOT_ANGLES do
				local a = math.rad(deg)
				local dir = Vector3.new(math.cos(a), 0, math.sin(a) * dz)
				local pos = Vector3.new(rim.X, floorY, rim.Z) + dir * THREE.SPOT_RADIUS
				local marker = part({
					name = "Spot" .. i,
					size = Vector3.new(0.12, 4, 4),
					cframe = CFrame.new(pos + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, 0, math.pi / 2),
					color = Color3.fromRGB(255, 160, 40),
					material = Enum.Material.Neon,
					shape = Enum.PartType.Cylinder,
					collide = false,
					parent = folder,
				})
				local rackPos = pos + dir * 2.8
				local rack = part({
					name = "Rack",
					size = Vector3.new(1.4, 1.6, 3.6),
					cframe = CFrame.lookAt(rackPos + Vector3.new(0, 0.8, 0), rackPos + Vector3.new(0, 0.8, 0) + dir) * CFrame.Angles(0, math.pi / 2, 0),
					color = Color3.fromRGB(35, 35, 40),
					material = Enum.Material.Metal,
					collide = false,
					parent = folder,
				})
				local balls = {}
				for b = 1, THREE.BALLS_PER_RACK do
					local money = b == THREE.BALLS_PER_RACK
					local offset = (b - (THREE.BALLS_PER_RACK + 1) / 2) * 1.15
					local ballPart = part({
						name = if money then "MoneyBall" else "RackBall",
						size = Vector3.one * 1.1,
						cframe = rack.CFrame * CFrame.new(0, 1.2, offset),
						color = if money then Color3.fromRGB(255, 215, 70) else Color3.fromRGB(230, 110, 30),
						material = if money then Enum.Material.Neon else Enum.Material.Rubber,
						shape = Enum.PartType.Ball,
						collide = false,
						parent = folder,
					})
					table.insert(balls, ballPart)
				end
				table.insert(lane.spots, { pos = pos, left = THREE.BALLS_PER_RACK, balls = balls, marker = marker })
			end
			table.insert(lanes, lane)
		end
	end
	-- a banner over the court so spectators know what's happening
	local banner = part({
		name = "Banner",
		size = Vector3.new(26, 4, 0.4),
		cframe = CFrame.new(center + Vector3.new(0, 18, 0)),
		color = Color3.fromRGB(20, 20, 26),
		collide = false,
		parent = folder,
	})
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		surfaceText(banner, face, "🏀 3-POINT CONTEST", Color3.fromRGB(255, 170, 60))
	end
	ev.data = {
		folder = folder,
		lanes = lanes,
		queue = {} :: { Player },
		done = {} :: { Turn },
		entrants = 0,
		graceUntil = nil :: number?,
	}
end

local function endTurn(ev: Event, lane: Lane, reason: string?)
	local turn = lane.turn
	if not turn then
		return
	end
	lane.turn = nil
	turn.ended = true
	turn.timeUsed = math.clamp(now() - turn.readyAt, 0, THREE.TURN)
	-- a ball still in hand when the buzzer goes doesn't count
	for ball, info in eventBalls do
		if info.turn == turn and ball.holder then
			eventBalls[ball] = nil
			Basketball.destroy(ball)
		end
	end
	table.insert(ev.data.done, turn)
	if turn.player.Parent then
		Basketball.announce({ turn.player }, string.format("%d POINTS", turn.score))
		if reason then
			Net.notify(turn.player, "TURN OVER", reason)
		end
	end
	refillSpots(lane)
	markDirty()
end

local function startTurn(lane: Lane, player: Player)
	local held = Basketball.heldBall(player)
	if held then
		Basketball.drop(held)
	end
	refillSpots(lane)
	local t = now()
	lane.turn = {
		player = player,
		name = player.DisplayName,
		readyAt = t + THREE.READY,
		endsAt = t + THREE.READY + THREE.TURN,
		endClock = os.clock() + THREE.READY + THREE.TURN,
		score = 0,
		made = 0,
		shots = 0,
		awaySince = nil,
		timeUsed = 0,
		ended = false,
	}
	local first = lane.spots[1]
	local character = player.Character
	if first and character then
		local stand = first.pos + Vector3.new(0, 3, 0)
		character:PivotTo(CFrame.lookAt(stand, Vector3.new(lane.rim.X, stand.Y, lane.rim.Z)))
	end
	Basketball.announce({ player }, "YOUR TURN! 60 SECONDS")
	Net.notify(player, "YOUR TURN", "Walk onto each orange spot to get its rack. Gold = money ball (2 pts).")
	markDirty()
end

local function tickThree(ev: Event)
	local m = court
	if not m then
		cancelEvent(ev, "The court is gone.")
		return
	end
	local d = ev.data
	local t = now()

	if ev.state == "Checkin" then
		if t < ev.phaseEndsAt then
			return
		end
		-- whoever is on the court (and not in a pickup game) shoots, in sign-up order
		for _, p in table.clone(ev.registered) do
			if p.Parent and onCourt(m, p, 6) and not p:GetAttribute("InGame") then
				table.insert(d.queue, p)
			else
				local i = table.find(ev.registered, p)
				if i then
					table.remove(ev.registered, i)
				end
				setEventAttr(p, nil)
				Net.notify(p, "MISSED CHECK-IN", "You weren't on the court when the 3-Point Contest started.")
			end
		end
		d.entrants = #d.queue
		if #d.queue == 0 then
			cancelEvent(ev, "No shooters showed up at the court.")
			return
		end
		ev.state = "Running"
		ev.phase = "Shooting"
		ev.phaseEndsAt = 0
		markDirty()
		return
	end

	-- Running: two shooters at once, one per hoop.
	for _, lane in d.lanes do
		local turn = lane.turn
		if turn then
			local p = turn.player
			local humanoid = humanoidOf(p)
			if not p.Parent or not isRegistered(ev, p) then
				endTurn(ev, lane, nil)
			elseif not humanoid or humanoid.Health <= 0 then
				endTurn(ev, lane, "You went down mid-turn.")
			elseif p:GetAttribute("InGame") then
				endTurn(ev, lane, "You joined a pickup game, so your turn ended.")
			else
				if not onCourt(m, p, 8) then
					turn.awaySince = turn.awaySince or t
					if t - (turn.awaySince :: number) > 5 then
						endTurn(ev, lane, "You left the court.")
						continue
					end
				else
					turn.awaySince = nil
				end
				if t >= turn.endsAt then
					endTurn(ev, lane, "Time!")
					continue
				end
				if t >= turn.readyAt then
					local held = Basketball.heldBall(p)
					if held and not eventBalls[held] then
						Basketball.drop(held) -- only rack balls count
						held = nil
					end
					local r = rootOf(p)
					if not held and r then
						for _, spot in lane.spots do
							if spot.left > 0 and flatDist(r.Position, spot.pos) <= THREE.SPOT_REACH then
								local money = spot.left == 1
								spot.left -= 1
								spot.balls[THREE.BALLS_PER_RACK - spot.left].Transparency = 1
								local ball = Basketball.newBall(spot.pos + Vector3.new(0, 3, 0))
								ball.owner = p
								eventBalls[ball] = { lane = lane, turn = turn, player = p, money = money }
								Basketball.give(ball, p)
								turn.shots += 1
								if money then
									Basketball.announce({ p }, "MONEY BALL")
								end
								break
							end
						end
					end
					-- every rack used and nothing left in the air: turn complete
					local remaining = 0
					for _, spot in lane.spots do
						remaining += spot.left
					end
					if remaining == 0 then
						local inPlay = false
						for _, info in eventBalls do
							if info.turn == turn then
								inPlay = true
								break
							end
						end
						if not inPlay then
							endTurn(ev, lane, "All 15 balls shot.")
							continue
						end
					end
				end
			end
		end
		if not lane.turn then
			-- next shooter in line who is still around and on the court
			while #d.queue > 0 and not lane.turn do
				local p = table.remove(d.queue, 1) :: Player
				if p.Parent and isRegistered(ev, p) then
					if onCourt(m, p, 30) then
						startTurn(lane, p)
					else
						Net.notify(p, "SKIPPED", "You weren't near the court when your turn came up.")
						table.insert(d.done, {
							player = p,
							name = p.DisplayName,
							readyAt = t,
							endsAt = t,
							endClock = 0,
							score = 0,
							made = 0,
							shots = 0,
							timeUsed = THREE.TURN,
							ended = true,
						})
					end
				end
			end
		end
	end

	local busy = #d.queue > 0
	for _, lane in d.lanes do
		if lane.turn then
			busy = true
		end
	end
	if busy then
		d.graceUntil = nil
		return
	end
	-- let the last shots land before ranking
	if not d.graceUntil then
		d.graceUntil = t + 3
		return
	end
	if t < d.graceUntil then
		return
	end

	local turns = table.clone(d.done)
	table.sort(turns, function(a: Turn, b: Turn)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.timeUsed < b.timeUsed
	end)
	local ranked, lines = {}, {}
	for place, turn in turns do
		if turn.player.Parent and isRegistered(ev, turn.player) then
			table.insert(ranked, turn.player)
			local sec = section(turn.player)
			if sec and turn.score > sec.best3pt then
				sec.best3pt = turn.score
				PlayerData.markChanged(turn.player)
				Net.notify(turn.player, "PERSONAL BEST", string.format("New 3-Point Contest best: %d points.", turn.score))
			end
		end
		if place <= 5 then
			table.insert(lines, string.format("%d. %s — %d pts (%d/%d)", place, turn.name, turn.score, turn.made, turn.shots))
		end
	end
	local scores = {}
	for _, turn in turns do
		scores[turn.player] = turn.score
	end
	payPodium(ev, ranked, d.entrants, function(p: Player)
		return (scores[p] or 0) > 0
	end)
	pushResult(ev, lines, turns[1] and turns[1].name or nil)
	if turns[1] then
		Basketball.announce(ranked, turns[1].name:upper() .. " WINS THE 3-POINT CONTEST")
	end
	closeEvent(ev)
end

cleanupByKind.ThreePoint = function(ev: Event)
	local d = ev.data
	if d and d.lanes then
		for _, lane in d.lanes do
			lane.turn = nil
		end
	end
	for ball, info in eventBalls do
		if d and table.find(d.lanes, info.lane) then
			eventBalls[ball] = nil
			Basketball.destroy(ball)
		end
	end
	if d and d.folder then
		d.folder:Destroy()
	end
	if court then
		court:SetAttribute("Event", nil)
		court:SetAttribute("EventName", nil)
	end
end

local function liveThree(ev: Event, viewer: Player): any
	local d = ev.data
	local lines, status = {}, ""
	local you: Turn? = nil
	if ev.state == "Checkin" then
		local here = 0
		for _, p in ev.registered do
			if court and onCourt(court, p, 6) then
				here += 1
			end
		end
		table.insert(lines, string.format("%d / %d shooters on the court", here, #ev.registered))
		status = if isRegistered(ev, viewer)
			then (if court and onCourt(court, viewer, 6) then "You're checked in. Wait for your turn." else "Get onto the Neighborhood Court!")
			else "Check-in is open"
	else
		for _, lane in d.lanes do
			local turn = lane.turn
			if turn then
				local left = 0
				for _, spot in lane.spots do
					left += spot.left
				end
				local clock = if now() < turn.readyAt then "ready" else EC.formatIn(turn.endsAt - now())
				table.insert(lines, string.format("%s hoop: %s · %d pts · %d balls · %s", lane.side, turn.name, turn.score, left, clock))
				if turn.player == viewer then
					you = turn
				end
			end
		end
		local board = table.clone(d.done)
		table.sort(board, function(a: Turn, b: Turn)
			return a.score > b.score
		end)
		for i = 1, math.min(3, #board) do
			table.insert(lines, string.format("#%d %s — %d", i, board[i].name, board[i].score))
		end
		if #d.queue > 0 then
			local names = {}
			for i = 1, math.min(3, #d.queue) do
				table.insert(names, d.queue[i].DisplayName)
			end
			table.insert(lines, "Up next: " .. table.concat(names, ", "))
		end
		if you then
			status = if now() < you.readyAt then "Get ready…" else string.format("YOUR TURN · %d pts · %s left", you.score, EC.formatIn(you.endsAt - now()))
		elseif table.find(d.queue, viewer) then
			status = string.format("You're #%d in line", table.find(d.queue, viewer) :: number)
		elseif isRegistered(ev, viewer) then
			status = "Done shooting. Waiting for results."
		else
			status = "Watching"
		end
	end
	return {
		lines = lines,
		status = status,
		endsAt = if you then you.endsAt elseif ev.state == "Checkin" then ev.phaseEndsAt else 0,
		highlight = you ~= nil,
	}
end

---------------------------------------------------------------------------
-- CITY 5K
---------------------------------------------------------------------------
local ROUTE = RUN.ROUTE

local function legDistance(fromIndex: number, toIndex: number): number
	return flatDist(ROUTE[fromIndex], ROUTE[toIndex])
end

local function buildRunVenue(ev: Event)
	local folder = Instance.new("Folder")
	folder.Name = "City5K"
	folder.Parent = root
	for i, pos in ROUTE do
		local nextPos = ROUTE[i % #ROUTE + 1]
		local prevPos = ROUTE[if i == 1 then #ROUTE else i - 1]
		local heading = flat(nextPos - prevPos)
		heading = if heading.Magnitude > 0.1 then heading.Unit else Vector3.new(1, 0, 0)
		local side = Vector3.new(-heading.Z, 0, heading.X)
		local isStart = i == 1
		local color = if isStart then Color3.fromRGB(80, 255, 140) else Color3.fromRGB(255, 80, 200)
		local m = Instance.new("Model")
		m.Name = "Gate" .. i
		m.Parent = folder
		local width = if isStart then 16 else 12
		local height = if isStart then 14 else 11
		for _, s in { -1, 1 } do
			part({ name = "Post", size = Vector3.new(1, height, 1), cframe = CFrame.new(pos + side * (width / 2) * s + Vector3.new(0, height / 2, 0)), color = color, material = Enum.Material.Neon, collide = false, parent = m })
		end
		local bar = part({
			name = "Banner",
			size = Vector3.new(width + 1, 2.6, 0.6),
			cframe = CFrame.lookAt(pos + Vector3.new(0, height, 0), pos + Vector3.new(0, height, 0) + heading),
			color = Color3.fromRGB(20, 20, 26),
			collide = false,
			parent = m,
		})
		local text = if isStart then "CITY 5K · START / FINISH" else "5K · CHECKPOINT " .. (i - 1)
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			surfaceText(bar, face, text, color)
		end
		if isStart then
			-- start box on the ground
			part({
				name = "StartBox",
				size = Vector3.new(0.1, RUN.START_RADIUS * 2, RUN.START_RADIUS * 2),
				cframe = CFrame.new(pos + Vector3.new(0, 0.55, 0)) * CFrame.Angles(0, 0, math.pi / 2),
				color = color,
				material = Enum.Material.Neon,
				transparency = 0.6,
				shape = Enum.PartType.Cylinder,
				collide = false,
				parent = m,
			})
		end
	end
	ev.data = {
		folder = folder,
		racers = {} :: { Racer },
		goAt = 0,
		entrants = 0,
		started = false,
	}
end

local function racerRank(d: any): { Racer }
	local list = {}
	for _, racer in d.racers do
		table.insert(list, racer)
	end
	table.sort(list, function(a: Racer, b: Racer)
		if (a.out ~= nil) ~= (b.out ~= nil) then
			return a.out == nil
		end
		if a.finished ~= b.finished then
			return a.finished
		end
		if a.finished then
			return a.time < b.time
		end
		if a.passed ~= b.passed then
			return a.passed > b.passed
		end
		local ra, rb = rootOf(a.player), rootOf(b.player)
		local da = if ra then flatDist(ra.Position, ROUTE[a.nextIndex]) else math.huge
		local db = if rb then flatDist(rb.Position, ROUTE[b.nextIndex]) else math.huge
		return da < db
	end)
	return list
end

local function knockOut(racer: Racer, reason: string)
	if racer.out or racer.finished then
		return
	end
	racer.out = reason
	if racer.player.Parent then
		Net.notify(racer.player, "OUT OF THE 5K", reason)
	end
	markDirty()
end

local function onFoot(player: Player): boolean
	local humanoid = humanoidOf(player)
	return humanoid ~= nil and humanoid.SeatPart == nil and (player:GetAttribute("Driving") or "") == ""
end

local function tickRun(ev: Event)
	local d = ev.data
	local t = now()
	local start = ROUTE[1]

	if ev.state == "Checkin" then
		if t < ev.phaseEndsAt then
			return
		end
		for _, p in table.clone(ev.registered) do
			local r = rootOf(p)
			if p.Parent and r and flatDist(r.Position, start) <= RUN.START_RADIUS + 2 and onFoot(p) then
				table.insert(d.racers, {
					player = p,
					name = p.DisplayName,
					nextIndex = 2,
					passed = 0,
					legStart = 0,
					samples = {},
					lastSample = 0,
					finished = false,
					time = 0,
					out = nil,
				})
			else
				local i = table.find(ev.registered, p)
				if i then
					table.remove(ev.registered, i)
				end
				setEventAttr(p, nil)
				Net.notify(p, "MISSED THE START", "You weren't on foot in the start box when the 5K began.")
			end
		end
		d.entrants = #d.racers
		if #d.racers == 0 then
			cancelEvent(ev, "No runners were in the start box.")
			return
		end
		ev.state = "Running"
		ev.phase = "Starting"
		d.goAt = t + RUN.COUNTDOWN
		ev.phaseEndsAt = d.goAt
		local runners = {}
		for _, racer in d.racers do
			racer.legStart = d.goAt
			table.insert(runners, racer.player)
		end
		Basketball.announce(runners, "ON YOUR MARKS…")
		markDirty()
		return
	end

	if not d.started then
		if t < d.goAt then
			return
		end
		d.started = true
		ev.phase = "Racing"
		ev.phaseEndsAt = d.goAt + RUN.TIME_LIMIT
		local runners = {}
		for _, racer in d.racers do
			table.insert(runners, racer.player)
		end
		Basketball.announce(runners, "GO!")
		markDirty()
	end

	local clock = os.clock()
	local active = 0
	for _, racer in d.racers do
		if racer.out or racer.finished then
			continue
		end
		local p = racer.player
		local humanoid = humanoidOf(p)
		local r = rootOf(p)
		if not p.Parent or not isRegistered(ev, p) then
			knockOut(racer, "You left the race.")
			continue
		elseif not humanoid or humanoid.Health <= 0 or not r then
			knockOut(racer, "You went down. DNF.")
			continue
		elseif not onFoot(p) then
			knockOut(racer, "Vehicles and seats aren't allowed in the 5K. DQ.")
			continue
		end
		active += 1
		local pos = r.Position

		-- teleport / speed check against a sample at least 1.5 s old
		if clock - racer.lastSample >= 0.25 then
			racer.lastSample = clock
			table.insert(racer.samples, { t = clock, pos = pos })
			while #racer.samples > 0 and clock - racer.samples[1].t > 3 do
				table.remove(racer.samples, 1)
			end
			local old = racer.samples[1]
			if old and clock - old.t >= 1.5 then
				local moved = flatDist(pos, old.pos)
				if moved > RUN.MAX_SPEED * (clock - old.t) + 12 or math.abs(pos.Y - old.pos.Y) > 60 then
					knockOut(racer, "You moved impossibly fast. DQ.")
					active -= 1
					continue
				end
			end
		end

		local target = ROUTE[racer.nextIndex]
		if flatDist(pos, target) <= RUN.GATE_RADIUS and math.abs(pos.Y - target.Y) < 14 then
			local prev = if racer.nextIndex == 1 then #ROUTE else racer.nextIndex - 1
			local minTime = legDistance(prev, racer.nextIndex) / RUN.MAX_SPEED
			if t - racer.legStart < minTime then
				knockOut(racer, "That checkpoint was reached impossibly fast. DQ.")
				active -= 1
				continue
			end
			racer.legStart = t
			racer.passed += 1
			if racer.nextIndex == 1 then
				racer.finished = true
				racer.time = math.floor((t - d.goAt) * 10) / 10
				active -= 1
				Basketball.announce({ p }, "FINISHED " .. EC.formatTime(racer.time))
				markDirty()
			else
				racer.nextIndex = if racer.nextIndex == #ROUTE then 1 else racer.nextIndex + 1
			end
		end
	end

	if active > 0 and t < ev.phaseEndsAt then
		return
	end
	for _, racer in d.racers do
		if not racer.finished and not racer.out then
			knockOut(racer, "Time's up. DNF.")
		end
	end

	local ranked, lines = {}, {}
	local finishers = {}
	for _, racer in racerRank(d) do
		if racer.finished then
			table.insert(finishers, racer)
		end
	end
	for place, racer in finishers do
		local p = racer.player
		if p.Parent then
			table.insert(ranked, p)
			PlayerData.addStatXP(p, "Stamina", 30)
			PlayerData.addStatXP(p, "Speed", 15)
			local sec = section(p)
			if sec and (sec.best5k == 0 or racer.time < sec.best5k) then
				sec.best5k = racer.time
				PlayerData.markChanged(p)
				Net.notify(p, "PERSONAL BEST", "New City 5K best: " .. EC.formatTime(racer.time))
			end
		end
		if place <= 5 then
			table.insert(lines, string.format("%d. %s — %s", place, racer.name, EC.formatTime(racer.time)))
		end
	end
	if #finishers == 0 then
		table.insert(lines, "Nobody finished the course.")
	end
	payPodium(ev, ranked, d.entrants, function()
		return true
	end)
	pushResult(ev, lines, finishers[1] and finishers[1].name or nil)
	closeEvent(ev)
end

cleanupByKind.City5K = function(ev: Event)
	if ev.data and ev.data.folder then
		ev.data.folder:Destroy()
	end
end

local function liveRun(ev: Event, viewer: Player): any
	local d = ev.data
	local lines = {}
	local status = ""
	local gps = nil
	local timerFrom = 0
	if ev.state == "Checkin" then
		local here = 0
		for _, p in ev.registered do
			local r = rootOf(p)
			if r and flatDist(r.Position, ROUTE[1]) <= RUN.START_RADIUS + 2 then
				here += 1
			end
		end
		table.insert(lines, string.format("%d / %d runners in the start box", here, #ev.registered))
		local r = rootOf(viewer)
		status = if not isRegistered(ev, viewer)
			then "Check-in is open"
			elseif r and flatDist(r.Position, ROUTE[1]) <= RUN.START_RADIUS + 2 then "In the start box. Stay on foot!"
			else "Get to the start arch (on foot)!"
		gps = { name = "5K Start", pos = ROUTE[1] }
	else
		local ranked = racerRank(d)
		for i, racer in ranked do
			if i <= 5 then
				local detail = if racer.out
					then "out"
					elseif racer.finished then EC.formatTime(racer.time)
					else string.format("CP %d/%d", racer.passed, #ROUTE)
				table.insert(lines, string.format("%d. %s — %s", i, racer.name, detail))
			end
			if racer.player == viewer then
				if racer.out then
					status = racer.out
				elseif racer.finished then
					status = string.format("Finished #%d in %s", i, EC.formatTime(racer.time))
				elseif not d.started then
					status = "Get ready…"
				else
					local label = if racer.nextIndex == 1 then "FINISH" else "Checkpoint " .. (racer.nextIndex - 1)
					status = string.format("Position %d/%d · next: %s", i, #ranked, label)
					gps = { name = "5K " .. label, pos = ROUTE[racer.nextIndex], index = racer.nextIndex }
					timerFrom = d.goAt
				end
			end
		end
		if status == "" then
			status = if d.started then "Watching the race" else "Starting…"
		end
	end
	return {
		lines = lines,
		status = status,
		endsAt = ev.phaseEndsAt,
		gps = gps,
		timerFrom = timerFrom,
	}
end

---------------------------------------------------------------------------
-- CAR MEET
---------------------------------------------------------------------------
local function buildMeetLot(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "CarMeetLot"
	folder.Parent = parent
	local c = MEET.LOT_CENTER
	local size = MEET.LOT_SIZE
	part({ name = "Lot", size = Vector3.new(size.X, 0.3, size.Z), cframe = CFrame.new(c + Vector3.new(0, 0.15, 0)), color = Color3.fromRGB(48, 48, 54), material = Enum.Material.Asphalt, parent = folder })
	local white = Color3.fromRGB(235, 235, 235)
	local bayW, bayL = MEET.BAY_SIZE.X, MEET.BAY_SIZE.Z
	local index = 0
	for _, row in { -1, 1 } do
		local rowZ = c.Z + row * (bayL / 2 + 6)
		for i = -2, 2 do
			index += 1
			local center = Vector3.new(c.X + i * (bayW + 1), c.Y, rowZ)
			-- side lines
			for _, s in { -1, 1 } do
				part({ name = "BayLine", size = Vector3.new(0.4, 0.05, bayL), cframe = CFrame.new(center + Vector3.new(s * (bayW / 2 + 0.5), 0.33, 0)), color = white, collide = false, parent = folder })
			end
			-- back line (far from the aisle) and a glow strip that lights up during meets
			local backZ = center.Z + row * (bayL / 2)
			part({ name = "BayLine", size = Vector3.new(bayW + 1.4, 0.05, 0.4), cframe = CFrame.new(Vector3.new(center.X, c.Y + 0.33, backZ)), color = white, collide = false, parent = folder })
			local glow = part({
				name = "BayGlow",
				size = Vector3.new(bayW - 1, 0.06, 0.6),
				cframe = CFrame.new(Vector3.new(center.X, c.Y + 0.34, backZ - row * 1)),
				color = Color3.fromRGB(70, 70, 80),
				material = Enum.Material.SmoothPlastic,
				collide = false,
				parent = folder,
			})
			local plate = part({
				name = "BayNumber",
				size = Vector3.new(4, 0.05, 2.4),
				cframe = CFrame.new(Vector3.new(center.X, c.Y + 0.33, backZ - row * 3)),
				color = Color3.fromRGB(48, 48, 54),
				collide = false,
				parent = folder,
			})
			plate.Transparency = 1
			local label = surfaceText(plate, Enum.NormalId.Top, tostring(index), white, 30)
			table.insert(meetBays, { index = index, center = center, glow = glow, plate = label })
		end
	end
	-- welcome arch facing the main road
	local gateZ = c.Z - size.Z / 2 - 1
	local gateColor = Color3.fromRGB(150, 90, 255)
	for _, s in { -1, 1 } do
		part({ name = "ArchPost", size = Vector3.new(1, 12, 1), cframe = CFrame.new(Vector3.new(c.X + s * 14, c.Y + 6, gateZ)), color = gateColor, material = Enum.Material.Neon, collide = false, parent = folder })
	end
	local banner = part({ name = "ArchBanner", size = Vector3.new(29, 3, 0.5), cframe = CFrame.new(Vector3.new(c.X, c.Y + 12, gateZ)), color = Color3.fromRGB(20, 20, 26), collide = false, parent = folder })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		surfaceText(banner, face, "🚗 CITY CAR MEET LOT", gateColor)
	end
	Places.mapPoint(parent.Parent or parent, "Car Meet Lot", "Event", c + Vector3.new(0, 3, -size.Z / 2 - 4))
end

local function setBayGlow(lit: boolean)
	for _, bay in meetBays do
		bay.glow.Material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
		bay.glow.Color = if lit then Color3.fromRGB(150, 90, 255) else Color3.fromRGB(70, 70, 80)
	end
end

local function vehicleOf(player: Player): Model?
	for _, m in CollectionService:GetTagged("CityVehicle") do
		if m:IsA("Model") and m:GetAttribute("Owner") == player.UserId and m.Parent then
			return m
		end
	end
	return nil
end

local function bayAt(pos: Vector3): Bay?
	for _, bay in meetBays do
		local offset = pos - bay.center
		if math.abs(offset.X) <= MEET.BAY_SIZE.X / 2 + 0.5 and math.abs(offset.Z) <= MEET.BAY_SIZE.Z / 2 + 0.5 and math.abs(offset.Y) < 10 then
			return bay
		end
	end
	return nil
end

local function describeVehicle(m: Model): { vehicle: string, paint: string, rim: string, glow: string }
	local spec = VC.byId[m:GetAttribute("VehicleId") or ""]
	local paint = VC.PAINTS[m:GetAttribute("Paint") or 0]
	local rim = VC.RIMS[m:GetAttribute("Rim") or 0]
	local glow = VC.GLOWS[m:GetAttribute("Glow") or 0]
	return {
		vehicle = if spec then spec.name else m.Name,
		paint = if paint then paint.name else "Stock",
		rim = if rim then rim.name else "Stock",
		glow = if glow then glow.name else "None",
	}
end

local function startMeet(ev: Event)
	setBayGlow(true)
	ev.data = {
		parked = {} :: { [Player]: Bay },
		candidates = {} :: { any },
		votes = {} :: { [number]: { [string]: number } },
		attendees = {} :: { Player },
	}
end

local function refreshBayPlates(ev: Event?)
	for _, bay in meetBays do
		if bay.plate then
			bay.plate.Text = tostring(bay.index)
			bay.plate.TextColor3 = Color3.fromRGB(235, 235, 235)
		end
	end
	if ev and ev.data and ev.data.parked then
		for _, bay in ev.data.parked do
			if bay.plate then
				bay.plate.TextColor3 = Color3.fromRGB(120, 255, 140)
			end
		end
	end
end

local function voteCandidates(ev: Event, voter: Player): any
	local list = {}
	for _, c in ev.data.candidates do
		table.insert(list, c)
	end
	return {
		id = ev.id,
		name = ev.name,
		endsAt = ev.phaseEndsAt,
		categories = MEET.CATEGORIES,
		candidates = list,
		mine = ev.data.votes[voter.UserId] or {},
		you = voter.UserId,
	}
end

local function tickMeet(ev: Event)
	local d = ev.data
	local t = now()

	if ev.state == "Checkin" then
		-- Track who is parked in which bay right now.
		local taken: { [Bay]: Player } = {}
		for p, bay in d.parked do
			taken[bay] = p
		end
		local changed = false
		for _, p in ev.registered do
			local m = vehicleOf(p)
			local chassis = m and m.PrimaryPart
			local bay = nil
			if chassis then
				local still = chassis.Anchored or chassis.AssemblyLinearVelocity.Magnitude <= MEET.MAX_PARK_SPEED
				local here = bayAt(chassis.Position)
				if here and still and (taken[here] == nil or taken[here] == p) then
					bay = here
				end
			end
			if d.parked[p] ~= bay then
				if d.parked[p] then
					taken[d.parked[p]] = nil
				end
				d.parked[p] = bay
				if bay then
					taken[bay] = p
					Net.notify(p, "PARKED", "You're in bay " .. bay.index .. ". Stay put until voting opens.")
				end
				changed = true
			end
		end
		for p in d.parked do
			if not isRegistered(ev, p) then
				d.parked[p] = nil
				changed = true
			end
		end
		if changed then
			refreshBayPlates(ev)
			markDirty()
		end
		if t < ev.phaseEndsAt then
			return
		end

		-- Gathering over: parked cars become the line-up.
		local lineup = {}
		for p, bay in d.parked do
			local m = vehicleOf(p)
			if p.Parent and m then
				table.insert(lineup, { player = p, bay = bay, model = m })
			end
		end
		table.sort(lineup, function(a, b)
			return a.bay.index < b.bay.index
		end)
		for _, p in table.clone(ev.registered) do
			if not d.parked[p] then
				local i = table.find(ev.registered, p)
				if i then
					table.remove(ev.registered, i)
				end
				setEventAttr(p, nil)
				Net.notify(p, "NOT PARKED", "Your ride wasn't parked in a bay when the Car Meet line-up closed.")
			end
		end
		if #lineup < 2 then
			cancelEvent(ev, "A meet needs at least 2 parked cars.")
			return
		end
		for _, entry in lineup do
			local info = describeVehicle(entry.model)
			table.insert(d.candidates, {
				userId = entry.player.UserId,
				name = entry.player.DisplayName,
				bay = entry.bay.index,
				vehicle = info.vehicle,
				paint = info.paint,
				rim = info.rim,
				glow = info.glow,
			})
			table.insert(d.attendees, entry.player)
		end
		ev.state = "Voting"
		ev.phase = "Voting"
		ev.phaseEndsAt = t + MEET.VOTE
		for _, p in d.attendees do
			Update:FireClient(p, "Vote", voteCandidates(ev, p))
			Net.notify(p, "VOTING OPEN", "Vote Best Car, Best Colour and Best Customization. You can't vote for yourself.")
		end
		markDirty()
		return
	end

	-- Voting: ends on time, or a moment after every attendee has voted in every category.
	local everyone = true
	for _, p in d.attendees do
		if p.Parent then
			local mine = d.votes[p.UserId]
			for _, cat in MEET.CATEGORIES do
				if not mine or not mine[cat] then
					everyone = false
				end
			end
		end
	end
	if everyone and ev.phaseEndsAt - t > 3 then
		ev.phaseEndsAt = t + 3
		markDirty()
	end
	if t < ev.phaseEndsAt then
		return
	end

	local present: { [number]: Player } = {}
	for _, p in d.attendees do
		if p.Parent and isRegistered(ev, p) then
			present[p.UserId] = p
		end
	end
	local lines = {}
	local firstWinner = nil
	for _, cat in MEET.CATEGORIES do
		local tally: { [number]: number } = {}
		for voterId, mine in d.votes do
			local target = mine[cat]
			if present[voterId] and target and target ~= voterId and present[target] then
				tally[target] = (tally[target] or 0) + 1
			end
		end
		local best, bestVotes = nil, 0
		for _, c in d.candidates do -- candidates are in bay order: the lower bay wins a tie
			local v = tally[c.userId] or 0
			if v > bestVotes then
				best, bestVotes = c, v
			end
		end
		if best then
			local winner = present[best.userId]
			table.insert(lines, string.format("%s: %s (%s) · %d vote%s", cat, best.name, best.vehicle, bestVotes, if bestVotes == 1 then "" else "s"))
			firstWinner = firstWinner or best.name
			if winner then
				local reward = EC.KINDS.CarMeet.podium[1]
				give(winner, reward, "Car Meet: " .. cat)
				PlayerData.addFame(winner, EC.FAME_PER_CAR_AWARD)
				local sec = section(winner)
				if sec then
					sec.carAwards += 1
					sec.podiums += 1
					PlayerData.markChanged(winner)
				end
				Net.notify(winner, cat:upper() .. "!", string.format("Your %s won %s at the Car Meet. %s · +%d fame", best.vehicle, cat, EC.rewardText(reward), EC.FAME_PER_CAR_AWARD))
			end
		else
			table.insert(lines, cat .. ": no votes")
		end
	end
	for _, p in present do
		give(p, EC.KINDS.CarMeet.finisher, "Car Meet attendance")
		Net.notify(p, "CAR MEET RESULTS", table.concat(lines, "\n"))
		Update:FireClient(p, "VoteClosed", ev.id)
	end
	pushResult(ev, lines, firstWinner)
	closeEvent(ev)
end

cleanupByKind.CarMeet = function(ev: Event)
	setBayGlow(false)
	refreshBayPlates(nil)
	if ev.data and ev.data.attendees then
		for _, p in ev.data.attendees do
			if p.Parent then
				Update:FireClient(p, "VoteClosed", ev.id)
			end
		end
	end
end

local function liveMeet(ev: Event, viewer: Player): any
	local d = ev.data
	local lines, status = {}, ""
	if ev.state == "Checkin" then
		local count = 0
		for p, bay in d.parked do
			count += 1
			if count <= 5 then
				local m = vehicleOf(p)
				table.insert(lines, string.format("Bay %d: %s%s", bay.index, p.DisplayName, if m then " · " .. describeVehicle(m).vehicle else ""))
			end
		end
		table.insert(lines, 1, string.format("%d / %d cars parked", count, #meetBays))
		if isRegistered(ev, viewer) then
			if d.parked[viewer] then
				status = "Parked in bay " .. d.parked[viewer].index .. ". Stay put!"
			elseif vehicleOf(viewer) then
				status = "Drive into an open bay and stop."
			else
				status = "Spawn your ride (Garage app) and park in a bay."
			end
		else
			status = "Line-up is filling"
		end
	else
		local voted = 0
		for _, p in d.attendees do
			local mine = d.votes[p.UserId]
			if mine and mine[MEET.CATEGORIES[#MEET.CATEGORIES]] then
				voted += 1
			end
		end
		table.insert(lines, string.format("%d / %d attendees voted", voted, #d.attendees))
		for _, c in d.candidates do
			if #lines < 6 then
				table.insert(lines, string.format("Bay %d: %s · %s", c.bay, c.name, c.vehicle))
			end
		end
		status = if table.find(d.attendees, viewer) then "Voting is open" else "Watching the vote"
	end
	return {
		lines = lines,
		status = status,
		endsAt = ev.phaseEndsAt,
		canVote = ev.state == "Voting" and table.find(d.attendees, viewer) ~= nil,
	}
end

---------------------------------------------------------------------------
-- Scheduler
---------------------------------------------------------------------------
local function kindAvailable(kind: string): boolean
	if kind == "ThreePoint" then
		return court ~= nil
	elseif kind == "CarMeet" then
		return #meetBays > 0
	elseif kind == "City5K" then
		return true
	end
	local h = registry[kind]
	if not h or not EC.KINDS[kind] then
		return false -- module missing or failed to load
	end
	if h.available then
		local ok, yes = pcall(h.available)
		return ok and yes == true
	end
	return true
end

local function pickKind(): string
	for _ = 1, 10 do
		if #kindBag == 0 then
			kindBag = table.clone(EC.ORDER)
			for i = #kindBag, 2, -1 do
				local j = rng:NextInteger(1, i)
				kindBag[i], kindBag[j] = kindBag[j], kindBag[i]
			end
			if kindBag[1] == lastKind and #kindBag > 1 then
				kindBag[1], kindBag[2] = kindBag[2], kindBag[1]
			end
		end
		local kind = table.remove(kindBag, 1) :: string
		-- a kind that is already scheduled waits for the next bag, so one
		-- kind never fills the whole upcoming list
		local queued = false
		for _, ev in events do
			if ev.kind == kind then
				queued = true
			end
		end
		if not queued and kindAvailable(kind) then
			lastKind = kind
			return kind
		end
	end
	return "City5K"
end

-- Where a registry kind will happen: (position, location text, venue).
local function venueOf(kind: string): (Vector3?, string?, any)
	local h = registry[kind]
	if h and h.pickVenue then
		local ok, pos, label, venue = pcall(h.pickVenue)
		if ok and typeof(pos) == "Vector3" then
			return pos, label, venue
		end
	end
	return nil, nil, nil
end

local function locationOf(kind: string): Vector3
	if kind == "ThreePoint" and court then
		return courtCenter(court) + Vector3.new(0, 0, courtSize(court).Z / 2 + 8)
	elseif kind == "CarMeet" then
		return MEET.LOT_CENTER + Vector3.new(0, 0, -MEET.LOT_SIZE.Z / 2 - 4)
	end
	return ROUTE[1]
end

local function schedule()
	local upcoming = 0
	for _, ev in events do
		if ev.state == "Upcoming" then
			upcoming += 1
		end
	end
	while upcoming < EC.UPCOMING_COUNT do
		local startsAt = if lastScheduledAt == 0
			then now() + EC.FIRST_EVENT_DELAY
			else math.max(lastScheduledAt + rng:NextInteger(EC.MIN_GAP, EC.MAX_GAP), now() + EC.ANNOUNCE_AHEAD)
		lastScheduledAt = startsAt
		local kind = pickKind()
		local info = EC.KINDS[kind]
		local venuePos, venueLabel, venue = venueOf(kind)
		nextId += 1
		table.insert(events, {
			id = "E" .. nextId,
			kind = kind,
			name = info.name,
			icon = info.icon,
			location = venueLabel or info.location,
			pos = venuePos or locationOf(kind),
			startsAt = startsAt,
			state = "Upcoming",
			phase = "Upcoming",
			phaseEndsAt = startsAt,
			registered = {},
			reminders = {},
			watchers = {},
			announced = false,
			reminded = false,
			postpones = 0,
			venue = venue,
			data = nil,
		})
		upcoming += 1
		markDirty()
	end
	table.sort(events, function(a, b)
		return a.startsAt < b.startsAt
	end)
end

local function postpone(ev: Event, msg: string)
	ev.postpones += 1
	if ev.postpones > EC.MAX_POSTPONES then
		cancelEvent(ev, msg)
		return
	end
	ev.startsAt = now() + EC.POSTPONE_SECONDS
	ev.phaseEndsAt = ev.startsAt
	ev.reminded = false
	for _, p in ev.registered do
		Net.notify(p, ev.name:upper() .. " POSTPONED", msg .. " Trying again in 2 minutes.")
	end
	markDirty()
end

local function goLive(ev: Event)
	local h = registry[ev.kind]
	if h then
		local ok, status, msg = pcall(h.goLive, ev)
		if not ok then
			warn("[CityGrind] Event " .. ev.kind .. " failed to start:", status)
			cancelEvent(ev, "This event couldn't be set up.")
			return
		elseif status == "postpone" then
			postpone(ev, msg or "The venue is busy.")
			return
		elseif status ~= "live" then
			cancelEvent(ev, msg or "This event couldn't be set up.")
			return
		end
	elseif ev.kind == "ThreePoint" then
		local m = court
		if not m then
			cancelEvent(ev, "The court is unavailable.")
			return
		end
		if not courtIdle(m) or m:GetAttribute("Event") then
			ev.postpones += 1
			if ev.postpones > EC.MAX_POSTPONES then
				cancelEvent(ev, "The court stayed busy with pickup games.")
				return
			end
			ev.startsAt = now() + EC.POSTPONE_SECONDS
			ev.phaseEndsAt = ev.startsAt
			ev.reminded = false
			for _, p in ev.registered do
				Net.notify(p, "CONTEST POSTPONED", "A game is on at the court. The 3-Point Contest starts in 2 minutes.")
			end
			markDirty()
			return
		end
		m:SetAttribute("Event", true)
		m:SetAttribute("EventName", ev.name)
		buildThreeVenue(ev, m)
		ev.state = "Checkin"
		ev.phase = "Check-in: get on the court"
		ev.phaseEndsAt = now() + THREE.CHECKIN
	elseif ev.kind == "City5K" then
		buildRunVenue(ev)
		ev.state = "Checkin"
		ev.phase = "Check-in at the start arch"
		ev.phaseEndsAt = now() + RUN.CHECKIN
	else
		startMeet(ev)
		ev.state = "Checkin"
		ev.phase = "Gathering: park in a bay"
		ev.phaseEndsAt = now() + MEET.GATHER
	end
	for _, p in ev.registered do
		setEventAttr(p, ev.id)
		Update:FireClient(p, "Gps", ev.name, ev.pos)
	end
	notifyAll(ev.icon .. " " .. ev.name:upper() .. " STARTING NOW", string.format("At %s. Open the Events app to join or watch.", ev.location))
	markDirty()
end

local TICKS: { [string]: (Event) -> () } = { ThreePoint = tickThree, City5K = tickRun, CarMeet = tickMeet }
local LIVE: { [string]: (Event, Player) -> any } = { ThreePoint = liveThree, City5K = liveRun, CarMeet = liveMeet }

local function tickFn(kind: string): ((Event) -> ())?
	local h = registry[kind]
	return if h then h.tick else TICKS[kind]
end

local function liveFn(kind: string): ((Event, Player) -> any)?
	local h = registry[kind]
	return if h then h.live else LIVE[kind]
end

local function tickSchedule()
	local t = now()
	for _, ev in table.clone(events) do
		if ev.state == "Upcoming" then
			if not ev.announced and t >= ev.startsAt - EC.ANNOUNCE_AHEAD then
				ev.announced = true
				notifyAll(ev.icon .. " " .. ev.name:upper() .. " IN 5 MIN", string.format("At %s. Open the Events app to join.", ev.location))
			end
			if not ev.reminded and t >= ev.startsAt - EC.REMINDER_AHEAD then
				ev.reminded = true
				for p in ev.reminders do
					if p.Parent then
						Net.notify(p, "⏰ EVENT REMINDER", string.format("%s starts in 1 minute at %s.", ev.name, ev.location))
					end
				end
			end
			if t >= ev.startsAt then
				goLive(ev)
			end
		end
	end
	schedule()
end

---------------------------------------------------------------------------
-- Community goal (114)
---------------------------------------------------------------------------
local goal = {
	kind = "points",
	text = "",
	target = 1,
	progress = 0,
	startedAt = 0,
	endsAt = 0,
	done = false,
}
local goalCount = 0

local function newGoal()
	goalCount += 1
	local online = math.max(1, #Players:GetPlayers())
	goal.startedAt = now()
	goal.endsAt = goal.startedAt + EC.GOAL.WINDOW
	goal.progress = 0
	goal.done = false
	if goalCount % 2 == 1 then
		goal.kind = "points"
		goal.target = math.clamp(100 * online, 150, 500)
		goal.text = string.format("Score %d basketball points this hour as a city", goal.target)
	else
		goal.kind = "threes"
		goal.target = math.clamp(20 * online, 25, 100)
		goal.text = string.format("Hit %d three-pointers this hour as a city", goal.target)
	end
	markDirty()
end

local function addGoalProgress(amount: number)
	if goal.done or amount <= 0 or now() > goal.endsAt then
		return
	end
	goal.progress = math.min(goal.target, goal.progress + amount)
	markDirty()
	if goal.progress >= goal.target then
		goal.done = true
		local reward = EC.GOAL.REWARD
		for _, p in Players:GetPlayers() do
			if PlayerData.isLoaded(p) then
				PlayerData.addCash(p, reward.cash, "Community goal reward")
				PlayerData.addXP(p, reward.xp)
				Net.notify(p, "🏙️ COMMUNITY GOAL COMPLETE", string.format("The city did it! Everyone online gets $%d + %d XP.", reward.cash, reward.xp))
			end
		end
	end
end

---------------------------------------------------------------------------
-- Ball rules during the contest. CourtGames owns Basketball.policy; we wrap
-- it so rack balls can only ever be in the hands the server put them in.
---------------------------------------------------------------------------
local function currentShooter(player: Player): boolean
	for _, ev in events do
		if ev.kind == "ThreePoint" and ev.state == "Running" and ev.data then
			for _, lane in ev.data.lanes do
				if lane.turn and lane.turn.player == player then
					return true
				end
			end
		end
	end
	return false
end

local function wrapPolicy()
	local policy = Basketball.policy
	local canHold = policy.canHold
	policy.canHold = function(player, ball)
		if eventBalls[ball] then
			return false -- rack balls are handed out by the contest, never picked up
		end
		if currentShooter(player) then
			return false -- shooters only use their rack
		end
		return canHold(player, ball)
	end
	local canSteal = policy.canSteal
	policy.canSteal = function(player, victim, ball)
		if eventBalls[ball] or currentShooter(victim) or currentShooter(player) then
			return false
		end
		return canSteal(player, victim, ball)
	end
	local passTargets = policy.passTargets
	policy.passTargets = function(player, ball)
		if eventBalls[ball] then
			return {}
		end
		return passTargets(player, ball)
	end
end

local function onScored(ball: any, hoop: any, shot: any)
	if shot and shot.shooter and shot.shooter.Parent then
		if goal.kind == "points" then
			addGoalProgress(shot.points)
		elseif shot.points == 3 then
			addGoalProgress(1)
		end
	end
	local info = eventBalls[ball]
	if not info then
		return
	end
	info.scoredAt = os.clock()
	local turn = info.turn
	if shot and shot.shooter == info.player and shot.points == 3 and hoop.side == info.lane.side and hoop.court == court and shot.at <= turn.endClock + 0.05 then
		local points = if info.money then 2 else 1
		turn.score += points
		turn.made += 1
		if info.player.Parent then
			Basketball.announce({ info.player }, if info.money then "MONEY! +2" else "+1")
		end
		markDirty()
	end
end

local function tickBalls()
	local clock = os.clock()
	local live = Basketball.balls()
	for ball, info in eventBalls do
		if not live[ball] then
			eventBalls[ball] = nil
		elseif ball.holder == nil then
			info.releasedAt = info.releasedAt or clock
			if clock - (info.releasedAt :: number) > 3.5 or (info.scoredAt and clock - info.scoredAt > 1) then
				eventBalls[ball] = nil
				Basketball.destroy(ball)
			end
		elseif ball.holder ~= info.player then
			eventBalls[ball] = nil
			Basketball.destroy(ball)
		end
	end
end

---------------------------------------------------------------------------
-- Discovery billboards (92)
---------------------------------------------------------------------------
local boardLabels: { TextLabel } = {}

local function buildBoards(parent: Instance)
	for _, b in EC.BOARDS do
		local m = Instance.new("Model")
		m.Name = "EventBoard_" .. b.name
		m.Parent = parent
		local face = b.facing
		local pos = b.pos
		for _, x in { -4.6, 4.6 } do
			part({ name = "Leg", size = Vector3.new(0.5, 9, 0.5), cframe = CFrame.new(pos + Vector3.new(x, 4.5, 0)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
		end
		local board = part({
			name = "Board",
			size = Vector3.new(10, 6, 0.4),
			cframe = CFrame.lookAt(pos + Vector3.new(0, 6, 0), pos + Vector3.new(0, 6, face)),
			color = Color3.fromRGB(16, 16, 22),
			parent = m,
		})
		part({ name = "Trim", size = Vector3.new(10.4, 0.3, 0.6), cframe = CFrame.new(pos + Vector3.new(0, 9.1, 0)), color = Color3.fromRGB(255, 120, 60), material = Enum.Material.Neon, collide = false, parent = m })
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 50
		gui.LightInfluence = 0
		gui.Parent = board
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, 0, 0.2, 0)
		title.Text = "CITY EVENTS"
		title.TextColor3 = Color3.fromRGB(255, 140, 60)
		title.Font = Enum.Font.GothamBlack
		title.TextScaled = true
		title.Parent = gui
		local body = Instance.new("TextLabel")
		body.BackgroundTransparency = 1
		body.Position = UDim2.fromScale(0.04, 0.22)
		body.Size = UDim2.fromScale(0.92, 0.64)
		body.Text = ""
		body.TextColor3 = Color3.fromRGB(240, 240, 245)
		body.Font = Enum.Font.GothamBold
		body.TextScaled = true
		body.TextXAlignment = Enum.TextXAlignment.Left
		body.TextYAlignment = Enum.TextYAlignment.Top
		body.Parent = gui
		local foot = Instance.new("TextLabel")
		foot.BackgroundTransparency = 1
		foot.Position = UDim2.fromScale(0, 0.88)
		foot.Size = UDim2.fromScale(1, 0.1)
		foot.Text = "Join from the Events app on your phone"
		foot.TextColor3 = Color3.fromRGB(160, 160, 175)
		foot.Font = Enum.Font.GothamMedium
		foot.TextScaled = true
		foot.Parent = gui
		table.insert(boardLabels, body)
	end
end

local function refreshBoards()
	local t = now()
	local lines = {}
	for _, ev in events do
		if #lines >= 4 then
			break
		end
		local when = if isLive(ev) then "LIVE NOW" else "in " .. EC.formatIn(ev.startsAt - t)
		table.insert(lines, string.format("%s %s · %s · %d/%d", ev.icon, ev.name, when, #ev.registered, EC.KINDS[ev.kind].maxPlayers))
	end
	if goal.endsAt > 0 then
		table.insert(lines, string.format("🏙️ Goal: %d/%d%s", goal.progress, goal.target, if goal.done then " ✓" else ""))
	end
	local text = if #lines > 0 then table.concat(lines, "\n") else "No events scheduled."
	for _, label in boardLabels do
		label.Text = text
	end
end

---------------------------------------------------------------------------
-- Snapshots for the app
---------------------------------------------------------------------------
local function summary(ev: Event, viewer: Player?): any
	local info = EC.KINDS[ev.kind]
	local names = {}
	for i, p in ev.registered do
		if i <= 12 then
			table.insert(names, p.DisplayName)
		end
	end
	local joinable = ev.state == "Upcoming" or ev.state == "Checkin"
	return {
		id = ev.id,
		kind = ev.kind,
		name = ev.name,
		icon = ev.icon,
		location = ev.location,
		position = ev.pos,
		startsAt = ev.startsAt,
		state = ev.state,
		live = isLive(ev),
		phase = ev.phase,
		phaseEndsAt = ev.phaseEndsAt,
		duration = info.duration,
		maxPlayers = info.maxPlayers,
		count = #ev.registered,
		participants = names,
		blurb = info.blurb,
		firstPrize = EC.rewardText(info.podium[1]),
		entryPrize = EC.rewardText(info.finisher),
		postponed = ev.postpones > 0,
		joinable = joinable and #ev.registered < info.maxPlayers,
		joined = viewer ~= nil and isRegistered(ev, viewer),
		reminder = viewer ~= nil and ev.reminders[viewer] == true,
		watching = viewer ~= nil and ev.watchers[viewer] == true,
	}
end

local function snapshot(player: Player): any
	local list = {}
	for _, ev in events do
		table.insert(list, summary(ev, player))
	end
	local sec = section(player)
	return {
		now = now(),
		events = list,
		results = results,
		goal = {
			text = goal.text,
			progress = goal.progress,
			target = goal.target,
			endsAt = goal.endsAt,
			done = goal.done,
			reward = string.format("$%d + %d XP for everyone online", EC.GOAL.REWARD.cash, EC.GOAL.REWARD.xp),
		},
		me = {
			event = player:GetAttribute("Event"),
			best5k = sec and sec.best5k or 0,
			best3pt = sec and sec.best3pt or 0,
			wins = sec and sec.wins or 0,
			podiums = sec and sec.podiums or 0,
			carAwards = sec and sec.carAwards or 0,
			dunkBest = sec and sec.dunkBest or 0,
			caches = sec and sec.caches or 0,
			photoWins = sec and sec.photoWins or 0,
			fashionWins = sec and sec.fashionWins or 0,
			streetballWins = sec and sec.streetballWins or 0,
		},
	}
end

local function pushLive()
	for _, ev in events do
		local fn = liveFn(ev.kind)
		if isLive(ev) and ev.data and fn then
			local audience = table.clone(ev.registered)
			for p in ev.watchers do
				if not table.find(audience, p) then
					table.insert(audience, p)
				end
			end
			for _, p in audience do
				if p.Parent then
					local ok, data = pcall(fn, ev, p)
					if ok and data then
						data.id = ev.id
						data.name = ev.name
						data.icon = ev.icon
						data.kind = ev.kind
						data.phase = ev.phase
						data.role = if isRegistered(ev, p) then "player" else "watcher"
						Update:FireClient(p, "Live", data)
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Joining / leaving
---------------------------------------------------------------------------
local function leave(ev: Event, player: Player, quiet: boolean?)
	local i = table.find(ev.registered, player)
	if not i then
		return
	end
	table.remove(ev.registered, i)
	if player.Parent and player:GetAttribute("Event") == ev.id then
		setEventAttr(player, nil)
	end
	if ev.data then
		if ev.kind == "ThreePoint" then
			local qi = table.find(ev.data.queue, player)
			if qi then
				table.remove(ev.data.queue, qi)
			end
			for _, lane in ev.data.lanes do
				if lane.turn and lane.turn.player == player then
					endTurn(ev, lane, nil)
				end
			end
		elseif ev.kind == "City5K" then
			for _, racer in ev.data.racers do
				if racer.player == player then
					knockOut(racer, "You left the race.")
				end
			end
		elseif ev.kind == "CarMeet" then
			ev.data.parked[player] = nil
			refreshBayPlates(ev)
		elseif registry[ev.kind] and registry[ev.kind].leave then
			local ok, err = pcall((registry[ev.kind] :: any).leave, ev, player)
			if not ok then
				warn("[CityGrind] Event leave failed:", err)
			end
		end
	end
	if player.Parent then
		Update:FireClient(player, "Closed", ev.id)
		if not quiet then
			Net.notify(player, "LEFT EVENT", "You left the " .. ev.name .. ".")
		end
	end
	markDirty()
end

local function join(ev: Event, player: Player): (boolean, string)
	if not PlayerData.isLoaded(player) then
		return false, "Your data is still loading."
	end
	if isRegistered(ev, player) then
		return true, "You're already in."
	end
	if not (ev.state == "Upcoming" or ev.state == "Checkin") then
		return false, "Sign-ups for this event are closed. You can still watch."
	end
	local other = registrationOf(player)
	if other then
		return false, "You're signed up for the " .. other.name .. ". Leave it first."
	end
	if #ev.registered >= EC.KINDS[ev.kind].maxPlayers then
		return false, "This event is full."
	end
	table.insert(ev.registered, player)
	ev.watchers[player] = nil
	local sec = section(player)
	if sec then
		sec.joined += 1
		PlayerData.markChanged(player)
	end
	if ev.state ~= "Upcoming" then
		setEventAttr(player, ev.id)
	end
	markDirty()
	local tip = if registry[ev.kind] then " " .. (registry[ev.kind].tip or "")
		elseif ev.kind == "CarMeet" then " Bring a spawned vehicle (Garage app)."
		elseif ev.kind == "City5K" then " Be on foot in the start box."
		else " Be on the court at check-in."
	if ev.state == "Upcoming" then
		return true, string.format("You're in! Starts in %s at %s.%s", EC.formatIn(ev.startsAt - now()), ev.location, tip)
	end
	return true, "You're in! Head to " .. ev.location .. " now." .. tip
end

local function getMessages(): any
	local module = script.Parent:FindFirstChild("Messages")
	if not module then
		return nil
	end
	local ok, M = pcall(require, module)
	return if ok then M else nil
end

---------------------------------------------------------------------------
-- Remote handling
---------------------------------------------------------------------------
local COOLDOWNS = { List = 0.4, Join = 1, Leave = 1, Remind = 0.5, Watch = 0.5, Unwatch = 0.5, Vote = 0.25, Invite = 2, Submit = 2, Entry = 0.3 }

local function handle(player: Player, action: any, a: any, b: any, c: any): any
	if type(action) ~= "string" or not COOLDOWNS[action] then
		return { ok = false, msg = "Unknown action." }
	end
	if not Net.allow(player, "Events" .. action, COOLDOWNS[action]) then
		return { ok = false, msg = "Slow down a little." }
	end
	if action == "List" then
		return { ok = true, data = snapshot(player) }
	end
	local ev = findEvent(a)
	if not ev then
		return { ok = false, msg = "That event is over." }
	end
	if action == "Join" then
		local ok, msg = join(ev, player)
		return { ok = ok, msg = msg, name = ev.name, position = ev.pos }
	elseif action == "Leave" then
		leave(ev, player)
		return { ok = true, msg = "You left the " .. ev.name .. "." }
	elseif action == "Remind" then
		if type(b) ~= "boolean" then
			return { ok = false, msg = "Bad request." }
		end
		if ev.state ~= "Upcoming" then
			return { ok = false, msg = "It's already started." }
		end
		ev.reminders[player] = if b then true else nil
		if b and ev.startsAt - now() <= EC.REMINDER_AHEAD then
			Net.notify(player, "⏰ EVENT REMINDER", string.format("%s starts in under a minute at %s.", ev.name, ev.location))
		end
		markDirty()
		return { ok = true, msg = if b then "We'll ping you 1 minute before it starts." else "Reminder removed." }
	elseif action == "Watch" then
		if not isLive(ev) then
			return { ok = false, msg = "It hasn't started yet." }
		end
		ev.watchers[player] = true
		markDirty()
		return { ok = true, msg = "Watching " .. ev.name .. ". GPS set.", name = ev.name, position = ev.pos }
	elseif action == "Unwatch" then
		ev.watchers[player] = nil
		markDirty()
		return { ok = true, msg = "Stopped watching." }
	elseif action == "Vote" or action == "Submit" or action == "Entry" then
		local h = registry[ev.kind]
		if h then
			if not h.request or not ev.data then
				return { ok = false, msg = "Nothing to do here right now." }
			end
			return (h.request :: any)(ev, player, action, b, c)
		end
		if action ~= "Vote" or ev.kind ~= "CarMeet" or ev.state ~= "Voting" or not ev.data then
			return { ok = false, msg = "Voting isn't open." }
		end
		if type(b) ~= "number" or b % 1 ~= 0 or not MEET.CATEGORIES[b] or type(c) ~= "number" then
			return { ok = false, msg = "Bad vote." }
		end
		if not table.find(ev.data.attendees, player) then
			return { ok = false, msg = "Only cars in the line-up can vote." }
		end
		if c == player.UserId then
			return { ok = false, msg = "You can't vote for yourself." }
		end
		local found = false
		for _, cand in ev.data.candidates do
			if cand.userId == c then
				found = true
			end
		end
		if not found then
			return { ok = false, msg = "That car isn't in the line-up." }
		end
		local mine = ev.data.votes[player.UserId] or {}
		ev.data.votes[player.UserId] = mine
		mine[MEET.CATEGORIES[b]] = c
		markDirty()
		return { ok = true, msg = "Vote saved.", mine = mine }
	elseif action == "Invite" then
		if type(b) ~= "number" then
			return { ok = false, msg = "Pick a player." }
		end
		local target = Players:GetPlayerByUserId(b)
		if not target or target == player then
			return { ok = false, msg = "They're not in this server." }
		end
		local M = getMessages()
		if not M or not M.sendInvite then
			return { ok = false, msg = "Invites aren't available right now." }
		end
		local ok, okSend, reason = pcall(M.sendInvite, player, target, "event", {
			label = ev.name,
			place = ev.location,
			position = ev.pos,
			eventId = ev.id,
		})
		if not ok then
			return { ok = false, msg = "Couldn't send the invite." }
		end
		return { ok = okSend == true, msg = if okSend then "Invite sent to " .. target.DisplayName .. "." else (reason or "Couldn't send the invite.") }
	end
	return { ok = false, msg = "Unknown action." }
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Every scheduled or live event (public info only).
function Events.list(): { any }
	local list = {}
	for _, ev in events do
		table.insert(list, summary(ev, nil))
	end
	return list
end

-- The id of the live event this player is taking part in, if any.
function Events.isInEvent(player: Player): string?
	for _, ev in events do
		if isLive(ev) and isRegistered(ev, player) then
			return ev.id
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Shared helpers handed to the kind modules (EventDunk, EventHunt, ...)
---------------------------------------------------------------------------
local KIND_MODULES = {
	DunkContest = "EventDunk",
	TreasureHunt = "EventHunt",
	PhotoChallenge = "EventPhoto",
	FashionShow = "EventFashion",
	StreetballTournament = "EventStreetball",
}

-- Courts an event may take over: public (not the gated Luxury Hills club) and
-- at street level (not the Summit rooftop, which needs the elevator).
local function publicCourt(m: Instance): boolean
	return m:IsA("Model") and m.Parent ~= nil and not m.Name:find("Private") and courtCenter(m :: Model).Y < 20
end

local function courtFree(m: Model): boolean
	return publicCourt(m) and courtIdle(m) and not m:GetAttribute("Event") and rimOf(m, "North") ~= nil and rimOf(m, "South") ~= nil
end

-- A public court that no event and no pickup game is using right now.
-- `prefer` (a court or court names, best first) wins when free; `avoid` never.
local function freeCourt(prefer: any, avoid: Model?): Model?
	local wanted: { Model } = {}
	if typeof(prefer) == "Instance" and prefer:IsA("Model") then
		table.insert(wanted, prefer)
	elseif type(prefer) == "table" then
		for _, name in prefer do
			for _, m in CollectionService:GetTagged("Court") do
				if m:IsA("Model") and m.Name == name then
					table.insert(wanted, m)
				end
			end
		end
	end
	for _, m in wanted do
		if m ~= avoid and courtFree(m) then
			return m
		end
	end
	for _, m in CollectionService:GetTagged("Court") do
		if m:IsA("Model") and m ~= avoid and courtFree(m) then
			return m
		end
	end
	return nil
end

local function makeCtx(): any
	return {
		EC = EC,
		root = root,
		rng = rng,
		now = now,
		part = part,
		surfaceText = surfaceText,
		rootOf = rootOf,
		humanoidOf = humanoidOf,
		flat = flat,
		flatDist = flatDist,
		onFoot = onFoot,
		notify = Net.notify,
		notifyAll = notifyAll,
		announce = function(players: { Player }, text: string)
			Basketball.announce(players, text)
		end,
		section = section,
		give = give,
		payPlace = payPlace,
		payPodium = payPodium,
		pushResult = pushResult,
		closeEvent = closeEvent,
		cancelEvent = cancelEvent,
		dropEntrant = dropEntrant,
		isRegistered = isRegistered,
		setEventAttr = setEventAttr,
		markDirty = markDirty,
		fire = function(p: Player, ...)
			if p.Parent then
				Update:FireClient(p, ...)
			end
		end,
		audience = function(ev: Event): { Player }
			local list = table.clone(ev.registered)
			for p in ev.watchers do
				if p.Parent and not table.find(list, p) then
					table.insert(list, p)
				end
			end
			return list
		end,
		-- courts
		courtCenter = courtCenter,
		courtSize = courtSize,
		courtIdle = courtIdle,
		onCourt = onCourt,
		rimOf = rimOf,
		freeCourt = freeCourt,
		publicCourt = publicCourt,
		minEntrants = function(kind: string): number
			return EC.MIN_ENTRANTS[kind] or 1
		end,
		threeCourt = function(): Model?
			return court
		end,
		claimCourt = function(m: Model, name: string)
			m:SetAttribute("Event", true)
			m:SetAttribute("EventName", name)
		end,
		releaseCourt = function(m: Model?)
			if m then
				m:SetAttribute("Event", nil)
				m:SetAttribute("EventName", nil)
			end
		end,
		courtLabel = function(m: Model): string
			local n = m:GetAttribute("DisplayName")
			return if type(n) == "string" then n else m.Name
		end,
	}
end

local function loadKinds()
	local ctx = makeCtx()
	for kindId, moduleName in KIND_MODULES do
		local module = script.Parent:FindFirstChild(moduleName)
		if not module then
			warn("[CityGrind] Events: missing kind module " .. moduleName)
			continue
		end
		local ok, err = pcall(function()
			local handlers = require(module :: ModuleScript).init(ctx)
			Events.registerKind(kindId, handlers)
		end)
		if not ok then
			warn("[CityGrind] Events: " .. moduleName .. " failed to load:", err)
		end
	end
end

function Events.start(city: Instance)
	Request = Net.remote("RemoteFunction", "EventsRequest")
	Update = Net.remote("RemoteEvent", "EventsUpdate")

	root = Instance.new("Folder")
	root.Name = "Events"
	root.Parent = city

	court = findCourt()
	local okLot, errLot = pcall(buildMeetLot, root)
	if not okLot then
		warn("[CityGrind] Events: car meet lot failed:", errLot)
	end
	buildBoards(root)
	wrapPolicy()
	Basketball.scored.connect(onScored)
	loadKinds()

	-- Server shutting down: close every event cleanly (venues, courts, balls).
	game:BindToClose(function()
		for _, ev in table.clone(events) do
			if isLive(ev) then
				pcall(cancelEvent, ev, "The server is shutting down.")
			end
		end
	end)

	Request.OnServerInvoke = function(player, action, a, b, c)
		local ok, result = pcall(handle, player, action, a, b, c)
		if not ok then
			warn("[CityGrind] Events request failed:", result)
			return { ok = false, msg = "Something went wrong." }
		end
		return result
	end

	-- Invites sent from the Events app arrive as Messages invite cards.
	local M = getMessages()
	if M and M.onInvite then
		M.onInvite("event", function(_from: Player?, to: Player, payload: any)
			local ev = findEvent(payload and payload.eventId)
			if not ev then
				return false, "That event is already over."
			end
			Update:FireClient(to, "Gps", ev.name, ev.pos)
			if isRegistered(ev, to) then
				return true, "You're already in. GPS set."
			end
			if ev.state == "Upcoming" or ev.state == "Checkin" then
				local ok, msg = join(ev, to)
				if ok then
					return true, msg
				end
			end
			return true, "GPS set to " .. ev.location .. "."
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		for _, ev in table.clone(events) do
			leave(ev, player, true)
			ev.reminders[player] = nil
			ev.watchers[player] = nil
		end
	end)

	newGoal()
	schedule()
	refreshBoards()

	-- Event logic at 10 Hz, live HUD pushes at 4 Hz, list / boards once a second.
	task.spawn(function()
		local liveAcc, slowAcc = 0, 0
		while true do
			local dt = task.wait(0.1)
			tickBalls()
			for _, ev in table.clone(events) do
				local fn = tickFn(ev.kind)
				if isLive(ev) and table.find(events, ev) and fn then
					local ok, err = pcall(fn, ev)
					if not ok then
						warn("[CityGrind] Event " .. ev.kind .. " failed:", err)
						pcall(cancelEvent, ev, "Something went wrong running this event.")
					end
				end
			end
			liveAcc += dt
			if liveAcc >= 0.25 then
				liveAcc = 0
				pushLive()
			end
			slowAcc += dt
			if slowAcc >= 1 then
				slowAcc = 0
				local okS, errS = pcall(tickSchedule)
				if not okS then
					warn("[CityGrind] Events scheduler failed:", errS)
				end
				if now() >= goal.endsAt then
					newGoal()
				end
				refreshBoards()
				if listDirty then
					listDirty = false
					Update:FireAllClients("Changed")
				end
			end
		end
	end)
end

return Events
