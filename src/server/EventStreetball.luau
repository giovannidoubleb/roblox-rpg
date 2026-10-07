-- CITY GRIND: Streetball Tournament (city event kind, plugs into Events.registerKind).
-- A knockout bracket of half-court games on a reserved public court: 1v1, or
-- 2v2 when the field is big and even. Both hoops are used, so two games run at
-- once. Games are run here rather than by CourtGames (CourtGames only starts
-- games from players standing on its pads and has no "start a match between
-- these players" hook); the court is claimed with the Event attribute so
-- CourtGames keeps it free while the tournament runs.
--
-- Rules: ones and twos (a basket inside the arc is 1, beyond it 2), loser's
-- ball after a make, out of bounds or a ball left loose for a few seconds goes to
-- the other side, first to STREETBALL.TARGET or the leader when the game clock
-- runs out (tied: next basket wins, then the higher seed). Teams that aren't at
-- the court when their game comes up forfeit.
--
-- Saved: section "events".streetballWins.

local Players = game:GetService("Players")

local Basketball = require(script.Parent:WaitForChild("Basketball"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local EventStreetball = {}

type Team = { id: number, players: { Player }, name: string, seed: number, out: number?, lostPoints: number, played: boolean }
type Lane = { side: string, rim: Vector3, dir: Vector3, key: Vector3, match: any?, freeAt: number }
type Match = {
	round: number,
	a: Team,
	b: Team,
	lane: Lane?,
	score: { [Team]: number },
	startedAt: number,
	endsAt: number,
	sudden: boolean,
	winner: Team?,
	ball: any?,
	lastTouch: Team?,
	looseSince: number?,
	checkAt: number?,
	checkTo: Team?,
	awaySince: { [Player]: number },
	done: boolean,
	ev: any,
}

local COURT_PREFER = { "BeachCourt", "GrandArena", "NeighborhoodCourt" }
local SUDDEN_LIMIT = 60

function EventStreetball.init(ctx: any): any
	local EC = ctx.EC
	local S = EC.STREETBALL
	local now = ctx.now

	local matchBalls: { [any]: Match } = {}
	local playerMatch: { [Player]: Match } = {}

	local function teamOf(m: Match, p: Player?): Team?
		if not p then
			return nil
		end
		if table.find(m.a.players, p) then
			return m.a
		elseif table.find(m.b.players, p) then
			return m.b
		end
		return nil
	end

	local function other(m: Match, t: Team): Team
		return if t == m.a then m.b else m.a
	end

	local function matchPlayers(m: Match): { Player }
		local list = table.clone(m.a.players)
		for _, p in m.b.players do
			table.insert(list, p)
		end
		return list
	end

	---------------------------------------------------------------------------
	-- Ball rules for tournament games
	---------------------------------------------------------------------------
	local policy = Basketball.policy
	local canHold = policy.canHold
	policy.canHold = function(player, ball)
		local m = matchBalls[ball]
		if m then
			return not m.done and playerMatch[player] == m and m.checkAt == nil
		end
		if playerMatch[player] then
			return false -- only the game ball during a game
		end
		return canHold(player, ball)
	end
	local canSteal = policy.canSteal
	policy.canSteal = function(player, victim, ball)
		local m = matchBalls[ball]
		if m then
			local tp, tv = teamOf(m, player), teamOf(m, victim)
			return tp ~= nil and tv ~= nil and tp ~= tv and playerMatch[player] == m
		end
		if playerMatch[player] or playerMatch[victim] then
			return false
		end
		return canSteal(player, victim, ball)
	end
	local passTargets = policy.passTargets
	policy.passTargets = function(player, ball)
		local m = matchBalls[ball]
		if m then
			local t = teamOf(m, player)
			local mates = {}
			if t then
				for _, p in t.players do
					if p ~= player and p.Parent then
						table.insert(mates, p)
					end
				end
			end
			return mates
		end
		return passTargets(player, ball)
	end
	local opponents = policy.opponents
	policy.opponents = function(player, ball)
		local m = playerMatch[player]
		if m then
			local t = teamOf(m, player)
			return if t then other(m, t).players else {}
		end
		return opponents(player, ball)
	end

	---------------------------------------------------------------------------
	-- Lanes (one per hoop) and the half-court box
	---------------------------------------------------------------------------
	local function inHalf(d: any, lane: Lane, pos: Vector3, margin: number): boolean
		local center = d.center
		local size = d.size
		local o = pos - center
		if math.abs(o.X) > size.X / 2 + margin or math.abs(o.Z) > size.Z / 2 + margin then
			return false
		end
		-- the lane's half: same side of the centre line as its rim
		local side = (lane.rim - center).Z
		return o.Z * math.sign(side) >= -margin
	end

	local function present(ev: any, d: any, p: Player): boolean
		return p.Parent ~= nil and ctx.isRegistered(ev, p) and ctx.onCourt(d.court, p, 40)
	end

	local function giveTo(m: Match, t: Team)
		local ball = m.ball
		if not ball then
			return
		end
		local here = {}
		for _, p in t.players do
			if p.Parent and playerMatch[p] == m and ctx.rootOf(p) then
				table.insert(here, p)
			end
		end
		if #here == 0 then
			return
		end
		Basketball.give(ball, here[math.random(1, #here)])
		m.lastTouch = t
		m.looseSince = nil
	end

	-- Ball goes to team `t` after a short pause (a "check").
	local function check(m: Match, t: Team, delay: number)
		m.checkAt = os.clock() + delay
		m.checkTo = t
		local ball = m.ball
		if ball and ball.holder then
			Basketball.drop(ball)
		end
	end

	local function finishMatch(ev: any, m: Match, winner: Team, why: string?)
		if m.done then
			return
		end
		m.done = true
		m.winner = winner
		local loser = other(m, winner)
		loser.out = m.round
		loser.lostPoints = m.score[loser]
		for _, p in matchPlayers(m) do
			if playerMatch[p] == m then
				playerMatch[p] = nil
			end
		end
		if m.ball then
			matchBalls[m.ball] = nil
			Basketball.destroy(m.ball)
			m.ball = nil
		end
		if m.lane then
			m.lane.match = nil
			m.lane.freeAt = now() + S.BETWEEN
		end
		local d = ev.data
		table.insert(d.log, 1, string.format("R%d: %s %d-%d %s%s", m.round, winner.name, m.score[winner], m.score[loser], loser.name, if why then " (" .. why .. ")" else ""))
		for _, p in winner.players do
			if p.Parent then
				ctx.announce({ p }, "YOU ADVANCE!")
			end
		end
		for _, p in loser.players do
			if p.Parent then
				ctx.announce({ p }, "ELIMINATED")
				ctx.notify(p, "KNOCKED OUT", string.format("%s beat you %d-%d. Stick around for the payouts.", winner.name, m.score[winner], m.score[loser]))
			end
		end
		ctx.markDirty()
	end

	local function startMatch(ev: any, m: Match, lane: Lane)
		local d = ev.data
		m.lane = lane
		lane.match = m
		local t = now()
		m.startedAt = t
		m.endsAt = t + S.GAME_TIME
		m.a.played = true
		m.b.played = true
		-- offence lines up at the top of the key, defence between them and the rim
		local function place(team: Team, dist: number)
			for i, p in team.players do
				if p.Parent then
					playerMatch[p] = m
					local held = Basketball.heldBall(p)
					if held then
						Basketball.drop(held)
					end
					local side = Vector3.new(-lane.dir.Z, 0, lane.dir.X)
					local pos = Vector3.new(lane.rim.X, d.floorY + 3, lane.rim.Z) + lane.dir * dist + side * ((i - (#team.players + 1) / 2) * 6)
					local character = p.Character
					if character then
						character:PivotTo(CFrame.lookAt(pos, Vector3.new(lane.rim.X, pos.Y, lane.rim.Z)))
					end
				end
			end
		end
		local first = if ctx.rng:NextNumber() < 0.5 then m.a else m.b
		place(first, 23)
		place(other(m, first), 15)
		local ball = Basketball.newBall(lane.key + Vector3.new(0, 3, 0))
		ball.court = d.court
		m.ball = ball
		matchBalls[ball] = m
		check(m, first, 1.5)
		local mode = #m.a.players .. "v" .. #m.b.players
		ctx.announce(matchPlayers(m), string.format("%s · FIRST TO %d", mode, S.TARGET))
		ctx.announce(ctx.audience(ev), string.format("%s VS %s", m.a.name:upper(), m.b.name:upper()))
		ctx.markDirty()
	end

	---------------------------------------------------------------------------
	-- Scoring
	---------------------------------------------------------------------------
	Basketball.scored.connect(function(ball, hoop, shot)
		local m = matchBalls[ball]
		if not m or m.done or not m.lane then
			return
		end
		local d = m.ev.data
		if not d or hoop.court ~= d.court or hoop.side ~= m.lane.side then
			return
		end
		local team = (shot and teamOf(m, shot.shooter)) or teamOf(m, ball.lastHolder) or m.lastTouch
		if not team then
			return
		end
		local points = if shot and shot.points == 3 then 2 else 1
		m.score[team] += points
		if shot and shot.shooter and teamOf(m, shot.shooter) == team then
			PlayerData.recordBasketball(shot.shooter, {
				points = points,
				threes = if points == 2 then 1 else 0,
				dunks = if shot.kind == "dunk" then 1 else 0,
			})
		end
		ctx.announce(matchPlayers(m), string.format("%s +%d  ·  %d-%d", team.name:upper(), points, m.score[m.a], m.score[m.b]))
		ctx.markDirty()
		if m.score[team] >= S.TARGET or m.sudden then
			task.delay(1, function()
				finishMatch(m.ev, m, team, nil)
			end)
			return
		end
		check(m, other(m, team), 1.2)
	end)

	---------------------------------------------------------------------------
	-- Bracket
	---------------------------------------------------------------------------
	local function buildRound(d: any, teams: { Team })
		d.roundTeams = teams
		d.matches = {}
		d.bye = nil
		local list = table.clone(teams)
		if #list % 2 == 1 then
			-- the best seed sits this round out
			table.sort(list, function(a: Team, b: Team)
				return a.seed < b.seed
			end)
			d.bye = table.remove(list, 1)
		end
		-- pair best remaining seed with worst
		table.sort(list, function(a: Team, b: Team)
			return a.seed < b.seed
		end)
		while #list >= 2 do
			local a = table.remove(list, 1) :: Team
			local b = table.remove(list) :: Team
			table.insert(d.matches, {
				round = d.round,
				a = a,
				b = b,
				lane = nil,
				score = { [a] = 0, [b] = 0 },
				startedAt = 0,
				endsAt = 0,
				sudden = false,
				winner = nil,
				ball = nil,
				lastTouch = nil,
				looseSince = nil,
				checkAt = nil,
				checkTo = nil,
				awaySince = {},
				done = false,
				ev = d.ev,
			} :: Match)
		end
	end

	local function finish(ev: any, champion: Team?)
		local d = ev.data
		-- champion, then by round reached, then points in the losing game, then seed
		local order = table.clone(d.teams)
		table.sort(order, function(a: Team, b: Team)
			if a == champion then
				return true
			elseif b == champion then
				return false
			end
			local ra, rb = a.out or math.huge, b.out or math.huge
			if ra ~= rb then
				return ra > rb
			end
			if a.lostPoints ~= b.lostPoints then
				return a.lostPoints > b.lostPoints
			end
			return a.seed < b.seed
		end)
		local lines = {}
		for place, team in order do
			if place <= 4 then
				table.insert(lines, string.format("%d. %s%s", place, team.name, if team == champion then " 🏆" elseif team.out then " (out R" .. team.out .. ")" else ""))
			end
			for _, p in team.players do
				if p.Parent and ctx.isRegistered(ev, p) then
					ctx.payPlace(ev, p, place, #order, team.played)
					PlayerData.addStatXP(p, "BallHandling", 10)
					if team == champion then
						local sec = ctx.section(p)
						if sec then
							sec.streetballWins = (sec.streetballWins or 0) + 1
							PlayerData.markChanged(p)
						end
						PlayerData.addFame(p, 15)
					end
				end
			end
		end
		for i = 1, math.min(2, #d.log) do
			table.insert(lines, d.log[i])
		end
		ctx.pushResult(ev, lines, if champion then champion.name else nil)
		if champion then
			ctx.announce(ctx.audience(ev), champion.name:upper() .. " WIN THE STREETBALL TOURNAMENT")
		end
		ctx.closeEvent(ev)
	end

	---------------------------------------------------------------------------
	-- Handlers
	---------------------------------------------------------------------------
	local function pickCourt(prefer: any): Model?
		return ctx.freeCourt(prefer or COURT_PREFER, ctx.threeCourt()) or ctx.freeCourt(prefer or COURT_PREFER, nil)
	end

	local handlers = {}
	handlers.tip = "Be on the tournament court at check-in. Ones and twos, first to " .. S.TARGET .. "."

	function handlers.available(): boolean
		return pickCourt(nil) ~= nil
	end

	function handlers.pickVenue(): (Vector3, string?, any)
		local court = pickCourt(nil)
		if not court then
			return nil :: any, nil, nil
		end
		return ctx.courtCenter(court) + Vector3.new(0, 0, ctx.courtSize(court).Z / 2 + 8), ctx.courtLabel(court), court
	end

	function handlers.goLive(ev: any): (string, string?)
		local court = pickCourt(ev.venue)
		if not court then
			return "postpone", "Every court is busy with games."
		end
		ctx.claimCourt(court, ev.name)
		ev.venue = court
		ev.location = ctx.courtLabel(court)
		ev.pos = ctx.courtCenter(court) + Vector3.new(0, 0, ctx.courtSize(court).Z / 2 + 8)
		local center = ctx.courtCenter(court)
		local folder = Instance.new("Folder")
		folder.Name = "StreetballTournament"
		folder.Parent = ctx.root
		local banner = ctx.part({
			name = "Banner",
			size = Vector3.new(30, 4, 0.4),
			cframe = CFrame.new(center + Vector3.new(0, 18, 0)),
			color = Color3.fromRGB(20, 20, 26),
			collide = false,
			parent = folder,
		})
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			ctx.surfaceText(banner, face, "🏆 STREETBALL TOURNAMENT", Color3.fromRGB(255, 170, 70))
		end
		local lanes: { Lane } = {}
		for _, side in { "North", "South" } do
			local rim = ctx.rimOf(court, side) :: Vector3
			local dir = ctx.flat(center - rim)
			dir = if dir.Magnitude > 0.1 then dir.Unit else Vector3.new(0, 0, 1)
			table.insert(lanes, { side = side, rim = rim, dir = dir, key = Vector3.new(rim.X, center.Y + 0.5, rim.Z) + dir * 20, match = nil, freeAt = 0 })
		end
		ev.data = {
			ev = ev,
			court = court,
			center = center,
			size = ctx.courtSize(court),
			floorY = center.Y + 0.45,
			folder = folder,
			lanes = lanes,
			teams = {} :: { Team },
			round = 0,
			roundTeams = {} :: { Team },
			matches = {} :: { Match },
			bye = nil :: Team?,
			log = {} :: { string },
			mode = "1v1",
		}
		ev.state = "Checkin"
		ev.phase = "Check-in: get on the court"
		ev.phaseEndsAt = now() + S.CHECKIN
		return "live", nil
	end

	local function tickMatch(ev: any, d: any, m: Match)
		local lane = m.lane :: Lane
		local t = now()
		local clock = os.clock()
		-- presence: a team with nobody left at the court forfeits
		for _, team in { m.a, m.b } do
			local anyone = false
			for _, p in team.players do
				if p.Parent and ctx.isRegistered(ev, p) then
					if ctx.onCourt(d.court, p, 25) then
						m.awaySince[p] = nil
						anyone = true
					else
						m.awaySince[p] = m.awaySince[p] or t
						if t - m.awaySince[p] < 10 then
							anyone = true
						end
					end
				end
			end
			if not anyone then
				finishMatch(ev, m, other(m, team), "forfeit")
				return
			end
		end

		local ball = m.ball
		if not ball or not Basketball.balls()[ball] then
			-- the ball vanished (fell out of the world): new one to the side that didn't touch it last
			local nb = Basketball.newBall(lane.key + Vector3.new(0, 3, 0))
			nb.court = d.court
			if ball then
				matchBalls[ball] = nil
			end
			m.ball = nb
			matchBalls[nb] = m
			check(m, if m.lastTouch then other(m, m.lastTouch) else m.a, 0.5)
			return
		end

		if m.checkAt then
			if clock >= m.checkAt then
				local to = m.checkTo or m.a
				m.checkAt = nil
				m.checkTo = nil
				Basketball.moveTo(ball, lane.key + Vector3.new(0, 3, 0))
				giveTo(m, to)
			end
		elseif ball.holder then
			local team = teamOf(m, ball.holder)
			m.lastTouch = team or m.lastTouch
			m.looseSince = nil
			local r = ctx.rootOf(ball.holder)
			if r and team and not inHalf(d, lane, r.Position, 1.5) then
				ctx.announce(matchPlayers(m), "OUT OF BOUNDS")
				check(m, other(m, team), 0.8)
			end
		elseif not ball.part.Anchored then
			local pos = ball.part.Position
			m.looseSince = m.looseSince or clock
			if not inHalf(d, lane, pos, 1.5) and pos.Y < d.center.Y + 4 then
				ctx.announce(matchPlayers(m), "OUT OF BOUNDS")
				check(m, if m.lastTouch then other(m, m.lastTouch) else m.a, 0.8)
			elseif clock - (m.looseSince :: number) > S.LOOSE_TURNOVER then
				check(m, if m.lastTouch then other(m, m.lastTouch) else m.a, 0.3)
			end
		end

		if not m.done and t >= m.endsAt then
			local sa, sb = m.score[m.a], m.score[m.b]
			if sa ~= sb then
				finishMatch(ev, m, if sa > sb then m.a else m.b, "time")
			elseif not m.sudden then
				m.sudden = true
				m.endsAt = t + SUDDEN_LIMIT
				ctx.announce(matchPlayers(m), "TIED! NEXT BUCKET WINS")
				ctx.markDirty()
			else
				finishMatch(ev, m, if m.a.seed < m.b.seed then m.a else m.b, "seed tiebreak")
			end
		end
	end

	function handlers.tick(ev: any)
		local d = ev.data
		local court: Model = d.court
		if not court.Parent then
			ctx.cancelEvent(ev, "The court is gone.")
			return
		end
		local t = now()
		if ev.state == "Checkin" then
			if t < ev.phaseEndsAt then
				return
			end
			local players = {}
			for _, p in table.clone(ev.registered) do
				if p.Parent and ctx.onCourt(court, p, 15) then
					table.insert(players, p)
				else
					ctx.dropEntrant(ev, p, "MISSED CHECK-IN", "You weren't at the court when the Streetball Tournament started.")
				end
			end
			if #players < ctx.minEntrants(ev.kind) then
				ctx.cancelEvent(ev, string.format("A tournament needs at least %d players at the court.", ctx.minEntrants(ev.kind)))
				return
			end
			for i = #players, 2, -1 do
				local j = ctx.rng:NextInteger(1, i)
				players[i], players[j] = players[j], players[i]
			end
			local size = if #players >= S.TWO_V_TWO_FROM and #players % 2 == 0 then 2 else 1
			d.mode = size .. "v" .. size
			for i = 1, #players, size do
				local members = {}
				for k = i, math.min(#players, i + size - 1) do
					table.insert(members, players[k])
				end
				local names = {}
				for _, p in members do
					table.insert(names, p.DisplayName)
				end
				table.insert(d.teams, { id = #d.teams + 1, players = members, name = table.concat(names, " & "), seed = #d.teams + 1, out = nil, lostPoints = 0, played = false })
			end
			d.round = 1
			buildRound(d, d.teams)
			ev.state = "Running"
			ev.phase = string.format("Round 1 · %s", d.mode)
			ev.phaseEndsAt = 0
			ctx.announce(players, string.format("%d TEAMS · %s · FIRST TO %d", #d.teams, d.mode, S.TARGET))
			ctx.markDirty()
			return
		end

		-- live games
		for _, lane in d.lanes do
			local m = lane.match
			if m and not m.done then
				tickMatch(ev, d, m)
			end
		end
		-- start waiting games on free hoops
		for _, m in d.matches do
			if not m.done and not m.lane then
				local lane: Lane? = nil
				for _, l in d.lanes do
					if not l.match and t >= l.freeAt then
						lane = l
						break
					end
				end
				if not lane then
					break
				end
				-- a team with nobody at the court forfeits on the spot
				local aHere, bHere = false, false
				for _, p in m.a.players do
					aHere = aHere or present(ev, d, p)
				end
				for _, p in m.b.players do
					bHere = bHere or present(ev, d, p)
				end
				if not aHere and not bHere then
					m.a.played, m.b.played = false, false
					finishMatch(ev, m, if m.a.seed < m.b.seed then m.a else m.b, "no-show")
				elseif not aHere then
					m.b.played = true
					finishMatch(ev, m, m.b, "no-show")
				elseif not bHere then
					m.a.played = true
					finishMatch(ev, m, m.a, "no-show")
				else
					startMatch(ev, m, lane)
				end
			end
		end

		-- round over?
		for _, m in d.matches do
			if not m.done then
				return
			end
		end
		local winners: { Team } = {}
		for _, m in d.matches do
			if m.winner then
				table.insert(winners, m.winner)
			end
		end
		if d.bye then
			table.insert(winners, d.bye)
		end
		if #winners <= 1 then
			finish(ev, winners[1])
			return
		end
		d.round += 1
		buildRound(d, winners)
		ev.phase = if #winners == 2 then "Final · " .. d.mode else string.format("Round %d · %s", d.round, d.mode)
		ctx.announce(ctx.audience(ev), if #winners == 2 then "THE FINAL IS NEXT" else "ROUND " .. d.round)
		ctx.markDirty()
	end

	function handlers.live(ev: any, viewer: Player): any
		local d = ev.data
		local lines = {}
		local status
		local out: any = { lines = lines, endsAt = ev.phaseEndsAt }
		if ev.state == "Checkin" then
			local here = 0
			for _, p in ev.registered do
				if ctx.onCourt(d.court, p, 15) then
					here += 1
				end
			end
			table.insert(lines, string.format("%d / %d players at %s", here, #ev.registered, ctx.courtLabel(d.court)))
			table.insert(lines, string.format("%d+ players (even) plays 2v2, otherwise 1v1.", S.TWO_V_TWO_FROM))
			status = if ctx.isRegistered(ev, viewer)
				then (if ctx.onCourt(d.court, viewer, 15) then "Checked in. Warm up!" else "Get to the court!")
				else "Check-in is open"
		else
			local mine: Match? = nil
			for _, lane in d.lanes do
				local m = lane.match
				if m then
					local left = math.max(0, m.endsAt - now())
					table.insert(lines, string.format("%s hoop: %s %d-%d %s · %s", lane.side, m.a.name, m.score[m.a], m.score[m.b], m.b.name, if m.sudden then "next bucket" else EC.formatIn(left)))
					if teamOf(m, viewer) then
						mine = m
					end
				end
			end
			local waiting = {}
			for _, m in d.matches do
				if not m.done and not m.lane then
					table.insert(waiting, m.a.name .. " vs " .. m.b.name)
				end
			end
			if #waiting > 0 then
				table.insert(lines, "Up next: " .. table.concat(waiting, " · "))
			end
			if d.bye then
				table.insert(lines, "Bye: " .. d.bye.name)
			end
			for i = 1, math.min(2, #d.log) do
				table.insert(lines, d.log[i])
			end
			if mine then
				local myTeam = teamOf(mine, viewer) :: Team
				local them = other(mine, myTeam)
				status = string.format("YOUR GAME · %d-%d vs %s", mine.score[myTeam], mine.score[them], them.name)
				out.endsAt = mine.endsAt
				out.highlight = true
			elseif ctx.isRegistered(ev, viewer) then
				local myTeam: Team? = nil
				for _, team in d.teams do
					if table.find(team.players, viewer) then
						myTeam = team
					end
				end
				if myTeam and myTeam.out then
					status = string.format("Out in round %d. Payouts at the end.", myTeam.out)
				elseif myTeam and d.bye == myTeam then
					status = "Bye this round. Stay close."
				else
					status = "Your game is coming up. Stay at the court."
				end
			else
				status = "Watching the bracket"
			end
		end
		out.status = status
		return out
	end

	function handlers.leave(ev: any, p: Player)
		local m = playerMatch[p]
		if m and m.ev == ev then
			playerMatch[p] = nil
			if m.ball and m.ball.holder == p then
				Basketball.drop(m.ball)
			end
		end
	end

	function handlers.cleanup(ev: any)
		local d = ev.data
		for ball, m in matchBalls do
			if m.ev == ev then
				matchBalls[ball] = nil
				Basketball.destroy(ball)
			end
		end
		for p, m in playerMatch do
			if m.ev == ev then
				playerMatch[p] = nil
			end
		end
		if d then
			for _, m in d.matches or {} do
				m.done = true
			end
			if d.folder then
				d.folder:Destroy()
			end
			ctx.releaseCourt(d.court)
		end
	end

	Players.PlayerRemoving:Connect(function(p)
		playerMatch[p] = nil
	end)

	return handlers
end

return EventStreetball
