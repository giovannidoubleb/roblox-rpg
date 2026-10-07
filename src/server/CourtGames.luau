-- CITY GRIND: pickup games on every tagged court (sections 51, 71).
-- Stand on the HOME or AWAY pad; when both sides have the same number of
-- players (1v1, 2v2 or 3v3) a countdown starts. First to 11 wins, or whoever
-- leads after 6 minutes (tied games go to next basket). Between games the
-- ball rack gives out free-play balls.
--
-- Other systems (Ranked) can run a scheduled match on a court with
-- CourtGames.startMatch(model, home, away, opts): the court is "Reserved" for a
-- short countdown (nobody else can join from the pads), then plays by the same
-- rules. Pickup rewards are skipped and opts.onEnded(result) gets the outcome.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Config"))
local Basketball = require(script.Parent:WaitForChild("Basketball"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local G = Config.Game
local B = Config.Ball

local CourtGames = {}

type Team = "Home" | "Away"
type Court = {
	model: Model,
	name: string,
	center: Vector3,
	size: Vector3,
	hoops: { [string]: Basketball.Hoop },
	pads: { [Team]: BasePart },
	scoreText: TextLabel?,
	state: string,
	teams: { [Team]: { Player } },
	score: { [Team]: number },
	startedAt: number,
	countdownEnds: number,
	overtime: boolean,
	ball: Basketball.Ball?,
	freeBalls: { [Basketball.Ball]: boolean },
	points: { [Player]: number },
	awaySince: { [Player]: number },
	match: Match?, -- set while a scheduled (ranked) match owns the court
}
-- A scheduled match (CourtGames.startMatch). `leavers` lists players who left
-- before the result was decided; `decided` flips when the winning bucket drops.
type Match = {
	label: string,
	ranked: boolean,
	home: { Player },
	away: { Player },
	leavers: { Player },
	decided: boolean,
	over: boolean,
	onEnded: ((result: any) -> ())?,
}

local courts: { Court } = {}
local playerGame: { [Player]: { court: Court, team: Team } } = {}

local function other(team: Team): Team
	return if team == "Home" then "Away" else "Home"
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function gamePlayers(court: Court): { Player }
	local list = table.clone(court.teams.Home)
	for _, p in court.teams.Away do
		table.insert(list, p)
	end
	return list
end

-- Everyone in the game plus anyone watching nearby.
local function audience(court: Court): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		local r = rootOf(player)
		if (playerGame[player] and playerGame[player].court == court) or (r and flatDistance(r.Position, court.center) < 90) then
			table.insert(list, player)
		end
	end
	return list
end

local function setScoreboard(court: Court, text: string)
	if court.scoreText then
		court.scoreText.Text = text
	end
end

local function publish(court: Court)
	local m = court.model
	m:SetAttribute("State", court.state)
	m:SetAttribute("HomeScore", court.score.Home)
	m:SetAttribute("AwayScore", court.score.Away)
	m:SetAttribute("Mode", #court.teams.Home .. "v" .. #court.teams.Away)
	m:SetAttribute("Overtime", court.overtime)
	local timeLeft = if court.state == "Playing" then math.max(0, G.TIME_LIMIT - (os.clock() - court.startedAt)) else 0
	m:SetAttribute("TimeLeft", math.floor(timeLeft))
	m:SetAttribute("Countdown", if court.state == "Countdown" or court.state == "Reserved" then math.max(0, math.ceil(court.countdownEnds - os.clock())) else 0)
	m:SetAttribute("Ranked", if court.match then court.match.ranked else nil)
end

local function inBounds(court: Court, position: Vector3, margin: number): boolean
	local offset = position - court.center
	return math.abs(offset.X) <= court.size.X / 2 + margin and math.abs(offset.Z) <= court.size.Z / 2 + margin
end

local function onPad(pad: BasePart, root: BasePart): boolean
	local offset = pad.CFrame:PointToObjectSpace(root.Position)
	return math.abs(offset.X) <= pad.Size.X / 2 + 0.5 and math.abs(offset.Z) <= pad.Size.Z / 2 + 0.5 and offset.Y > -1 and offset.Y < 6
end

local function clearFreeBalls(court: Court)
	for ball in court.freeBalls do
		Basketball.destroy(ball)
	end
	table.clear(court.freeBalls)
end

---------------------------------------------------------------------------
-- Rules handed to the ball system
---------------------------------------------------------------------------
Basketball.policy.canHold = function(player, ball)
	local entry = playerGame[player]
	if ball.gameCourt then
		return entry ~= nil and entry.court.model == ball.gameCourt and entry.court.state == "Playing"
	end
	return entry == nil
end

Basketball.policy.targetHoop = function(player, _ball)
	local entry = playerGame[player]
	if not entry then
		return nil
	end
	return entry.court.hoops[if entry.team == "Home" then "North" else "South"]
end

Basketball.policy.opponents = function(player, _ball)
	local entry = playerGame[player]
	if not entry then
		return {}
	end
	return entry.court.teams[other(entry.team)]
end

Basketball.policy.passTargets = function(player, _ball)
	local entry = playerGame[player]
	if entry then
		local mates = {}
		for _, p in entry.court.teams[entry.team] do
			if p ~= player then
				table.insert(mates, p)
			end
		end
		return mates
	end
	local list = {}
	for _, p in Players:GetPlayers() do
		if p ~= player and not playerGame[p] then
			table.insert(list, p)
		end
	end
	return list
end

Basketball.policy.canSteal = function(player, victim, _ball)
	local a, b = playerGame[player], playerGame[victim]
	if a and b then
		return a.court == b.court and a.team ~= b.team
	end
	return a == nil and b == nil
end

---------------------------------------------------------------------------
-- Game flow
---------------------------------------------------------------------------
local function giveTo(court: Court, team: Team)
	local ball = court.ball
	local list = court.teams[team]
	if not ball or #list == 0 then
		return
	end
	-- Check the ball to a random player on that team.
	Basketball.give(ball, list[math.random(1, #list)])
end

local function leaveGame(player: Player)
	local entry = playerGame[player]
	if not entry then
		return
	end
	playerGame[player] = nil
	local match = entry.court.match
	if match and not match.over and not match.decided and not table.find(match.leavers, player) then
		table.insert(match.leavers, player)
	end
	local list = entry.court.teams[entry.team]
	local i = table.find(list, player)
	if i then
		table.remove(list, i)
	end
	if player.Parent then
		player:SetAttribute("InGame", nil)
		player:SetAttribute("Team", nil)
	end
	local ball = entry.court.ball
	if ball and ball.holder == player then
		Basketball.drop(ball)
	end
end

local function endGame(court: Court, winner: Team?, forfeit: boolean)
	local match = court.match
	if match then
		match.over = true
	end
	court.state = "Ended"
	-- Scheduled first, so the court always reopens even if a payout below errors.
	task.delay(6, function()
		if court.state == "Ended" then
			court.match = nil
			court.state = "Idle"
			court.score = { Home = 0, Away = 0 }
			court.overtime = false
			setScoreboard(court, "OPEN COURT")
			publish(court)
		end
	end)
	local duration = os.clock() - court.startedAt
	local total = court.score.Home + court.score.Away
	local eligible = not forfeit and duration >= G.MIN_SECONDS_FOR_REWARDS and total >= G.MIN_POINTS_FOR_REWARDS
	local teamSize = math.max(#court.teams.Home, #court.teams.Away)
	local sizeBonus = 1 + 0.25 * (teamSize - 1)

	for _, team in { "Home", "Away" } :: { Team } do
		for _, player in table.clone(court.teams[team]) do
			local won = team == winner
			if match then
				-- Scheduled matches pay out through their owner (onEnded), not pickup rewards.
				Basketball.announce({ player }, if won then "YOU WIN!" else "GOOD GAME")
				leaveGame(player)
				continue
			end
			if eligible then
				if won then
					PlayerData.addCash(player, math.floor(G.WIN_CASH * sizeBonus), "Won a " .. teamSize .. "v" .. teamSize .. " at " .. court.name)
					PlayerData.addXP(player, math.floor(G.WIN_XP * sizeBonus))
					PlayerData.addReputation(player, math.floor(G.WIN_REP * sizeBonus))
				else
					PlayerData.addCash(player, G.LOSS_CASH, "Played a " .. teamSize .. "v" .. teamSize .. " at " .. court.name)
					PlayerData.addXP(player, G.LOSS_XP)
					PlayerData.addReputation(player, G.LOSS_REP)
				end
				PlayerData.recordBasketball(player, { games = 1, wins = if won then 1 else 0, losses = if won then 0 else 1 })
			end
			Basketball.announce({ player }, if won then "YOU WIN!" else "GOOD GAME")
			if not eligible and not forfeit then
				PlayerData.onNotify:Fire(player, "SHORT GAME", "Games need 1+ minute and 5+ points to count for rewards.")
			end
			leaveGame(player)
		end
	end

	if court.ball then
		Basketball.destroy(court.ball)
		court.ball = nil
	end
	local result = if winner then string.upper(winner) .. " WINS" else "GAME OVER"
	setScoreboard(court, string.format("%s\n%d - %d", result, court.score.Home, court.score.Away))
	publish(court)
	if match and match.onEnded then
		local outcome = {
			winner = winner,
			score = { Home = court.score.Home, Away = court.score.Away },
			forfeit = forfeit,
			duration = duration,
			home = match.home,
			away = match.away,
			leavers = match.leavers,
			points = table.clone(court.points),
			court = court.model,
		}
		local onEnded = match.onEnded
		task.spawn(function()
			local ok, err = pcall(onEnded, outcome)
			if not ok then
				warn("[CityGrind] Match result handler failed:", err)
			end
		end)
	end
end

local function startGame(court: Court, home: { Player }, away: { Player })
	clearFreeBalls(court)
	for _, p in home do
		local held = Basketball.heldBall(p)
		if held then
			Basketball.destroy(held)
		end
	end
	for _, p in away do
		local held = Basketball.heldBall(p)
		if held then
			Basketball.destroy(held)
		end
	end
	court.teams = { Home = home, Away = away }
	court.score = { Home = 0, Away = 0 }
	court.points = {}
	court.awaySince = {}
	court.overtime = false
	court.state = "Playing"
	court.startedAt = os.clock()

	-- Line up at half court. Home attacks the north hoop (toward -z).
	for team, list in court.teams do
		local zSide = if team == "Home" then 6 else -6
		local facing = if team == "Home" then Vector3.new(0, 0, -1) else Vector3.new(0, 0, 1)
		for i, player in list do
			playerGame[player] = { court = court, team = team }
			player:SetAttribute("InGame", court.name)
			player:SetAttribute("Team", team)
			local pos = court.center + Vector3.new((i - (#list + 1) / 2) * 7, 3.5, zSide)
			local humanoid = court.match and player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.SeatPart then
				-- a summoned ranked player who sat in a car: unweld first so the car isn't dragged along
				local weld = humanoid.SeatPart:FindFirstChild("SeatWeld")
				if weld then
					weld:Destroy()
				end
				humanoid.Sit = false
			end
			if player.Character then
				player.Character:PivotTo(CFrame.lookAt(pos, pos + facing))
			end
		end
	end

	local ball = Basketball.newBall(court.center + Vector3.new(0, 4, 0))
	ball.gameCourt = court.model
	ball.court = court.model
	court.ball = ball
	local first: Team = if math.random() < 0.5 then "Home" else "Away"
	giveTo(court, first)
	local mode = #home .. "v" .. #away
	if court.match then
		mode = court.match.label
	end
	Basketball.announce(gamePlayers(court), mode .. "  ·  FIRST TO " .. G.TARGET_SCORE)
	publish(court)
end

local function updateIdle(court: Court)
	-- A city event (3-Point Contest) has the court; no pickup games until it ends.
	if court.model:GetAttribute("Event") then
		court.state = "Idle"
		setScoreboard(court, court.model:GetAttribute("EventName") or "CITY EVENT")
		publish(court)
		return
	end
	local home, away = {}, {}
	for _, player in Players:GetPlayers() do
		local r = rootOf(player)
		if r and not playerGame[player] then
			if onPad(court.pads.Home, r) and #home < G.MAX_TEAM_SIZE then
				table.insert(home, player)
			elseif onPad(court.pads.Away, r) and #away < G.MAX_TEAM_SIZE then
				table.insert(away, player)
			end
		end
	end
	local ready = #home >= 1 and #home == #away
	if court.state == "Idle" then
		if ready then
			court.state = "Countdown"
			court.countdownEnds = os.clock() + G.COUNTDOWN
		elseif #home + #away > 0 then
			setScoreboard(court, string.format("HOME %d  ·  AWAY %d\nNeed even teams", #home, #away))
		else
			setScoreboard(court, "OPEN COURT")
		end
	end
	if court.state == "Countdown" then
		if not ready then
			court.state = "Idle"
		elseif os.clock() >= court.countdownEnds then
			startGame(court, home, away)
			return
		else
			setScoreboard(court, string.format("%dv%d STARTS IN %d", #home, #away, math.ceil(court.countdownEnds - os.clock())))
		end
	end
	publish(court)
end

local function updatePlaying(court: Court)
	local now = os.clock()
	-- Players who wander off (or die and respawn far away) leave the game.
	for _, player in gamePlayers(court) do
		local r = rootOf(player)
		if not player.Parent then
			leaveGame(player)
		elseif not r or flatDistance(r.Position, court.center) > 90 then
			court.awaySince[player] = court.awaySince[player] or now
			if now - court.awaySince[player] > 8 then
				PlayerData.onNotify:Fire(player, "LEFT THE GAME", "You went too far from " .. court.name .. ".")
				leaveGame(player)
			end
		else
			court.awaySince[player] = nil
		end
	end
	if #court.teams.Home == 0 or #court.teams.Away == 0 then
		local winner: Team? = if #court.teams.Home > 0 then "Home" elseif #court.teams.Away > 0 then "Away" else nil
		endGame(court, winner, true)
		return
	end

	local ball = court.ball
	if ball then
		-- Out of bounds: the other team takes it.
		local holder = ball.holder
		if holder then
			local r = rootOf(holder)
			if r and not inBounds(court, r.Position, 1.5) then
				local entry = playerGame[holder]
				if entry then
					Basketball.announce(audience(court), "OUT OF BOUNDS")
					giveTo(court, other(entry.team))
				end
			end
		elseif not ball.part.Anchored then
			local pos = ball.part.Position
			if not inBounds(court, pos, 1.5) and pos.Y < court.center.Y + 4 then
				local last = ball.lastHolder and playerGame[ball.lastHolder]
				local team: Team = if last then other(last.team) else "Home"
				Basketball.announce(audience(court), "OUT OF BOUNDS")
				giveTo(court, team)
			end
		end
	end

	if now - court.startedAt >= G.TIME_LIMIT and not court.overtime then
		if court.score.Home ~= court.score.Away then
			endGame(court, if court.score.Home > court.score.Away then "Home" else "Away", false)
			return
		end
		court.overtime = true
		Basketball.announce(audience(court), "TIED! NEXT BUCKET WINS")
	end

	local timeLeft = math.max(0, G.TIME_LIMIT - (now - court.startedAt))
	setScoreboard(
		court,
		string.format(
			if court.match then "RANKED %d - %d\n%s" else "HOME %d - %d AWAY\n%s",
			court.score.Home,
			court.score.Away,
			if court.overtime then "NEXT BUCKET WINS" else string.format("%d:%02d", timeLeft // 60, timeLeft % 60)
		)
	)
	publish(court)
end

-- A scheduled match's countdown: the teams are on court, nobody else can join.
local function updateReserved(court: Court)
	for _, player in gamePlayers(court) do
		if not player.Parent then
			leaveGame(player)
		end
	end
	if #court.teams.Home == 0 or #court.teams.Away == 0 then
		local winner: Team? = if #court.teams.Home > 0 then "Home" elseif #court.teams.Away > 0 then "Away" else nil
		endGame(court, winner, true)
		return
	end
	if os.clock() >= court.countdownEnds then
		startGame(court, court.teams.Home, court.teams.Away)
		return
	end
	local label = if court.match then court.match.label else "MATCH"
	setScoreboard(court, string.format("%s\nSTARTS IN %d", label, math.ceil(court.countdownEnds - os.clock())))
	publish(court)
end

---------------------------------------------------------------------------
-- Ball events
---------------------------------------------------------------------------
local function courtOfModel(model: Model?): Court?
	for _, court in courts do
		if court.model == model then
			return court
		end
	end
	return nil
end

Basketball.scored.connect(function(ball, hoop, shot)
	local court = courtOfModel(ball.gameCourt)
	local shooter = shot and shot.shooter

	if not court or court.state ~= "Playing" or ball ~= court.ball then
		-- Free play: training only, and a callout for the big ones.
		if shooter and shooter.Parent then
			if shot.kind == "dunk" then
				Basketball.train(shooter, "Vertical", 5)
				Basketball.train(shooter, "Finishing", 4)
				Basketball.announce({ shooter }, "SLAM!")
			elseif shot.kind == "layup" then
				Basketball.train(shooter, "Finishing", 4)
				Basketball.announce({ shooter }, "BUCKET")
			else
				Basketball.train(shooter, "Shooting", if shot.points == 3 then 6 else 4)
				if shot.perfect then
					Basketball.announce({ shooter }, "PERFECT RELEASE!")
				else
					Basketball.announce({ shooter }, if shot.points == 3 then "SPLASH! +3" else "BUCKET +2")
				end
			end
		end
		return
	end

	local team: Team = if hoop.side == "North" then "Home" else "Away"
	local points = 2
	local shooterEntry = shooter and playerGame[shooter]
	if shot and shooterEntry and shooterEntry.court == court and shooterEntry.team == team then
		points = shot.points
		court.points[shooter] = (court.points[shooter] or 0) + points
		PlayerData.recordBasketball(shooter, {
			points = points,
			threes = if points == 3 then 1 else 0,
			dunks = if shot.kind == "dunk" then 1 else 0,
		})
		if shot.kind == "dunk" then
			Basketball.train(shooter, "Vertical", 5)
			Basketball.train(shooter, "Finishing", 5)
		elseif shot.kind == "layup" then
			Basketball.train(shooter, "Finishing", 5)
		else
			Basketball.train(shooter, "Shooting", if points == 3 then 8 else 5)
		end
	end
	local before = court.score[team]
	local wasTied = court.score.Home == court.score.Away
	court.score[team] += points

	local gameOver = court.overtime or court.score[team] >= G.TARGET_SCORE
	if gameOver and court.match then
		court.match.decided = true
	end
	local callout
	if gameOver then
		callout = "GAME WINNER!"
	elseif wasTied and before >= G.TARGET_SCORE - 4 then
		callout = "CLUTCH!"
	elseif shot and shot.kind == "dunk" and shot.contestedBy then
		callout = "POSTER!"
	elseif shot and shot.perfect then
		callout = "PERFECT RELEASE!"
	elseif points == 3 then
		callout = "FROM DOWNTOWN!"
	end
	if callout then
		Basketball.announce(audience(court), callout)
	end
	publish(court)

	if gameOver then
		task.delay(1.2, function()
			if court.state == "Playing" then
				endGame(court, team, false)
			end
		end)
		return
	end
	-- Possession goes to the team that got scored on once the ball drops.
	task.delay(1, function()
		if court.state == "Playing" and court.ball == ball and not ball.holder then
			giveTo(court, other(team))
		end
	end)
end)

Basketball.blocked.connect(function(ball, blocker, _shooter)
	local court = courtOfModel(ball.gameCourt)
	if court and court.state == "Playing" then
		PlayerData.recordBasketball(blocker, { blocks = 1 })
		Basketball.announce(audience(court), "BIG BLOCK!")
	else
		Basketball.announce({ blocker }, "BIG BLOCK!")
	end
end)

Basketball.stolen.connect(function(ball, stealer, _victim)
	local court = courtOfModel(ball.gameCourt)
	if court and court.state == "Playing" then
		PlayerData.recordBasketball(stealer, { steals = 1 })
		Basketball.announce(audience(court), "STEAL!")
	end
end)

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local setUp: { [Model]: boolean } = {}
local function setupCourt(model: Model)
	if setUp[model] then
		return
	end
	setUp[model] = true
	local hoops = {}
	for _, side in { "North", "South" } do
		local hoopModel = model:FindFirstChild("Hoop" .. side)
		local marker = hoopModel and hoopModel:FindFirstChild("RimCenter", true)
		if marker and marker:IsA("Attachment") then
			local hoop: Basketball.Hoop = {
				model = hoopModel,
				rim = marker.WorldPosition,
				radius = hoopModel:GetAttribute("RimRadius") or 1.45,
				court = model,
				side = side,
			}
			hoops[side] = hoop
			Basketball.registerHoop(hoop)
		end
	end
	local homePad = model:FindFirstChild("HomePad")
	local awayPad = model:FindFirstChild("AwayPad")
	if not hoops.North or not hoops.South or not homePad or not awayPad then
		warn("[CityGrind] Court is missing hoops or pads:", model:GetFullName())
		return
	end
	local scoreboard = model:FindFirstChild("Scoreboard")
	local gui = scoreboard and scoreboard:FindFirstChildOfClass("SurfaceGui")

	local court: Court = {
		model = model,
		name = model:GetAttribute("DisplayName") or model.Name,
		center = model:GetAttribute("CourtCenter"),
		size = model:GetAttribute("CourtSize"),
		hoops = hoops,
		pads = { Home = homePad, Away = awayPad },
		scoreText = gui and gui:FindFirstChildOfClass("TextLabel"),
		state = "Idle",
		teams = { Home = {}, Away = {} },
		score = { Home = 0, Away = 0 },
		startedAt = 0,
		countdownEnds = 0,
		overtime = false,
		ball = nil,
		freeBalls = {},
		points = {},
		awaySince = {},
	}
	table.insert(courts, court)
	setScoreboard(court, "OPEN COURT")
	publish(court)

	local rack = model:FindFirstChild("BallRack")
	local prompt = rack and rack:FindFirstChild("GrabBall")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Triggered:Connect(function(player)
			if model:GetAttribute("Event") then
				PlayerData.onNotify:Fire(player, "EVENT IN PROGRESS", "The rack is closed during the contest.")
				return
			end
			if playerGame[player] or court.state == "Playing" or court.state == "Reserved" then
				PlayerData.onNotify:Fire(player, "GAME IN PROGRESS", "Free play balls come back when the game ends.")
				return
			end
			if Basketball.heldBall(player) then
				return
			end
			-- One practice ball per player, a few per court.
			for ball in court.freeBalls do
				if ball.owner == player then
					Basketball.destroy(ball)
					court.freeBalls[ball] = nil
				end
			end
			local count = 0
			for _ in court.freeBalls do
				count += 1
			end
			if count >= B.FREE_BALLS_PER_COURT then
				PlayerData.onNotify:Fire(player, "RACK IS EMPTY", "Grab a loose ball on the court instead.")
				return
			end
			local ball = Basketball.newBall((rack :: BasePart).Position + Vector3.new(0, 2.5, 0))
			ball.court = model
			ball.owner = player
			court.freeBalls[ball] = true
			Basketball.give(ball, player)
		end)
	end

	task.spawn(function()
		while model.Parent do
			-- pcall: one bad tick must never kill the court's loop (a stuck court
			-- would also hold a ranked match forever).
			local ok, err = pcall(function()
				if court.state == "Idle" or court.state == "Countdown" then
					updateIdle(court)
				elseif court.state == "Playing" then
					updatePlaying(court)
				elseif court.state == "Reserved" then
					updateReserved(court)
				end
			end)
			if not ok then
				warn("[CityGrind] Court update failed at " .. court.name .. ":", err)
			end
			-- tidy up practice balls nobody has touched for a while
			for ball in court.freeBalls do
				if not Basketball.balls()[ball] then
					court.freeBalls[ball] = nil
				elseif not ball.holder and os.clock() - ball.lastActive > B.FREE_BALL_IDLE_SECONDS then
					Basketball.destroy(ball)
					court.freeBalls[ball] = nil
				end
			end
			task.wait(0.2)
		end
	end)
end

function CourtGames.start()
	for _, model in CollectionService:GetTagged("Court") do
		if model:IsA("Model") then
			setupCourt(model)
		end
	end
	-- Courts built later (other districts) join automatically.
	-- The tag is added before the court is finished building, so wait a frame.
	CollectionService:GetInstanceAddedSignal("Court"):Connect(function(model)
		if model:IsA("Model") then
			task.defer(setupCourt, model)
		end
	end)
	Players.PlayerRemoving:Connect(leaveGame)
end

-- True when a court can host a scheduled match right now: set up, no event,
-- no pickup game or countdown, nobody standing on the team pads.
function CourtGames.isFree(model: Model): boolean
	local court = courtOfModel(model)
	if not court or court.state ~= "Idle" or court.match or model:GetAttribute("Event") then
		return false
	end
	for _, player in Players:GetPlayers() do
		local r = rootOf(player)
		if r and (onPad(court.pads.Home, r) or onPad(court.pads.Away, r)) then
			return false
		end
	end
	return true
end

-- Runs a scheduled match (Ranked). `home`/`away` are 1-3 players each, all on
-- no other court. opts: { label: string?, ranked: boolean?, countdown: number?,
-- onEnded: ((result) -> ())? } where result = { winner: "Home" | "Away" | nil,
-- score = {Home, Away}, forfeit, duration (seconds), home, away (rosters at the
-- start), leavers (left before the result was decided), points ({[Player]: n}), court }.
-- The court is "Reserved" (State attribute) during the countdown; pickup rewards
-- are not paid for these games and nobody else can join until it ends.
function CourtGames.startMatch(model: Model, home: { Player }, away: { Player }, opts: any?): (boolean, string?)
	opts = opts or {}
	local court = courtOfModel(model)
	if not court then
		return false, "That court isn't set up."
	end
	if not CourtGames.isFree(model) then
		return false, "That court is busy."
	end
	if #home < 1 or #away < 1 or #home > G.MAX_TEAM_SIZE or #away > G.MAX_TEAM_SIZE then
		return false, "Teams need 1 to " .. G.MAX_TEAM_SIZE .. " players."
	end
	local seen = {}
	for _, list in { home, away } do
		for _, p in list do
			if typeof(p) ~= "Instance" or not p:IsA("Player") or not p.Parent or seen[p] or playerGame[p] then
				return false, "A player is unavailable."
			end
			seen[p] = true
		end
	end
	clearFreeBalls(court)
	court.match = {
		label = if type(opts.label) == "string" then opts.label else (#home .. "v" .. #away),
		ranked = opts.ranked == true,
		home = table.clone(home),
		away = table.clone(away),
		leavers = {},
		decided = false,
		over = false,
		onEnded = if type(opts.onEnded) == "function" then opts.onEnded else nil,
	}
	court.teams = { Home = table.clone(home), Away = table.clone(away) }
	court.score = { Home = 0, Away = 0 }
	court.overtime = false
	court.state = "Reserved"
	court.startedAt = os.clock()
	court.countdownEnds = os.clock() + (if type(opts.countdown) == "number" then math.clamp(opts.countdown, 0, 30) else G.COUNTDOWN)
	for team, list in court.teams do
		for _, p in list do
			playerGame[p] = { court = court, team = team }
			p:SetAttribute("InGame", court.name)
			p:SetAttribute("Team", team)
			local held = Basketball.heldBall(p)
			if held then
				Basketball.destroy(held)
			end
		end
	end
	publish(court)
	return true
end

function CourtGames.gameOf(player: Player): string?
	local entry = playerGame[player]
	return entry and entry.court.name
end

return CourtGames
