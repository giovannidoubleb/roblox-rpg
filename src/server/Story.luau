-- CITY GRIND: the story (spec sections 83, 109, 110). Server side.
--
-- * First join: the client plays a camera fly-over of the city (Story client).
--   Messages.luau already sends Coach Ray's two intro texts on a first join, so
--   this module never repeats them; it sends each chapter's mission briefing
--   and wrap-up through Messages.sendSystem("Coach Ray", ...).
-- * 8 chapters of real missions (shared/StoryConfig). A mission completes when
--   its server-side metric (Quests.metric) reaches the goal; the client never
--   reports progress. Missions that need the districts are skipped when the
--   districts aren't built. Each mission pays a little; each chapter pays more
--   and gets a banner + Coach Ray message. Finishing Chapter 8 unlocks the
--   "Rise to the Top" achievement.
--
-- Remotes: StoryRequest (RemoteFunction, client -> server: "Get" | "CinematicDone") -> state
--          StoryEvent   (RemoteEvent, server -> client):
--            ("State", state) | ("Cinematic") | ("Chapter", info) | ("Mission", title, text)
-- Player attribute: StoryCinematic (true while the intro fly-over plays).
-- Saved section "story": { chapter, mission, cinematic, introSent, done }

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local SC = require(shared:WaitForChild("StoryConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Quests = require(script.Parent:WaitForChild("Quests"))

local Story = {}

local SECTION = "story"
local CHAPTERS = SC.CHAPTERS

PlayerData.registerSection(SECTION, function()
	return {
		chapter = 1,
		mission = 1,
		cinematic = false, -- intro fly-over handled (played or skipped)
		introSent = 0, -- last chapter whose Coach Ray briefing was sent
		done = false,
	}
end)

local function sec(player: Player): any
	return PlayerData.section(player, SECTION)
end

local StoryEvent: RemoteEvent
local cityModel: Instance? = nil
local active: { [Player]: boolean } = {} -- story running (cinematic finished)
local loadedAt: { [Player]: number } = {}
local signatures: { [Player]: string } = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local messagesModule: any = nil
local function coach(player: Player, text: string)
	if messagesModule == nil then
		messagesModule = false
		local module = script.Parent:FindFirstChild("Messages")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				messagesModule = result
			end
		end
	end
	if messagesModule and type(messagesModule.sendSystem) == "function" and player.Parent then
		local ok, err = pcall(messagesModule.sendSystem, player, SC.COACH, text)
		if ok then
			return
		end
		warn("[CityGrind] Story: Coach Ray message failed:", err)
	end
	Net.notify(player, SC.COACH, text) -- no Messages module: still tell them
end

local function available(m: SC.Mission): boolean
	return m.needs ~= "districts" or Quests.districtsAvailable()
end

local function isComplete(player: Player, m: SC.Mission): boolean
	if Quests.metric(player, m.metric) >= m.goal then
		return true
	end
	return m.alt ~= nil and Quests.metric(player, m.alt.metric) >= m.alt.goal
end

-- Where a mission's GPS should point, worked out from the live city.
local function placePosition(player: Player, place: string?): Vector3?
	if not place then
		return nil
	end
	local city = cityModel or workspace:FindFirstChild("City")
	if place == "court" then
		local best, bestDist = nil, math.huge
		for _, court in CollectionService:GetTagged("Court") do
			local c = court:GetAttribute("CourtCenter")
			if typeof(c) == "Vector3" then
				local d = Net.distance(player, c)
				if d < bestDist or best == nil then
					best, bestDist = c, d
				end
			end
		end
		return best
	end
	local points = city and city:FindFirstChild("MapPoints")
	local point = points and points:FindFirstChild(place)
	if point and point:IsA("BasePart") then
		return point.Position
	end
	local districts = city and city:FindFirstChild("Districts")
	local district = districts and districts:FindFirstChild(place)
	local center = district and district:GetAttribute("Center")
	if typeof(center) == "Vector3" then
		return center
	end
	return nil
end

---------------------------------------------------------------------------
-- State for the client
---------------------------------------------------------------------------
local function stateFor(player: Player): any
	local s = sec(player)
	if not s then
		return nil
	end
	local chapter = CHAPTERS[s.chapter]
	local state: any = {
		chapter = s.chapter,
		mission = s.mission,
		done = s.done,
		active = active[player] == true,
		chapterCount = #CHAPTERS,
	}
	if s.done or not chapter then
		state.done = true
		return state
	end
	local list = {}
	for i, m in chapter.missions do
		local status = if not available(m) then "skipped" elseif i < s.mission then "done" elseif i == s.mission then "current" else "todo"
		table.insert(list, { status = status })
	end
	state.statuses = list
	local m = chapter.missions[s.mission]
	if m then
		state.progress = math.min(Quests.metric(player, m.metric), m.goal)
		state.altProgress = if m.alt then math.min(Quests.metric(player, m.alt.metric), m.alt.goal) else nil
		local pos = placePosition(player, m.place)
		if pos then
			state.gps = { name = if m.place == "court" then "Basketball Court" else m.place, x = pos.X, y = pos.Y, z = pos.Z }
		end
	end
	return state
end

local function pushState(player: Player, force: boolean?)
	local state = stateFor(player)
	if not state or not StoryEvent or not player.Parent then
		return
	end
	-- the GPS spot of "court" changes as the player moves; don't resend for that alone
	local sigState = table.clone(state)
	sigState.gps = state.gps and state.gps.name
	local ok, signature = pcall(HttpService.JSONEncode, HttpService, sigState)
	if not force and ok and signatures[player] == signature then
		return
	end
	signatures[player] = if ok then signature else ""
	StoryEvent:FireClient(player, "State", state)
end

---------------------------------------------------------------------------
-- Progression
---------------------------------------------------------------------------
local function briefing(player: Player, s: any)
	local chapter = CHAPTERS[s.chapter]
	if not chapter or s.introSent >= s.chapter then
		return
	end
	s.introSent = s.chapter
	PlayerData.markChanged(player)
	local m = chapter.missions[s.mission]
	local text = string.format("Chapter %d: %s. %s", s.chapter, chapter.name, chapter.intro)
	coach(player, text)
	if m then
		StoryEvent:FireClient(player, "Mission", if s.chapter == 1 and s.mission == 1 then SC.FIRST_MOVE else "CHAPTER " .. s.chapter .. ": " .. chapter.name:upper(), m.text)
	end
end

local evaluate: (Player) -> ()

local function completeChapter(player: Player, s: any)
	local index = s.chapter
	local chapter = CHAPTERS[index]
	PlayerData.addCash(player, chapter.cash, "Story: Chapter " .. index .. " complete")
	PlayerData.addXP(player, chapter.xp)
	PlayerData.addReputation(player, chapter.rep)
	StoryEvent:FireClient(player, "Chapter", { chapter = index, name = chapter.name, cash = chapter.cash, xp = chapter.xp, rep = chapter.rep, last = index == #CHAPTERS })
	coach(player, chapter.outro)
	if index >= #CHAPTERS then
		s.done = true
		PlayerData.markChanged(player)
		Quests.unlock(player, "story_done") -- grants the "Top of the City" title
		return
	end
	s.chapter = index + 1
	s.mission = 1
	PlayerData.markChanged(player)
	task.delay(7, function()
		local now = sec(player)
		if player.Parent and now and now.chapter == index + 1 then
			briefing(player, now)
			evaluate(player)
		end
	end)
end

-- Completes every finished (or skipped) mission in order.
evaluate = function(player: Player)
	local s = sec(player)
	if not s or s.done or not active[player] then
		return
	end
	for _ = 1, 64 do -- safety bound
		local chapter = CHAPTERS[s.chapter]
		if not chapter then
			s.done = true
			PlayerData.markChanged(player)
			break
		end
		local m = chapter.missions[s.mission]
		if not m then
			completeChapter(player, s)
			break -- the next chapter starts after its briefing
		elseif not available(m) then
			s.mission += 1
			PlayerData.markChanged(player)
		elseif isComplete(player, m) then
			local cash = SC.MISSION_CASH * s.chapter
			local xp = SC.MISSION_XP * s.chapter
			s.mission += 1
			PlayerData.markChanged(player)
			PlayerData.addCash(player, cash, "Story: " .. m.text)
			PlayerData.addXP(player, xp)
			local nextMission = chapter.missions[s.mission]
			StoryEvent:FireClient(player, "Mission", "MISSION COMPLETE", m.text .. "  +$" .. cash .. "  +" .. xp .. " XP")
			if nextMission and available(nextMission) then
				Net.notify(player, "NEXT MISSION", nextMission.text)
			end
		else
			break
		end
	end
	pushState(player)
end

local function startStory(player: Player)
	local s = sec(player)
	if not s or active[player] then
		return
	end
	active[player] = true
	player:SetAttribute("StoryCinematic", false)
	if not s.cinematic then
		s.cinematic = true
		PlayerData.markChanged(player)
	end
	pushState(player, true)
	if s.done then
		return
	end
	-- Messages sends Coach Ray's two welcome texts ~8-12 s after a first load;
	-- the chapter briefing follows them, never replaces them.
	local wait = math.max(3, 15 - (os.clock() - (loadedAt[player] or 0)))
	task.delay(wait, function()
		local now = sec(player)
		if player.Parent and now and active[player] then
			briefing(player, now)
			evaluate(player)
		end
	end)
end

local function onLoaded(player: Player)
	local s = sec(player)
	local data = PlayerData.get(player)
	if not s or not data or not player.Parent then
		return
	end
	loadedAt[player] = os.clock()
	if s.cinematic then
		startStory(player)
		return
	end
	-- Only brand-new players get the fly-over; saves from before the story skip it.
	local brandNew = data.level <= 1 and data.xp < 100 and os.time() - (data.firstJoin or 0) < 30 * 60
	if not brandNew then
		startStory(player)
		return
	end
	player:SetAttribute("StoryCinematic", true)
	StoryEvent:FireClient(player, "Cinematic")
	-- never leave the story waiting on a client that doesn't answer
	task.delay(75, function()
		if player.Parent and not active[player] then
			startStory(player)
		end
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Story.start(city: Instance)
	cityModel = city
	StoryEvent = Net.remote("RemoteEvent", "StoryEvent")
	local Request = Net.remote("RemoteFunction", "StoryRequest")

	Request.OnServerInvoke = function(player: Player, action: any)
		if type(action) ~= "string" or not Net.allow(player, "StoryRequest", 0.25) then
			return nil
		end
		if action == "CinematicDone" then
			-- only meaningful while the fly-over is pending; harmless otherwise
			if player:GetAttribute("StoryCinematic") == true then
				startStory(player)
			end
		elseif action ~= "Get" then
			return nil
		end
		return stateFor(player)
	end

	Quests.onProgress(evaluate)
	PlayerData.onLoaded(onLoaded)
	Players.PlayerRemoving:Connect(function(player)
		active[player] = nil
		loadedAt[player] = nil
		signatures[player] = nil
	end)
end

return Story
