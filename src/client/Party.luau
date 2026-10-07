-- CITY GRIND: parties (section 93). Client side.
-- * Compact party panel on the left edge of the HUD (members, distance, leader tools).
-- * Markers over party members' heads (only party members see them), with distance.
-- * "Party" phone app: create, invite players in the server, manage members,
--   set a destination (GPS for everyone), travel together, queue basketball.
-- * Invite prompt when the Messages app isn't there to show invite cards.
-- * "INVITE TO PARTY" in the player interaction menu (Social.addMenuAction).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")

local player = Players.LocalPlayer
local colors = UI.colors

local Party = {}

local PARTY_COLOR = Color3.fromRGB(90, 170, 255)
local LEADER_COLOR = Color3.fromRGB(255, 205, 60)
local STUDS_PER_METRE = 3.57

type Member = { userId: number, name: string, username: string, leader: boolean }
type State = { id: string, leaderId: number, members: { Member }, max: number }

local state: State? = nil
local PartyAction: RemoteEvent? = nil
local gui: ScreenGui? = nil
local panel: Frame
local panelTitle: TextLabel
local memberList: Frame
local leaderRow: Frame
local memberRow: Frame
local selectedUserId: number? = nil
local markers: { [number]: BillboardGui } = {}
local invitePopup: Frame
local inviteText: TextLabel
local pendingInvite: { partyId: string, fromName: string }? = nil
local collapsed = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function act(action: string, arg: any?)
	if PartyAction then
		PartyAction:FireServer(action, arg)
	end
end

local function isLeader(): boolean
	return state ~= nil and state.leaderId == player.UserId
end

local function inParty(userId: number): boolean
	if not state then
		return false
	end
	for _, m in state.members do
		if m.userId == userId then
			return true
		end
	end
	return false
end

local function rootOf(p: Player?): BasePart?
	local character = p and p.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function distanceTo(p: Player?): number?
	local a, b = rootOf(player), rootOf(p)
	if not a or not b then
		return nil
	end
	return (a.Position - b.Position).Magnitude / STUDS_PER_METRE
end

local function distanceText(p: Player?): string
	if not p then
		return "away"
	end
	local interior = p:GetAttribute("Interior")
	if type(interior) == "string" and interior ~= "" then
		return "inside"
	end
	local d = distanceTo(p)
	if not d then
		return "-"
	end
	return if d < 1000 then string.format("%dm", math.floor(d)) else string.format("%.1fkm", d / 1000)
end

---------------------------------------------------------------------------
-- Markers over party members (visible only to you, because they're in your PlayerGui)
---------------------------------------------------------------------------
local function clearMarkers()
	for id, marker in markers do
		marker:Destroy()
		markers[id] = nil
	end
end

local function updateMarkers()
	if not gui then
		return
	end
	local wanted: { [number]: boolean } = {}
	if state then
		for _, m in state.members do
			if m.userId ~= player.UserId then
				wanted[m.userId] = true
			end
		end
	end
	for id, marker in markers do
		if not wanted[id] then
			marker:Destroy()
			markers[id] = nil
		end
	end
	for id in wanted do
		local other = Players:GetPlayerByUserId(id)
		local character = other and other.Character
		local head = character and character:FindFirstChild("Head")
		local marker = markers[id]
		if not marker then
			marker = UI.new("BillboardGui", {
				Name = "PartyMarker",
				AlwaysOnTop = true,
				LightInfluence = 0,
				Size = UDim2.fromOffset(140, 40),
				StudsOffset = Vector3.new(0, 3.4, 0),
				ResetOnSpawn = false,
				-- a BillboardGui nested inside a ScreenGui doesn't render: parent it to PlayerGui
				Parent = (gui :: ScreenGui).Parent,
			})
			UI.label({ Name = "Name", Text = "", Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = PARTY_COLOR, TextStrokeTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 18), Parent = marker })
			UI.label({ Name = "Dist", Text = "", Font = UI.FONT_BOLD, TextSize = 12, TextStrokeTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 14), Parent = marker })
			markers[id] = marker
		end
		local member = nil
		for _, m in (state :: State).members do
			if m.userId == id then
				member = m
			end
		end
		marker.Adornee = if head and head:IsA("BasePart") then head else nil
		marker.Enabled = marker.Adornee ~= nil
		local nameLabel = marker:FindFirstChild("Name") :: TextLabel
		nameLabel.Text = (if member and member.leader then "👑 " else "◆ ") .. (if member then member.name else "")
		nameLabel.TextColor3 = if member and member.leader then LEADER_COLOR else PARTY_COLOR
		local d = distanceTo(other)
		local distLabel = marker:FindFirstChild("Dist") :: TextLabel
		distLabel.Text = if d then string.format("%dm", math.floor(d)) else ""
		-- don't clutter the screen with a marker on someone right next to you
		if d and d < 4 then
			marker.Enabled = false
		end
	end
end

---------------------------------------------------------------------------
-- HUD panel
---------------------------------------------------------------------------
local function smallButton(parent: Instance, text: string, color: Color3?, order: number, fn: () -> ()): TextButton
	local b = UI.button({ Text = text, TextSize = 11, BackgroundColor3 = color or colors.panelLight, Size = UDim2.new(0, 56, 1, 0), LayoutOrder = order, Parent = parent })
	b.Activated:Connect(fn)
	return b
end

local function openApp()
	Phone.setOpen(true)
	Phone.showPage("Party")
end

local function rebuildPanel()
	if not gui then
		return
	end
	panel.Visible = state ~= nil
	if not state then
		return
	end
	panelTitle.Text = string.format("%s PARTY  %d/%d", if collapsed then "▸" else "▾", #state.members, state.max)
	memberList.Visible = not collapsed
	for _, child in memberList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for i, m in state.members do
		local row = UI.button({
			Name = "Member",
			Text = "",
			AutoButtonColor = isLeader() and m.userId ~= player.UserId,
			BackgroundColor3 = if selectedUserId == m.userId then Color3.fromRGB(50, 50, 66) else colors.panelLight,
			BackgroundTransparency = 0.1,
			Size = UDim2.new(1, 0, 0, if selectedUserId == m.userId then 52 else 26),
			LayoutOrder = i,
			Parent = memberList,
		})
		row:SetAttribute("UserId", m.userId)
		local nameLabel = UI.label({
			Text = (if m.leader then "👑 " else "") .. m.name .. (if m.userId == player.UserId then " (you)" else ""),
			Font = UI.FONT_BOLD,
			TextSize = 12,
			TextColor3 = if m.leader then LEADER_COLOR else colors.text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -60, 0, 26),
			Parent = row,
		})
		nameLabel.Name = "NameLabel"
		UI.label({
			Name = "Dist",
			Text = if m.userId == player.UserId then "" else distanceText(Players:GetPlayerByUserId(m.userId)),
			TextSize = 11,
			TextColor3 = colors.subtext,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.fromOffset(50, 26),
			Parent = row,
		})
		if isLeader() and m.userId ~= player.UserId then
			row.Activated:Connect(function()
				selectedUserId = if selectedUserId == m.userId then nil else m.userId
				rebuildPanel()
			end)
			if selectedUserId == m.userId then
				local tools = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 26), Size = UDim2.new(1, -12, 0, 22), Parent = row }, {
					UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
				})
				local target = Players:GetPlayerByUserId(m.userId)
				smallButton(tools, "LEADER", LEADER_COLOR, 1, function()
					if target then
						act("promote", target)
					end
					selectedUserId = nil
				end).TextColor3 = Color3.new(0.1, 0.1, 0.1)
				smallButton(tools, "KICK", colors.danger, 2, function()
					if target then
						act("kick", target)
					end
					selectedUserId = nil
				end)
			end
		end
	end
	leaderRow.Visible = not collapsed and isLeader()
	memberRow.Visible = not collapsed
end

local function refreshDistances()
	if not state or collapsed then
		return
	end
	for _, row in memberList:GetChildren() do
		local id = row:GetAttribute("UserId")
		local dist = row:FindFirstChild("Dist")
		if type(id) == "number" and dist and dist:IsA("TextLabel") and id ~= player.UserId then
			dist.Text = distanceText(Players:GetPlayerByUserId(id))
		end
	end
end

local function buildPanel()
	panel = UI.new("Frame", {
		Name = "PartyPanel",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.42, 0),
		Size = UDim2.fromOffset(196, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = gui,
	}, {
		UI.corner(12),
		UI.stroke(PARTY_COLOR, 1.5, 0.35),
		UI.padding(8),
		UI.new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	HUD.slot("left", panel, 40)
	local header = UI.button({ Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 0, Parent = panel })
	panelTitle = UI.label({ Text = "PARTY", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = PARTY_COLOR, Size = UDim2.fromScale(1, 1), Parent = header })
	header.Activated:Connect(function()
		collapsed = not collapsed
		rebuildPanel()
	end)
	memberList = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = panel }, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	leaderRow = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 2, Parent = panel }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	smallButton(leaderRow, "📍 GO TO", nil, 1, openApp).Size = UDim2.new(0.333, -3, 1, 0)
	smallButton(leaderRow, "🧭 TO ME", nil, 2, function()
		act("travel")
	end).Size = UDim2.new(0.333, -3, 1, 0)
	smallButton(leaderRow, "🏀 HOOPS", nil, 3, function()
		act("hoops")
	end).Size = UDim2.new(0.333, -3, 1, 0)
	memberRow = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 3, Parent = panel }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	smallButton(memberRow, "+ INVITE", PARTY_COLOR, 1, openApp).Size = UDim2.new(0.5, -2, 1, 0)
	smallButton(memberRow, "LEAVE", colors.danger, 2, function()
		act("leave")
	end).Size = UDim2.new(0.5, -2, 1, 0)
end

---------------------------------------------------------------------------
-- Invite prompt (used when there's no Messages app)
---------------------------------------------------------------------------
local function buildInvitePopup()
	invitePopup = UI.new("Frame", {
		Name = "PartyInvite",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -250),
		Size = UDim2.fromOffset(320, 92),
		BackgroundColor3 = colors.panel,
		Visible = false,
		Parent = gui,
	}, { UI.corner(14), UI.stroke(PARTY_COLOR, 1.5, 0.2), UI.padding(10) })
	inviteText = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 15, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 34), Parent = invitePopup })
	local yes = UI.button({ Text = "JOIN", TextSize = 14, BackgroundColor3 = Color3.fromRGB(60, 170, 90), Position = UDim2.new(0, 0, 1, -34), Size = UDim2.new(0.5, -4, 0, 34), Parent = invitePopup })
	local no = UI.button({ Text = "DECLINE", TextSize = 14, Position = UDim2.new(0.5, 4, 1, -34), Size = UDim2.new(0.5, -4, 0, 34), Parent = invitePopup })
	yes.Activated:Connect(function()
		if pendingInvite then
			act("accept", pendingInvite.partyId)
		end
		pendingInvite = nil
		invitePopup.Visible = false
		Phone.refresh("Party")
	end)
	no.Activated:Connect(function()
		if pendingInvite then
			act("decline", pendingInvite.partyId)
		end
		pendingInvite = nil
		invitePopup.Visible = false
		Phone.refresh("Party")
	end)
end

local function showInvite(data: any)
	if type(data) ~= "table" or type(data.partyId) ~= "string" then
		return
	end
	pendingInvite = { partyId = data.partyId, fromName = tostring(data.fromName) }
	inviteText.Text = "🎉 " .. tostring(data.fromName) .. " invited you to their party"
	invitePopup.Visible = true
	local mine = pendingInvite
	task.delay(60, function()
		if pendingInvite == mine then
			invitePopup.Visible = false
		end
	end)
	Phone.refresh("Party")
end

---------------------------------------------------------------------------
-- Phone app
---------------------------------------------------------------------------
local function buildApp(content: ScrollingFrame)
	local function header(text: string, order: number)
		UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = order, Parent = content })
	end
	local function note(text: string, order: number)
		UI.label({ Text = text, TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 34), LayoutOrder = order, Parent = content })
	end

	local function render()
		Phone.clear(content)
		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end

		if pendingInvite and not state then
			local c = Phone.card(content, 86, nextOrder())
			UI.label({ Text = "🎉 " .. pendingInvite.fromName .. " invited you", Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, 0, 0, 18), Parent = c })
			local join = UI.button({ Text = "JOIN", TextSize = 13, BackgroundColor3 = Color3.fromRGB(60, 170, 90), Position = UDim2.fromOffset(0, 28), Size = UDim2.new(0.5, -4, 0, 32), Parent = c })
			local decline = UI.button({ Text = "DECLINE", TextSize = 13, Position = UDim2.new(0.5, 4, 0, 28), Size = UDim2.new(0.5, -4, 0, 32), Parent = c })
			local invite = pendingInvite
			join.Activated:Connect(function()
				act("accept", invite.partyId)
				pendingInvite = nil
				invitePopup.Visible = false
			end)
			decline.Activated:Connect(function()
				act("decline", invite.partyId)
				pendingInvite = nil
				invitePopup.Visible = false
				render()
			end)
		end

		if not state then
			local c = Phone.card(content, 110, nextOrder())
			UI.label({ Text = "No party yet", Font = UI.FONT_BLACK, TextSize = 16, Size = UDim2.new(1, 0, 0, 20), Parent = c })
			UI.label({ Text = "Team up with up to 6 people: shared GPS, markers over your crew and quick hoops runs.", TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 34), Parent = c })
			local create = UI.button({ Text = "CREATE PARTY", TextSize = 14, BackgroundColor3 = PARTY_COLOR, Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 30), Parent = c })
			create.Activated:Connect(function()
				act("create")
			end)
		else
			local s = state :: State
			header(string.format("MEMBERS  %d/%d", #s.members, s.max), nextOrder())
			for _, m in s.members do
				local other = Players:GetPlayerByUserId(m.userId)
				local showTools = isLeader() and m.userId ~= player.UserId
				local c = Phone.card(content, if showTools then 76 else 44, nextOrder())
				UI.label({ Text = (if m.leader then "👑 " else "") .. m.name, Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = if m.leader then LEADER_COLOR else colors.text, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -60, 0, 20), Parent = c })
				UI.label({ Text = if m.userId == player.UserId then "you" else distanceText(other), TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(60, 20), Parent = c })
				if showTools and other then
					local promote = UI.button({ Text = "MAKE LEADER", TextSize = 11, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(0.5, -4, 0, 26), Parent = c })
					local kick = UI.button({ Text = "KICK", TextSize = 11, BackgroundColor3 = colors.danger, Position = UDim2.new(0.5, 4, 0, 26), Size = UDim2.new(0.5, -4, 0, 26), Parent = c })
					promote.Activated:Connect(function()
						act("promote", other)
					end)
					kick.Activated:Connect(function()
						act("kick", other)
					end)
				end
			end

			if isLeader() then
				header("LEAD THE PARTY", nextOrder())
				local c = Phone.card(content, 84, nextOrder())
				local travel = UI.button({ Text = "🧭 TRAVEL TOGETHER", TextSize = 12, Size = UDim2.new(1, 0, 0, 28), Parent = c })
				local hoops = UI.button({ Text = "🏀 QUEUE BASKETBALL (nearest court)", TextSize = 12, BackgroundColor3 = Color3.fromRGB(200, 100, 30), Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 0, 28), Parent = c })
				travel.Activated:Connect(function()
					act("travel")
				end)
				hoops.Activated:Connect(function()
					act("hoops")
				end)

				header("SET DESTINATION (GPS FOR EVERYONE)", nextOrder())
				local city = Workspace:FindFirstChild("City")
				local points = city and city:FindFirstChild("MapPoints")
				local list = if points then points:GetChildren() else {}
				local root = rootOf(player)
				table.sort(list, function(a, b)
					if root and a:IsA("BasePart") and b:IsA("BasePart") then
						return (a.Position - root.Position).Magnitude < (b.Position - root.Position).Magnitude
					end
					return a.Name < b.Name
				end)
				for _, point in list do
					if point:IsA("BasePart") then
						local row = Phone.card(content, 40, nextOrder())
						UI.label({ Text = point.Name, Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -60, 1, 0), Parent = row })
						local go = UI.button({ Text = "SET", TextSize = 12, BackgroundColor3 = PARTY_COLOR, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(52, 26), Parent = row })
						go.Activated:Connect(function()
							act("destination", point.Name)
						end)
					end
				end
				if #list == 0 then
					note("No places on the map yet.", nextOrder())
				end
			end
		end

		-- invite players in this server
		header("INVITE PLAYERS IN THIS SERVER", nextOrder())
		local any = false
		local others = Players:GetPlayers()
		table.sort(others, function(a, b)
			return (distanceTo(a) or math.huge) < (distanceTo(b) or math.huge)
		end)
		for _, other in others do
			if other ~= player and not inParty(other.UserId) then
				any = true
				local row = Phone.card(content, 40, nextOrder())
				UI.label({ Text = other.DisplayName, Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -120, 1, 0), Parent = row })
				UI.label({ Text = distanceText(other), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.new(1, -116, 0, 0), Size = UDim2.new(0, 50, 1, 0), Parent = row })
				local inv = UI.button({ Text = "INVITE", TextSize = 12, BackgroundColor3 = PARTY_COLOR, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(62, 26), Parent = row })
				inv.Activated:Connect(function()
					act("invite", other)
					inv.Text = "SENT"
					inv.AutoButtonColor = false
				end)
			end
		end
		if not any then
			note("Nobody else to invite right now.", nextOrder())
		end

		if state then
			local c = Phone.card(content, 36, nextOrder())
			c.BackgroundTransparency = 1
			local leave = UI.button({ Text = "LEAVE PARTY", TextSize = 13, BackgroundColor3 = colors.danger, Size = UDim2.new(if isLeader() then 0.5 else 1, if isLeader() then -4 else 0, 1, 0), Parent = c })
			leave.Activated:Connect(function()
				act("leave")
			end)
			if isLeader() then
				local disband = UI.button({ Text = "DISBAND", TextSize = 13, BackgroundColor3 = Color3.fromRGB(120, 40, 40), Position = UDim2.new(0.5, 4, 0, 0), Size = UDim2.new(0.5, -4, 1, 0), Parent = c })
				disband.Activated:Connect(function()
					act("disband")
				end)
			end
		end
	end
	return render
end

---------------------------------------------------------------------------
-- Social menu
---------------------------------------------------------------------------
local function addMenuActions()
	local module = script.Parent:FindFirstChild("Social")
	if not module then
		return
	end
	local ok, Social = pcall(require, module)
	if not ok or type(Social) ~= "table" or type(Social.addMenuAction) ~= "function" then
		return
	end
	Social.addMenuAction({
		id = "PartyInvite",
		label = "INVITE TO PARTY",
		order = 20,
		visible = function(target: Player)
			if inParty(target.UserId) then
				return false
			end
			return not state or #state.members < state.max
		end,
		run = function(target: Player)
			act("invite", target)
		end,
	})
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Party.start()
	Phone.addApp({ id = "Party", label = "Party", icon = "🎉", color = PARTY_COLOR }, function(content)
		return buildApp(content)
	end)

	task.spawn(function()
		gui = UI.new("ScreenGui", {
			Name = "CityGrindParty",
			ResetOnSpawn = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = 3,
			Parent = player:WaitForChild("PlayerGui"),
		})
		buildPanel()
		buildInvitePopup()

		local remotes = shared:WaitForChild("Remotes")
		PartyAction = remotes:WaitForChild("PartyAction") :: RemoteEvent
		local PartyEvent = remotes:WaitForChild("PartyEvent") :: RemoteEvent
		PartyEvent.OnClientEvent:Connect(function(kind: any, a: any, b: any, c: any)
			if kind == "state" then
				state = if type(a) == "table" then a else nil
				if state and selectedUserId and not inParty(selectedUserId) then
					selectedUserId = nil
				end
				if state then
					pendingInvite = nil
					invitePopup.Visible = false
				end
				rebuildPanel()
				updateMarkers()
				Phone.refresh("Party")
			elseif kind == "invite" then
				showInvite(a)
			elseif kind == "gps" then
				if type(a) == "string" and typeof(b) == "Vector3" then
					Phone.setGPS(a, b)
					if type(c) == "string" then
						HUD.push("PARTY", c)
					end
				end
			end
		end)

		-- distances and markers tick
		while true do
			task.wait(0.5)
			if state then
				updateMarkers()
				refreshDistances()
			elseif next(markers) then
				clearMarkers()
			end
		end
	end)

	task.spawn(addMenuActions)
end

return Party
