-- CITY GRIND: City Bank phone app (sections 39, 49). Client side.
-- * Balance, income vs expenses (last 24h / 7d), recent transactions.
-- * SEND MONEY to a friend in this server: pick friend, amount, optional note,
--   "Send $X to Name?" confirmation, plus a second confirmation for big amounts.
--   The server re-checks everything (friends, limits, level, cooldown, cash).
-- * ATMs in the Neighborhood open this app; "SEND MONEY" in the player menu
--   opens the transfer screen with that friend picked.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local BC = require(shared:WaitForChild("BankConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Bank = {}

local APP_ID = "Bank"
local BANK_GREEN = Color3.fromRGB(40, 160, 90)

type Friend = { userId: number, name: string, username: string }

local BankAction: RemoteFunction? = nil
local content: ScrollingFrame? = nil
local summary: any = nil
local view = "home" -- "home" | "send" | "confirm" | "confirm2" | "result"
local pendingView: string? = nil
local range = "24h"
local draft = { friend = nil :: Friend?, amount = 0, note = "" }
local result = { ok = false, message = "" }
local sending = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function invoke(action: string, a: any?, b: any?, c: any?): (boolean, string?, any)
	if not BankAction then
		return false, "The bank is still connecting.", nil
	end
	local ok, success, message, data = pcall(function()
		return (BankAction :: RemoteFunction):InvokeServer(action, a, b, c)
	end)
	if not ok then
		return false, "The bank is unavailable right now.", nil
	end
	return success == true, message, data
end

local function fetchSummary(): boolean
	local ok, _, data = invoke("summary")
	if ok and type(data) == "table" then
		summary = data
		return true
	end
	return false
end

local function header(parent: Instance, text: string, order: number)
	UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = order, Parent = parent })
end

local function wideButton(parent: Instance, text: string, color: Color3, order: number): TextButton
	return UI.button({ Text = text, TextSize = 15, BackgroundColor3 = color, Size = UDim2.new(1, -20, 0, 40), LayoutOrder = order, Parent = parent })
end

local render: () -> ()

local function go(newView: string)
	view = newView
	render()
end

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------
local function renderHome(c: ScrollingFrame)
	local data = summary
	if not data then
		UI.label({ Text = "Your account is still loading...", TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1, Parent = c })
		return
	end

	local balance = Phone.card(c, 86, 1)
	balance.BackgroundColor3 = Color3.fromRGB(20, 70, 50)
	UI.label({ Text = "BALANCE", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = Color3.fromRGB(170, 230, 190), Size = UDim2.new(1, 0, 0, 14), Parent = balance })
	UI.label({ Text = UI.formatCash(data.cash), Font = UI.FONT_BLACK, TextSize = 32, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 36), Parent = balance })
	UI.label({ Text = "City Bank · " .. player.DisplayName, TextSize = 11, TextColor3 = Color3.fromRGB(170, 230, 190), Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 14), Parent = balance })

	-- income vs expenses with a 24H / 7D switch
	local income = if range == "24h" then data.income24 else data.income7
	local expenses = if range == "24h" then data.expenses24 else data.expenses7
	local summaryCard = Phone.card(c, 104, 2)
	for i, r in { "24h", "7d" } do
		local b = UI.button({
			Text = if r == "24h" then "24H" else "7D",
			TextSize = 11,
			BackgroundColor3 = if range == r then colors.xp else colors.panel,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -(2 - i) * 44, 0, 0),
			Size = UDim2.fromOffset(40, 20),
			Parent = summaryCard,
		})
		b.Activated:Connect(function()
			range = r
			render()
		end)
	end
	UI.label({ Text = if range == "24h" then "LAST 24 HOURS" else "LAST 7 DAYS", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, -90, 0, 20), Parent = summaryCard })
	UI.label({ Text = "Income", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(0.5, 0, 0, 14), Parent = summaryCard })
	UI.label({ Text = UI.formatCash(income), Font = UI.FONT_BOLD, TextSize = 16, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 40), Size = UDim2.new(0.5, 0, 0, 18), Parent = summaryCard })
	UI.label({ Text = "Expenses", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.new(0.5, 0, 0, 26), Size = UDim2.new(0.5, 0, 0, 14), Parent = summaryCard })
	UI.label({ Text = UI.formatCash(expenses), Font = UI.FONT_BOLD, TextSize = 16, TextColor3 = colors.danger, Position = UDim2.new(0.5, 0, 0, 40), Size = UDim2.new(0.5, 0, 0, 18), Parent = summaryCard })
	local total = income + expenses
	local _, setShare = UI.bar({ BackgroundColor3 = colors.danger, Position = UDim2.fromOffset(0, 66), Size = UDim2.new(1, 0, 0, 8), Parent = summaryCard }, colors.cash)
	setShare(if total > 0 then income / total else 0.5)
	local net = income - expenses
	UI.label({ Text = "Net " .. (if net >= 0 then "+" else "") .. UI.formatCash(net), Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = if net >= 0 then colors.cash else colors.danger, Position = UDim2.fromOffset(0, 78), Size = UDim2.new(1, 0, 0, 14), Parent = summaryCard })

	-- transfers
	local send = Phone.card(c, 84, 3)
	UI.label({ Text = "SEND MONEY", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = send })
	UI.label({
		Text = string.format("Sent today %s / %s", UI.formatCash(data.sentToday or 0), UI.formatCash(BC.DAILY_SEND_LIMIT)),
		TextSize = 12,
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = send,
	})
	if data.sendBlock then
		UI.label({ Text = data.sendBlock, TextSize = 12, TextWrapped = true, TextColor3 = colors.stamina, Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 30), Parent = send })
	else
		local b = UI.button({ Text = "SEND TO A FRIEND", TextSize = 13, BackgroundColor3 = BANK_GREEN, Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 30), Parent = send })
		b.Activated:Connect(function()
			draft = { friend = nil, amount = 0, note = "" }
			go("send")
		end)
	end

	header(c, "RECENT TRANSACTIONS", 4)
	if #data.transactions == 0 then
		UI.label({ Text = "No transactions yet.", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 24), LayoutOrder = 5, Parent = c })
	end
	for i, t in data.transactions do
		local row = Phone.card(c, 46, 4 + i)
		UI.label({ Text = tostring(t.label), Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -84, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		UI.label({ Text = UI.timeAgo(t.t), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, -84, 0, 14), Parent = row })
		UI.label({
			Text = (if t.amount > 0 then "+" else "") .. UI.formatCash(t.amount),
			Font = UI.FONT_BOLD,
			TextSize = 15,
			TextColor3 = if t.amount > 0 then colors.cash else colors.danger,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 4),
			Size = UDim2.fromOffset(84, 18),
			Parent = row,
		})
	end
end

local function renderSend(c: ScrollingFrame)
	local data = summary
	if not data then
		go("home")
		return
	end
	local back = UI.button({ Text = "‹ Account", TextSize = 13, BackgroundTransparency = 1, TextColor3 = colors.xp, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -20, 0, 24), LayoutOrder = 1, Parent = c })
	back.Activated:Connect(function()
		go("home")
	end)

	header(c, "1 · PICK A FRIEND IN THIS SERVER", 2)
	local friends: { Friend } = data.friends or {}
	if draft.friend then
		-- keep the pick only while they're still listed
		local still = false
		for _, f in friends do
			if f.userId == (draft.friend :: Friend).userId then
				still = true
			end
		end
		if not still then
			draft.friend = nil
		end
	end
	if #friends == 0 then
		UI.label({ Text = "None of your friends are in this server. Add friends from the player menu (click a player).", TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 48), LayoutOrder = 3, Parent = c })
		return
	end
	for i, f in friends do
		local picked = draft.friend ~= nil and (draft.friend :: Friend).userId == f.userId
		local row = UI.button({
			Text = "",
			BackgroundColor3 = if picked then Color3.fromRGB(30, 90, 60) else colors.panelLight,
			Size = UDim2.new(1, -20, 0, 42),
			LayoutOrder = 2 + i,
			Parent = c,
		})
		if picked then
			UI.stroke(colors.cash, 2).Parent = row
		end
		UI.label({ Text = f.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(12, 4), Size = UDim2.new(1, -50, 0, 18), Parent = row })
		UI.label({ Text = "@" .. f.username, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(12, 22), Size = UDim2.new(1, -50, 0, 14), Parent = row })
		UI.label({ Text = if picked then "✓" else "", Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = colors.cash, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(20, 20), Parent = row })
		row.Activated:Connect(function()
			draft.friend = f
			render()
		end)
	end

	local base = 3 + #friends
	header(c, "2 · AMOUNT", base)
	local amountCard = Phone.card(c, 92, base + 1)
	local amountBox = UI.new("TextBox", {
		Text = if draft.amount > 0 then tostring(draft.amount) else "",
		PlaceholderText = "$0",
		ClearTextOnFocus = false,
		Font = UI.FONT_BLACK,
		TextSize = 24,
		TextColor3 = colors.cash,
		PlaceholderColor3 = colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = colors.panel,
		Size = UDim2.new(1, 0, 0, 38),
		Parent = amountCard,
	}, { UI.corner(10), UI.padding(8) })
	amountBox:GetPropertyChangedSignal("Text"):Connect(function()
		local digits = amountBox.Text:gsub("%D", ""):sub(1, 7)
		if digits ~= amountBox.Text then
			amountBox.Text = digits
			return
		end
		draft.amount = tonumber(digits) or 0
	end)
	for i, add in { 100, 1000, 10000 } do
		local b = UI.button({
			Text = "+" .. UI.formatCash(add),
			TextSize = 12,
			BackgroundColor3 = colors.panel,
			Position = UDim2.new((i - 1) / 3, if i > 1 then 3 else 0, 0, 46),
			Size = UDim2.new(1 / 3, -4, 0, 28),
			Parent = amountCard,
		})
		b.Activated:Connect(function()
			draft.amount = math.min(BC.MAX_TRANSFER, draft.amount + add)
			amountBox.Text = tostring(draft.amount)
		end)
	end

	header(c, "3 · NOTE (OPTIONAL)", base + 2)
	local noteBox = UI.new("TextBox", {
		Text = draft.note,
		PlaceholderText = "For the sneakers...",
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 14,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = colors.panelLight,
		Size = UDim2.new(1, -20, 0, 36),
		LayoutOrder = base + 3,
		Parent = c,
	}, { UI.corner(10), UI.padding(8) })
	noteBox:GetPropertyChangedSignal("Text"):Connect(function()
		local text = noteBox.Text
		local length = utf8.len(text)
		if length and length > BC.NOTE_MAX then
			noteBox.Text = text:sub(1, (utf8.offset(text, BC.NOTE_MAX + 1) :: number) - 1)
			return
		end
		draft.note = noteBox.Text
	end)

	local review = wideButton(c, "REVIEW", BANK_GREEN, base + 4)
	review.Activated:Connect(function()
		if not draft.friend then
			HUD.push("BANK", "Pick a friend to send money to.")
		elseif draft.amount < BC.MIN_TRANSFER or draft.amount > BC.MAX_TRANSFER then
			HUD.push("BANK", "Enter an amount from $1 to $1,000,000.")
		elseif draft.amount > (summary and summary.cash or 0) then
			HUD.push("BANK", "You don't have that much cash.")
		else
			go("confirm")
		end
	end)
	UI.label({
		Text = string.format("Limits: %s per transfer · %s sent per day · Level %d+", UI.formatCash(BC.MAX_TRANSFER), UI.formatCash(BC.DAILY_SEND_LIMIT), BC.MIN_LEVEL_TO_SEND),
		TextSize = 11,
		TextWrapped = true,
		TextColor3 = colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, -20, 0, 28),
		LayoutOrder = base + 5,
		Parent = c,
	})
end

local function doSend()
	if sending or not draft.friend then
		return
	end
	sending = true
	local friend = draft.friend :: Friend
	local note = draft.note:match("^%s*(.-)%s*$") or ""
	local ok, message = invoke("transfer", friend.userId, draft.amount, if note ~= "" then note else nil)
	sending = false
	result = { ok = ok, message = message or (if ok then "Sent." else "The transfer didn't go through.") }
	fetchSummary()
	go("result")
end

local function renderConfirm(c: ScrollingFrame, second: boolean)
	local friend = draft.friend
	if not friend then
		go("send")
		return
	end
	local box = Phone.card(c, if second then 190 else 170, 1)
	box.BackgroundColor3 = if second then Color3.fromRGB(70, 40, 20) else colors.panelLight
	UI.label({
		Text = if second then "LARGE TRANSFER" else "CONFIRM TRANSFER",
		Font = UI.FONT_BLACK,
		TextSize = 12,
		TextColor3 = if second then colors.stamina else colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 14),
		Parent = box,
	})
	UI.label({
		Text = "Send " .. UI.formatCash(draft.amount) .. " to " .. friend.name .. "?",
		Font = UI.FONT_BLACK,
		TextSize = 22,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 58),
		Parent = box,
	})
	local lines = "@" .. friend.username
	if draft.note ~= "" then
		lines ..= "\nNote: \"" .. draft.note .. "\""
	end
	if second then
		lines ..= "\nThis is " .. UI.formatCash(draft.amount) .. ". Transfers can't be undone."
	else
		lines ..= "\nYour balance after: " .. UI.formatCash((summary and summary.cash or 0) - draft.amount)
	end
	UI.label({ Text = lines, TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 70), Parent = box })

	local confirm = wideButton(c, if second then "YES, SEND " .. UI.formatCash(draft.amount) else "CONFIRM", if second then Color3.fromRGB(220, 130, 30) else BANK_GREEN, 2)
	local cancel = wideButton(c, "CANCEL", colors.panel, 3)
	confirm.Activated:Connect(function()
		if sending then
			return
		end
		if not second and draft.amount >= BC.BIG_TRANSFER then
			go("confirm2")
		else
			confirm.Text = "SENDING..."
			doSend()
		end
	end)
	cancel.Activated:Connect(function()
		go("send")
	end)
end

local function renderResult(c: ScrollingFrame)
	local box = Phone.card(c, 120, 1)
	box.BackgroundColor3 = if result.ok then Color3.fromRGB(20, 70, 50) else Color3.fromRGB(80, 30, 34)
	UI.label({ Text = if result.ok then "✓" else "!", Font = UI.FONT_BLACK, TextSize = 36, TextColor3 = if result.ok then colors.cash else colors.danger, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 40), Parent = box })
	UI.label({ Text = result.message, Font = UI.FONT_BOLD, TextSize = 15, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 50), Parent = box })
	local done = wideButton(c, "DONE", BANK_GREEN, 2)
	done.Activated:Connect(function()
		go("home")
	end)
	if not result.ok then
		local again = wideButton(c, "EDIT TRANSFER", colors.panel, 3)
		again.Activated:Connect(function()
			go("send")
		end)
	end
end

render = function()
	local c = content
	if not c then
		return
	end
	Phone.clear(c)
	c.CanvasPosition = Vector2.zero
	if view == "send" then
		renderSend(c)
	elseif view == "confirm" then
		renderConfirm(c, false)
	elseif view == "confirm2" then
		renderConfirm(c, true)
	elseif view == "result" then
		renderResult(c)
	else
		renderHome(c)
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Opens the phone on the Bank app (ATMs use this).
function Bank.open(startView: string?)
	pendingView = startView or "home"
	if Phone.isOpen() then
		Phone.showPage(APP_ID)
	else
		Phone.setOpen(true)
		Phone.showPage(APP_ID)
	end
end

-- Opens the transfer screen with a friend already picked.
function Bank.sendTo(target: Player)
	draft = { friend = { userId = target.UserId, name = target.DisplayName, username = target.Name }, amount = 0, note = "" }
	Bank.open("send")
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function addMenuAction()
	local module = script.Parent:FindFirstChild("Social")
	if not module then
		return
	end
	local ok, Social = pcall(require, module)
	if not ok or type(Social) ~= "table" or type(Social.addMenuAction) ~= "function" then
		return
	end
	Social.addMenuAction({
		id = "bank_send",
		label = "SEND MONEY",
		order = 24,
		visible = function(target: Player)
			return type(Social.isFriend) == "function" and Social.isFriend(target.UserId) == true
		end,
		run = function(target: Player)
			Bank.sendTo(target)
		end,
	})
end

function Bank.start()
	Phone.addApp({ id = APP_ID, label = "Bank", icon = "💵", color = BANK_GREEN }, function(c: ScrollingFrame)
		content = c
		return function()
			-- every time the app opens: fresh numbers, then the requested view
			local wanted = pendingView or (if view == "home" or view == "result" then "home" else view)
			pendingView = nil
			if view == "confirm" or view == "confirm2" then
				wanted = if wanted == "home" then "home" else "send" -- never land on a stale confirmation
			end
			view = wanted
			fetchSummary()
			render()
		end
	end)

	task.spawn(function()
		local remotes = shared:WaitForChild("Remotes")
		BankAction = remotes:WaitForChild("BankAction") :: RemoteFunction
		local BankEvent = remotes:WaitForChild("BankEvent") :: RemoteEvent
		BankEvent.OnClientEvent:Connect(function(kind: any)
			if kind == "openATM" then
				Bank.open("home")
			elseif kind == "refresh" then
				if view == "home" then
					Phone.refresh(APP_ID)
				else
					fetchSummary() -- keep numbers current without leaving the transfer flow
				end
			end
		end)
	end)

	task.spawn(addMenuAction)
end

return Bank
