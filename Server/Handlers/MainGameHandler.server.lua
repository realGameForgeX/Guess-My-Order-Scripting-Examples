-- // Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- // Folders
local Services = ServerScriptService:WaitForChild("Services")
local MainGame = Services:WaitForChild("MainGame")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UIRemotes = Remotes:WaitForChild("UIRemotes")
local Assets = ReplicatedStorage:WaitForChild("Assets")
local ChairsFolder = Assets:WaitForChild("Chairs")
local AINpc = Assets:WaitForChild("NoobNPC") :: Model
local AITemp = workspace:WaitForChild("AITemp") :: Folder

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Data = Packages:WaitForChild("Data")

-- // Modules
local MainHandlerModule = require(MainGame:WaitForChild("MainGameService"))
local DataService = require(Data.DataService).server

-- // Workspace Stuffs
local TableAndChairs = workspace:WaitForChild("Map"):WaitForChild("TableAndChairs")
local HardMode = TableAndChairs:WaitForChild("HardMode")

-- // Remotes
local LeaveButton_RE = UIRemotes:WaitForChild("LeaveButton")
local TopBarTextChange_RE = UIRemotes:WaitForChild("TopBarTextChange")
local AIButton_RE = UIRemotes:WaitForChild("AIButton")
local QuickPlayButton_RE = UIRemotes:WaitForChild("QuickPlayButton")

-- // State & Tracking
local CountdownThreads = {}
local AiStartingDebounce = {}
local PlayersInGame = {}
local ProcessingSeats = {} -- Guard against recursive Occupant listener calls

local R15_SIT_ANIM = "rbxassetid://507768133"
local R6_SIT_ANIM = "rbxassetid://180612465"

--------------------------------------------------------------------------------
-- // HELPER FUNCTIONS
--------------------------------------------------------------------------------

local function GetChairNumber(ChairName: string): number
	return tonumber(ChairName:sub(6, 6))
end

local function GetSeatedPlayerCount(MainModel: Model): number
	local count = 0
	if MainModel:GetAttribute("Player1") then count += 1 end
	if MainModel:GetAttribute("Player2") then count += 1 end
	return count
end

local function CancelCountdown(model: Model)
	if CountdownThreads[model] then
		task.cancel(CountdownThreads[model])
		CountdownThreads[model] = nil
	end
end

local function CleanUpAiCharacter(PlayerUserId: number)
	local CleanUpFolder = {}
	for _, AiCharacter in ipairs(AITemp:GetChildren()) do
		local ownerId = AiCharacter:GetAttribute("Player")
		if ownerId == PlayerUserId or ownerId == nil then
			table.insert(CleanUpFolder, AiCharacter)
		else
			local plr = Players:GetPlayerByUserId(ownerId)
			if not plr or not plr.Parent then
				table.insert(CleanUpFolder, AiCharacter)
			end
		end
	end

	for _, LeftOverCharacter in ipairs(CleanUpFolder) do
		-- Safely unseat humanoid first before destroying to prevent engine event cascades
		local hum = LeftOverCharacter:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.Sit = false
		end
		LeftOverCharacter:Destroy()
	end
end

local function SpawnAICharacter(model: Model)
	local ChairModel
	local ownerUserId = nil

	if model:GetAttribute("Player1") then
		ChairModel = model:WaitForChild("Chair2") :: Model
		ownerUserId = model:GetAttribute("Player1")
	elseif model:GetAttribute("Player2") then
		ChairModel = model:WaitForChild("Chair1") :: Model
		ownerUserId = model:GetAttribute("Player2")
	else
		return
	end

	CleanUpAiCharacter(ownerUserId)

	local seat = ChairModel:WaitForChild("Seat") :: Seat
	local newAI = AINpc:Clone()

	for _, part in ipairs(newAI:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end

	newAI:SetAttribute("Player", ownerUserId)
	newAI:PivotTo(seat.CFrame * CFrame.new(0, 1, 0))
	newAI.Parent = AITemp

	local aiHumanoid = newAI:FindFirstChildOfClass("Humanoid") :: Humanoid
	if not aiHumanoid then return end

	local success, err = pcall(function()
		seat:Sit(aiHumanoid)
	end)
	if not success then
		warn("Error on making the AI NPC sit : " .. err)
		return
	end

	-- SeatWeld is created synchronously by Sit(), so we can grab it right away
	local seatWeld = seat:FindFirstChild("SeatWeld")
	if seatWeld then
		seatWeld.C0 = seatWeld.C0 * CFrame.new(0, 0, 0.45)
	end

	-- Manually drive the sit pose since NPCs have no client to run a LocalScript Animate
	local animator = aiHumanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = aiHumanoid
	end

	local sitAnim = Instance.new("Animation")
	sitAnim.AnimationId = (aiHumanoid.RigType == Enum.HumanoidRigType.R6) and R6_SIT_ANIM or R15_SIT_ANIM

	local animSuccess, animResult = pcall(function()
		local track = animator:LoadAnimation(sitAnim)
		track.Priority = Enum.AnimationPriority.Movement
		track:Play()
	end)

	if not animSuccess then
		warn("Error loading AI NPC sit animation : " .. tostring(animResult))
	end
end

--------------------------------------------------------------------------------
-- // QUICK PLAY HANDLER
--------------------------------------------------------------------------------

local function FindClosestAvailableSeat(hrp: BasePart): Seat?
	local prioritySeat: Seat? = nil
	local priorityDistance = math.huge

	local fallbackSeat: Seat? = nil
	local fallbackDistance = math.huge

	-- Iterate through all seats inside TableAndChairs
	for _, desc in ipairs(TableAndChairs:GetDescendants()) do
		if desc:IsA("Seat") then
			local ChairModel = desc.Parent
			local MainModel = ChairModel and ChairModel.Parent

			if MainModel then
				local ChairNumber = GetChairNumber(ChairModel.Name)
				local playerAttr = MainModel:GetAttribute("Player" .. ChairNumber)

				-- Check if seat is unassigned and has no physical occupant
				if not desc.Occupant and not playerAttr then
					local distance = (hrp.Position - desc.Position).Magnitude
					local seatedCount = GetSeatedPlayerCount(MainModel)

					if seatedCount == 1 then
						-- Table has an opponent waiting
						if distance < priorityDistance then
							priorityDistance = distance
							prioritySeat = desc
						end
					elseif seatedCount == 0 then
						-- Table is completely empty
						if distance < fallbackDistance then
							fallbackDistance = distance
							fallbackSeat = desc
						end
					end
				end
			end
		end
	end

	-- Return priority seat if found; otherwise, return the closest empty table seat
	return prioritySeat or fallbackSeat
end

--------------------------------------------------------------------------------
-- // SKIN MANAGEMENT
--------------------------------------------------------------------------------

local function GetOrCreateSkinFolder(ChairModel: Model): Folder
	local skin = ChairModel:FindFirstChild("__Skin")
	if not skin then
		skin = Instance.new("Folder")
		skin.Name = "__Skin"
		skin.Parent = ChairModel

		for _, child in ipairs(ChairModel:GetChildren()) do
			if not child:IsA("Seat") and child ~= skin then
				child.Parent = skin
			end
		end

		ChairModel:SetAttribute("Type", "Default")
	end
	return skin
end

local function ApplySkin(ChairModel: Model, SkinName: string)
	SkinName = SkinName or "Default"

	if ChairModel:GetAttribute("Type") == SkinName then return end

	local Template = ChairsFolder:FindFirstChild(SkinName)
	if not Template then return end

	local PersistentSeat = ChairModel:FindFirstChildOfClass("Seat")
	if not PersistentSeat then return end

	local skinFolder = GetOrCreateSkinFolder(ChairModel)
	local clone = Template:Clone()
	local cloneSeat = clone:FindFirstChildOfClass("Seat")

	if cloneSeat then
		local offset = clone:GetPivot():ToObjectSpace(cloneSeat.CFrame)
		clone:PivotTo(PersistentSeat.CFrame * offset:Inverse())
		cloneSeat:Destroy()
	else
		clone:PivotTo(PersistentSeat.CFrame)
	end

	skinFolder:ClearAllChildren()
	for _, part in ipairs(clone:GetChildren()) do
		part.Parent = skinFolder
	end
	clone:Destroy()

	ChairModel:SetAttribute("Type", SkinName)
end

local function HandleChairSkins(player: Player, ChairModel: Model)
	local EquippedChair = DataService:get(player, "EquippedChair")
	ApplySkin(ChairModel, EquippedChair)
end

local function ResetChairSkin(ChairModel: Model)
	ApplySkin(ChairModel, "Default")
end

--------------------------------------------------------------------------------
-- // GAME LOGIC & MATCHMAKING
--------------------------------------------------------------------------------

local function CheckForGameStart(model: Model, player: Player, IsAIGame: boolean)
	local p1Id = model:GetAttribute("Player1")
	local p2Id = model:GetAttribute("Player2")

	if PlayersInGame[player.UserId] then return end

	if p1Id and p2Id then
		-- PVP Logic
		CleanUpAiCharacter(p1Id)
		CleanUpAiCharacter(p2Id)
		CancelCountdown(model)

		local p1 = Players:GetPlayerByUserId(p1Id)
		local p2 = Players:GetPlayerByUserId(p2Id)

		if p1 then AIButton_RE:FireClient(p1, false) end
		if p2 then AIButton_RE:FireClient(p2, false) end

		CountdownThreads[model] = task.spawn(function()
			for i = 3, 1, -1 do
				if not model:GetAttribute("Player1") or not model:GetAttribute("Player2") then
					CountdownThreads[model] = nil
					return
				end
				model.BillboardGui.TextLabel.Text = "Game starts in " .. i .. "..."
				task.wait(1)
			end

			CountdownThreads[model] = nil

			-- Ensure both players are STILL sitting
			local p1Char = p1 and p1.Character
			local p2Char = p2 and p2.Character
			local p1Hum = p1Char and p1Char:FindFirstChildOfClass("Humanoid")
			local p2Hum = p2Char and p2Char:FindFirstChildOfClass("Humanoid")

			if not p1Hum or not p1Hum.SeatPart or not p2Hum or not p2Hum.SeatPart then
				-- One of the players stood up at the exact last millisecond
				return
			end

			if p1 then PlayersInGame[p1.UserId] = true end
			if p2 then PlayersInGame[p2.UserId] = true end

			if model:GetAttribute("HardMode") then
				MainHandlerModule:StartHardGame(model)
			else
				MainHandlerModule:StartGame(model)
			end
		end)

	elseif IsAIGame then
		CancelCountdown(model)
		CleanUpAiCharacter(player.UserId)
		SpawnAICharacter(model)

		AIButton_RE:FireClient(player, false)

		CountdownThreads[model] = task.spawn(function()
			for i = 3, 1, -1 do
				-- Abort if player left seat mid-countdown
				if model:GetAttribute("Player1") ~= player.UserId and model:GetAttribute("Player2") ~= player.UserId then
					CleanUpAiCharacter(player.UserId)
					CountdownThreads[model] = nil
					return
				end

				model.BillboardGui.TextLabel.Text = "Game starts in " .. i .. "..."
				task.wait(1)
			end

			CountdownThreads[model] = nil
			AiStartingDebounce[player.UserId] = nil

			-- Verify player is STILL sitting in the seat
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")

			if not hum or not hum.SeatPart then
				-- Player jumped / left remote fired at t=0
				CleanUpAiCharacter(player.UserId)
				PlayersInGame[player.UserId] = nil
				return
			end

			PlayersInGame[player.UserId] = true

			if model:GetAttribute("HardMode") then
				MainHandlerModule:StartHardAiGame(model)
			else
				MainHandlerModule:StartAiGame(model)
			end
		end)
	else
		TopBarTextChange_RE:FireClient(player, true, "Waiting for opponent..")
		model.BillboardGui.TextLabel.Text = "1/2 Players"

		if not AiStartingDebounce[player.UserId] then
			AIButton_RE:FireClient(player, true)
		end
	end
end

--------------------------------------------------------------------------------
-- // SEAT OCCUPATION LISTENERS
--------------------------------------------------------------------------------

local function SetupSeat(seat: Seat)
	local ChairModel = seat.Parent :: Model
	local MainModel = ChairModel.Parent :: Model
	local ChairNumber = GetChairNumber(ChairModel.Name)

	GetOrCreateSkinFolder(ChairModel)

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		-- Prevent re-entrancy / infinite recursion loops when AI is destroyed
		if ProcessingSeats[seat] then return end
		ProcessingSeats[seat] = true

		local humanoid = seat.Occupant

		if not humanoid then
			local playerAttr = MainModel:GetAttribute("Player"..ChairNumber)
			local player = playerAttr and Players:GetPlayerByUserId(playerAttr)

			MainModel:SetAttribute("Player"..ChairNumber, nil)
			CancelCountdown(MainModel)

			if player then
				CleanUpAiCharacter(player.UserId)
				AiStartingDebounce[player.UserId] = nil
				PlayersInGame[player.UserId] = nil

				if player.Parent then
					QuickPlayButton_RE:FireClient(player, true)
					LeaveButton_RE:FireClient(player, false)
					AIButton_RE:FireClient(player, false)
					TopBarTextChange_RE:FireClient(player, false, "...")
				end
			end

			ResetChairSkin(ChairModel)

			local remaining = GetSeatedPlayerCount(MainModel)
			if MainModel:FindFirstChild("BillboardGui") and MainModel.BillboardGui:FindFirstChild("TextLabel") then

				MainModel.BillboardGui.Other.Visible = true
				MainModel.BillboardGui.TextLabel.Visible = true
				MainModel.BillboardGui.TextLabel.Text = remaining .. "/2 Players"
			end

			ProcessingSeats[seat] = nil
			return
		end

		local seatedCharacter = humanoid.Parent
		-- Safely verify if occupant belongs to an AI character
		if seatedCharacter and (seatedCharacter.Parent == AITemp or seatedCharacter:GetAttribute("Player")) then
			ProcessingSeats[seat] = nil
			return
		end

		local player = Players:GetPlayerFromCharacter(seatedCharacter)
		if player then
			if PlayersInGame[player.UserId] or MainModel:GetAttribute("Player"..ChairNumber) then
				humanoid.Sit = false
				ProcessingSeats[seat] = nil
				return
			end

			MainModel:SetAttribute("Player"..ChairNumber, player.UserId)
			LeaveButton_RE:FireClient(player, true)
			QuickPlayButton_RE:FireClient(player, false)

			HandleChairSkins(player, ChairModel)
			CheckForGameStart(MainModel, player, false)
		end

		ProcessingSeats[seat] = nil
	end)
end

for _, seat in pairs(TableAndChairs:GetDescendants()) do
	if seat:IsA("Seat") then SetupSeat(seat) end
end

--------------------------------------------------------------------------------
-- // REMOTES & EVENT LISTENERS
--------------------------------------------------------------------------------

AIButton_RE.OnServerEvent:Connect(function(player: Player)
	if AiStartingDebounce[player.UserId] or PlayersInGame[player.UserId] then return end

	local function FindPlayerSeat(container: Instance)
		for _, seat in ipairs(container:GetDescendants()) do
			if seat:IsA("Seat") and seat.Occupant and seat.Occupant.Parent == player.Character then
				return seat
			end
		end
		return nil
	end

	local playerSeat = FindPlayerSeat(HardMode) or FindPlayerSeat(TableAndChairs)
	if not playerSeat or not player.Character then return end

	AiStartingDebounce[player.UserId] = true
	AIButton_RE:FireClient(player, false)

	CheckForGameStart(playerSeat.Parent.Parent, player, true)
end)

QuickPlayButton_RE.OnServerEvent:Connect(function(player: Player)
	-- Guard checks
	if PlayersInGame[player.UserId] or AiStartingDebounce[player.UserId] then return end

	local character = player.Character
	if not character or not character.Parent then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not humanoid or humanoid.Health <= 0 or not hrp then return end

	-- Check if player is already sitting somewhere
	if humanoid.SeatPart then return end

	-- Get nearest seat (prioritizing tables with 1 player)
	local availableSeat = FindClosestAvailableSeat(hrp)
	if not availableSeat then
		warn("QuickPlay: No available seats found for player " .. player.Name)
		return
	end

	-- Move character to seat position and sit
	character:PivotTo(availableSeat.CFrame * CFrame.new(0, 1, 0))

	task.wait(0.1) -- Brief pause to ensure PivotTo replicates before sitting

	local success, err = pcall(function()
		availableSeat:Sit(humanoid)
	end)

	if success then
		-- Hide the QuickPlay button on the client
		QuickPlayButton_RE:FireClient(player, false)
	else
		warn("QuickPlay Error sitting player: " .. tostring(err))
	end
end)

LeaveButton_RE.OnServerEvent:Connect(function(player: Player)
	-- Block leave logic if player is currently registered in an active game session
	if PlayersInGame[player.UserId] then return end

	-- Fallback check against global playing session table
	local playingTable = _G.PlayingTable or {}
	local sessionData = playingTable[player.UserId]
	if sessionData then
		-- Block standing up if match is active or mid-ending cleanup
		if sessionData.State == "Playing" or sessionData.State == "Choosing" or sessionData.MatchEnding then
			return
		end
	end

	-- Character and Humanoid validity check
	local character = player.Character
	if not character or not character.Parent then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	-- Ensure player is actually sitting on a valid seat before triggering jump
	if humanoid.SeatPart and humanoid.SeatPart:IsA("Seat") then
		humanoid.Sit = false
		humanoid.Jump = true
	end
end)

Players.PlayerRemoving:Connect(function(player)
	CleanUpAiCharacter(player.UserId)
	AiStartingDebounce[player.UserId] = nil
	PlayersInGame[player.UserId] = nil
end)
