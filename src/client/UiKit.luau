--[[
	Tiny shared UI polish helpers so every code-built panel gets the same
	rounded-corner, subtle-border look instead of flat rectangles.
]]

local UiKit = {}

function UiKit.RoundPanel(guiObject: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 10)
	corner.Parent = guiObject

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 70, 85)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.Parent = guiObject
end

function UiKit.RoundButton(guiObject: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 6)
	corner.Parent = guiObject
end

return UiKit
