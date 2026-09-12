-- // Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- // Assets
local TempFolder = workspace:WaitForChild("Temp")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local MainGameRemotes = Remotes:WaitForChild("MainGameRemotes")
local UpdateStandVisuals_RE = MainGameRemotes:WaitForChild("UpdateStandVisuals")
local AttachBottle_RE = MainGameRemotes:WaitForChild("AttachBottle")

local StandManager = {}

-- // Functions
local function bbox(parts)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

	for _, part in ipairs(parts) do
		local cframe = part.CFrame
		local size = part.Size
		local halfSize = size / 2

		local corners = {
			cframe * Vector3.new(-halfSize.X, -halfSize.Y, -halfSize.Z),
			cframe * Vector3.new(halfSize.X, -halfSize.Y, -halfSize.Z),
			cframe * Vector3.new(-halfSize.X, halfSize.Y, -halfSize.Z),
			cframe * Vector3.new(halfSize.X, halfSize.Y, -halfSize.Z),
			cframe * Vector3.new(-halfSize.X, -halfSize.Y, halfSize.Z),
			cframe * Vector3.new(halfSize.X, -halfSize.Y, halfSize.Z),
			cframe * Vector3.new(-halfSize.X, halfSize.Y, halfSize.Z),
			cframe * Vector3.new(halfSize.X, halfSize.Y, halfSize.Z),
		}

		for _, corner in ipairs(corners) do
			minX = math.min(minX, corner.X)
			minY = math.min(minY, corner.Y)
			minZ = math.min(minZ, corner.Z)
			maxX = math.max(maxX, corner.X)
			maxY = math.max(maxY, corner.Y)
			maxZ = math.max(maxZ, corner.Z)
		end
	end

	local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
	return CFrame.new(center), size
end

function StandManager:DisableMovement(player)
	if not player or typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	local char = player.Character
	if char and char:FindFirstChild("Humanoid") then
		local hum = char.Humanoid
		hum.WalkSpeed = 0
		hum.JumpHeight = 0
		hum.AutoRotate = false
	end
end

function StandManager:EnableMovement(player)
	if not player or typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	local char = player.Character
	if char and char:FindFirstChild("Humanoid") then
		local hum = char.Humanoid
		hum.WalkSpeed = 16
		hum.JumpHeight = 7.2
		hum.AutoRotate = true
	end
end

function StandManager:StandUpAndJump(player)
	if not player or typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChild("Humanoid")
	if not hum then return end
	hum.Sit = false
	hum.Jump = true
end

function StandManager:AnnounceWinnerOnBillboard(Model, winnerName)
	if not Model or not Model:FindFirstChild("BillboardGui") then return end
	Model.BillboardGui.TextLabel.Visible = true
	Model.BillboardGui.Other.Visible = true
	Model.BillboardGui.TextLabel.Text = winnerName .. " won!"
end

function StandManager:SetBarriers(Model, enabled)
	if not Model then return end
	local wallsFolder = Model:FindFirstChild("InvisibleWalls")
	if not wallsFolder then return end

	if enabled then
		local p1Attr = Model:GetAttribute("Player1")
		local p2Attr = Model:GetAttribute("Player2")

		local p1 = p1Attr and Players:GetPlayerByUserId(p1Attr) or nil
		local p2 = p2Attr and Players:GetPlayerByUserId(p2Attr) or nil

		local wallParts = {}
		for _, part in ipairs(wallsFolder:GetChildren()) do
			if part:IsA("BasePart") then table.insert(wallParts, part) end
		end

		if #wallParts > 0 then
			local cframe, size = bbox(wallParts)
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Include

			local bystanderCharacters = {}
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= p1 and p ~= p2 and p.Character then
					table.insert(bystanderCharacters, p.Character)
				end
			end
			overlapParams.FilterDescendantsInstances = bystanderCharacters

			local partsInVolume = workspace:GetPartBoundsInBox(cframe, size, overlapParams)
			local evacuatedPlayers = {}

			for _, hitPart in ipairs(partsInVolume) do
				local char = hitPart.Parent
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and char.PrimaryPart and not evacuatedPlayers[char] then
					evacuatedPlayers[char] = true
					local player = Players:GetPlayerFromCharacter(char)

					if player and player ~= p1 and player ~= p2 then
						local spawnLocation = workspace:FindFirstChildOfClass("SpawnLocation")
						if spawnLocation then
							char:PivotTo(spawnLocation.CFrame + Vector3.new(0, 5, 0))
						else
							char:PivotTo(CFrame.new(0, 5, 0)) 
						end
					end
				end
			end
		end
	end

	for _, part in ipairs(wallsFolder:GetChildren()) do
		if part:IsA("BasePart") then
			part.CanCollide = enabled
		end
	end
end

function StandManager:SweepOrphanedStands(playingTable)
	local activeStands = {}

	-- Register all valid active stands from playingTable (Includes both Human & AI entries)
	for userId, data in pairs(playingTable) do
		if data and data.BottleStand and data.BottleStand.Parent then
			activeStands[data.BottleStand] = true
		end
	end

	-- Sweep TempFolder for stands not linked to active sessions
	for _, child in ipairs(TempFolder:GetChildren()) do
		if not activeStands[child] then
			-- Check if it's an AI stand format ("AI_Stand_<UserId>")
			local hostUserIdStr = string.match(child.Name, "^AI_Stand_(%d+)$")

			if hostUserIdStr then
				local hostUserId = tonumber(hostUserIdStr)
				local hostData = playingTable[hostUserId]

				-- If host player is no longer in match, clean up orphan AI stand
				if not hostData or hostData.MatchEnding then
					child:Destroy()
				end
			else
				-- Unlinked or orphaned human/generic stand
				child:Destroy()
			end
		end
	end
end

function StandManager:UpdateSpectatorVisuals(P1, P2, stand, partName, skinName, count, layout, isUpperPart, orderedArray)
	for _, client in ipairs(Players:GetPlayers()) do
		if client ~= P1 and client ~= P2 then
			if isUpperPart then
				UpdateStandVisuals_RE:FireClient(client, stand, orderedArray, skinName)
			else
				AttachBottle_RE:FireClient(client, stand, partName, skinName, count, layout)
			end
		end
	end
end

return StandManager
