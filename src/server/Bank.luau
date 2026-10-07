-- CITY GRIND: City Bank (sections 39, 49). Server side.
-- * Balance, recent transactions, and income vs expenses for the last 24h / 7d.
--   PlayerData keeps only the newest transactions, so this module also keeps an
--   hourly ledger (saved) fed by every transaction PlayerData logs.
-- * Player transfers between friends in this server, fully validated here:
--   friends both ways, both online + loaded, integer amount 1..1,000,000, cash on
--   hand, daily send/receive limits, 10 s cooldown, Level 5+ (and account age)
--   to send, optional note filtered for each reader. Money moves with
--   PlayerData.spendCash + addCash; if the deposit fails the sender is refunded.
-- * Three ATM kiosks in the Neighborhood; their prompt opens the Bank app.
--
-- Remotes:  BankAction (RemoteFunction) client -> server (action, a, b, c) -> (ok, message?, data?)
--           BankEvent  (RemoteEvent)    server -> client ("openATM") | ("refresh")
-- Saved section "Bank": { day, sent, received, hours = { [hourIndex: string] = { i, e } }, ledgerInit }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Net = require(script.Parent:WaitForChild("Net"))
local Places = require(script.Parent:WaitForChild("Places"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local BC = require(shared:WaitForChild("BankConfig"))

local Bank = {}

local SECTION = "Bank"
local IS_STUDIO = RunService:IsStudio()

PlayerData.registerSection(SECTION, function()
	return { day = 0, sent = 0, received = 0, hours = {}, ledgerInit = false }
end)

local BankAction: RemoteFunction
local BankEvent: RemoteEvent

-- Newest transaction table already counted into the hourly ledger, per player.
local lastCounted: { [Player]: any } = {}
local busy: { [Player]: boolean } = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local socialModule: any = nil
local function social(): any
	if socialModule == nil then
		socialModule = false
		local module = script.Parent:FindFirstChild("Social")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				socialModule = result
			end
		end
	end
	return socialModule or nil
end

local function areFriends(a: Player, b: Player): boolean
	local S = social()
	if not S or type(S.areFriends) ~= "function" then
		return false
	end
	local ok, result = pcall(S.areFriends, a, b)
	return ok and result == true
end

local function isBlocked(a: Player, b: Player): boolean
	local S = social()
	if not S or type(S.isBlocked) ~= "function" then
		return false
	end
	local ok, result = pcall(S.isBlocked, a, b)
	return ok and result == true
end

local function sec(player: Player): any
	return PlayerData.section(player, SECTION)
end

local function today(): number
	return os.time() // 86400
end

-- Resets the daily counters when a new (UTC) day starts.
local function rollDay(s: any)
	local d = today()
	if s.day ~= d then
		s.day = d
		s.sent = 0
		s.received = 0
	end
end

local function hourIndex(t: number): number
	return t // 3600
end

local function bucketAdd(s: any, t: number, amount: number)
	local key = tostring(hourIndex(t))
	local b = s.hours[key]
	if not b then
		b = { i = 0, e = 0 }
		s.hours[key] = b
	end
	if amount > 0 then
		b.i += amount
	else
		b.e -= amount
	end
end

local function pruneHours(s: any)
	local oldest = hourIndex(os.time()) - BC.LEDGER_HOURS
	for key in s.hours do
		local h = tonumber(key)
		if not h or h <= oldest then
			s.hours[key] = nil
		end
	end
end

-- Totals over the last `hours` hours (current hour included).
local function totals(s: any, hours: number): (number, number)
	local income, expenses = 0, 0
	local from = hourIndex(os.time()) - hours
	for key, b in s.hours do
		local h = tonumber(key)
		if h and h > from then
			income += b.i or 0
			expenses += b.e or 0
		end
	end
	return income, expenses
end

-- Counts every transaction PlayerData logged since the last publish.
local function countNew(player: Player, data: any)
	local s = data.sections and data.sections[SECTION]
	local list = data.transactions
	if not s or type(list) ~= "table" then
		return
	end
	local top = list[1]
	if lastCounted[player] == nil then
		lastCounted[player] = top or false
		return
	end
	if top == nil or top == lastCounted[player] then
		return
	end
	for _, t in list do
		if t == lastCounted[player] then
			break
		end
		if type(t.amount) == "number" and type(t.t) == "number" then
			bucketAdd(s, t.t, t.amount)
		end
	end
	lastCounted[player] = top
	pruneHours(s)
end

local function canChat(fromId: number, toId: number): boolean
	if IS_STUDIO and (fromId <= 0 or toId <= 0) then
		return true
	end
	local ok, result = pcall(function()
		return TextChatService:CanUsersChatAsync(fromId, toId)
	end)
	return ok and result == true
end

local function cleanNote(raw: any): (boolean, string?)
	if raw == nil or raw == "" then
		return true, nil
	end
	if type(raw) ~= "string" or #raw > BC.NOTE_MAX * 4 + 16 or utf8.len(raw) == nil then
		return false, nil
	end
	local text = raw:gsub("%c", " "):gsub("%s+", " ")
	text = text:match("^%s*(.-)%s*$") or ""
	local length = utf8.len(text)
	if text == "" then
		return true, nil
	end
	if not length or length > BC.NOTE_MAX then
		return false, nil
	end
	return true, text
end

-- Filters a note for the sender and the receiver (nil, nil if filtering failed).
local function filterNote(note: string, from: Player, to: Player): (string?, string?)
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(note, from.UserId, Enum.TextFilterContext.PrivateChat)
	end)
	if ok and result then
		local okTo, forTo = pcall(function()
			return result:GetChatForUserAsync(to.UserId)
		end)
		local okFrom, forFrom = pcall(function()
			return result:GetChatForUserAsync(from.UserId)
		end)
		if okTo and type(forTo) == "string" then
			return if okFrom and type(forFrom) == "string" then forFrom else forTo, forTo
		end
	end
	if IS_STUDIO and from.UserId <= 0 then
		return note, note -- Studio test players can't be filtered
	end
	return nil, nil
end

local function levelOf(player: Player): number
	local data = PlayerData.get(player)
	return if data then data.level else 0
end

-- Why `player` can't send money at all right now (nil = can send).
local function sendBlockReason(player: Player): string?
	if levelOf(player) < BC.MIN_LEVEL_TO_SEND then
		return "Reach Level " .. BC.MIN_LEVEL_TO_SEND .. " to send money."
	end
	if not IS_STUDIO and player.AccountAge < BC.MIN_ACCOUNT_AGE_DAYS then
		return "Your Roblox account is too new to send money."
	end
	return nil
end

---------------------------------------------------------------------------
-- Transfers
---------------------------------------------------------------------------
local function formatCash(n: number): string
	local digits = tostring(math.floor(math.abs(n)))
	local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return "$" .. out
end

-- Every rule a transfer must pass. Never yields, so it can run right before the money moves.
local function checkTransfer(player: Player, target: Player, amount: number): (boolean, string?)
	if player.Parent ~= Players or target.Parent ~= Players then
		return false, "Your friend has to be in this server."
	end
	local fromData, toData = PlayerData.get(player), PlayerData.get(target)
	local fromSec, toSec = sec(player), sec(target)
	if not fromData or not toData or not fromSec or not toSec then
		return false, "Still loading in. Try again in a moment."
	end
	local blockReason = sendBlockReason(player)
	if blockReason then
		return false, blockReason
	end
	if isBlocked(player, target) or not areFriends(player, target) then
		return false, "You can only send money to friends."
	end
	rollDay(fromSec)
	rollDay(toSec)
	if fromData.cash < amount then
		return false, "You don't have enough cash."
	end
	if fromSec.sent + amount > BC.DAILY_SEND_LIMIT then
		local left = math.max(0, BC.DAILY_SEND_LIMIT - fromSec.sent)
		return false, "Daily send limit reached. You can send " .. formatCash(left) .. " more today."
	end
	if toSec.received + amount > BC.DAILY_RECEIVE_LIMIT then
		return false, target.DisplayName .. " can't receive that much more today."
	end
	if toData.cash + amount > Config.MAX_CASH then
		return false, target.DisplayName .. "'s account can't hold that much."
	end
	return true, nil
end

local function transfer(player: Player, targetId: any, amount: any, rawNote: any): (boolean, string?)
	if type(targetId) ~= "number" or targetId ~= targetId or targetId % 1 ~= 0 then
		return false, "Pick a friend to send money to."
	end
	if type(amount) ~= "number" or amount ~= amount or amount % 1 ~= 0 or amount < BC.MIN_TRANSFER or amount > BC.MAX_TRANSFER then
		return false, "Enter a whole amount from " .. formatCash(BC.MIN_TRANSFER) .. " to " .. formatCash(BC.MAX_TRANSFER) .. "."
	end
	local okNote, note = cleanNote(rawNote)
	if not okNote then
		return false, "Notes are up to " .. BC.NOTE_MAX .. " characters."
	end
	if targetId == player.UserId then
		return false, "You can't send money to yourself."
	end
	local target = Players:GetPlayerByUserId(targetId)
	if not target then
		return false, "Your friend has to be in this server."
	end
	if busy[player] then
		return false, "Your last transfer is still going through."
	end
	local ok, why = checkTransfer(player, target, amount)
	if not ok then
		return false, why
	end
	if not Net.allow(player, "BankTransfer", BC.TRANSFER_COOLDOWN) then
		return false, "Wait a few seconds between transfers."
	end

	-- Filtering yields, so it happens before the final check and the money move.
	local noteForSender, noteForTarget
	if note then
		busy[player] = true
		local chatOk = canChat(player.UserId, target.UserId)
		if chatOk then
			noteForSender, noteForTarget = filterNote(note, player, target)
		end
		busy[player] = nil
		if not chatOk then
			return false, "Notes can't be sent to this player. Remove the note and try again."
		end
		if not noteForTarget then
			return false, "Your note couldn't be checked right now. Remove it or try again."
		end
	end

	-- From here on nothing yields: re-validate and move the money in one step.
	ok, why = checkTransfer(player, target, amount)
	if not ok then
		return false, why
	end
	local sentLabel = "Sent to " .. target.DisplayName .. (if noteForSender then " · " .. noteForSender else "")
	local fromLabel = "From " .. player.DisplayName .. (if noteForTarget then " · " .. noteForTarget else "")
	if not PlayerData.spendCash(player, amount, sentLabel) then
		return false, "You don't have enough cash."
	end
	if not PlayerData.addCash(target, amount, fromLabel) then
		PlayerData.addCash(player, amount, "Refund · transfer to " .. target.DisplayName)
		return false, "The transfer failed and your money was returned."
	end
	local fromSec, toSec = sec(player), sec(target)
	fromSec.sent += amount
	toSec.received += amount
	PlayerData.markChanged(player)
	PlayerData.markChanged(target)

	local cash = formatCash(amount)
	Net.notify(player, "MONEY SENT", "You sent " .. cash .. " to " .. target.DisplayName .. ".")
	Net.notify(target, "MONEY RECEIVED", player.DisplayName .. " sent you " .. cash .. (if noteForTarget then ": " .. noteForTarget else "."))
	BankEvent:FireClient(player, "refresh")
	BankEvent:FireClient(target, "refresh")
	return true, "Sent " .. cash .. " to " .. target.DisplayName .. "."
end

---------------------------------------------------------------------------
-- Phone data
---------------------------------------------------------------------------
local function summary(player: Player)
	local data = PlayerData.get(player)
	local s = sec(player)
	if not data or not s then
		return nil
	end
	rollDay(s)
	pruneHours(s)
	local in24, out24 = totals(s, 24)
	local in7, out7 = totals(s, 24 * 7)
	local friends = {}
	for _, p in Players:GetPlayers() do
		if p ~= player and areFriends(player, p) and not isBlocked(player, p) then
			table.insert(friends, { userId = p.UserId, name = p.DisplayName, username = p.Name })
		end
	end
	table.sort(friends, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return {
		cash = data.cash,
		level = data.level,
		transactions = table.clone(data.transactions),
		income24 = in24,
		expenses24 = out24,
		income7 = in7,
		expenses7 = out7,
		sentToday = s.sent,
		receivedToday = s.received,
		sendBlock = sendBlockReason(player),
		friends = friends,
	}
end

local function onAction(player: Player, action: any, a: any, b: any, c: any): (boolean, string?, any)
	if action == "summary" then
		if not Net.allow(player, "BankSummary", 0.4) then
			return false, nil, nil
		end
		local data = summary(player)
		return data ~= nil, if data then nil else "Your account is still loading.", data
	elseif action == "transfer" then
		return transfer(player, a, b, c)
	end
	return false, nil, nil
end

---------------------------------------------------------------------------
-- ATMs (section 49 "Use ATMs")
---------------------------------------------------------------------------
-- Candidate sidewalk/storefront spots, in order of preference. `face` is the
-- direction the screen looks (toward the street). The first three clear spots win.
local ATM_SPOTS = {
	{ name = "ATM · Corner Mart", pos = Vector3.new(-99, 0, 43), face = Vector3.new(0, 0, -1) },
	{ name = "ATM · Mama's Kitchen", pos = Vector3.new(97, 0, 43), face = Vector3.new(0, 0, -1) },
	{ name = "ATM · Maple Court", pos = Vector3.new(-58, 0, -40), face = Vector3.new(0, 0, 1) },
	{ name = "ATM · Subway", pos = Vector3.new(62, 0, -40), face = Vector3.new(0, 0, 1) },
	{ name = "ATM · Threads", pos = Vector3.new(-152, 0, 43), face = Vector3.new(0, 0, -1) },
	{ name = "ATM · Gym Row", pos = Vector3.new(165, 0, -40), face = Vector3.new(0, 0, 1) },
}
local ATM_COUNT = 3
local ATM_FOOTPRINT = Vector3.new(5, 7, 4)

local function part(props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

-- Ground height at a spot: the first solid, visible surface under it.
local function groundY(pos: Vector3, ignore: { Instance }): number?
	-- selene: allow(undefined_variable)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip = table.clone(ignore)
	for _ = 1, 8 do
		params.FilterDescendantsInstances = skip
		local hit = Workspace:Raycast(pos + Vector3.new(0, 30, 0), Vector3.new(0, -60, 0), params)
		if not hit then
			return nil
		end
		local inst = hit.Instance
		if inst.Transparency < 1 and inst.CanCollide then
			return hit.Position.Y
		end
		table.insert(skip, inst) -- map points, triggers, markers
	end
	return nil
end

local function spotIsClear(cf: CFrame, ignore: { Instance }): boolean
	-- selene: allow(undefined_variable)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	for _, p in Workspace:GetPartBoundsInBox(cf * CFrame.new(0, ATM_FOOTPRINT.Y / 2 + 0.3, 0), ATM_FOOTPRINT, params) do
		if p.Transparency < 1 and p.Name ~= "GPSMarker" then
			return false
		end
	end
	return true
end

local function buildATM(folder: Folder, name: string, base: CFrame): (ProximityPrompt, BasePart)
	local m = Instance.new("Model")
	m.Name = "ATM"
	m:SetAttribute("Label", name)
	m.Parent = folder
	local dark = Color3.fromRGB(38, 40, 46)
	local green = Color3.fromRGB(40, 160, 90)

	part({ Name = "Plinth", Size = Vector3.new(4, 0.4, 3), CFrame = base * CFrame.new(0, 0.2, 0), Color = Color3.fromRGB(90, 90, 96), Material = Enum.Material.Concrete, Parent = m })
	local body = part({ Name = "Body", Size = Vector3.new(3.4, 6.4, 2.4), CFrame = base * CFrame.new(0, 3.6, 0.2), Color = dark, Material = Enum.Material.Metal, Parent = m })
	part({ Name = "Trim", Size = Vector3.new(3.5, 0.3, 2.5), CFrame = base * CFrame.new(0, 6.65, 0.2), Color = green, Material = Enum.Material.Neon, Parent = m })
	-- slanted fascia with the screen
	local fascia = part({ Name = "Fascia", Size = Vector3.new(3, 1.8, 0.3), CFrame = base * CFrame.new(0, 4.6, -1.05) * CFrame.Angles(math.rad(12), 0, 0), Color = Color3.fromRGB(20, 22, 26), Parent = m })
	local screen = part({ Name = "Screen", Size = Vector3.new(2.4, 1.3, 0.1), CFrame = fascia.CFrame * CFrame.new(0, 0, -0.17), Color = Color3.fromRGB(30, 120, 200), Material = Enum.Material.Neon, CanCollide = false, Parent = m })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.LightInfluence = 0
	gui.Parent = screen
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(16, 70, 120)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.Text = "CITY BANK\nWELCOME"
	label.Parent = gui
	-- keypad + card slot + cash slot
	part({ Name = "Keypad", Size = Vector3.new(1.4, 0.15, 0.9), CFrame = base * CFrame.new(0, 3.35, -1.2) * CFrame.Angles(math.rad(-20), 0, 0), Color = Color3.fromRGB(150, 150, 158), Material = Enum.Material.Metal, Parent = m })
	part({ Name = "CardSlot", Size = Vector3.new(0.8, 0.12, 0.12), CFrame = base * CFrame.new(1, 3.6, -1.02), Color = green, Material = Enum.Material.Neon, CanCollide = false, Parent = m })
	part({ Name = "CashSlot", Size = Vector3.new(1.8, 0.18, 0.12), CFrame = base * CFrame.new(0, 2.6, -1.02), Color = Color3.fromRGB(12, 12, 14), CanCollide = false, Parent = m })
	-- top sign, readable from the street
	local topSign = part({ Name = "Sign", Size = Vector3.new(3.4, 1, 0.3), CFrame = base * CFrame.new(0, 7.35, -0.6), Color = green, Parent = m })
	local sGui = Instance.new("SurfaceGui")
	sGui.Face = Enum.NormalId.Front
	sGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sGui.PixelsPerStud = 50
	sGui.LightInfluence = 0
	sGui.Parent = topSign
	local sLabel = Instance.new("TextLabel")
	sLabel.Size = UDim2.fromScale(1, 1)
	sLabel.BackgroundTransparency = 1
	sLabel.TextColor3 = Color3.new(1, 1, 1)
	sLabel.TextScaled = true
	sLabel.Font = Enum.Font.GothamBlack
	sLabel.Text = "$ ATM"
	sLabel.Parent = sGui
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(90, 170, 255)
	glow.Range = 8
	glow.Brightness = 0.8
	glow.Parent = screen
	m.PrimaryPart = body

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Use ATM"
	prompt.ObjectText = "City Bank"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = body
	return prompt, body
end

local function buildATMs(city: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Bank"
	folder.Parent = city
	local ignore: { Instance } = { folder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local built = 0
	for _, spot in ATM_SPOTS do
		if built >= ATM_COUNT then
			break
		end
		local y = groundY(spot.pos, ignore)
		if y then
			-- CFrame whose -z (front) looks along `face`
			local origin = Vector3.new(spot.pos.X, y, spot.pos.Z)
			local base = CFrame.lookAt(origin, origin + spot.face)
			if spotIsClear(base, ignore) then
				built += 1
				local prompt, body = buildATM(folder, spot.name, base)
				prompt.Triggered:Connect(function(player)
					if Net.allow(player, "BankATM", 1) and Net.distance(player, body.Position) < 14 then
						BankEvent:FireClient(player, "openATM")
					end
				end)
				Places.mapPoint(city, spot.name, "Bank", origin + Vector3.new(0, 3, 0) + spot.face * 4)
			end
		end
	end
	if built < ATM_COUNT then
		warn("[CityGrind] Bank: only found room for " .. built .. " ATMs")
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Bank.start(city: Instance)
	BankAction = Net.remote("RemoteFunction", "BankAction")
	BankEvent = Net.remote("RemoteEvent", "BankEvent")

	BankAction.OnServerInvoke = function(player: Player, action: any, a: any, b: any, c: any)
		local ok, okResult, message, data = pcall(onAction, player, action, a, b, c)
		if not ok then
			warn("[CityGrind] Bank action failed:", okResult)
			return false, "Something went wrong.", nil
		end
		return okResult, message, data
	end

	-- Feed every logged transaction into the hourly ledger.
	PlayerData.onPublish(countNew)
	PlayerData.onLoaded(function(player)
		local data = PlayerData.get(player)
		local s = sec(player)
		if not data or not s then
			return
		end
		if not s.ledgerInit then
			-- first time: seed the ledger from the transactions already on record
			s.ledgerInit = true
			for _, t in data.transactions do
				if type(t.amount) == "number" and type(t.t) == "number" then
					bucketAdd(s, t.t, t.amount)
				end
			end
			pruneHours(s)
		end
		lastCounted[player] = data.transactions[1] or false
		rollDay(s)
		PlayerData.markChanged(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastCounted[player] = nil
		busy[player] = nil
	end)

	buildATMs(city)
end

return Bank
