local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- // CONFIGURATION / TIME LIMITS
local NORMAL_MODE_TIME = 120
local HARD_MODE_TIME = 180

-- // Services & Data
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DataService = require(Packages:WaitForChild("Data").DataService).server
local DataHandler = require(ServerScriptService:WaitForChild("Handlers"):WaitForChild("DataHandler"))
local QuestsHandler = require(ServerScriptService:WaitForChild("Handlers"):WaitForChild("QuestsHandler"))

-- // Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UIRemotes = Remotes:WaitForChild("UIRemotes")
local MainGameRemotes = Remotes:WaitForChild("MainGameRemotes")
local TutorialRemotes = Remotes:WaitForChild("TutorialRemotes")

local TopBarTextChange_RE = UIRemotes:WaitForChild("TopBarTextChange")
local SetCamera_RE = MainGameRemotes:WaitForChild("SetCamera")
local ConnectBottleToUtility_RE = MainGameRemotes:WaitForChild("ConnectBottleToUtility")
local StartStopwatch_RE = MainGameRemotes:WaitForChild("StartStopwatch")
local SwapVisual_RE = MainGameRemotes:WaitForChild("SwapVisual_RE")
local TimerEnded_RE = MainGameRemotes:WaitForChild("TimerEnded")
local AttachBottle_RE = MainGameRemotes:WaitForChild("AttachBottle")
local SetMatchUIVisibility_RE = UIRemotes:WaitForChild("SetMatchUIVisibility")
local SubmitButton_RE = UIRemotes:WaitForChild("SubmitButton")
local LeaveButton_RE = UIRemotes:WaitForChild("LeaveButton")
local GiveUpButton_RE = UIRemotes:WaitForChild("GiveUpButton")
local QuickPlayButton_RE = UIRemotes:WaitForChild("QuickPlayButton")
local EndMatch_RE = MainGameRemotes:WaitForChild("EndMatch")
local ShowMatchResults_RE = MainGameRemotes:WaitForChild("ShowMatchResults")

local CheckTutorial_RE = TutorialRemotes:WaitForChild("CheckTutorialStatus")

-- // Utils
local Modules = ServerScriptService:WaitForChild("Services"):WaitForChild("MainGame"):WaitForChild("Modules")
local BottleUtils = require(Modules:WaitForChild("BottleUtils"))
local AIMoveGenerator = require(Modules:WaitForChild("AIMoveGenerator"))
local StandManager = require(Modules:WaitForChild("StandManager"))

local Assets = ReplicatedStorage:WaitForChild("Assets")
local BottleStand = Assets:WaitForChild("BottleStand") :: Model
local TempFolder = workspace:WaitForChild("Temp")

local AiMatch = {}

--------------------------------------------------------------------------------
-- // HELPER UTILS
--------------------------------------------------------------------------------

local function IsThreadValid(data, matchId)
	return data 
		and data.Mode == "AI" 
		and data.MatchId == matchId 
		and not data.MatchEnding 
		and data.Model 
		and data.Model.Parent ~= nil
end

local function CleanUpStands(d1, d2)
	if d1 and d1.BottleStand and d1.BottleStand.Parent then d1.BottleStand:Destroy() end
	if d2 and d2.BottleStand and d2.BottleStand.Parent then d2.BottleStand:Destroy() end
end

local function SyncSpectatorState(joiningPlayer)
	local playingTable = _G.PlayingTable or {}

	for userId, data in pairs(playingTable) do
		if data and data.Mode == "AI" and not data.MatchEnding then
			if data.BottleStand and data.BottleStand.Parent and data.CurrentLowerOrder then
				AttachBottle_RE:FireClient(
					joiningPlayer,
					data.BottleStand,
					"LowerPart",
					data.Skin or "Default",
					data.BottleCount,
					data.CurrentLowerOrder
				)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- // CLEANUP MECHANISM & PLAYER LISTENERS
--------------------------------------------------------------------------------

function AiMatch:CleanupMatch(humanPlayer, playingTable, forceDisconnect)
	local userId = type(humanPlayer) == "number" and humanPlayer or humanPlayer.UserId
	local humanData = playingTable[userId]
	if not humanData then return end

	local aiData = playingTable[humanData.OpponentId]

	if humanData.TurnThread then
		task.cancel(humanData.TurnThread)
		humanData.TurnThread = nil
	end
	if aiData and aiData.TurnThread then
		task.cancel(aiData.TurnThread)
		aiData.TurnThread = nil
	end

	CleanUpStands(humanData, aiData)

	if humanData.Model and humanData.Model.Parent then
		StandManager:SetBarriers(humanData.Model, false)
		humanData.Model:SetAttribute("EndedNormally", true)
	end

	if typeof(humanPlayer) == "Instance" and humanPlayer:IsA("Player") and humanPlayer.Parent then
		SetCamera_RE:FireClient(humanPlayer, "Unlock")
		SetMatchUIVisibility_RE:FireClient(humanPlayer, true)
		StandManager:EnableMovement(humanPlayer)
		StandManager:StandUpAndJump(humanPlayer)
		TopBarTextChange_RE:FireClient(humanPlayer, false, "...")
		GiveUpButton_RE:FireClient(humanPlayer, false)
		SubmitButton_RE:FireClient(humanPlayer, false)
		LeaveButton_RE:FireClient(humanPlayer, false)
		QuickPlayButton_RE:FireClient(humanPlayer, true)
	end

	playingTable[userId] = nil
	if aiData then
		playingTable[humanData.OpponentId] = nil
	end
end

Players.PlayerRemoving:Connect(function(leavingPlayer)
	local playingTable = _G.PlayingTable or {}
	if playingTable[leavingPlayer.UserId] and playingTable[leavingPlayer.UserId].Mode == "AI" then
		DataHandler.AwardLeave(leavingPlayer)
		AiMatch:CleanupMatch(leavingPlayer, playingTable, true)
	end
end)

Players.PlayerAdded:Connect(function(joiningPlayer)
	task.delay(1, function()
		if joiningPlayer and joiningPlayer.Parent then
			SyncSpectatorState(joiningPlayer)
		end
	end)
end)

--------------------------------------------------------------------------------
-- // MATCH FLOW
--------------------------------------------------------------------------------

function AiMatch:Start(humanPlayer, model, bottleCount, matchId)
	local aiId = -humanPlayer.UserId
	
	QuickPlayButton_RE:FireClient(humanPlayer, false)
	LeaveButton_RE:FireClient(humanPlayer, false)
	GiveUpButton_RE:FireClient(humanPlayer, false)

	if model:FindFirstChild("BillboardGui") and model.BillboardGui:FindFirstChild("TextLabel") then
		model.BillboardGui.Other.Visible = false
		model.BillboardGui.TextLabel.Visible = false
	end

	StandManager:DisableMovement(humanPlayer)
	StandManager:SetBarriers(model, true)

	local TableModel = model:WaitForChild("Table")
	local Stand1, Stand2 = BottleStand:Clone(), BottleStand:Clone()

	local Part1, Part2 = TableModel:WaitForChild("Part1"), TableModel:WaitForChild("Part2")
	if model:GetAttribute("Player1") then
		Stand1.PrimaryPart.Position = Part1.Position + Vector3.new(Part1.Size.X/2 - Stand1.PrimaryPart.Size.X/2, Part1.Size.Y/2, 0)
		Stand2.PrimaryPart.Position = Part2.Position + Vector3.new(Part2.Size.X/2 - Stand2.PrimaryPart.Size.X/2, Part2.Size.Y/2, 0)
	elseif model:GetAttribute("Player2") then
		Stand1.PrimaryPart.Position = Part2.Position + Vector3.new(-Part2.Size.X/2 + Stand1.PrimaryPart.Size.X/2, Part2.Size.Y/2, 0)
		Stand2.PrimaryPart.Position = Part1.Position + Vector3.new(-Part1.Size.X/2 + Stand2.PrimaryPart.Size.X/2, Part1.Size.Y/2, 0)
	end

	Stand1.Name = humanPlayer.Name .. "_Stand"
	Stand2.Name = "AI_Stand_" .. tostring(humanPlayer.UserId)

	Stand1.Parent, Stand2.Parent = TempFolder, TempFolder

	local p1Skin = DataService:get(humanPlayer, "EquippedBottle") or "Default"
	local p1ColorSet = BottleUtils:GenerateMasterColorLayout(p1Skin, bottleCount)
	local aiColorSet = BottleUtils:GenerateMasterColorLayout("Default", bottleCount)

	local playingTable = _G.PlayingTable or {}
	local isHardMode = (bottleCount == BottleUtils.HARD_MODE_BOTTLES)

	playingTable[humanPlayer.UserId] = {
		Mode = "AI", State = "Choosing", Turn = "None", MatchId = matchId,
		OpponentId = aiId, GivenBottleOrder = {}, CompletedTime = 999,
		BottleStand = Stand1, Skin = p1Skin, MatchEnding = false,
		StartingColorsList = table.clone(p1ColorSet), CurrentLowerOrder = table.clone(p1ColorSet),
		Model = model, BottleCount = bottleCount, IsHardMode = isHardMode,
		TurnThread = nil, GaveUp = false
	}

	playingTable[aiId] = {
		Mode = "AI", State = "Choosing", Turn = "None", MatchId = matchId,
		OpponentId = humanPlayer.UserId, GivenBottleOrder = {}, CompletedTime = 999,
		BottleStand = Stand2, Skin = "Default", MatchEnding = false,
		StartingColorsList = table.clone(aiColorSet), CurrentLowerOrder = table.clone(aiColorSet),
		Model = model, BottleCount = bottleCount, IsHardMode = isHardMode,
		TurnThread = nil, GaveUp = false
	}

	AttachBottle_RE:FireClient(humanPlayer, Stand1, "LowerPart", p1Skin, bottleCount, p1ColorSet)
	AttachBottle_RE:FireClient(humanPlayer, Stand2, "LowerPart", "Default", bottleCount, aiColorSet)

	StandManager:UpdateSpectatorVisuals(humanPlayer, nil, Stand1, "LowerPart", p1Skin, bottleCount, p1ColorSet, false, nil)
	StandManager:UpdateSpectatorVisuals(humanPlayer, nil, Stand2, "LowerPart", "Default", bottleCount, aiColorSet, false, nil)

	ConnectBottleToUtility_RE:FireClient(humanPlayer, Stand1, "LowerPart", true)
	SetCamera_RE:FireClient(humanPlayer, "Switch", Stand1)
	SetMatchUIVisibility_RE:FireClient(humanPlayer, false)

	TopBarTextChange_RE:FireClient(humanPlayer, true, "Choose Combinations for the AI!")
	SubmitButton_RE:FireClient(humanPlayer, true)

	task.delay(15, function()
		local data = playingTable[humanPlayer.UserId]
		if IsThreadValid(data, matchId) and data.State == "Choosing" then
			self:SubmitCombinations(humanPlayer, playingTable)
		end
	end)
end

function AiMatch:SubmitCombinations(humanPlayer, playingTable)
	local humanData = playingTable[humanPlayer.UserId]
	if not humanData or humanData.Mode ~= "AI" or humanData.State ~= "Choosing" or humanData.MatchEnding then return end

	local aiData = playingTable[humanData.OpponentId]
	if not aiData then return end

	humanData.State = "Playing"
	aiData.State = "Playing"
	SubmitButton_RE:FireClient(humanPlayer, false)

	local humanChosenOrder = humanData.CurrentLowerOrder or table.clone(humanData.StartingColorsList)
	aiData.GivenBottleOrder = table.clone(humanChosenOrder)

	humanData.GivenBottleOrder = BottleUtils:GenerateMasterColorLayout(humanData.Skin, humanData.BottleCount, humanChosenOrder)

	AttachBottle_RE:FireClient(
		humanPlayer,
		aiData.BottleStand,
		"UpperPart",
		"Default",
		aiData.BottleCount,
		aiData.GivenBottleOrder
	)

	ConnectBottleToUtility_RE:FireClient(humanPlayer, humanData.BottleStand, "LowerPart", false)

	task.wait(0.2)
	if not IsThreadValid(humanData, humanData.MatchId) then return end
	task.delay(10, function()
		GiveUpButton_RE:FireClient(humanPlayer, true)
	end)

	if math.random(1, 2) == 1 then
		self:StartHumanTurn(humanPlayer, humanData, playingTable)
	else
		self:RunAiTurn(humanPlayer, aiData, humanData, playingTable)
	end
end

function AiMatch:RunAiTurn(humanPlayer, aiData, humanData, playingTable)
	local matchId = aiData.MatchId
	aiData.Turn = "AI"
	humanData.Turn = "AI"
	aiData.TurnStartTime = tick()

	local maxTurnTime = humanData.IsHardMode and HARD_MODE_TIME or NORMAL_MODE_TIME

	SetCamera_RE:FireClient(humanPlayer, "Switch", aiData.BottleStand)
	ConnectBottleToUtility_RE:FireClient(humanPlayer, humanData.BottleStand, "LowerPart", false)

	TopBarTextChange_RE:FireClient(humanPlayer, true, "AI's Turn! 🤖")

	local timeToBeat = (humanData.CompletedTime < 999) and humanData.CompletedTime or nil
	StartStopwatch_RE:FireClient(humanPlayer, timeToBeat)

	humanData.TurnThread = task.spawn(function()
		local startOrder = table.clone(aiData.StartingColorsList)
		local targetOrder = aiData.GivenBottleOrder
		local workingOrder = table.clone(startOrder)

		local targetTotalTime = math.random(20, 70)
		local targetMoveCount = math.clamp(math.round(targetTotalTime / 2.25), 8, 30)

		local moves = AIMoveGenerator:GenerateOrderMoves(startOrder, targetOrder, targetMoveCount)

		task.wait(math.random(2, 5) / 10)

		local timedOut = false

		for _, move in ipairs(moves) do
			if not IsThreadValid(humanData, matchId) then return end

			if (tick() - aiData.TurnStartTime) >= maxTurnTime then
				timedOut = true
				break
			end

			local stepDelay = math.random(200, 250) / 100
			task.wait(stepDelay)

			if not IsThreadValid(humanData, matchId) then return end

			if (tick() - aiData.TurnStartTime) >= maxTurnTime then
				timedOut = true
				break
			end

			local idx1, idx2 = move[1], move[2]
			if idx1 and idx2 and workingOrder[idx1] and workingOrder[idx2] then
				workingOrder[idx1], workingOrder[idx2] = workingOrder[idx2], workingOrder[idx1]
				aiData.CurrentLowerOrder = table.clone(workingOrder)

				local matched = 0
				for i = 1, aiData.BottleCount do
					if workingOrder[i] == targetOrder[i] then matched += 1 end
				end

				TopBarTextChange_RE:FireClient(humanPlayer, true, "AI matched " .. matched .. " / " .. aiData.BottleCount .. " bottles! ⌛")

				SwapVisual_RE:FireAllClients("AI", aiData.BottleStand, "LowerPart", idx1, idx2)
			end
		end

		if not IsThreadValid(humanData, matchId) then return end

		humanData.TurnThread = nil

		if timedOut then
			aiData.CompletedTime = maxTurnTime
		else
			aiData.CurrentLowerOrder = table.clone(targetOrder)
			aiData.CompletedTime = math.min(tick() - aiData.TurnStartTime, maxTurnTime)
		end

		TimerEnded_RE:FireClient(humanPlayer)

		if humanData.CompletedTime == 999 then
			self:StartHumanTurn(humanPlayer, humanData, playingTable)
		else
			self:EndMatch(humanPlayer, humanData, aiData, playingTable)
		end
	end)
end

function AiMatch:StartHumanTurn(humanPlayer, humanData, playingTable)
	if not IsThreadValid(humanData, humanData.MatchId) then return end
	local aiData = playingTable[humanData.OpponentId]

	humanData.Turn = "Human"
	if aiData then aiData.Turn = "Human" end

	humanData.TurnStartTime = tick()
	local maxTurnTime = humanData.IsHardMode and HARD_MODE_TIME or NORMAL_MODE_TIME

	if humanData.GivenBottleOrder and #humanData.GivenBottleOrder > 0 then
		humanData.CurrentLowerOrder = BottleUtils:GenerateDerangement(humanData.GivenBottleOrder)
	else
		humanData.CurrentLowerOrder = humanData.CurrentLowerOrder or table.clone(humanData.StartingColorsList)
	end

	AttachBottle_RE:FireClient(
		humanPlayer, 
		humanData.BottleStand, 
		"LowerPart", 
		humanData.Skin, 
		humanData.BottleCount, 
		humanData.CurrentLowerOrder
	)

	StandManager:UpdateSpectatorVisuals(
		humanPlayer, 
		nil, 
		humanData.BottleStand, 
		"LowerPart", 
		humanData.Skin, 
		humanData.BottleCount, 
		humanData.CurrentLowerOrder, 
		false, 
		nil
	)

	SetCamera_RE:FireClient(humanPlayer, "Switch", humanData.BottleStand)
	ConnectBottleToUtility_RE:FireClient(humanPlayer, humanData.BottleStand, "LowerPart", true)

	TopBarTextChange_RE:FireClient(humanPlayer, true, "0 / " .. humanData.BottleCount .. " bottles matched! ⌛")

	local timeToBeat = (aiData and aiData.CompletedTime < 999) and aiData.CompletedTime or nil
	StartStopwatch_RE:FireClient(humanPlayer, timeToBeat)

	if humanData.TurnThread then task.cancel(humanData.TurnThread) end
	humanData.TurnThread = task.spawn(function()
		task.wait(maxTurnTime)
		if IsThreadValid(humanData, humanData.MatchId) and humanData.Turn == "Human" and humanData.CompletedTime == 999 then
			humanData.CompletedTime = maxTurnTime
			ConnectBottleToUtility_RE:FireClient(humanPlayer, humanData.BottleStand, "LowerPart", false)
			TimerEnded_RE:FireClient(humanPlayer)

			if aiData and aiData.CompletedTime == 999 then
				self:RunAiTurn(humanPlayer, aiData, humanData, playingTable)
			else
				self:EndMatch(humanPlayer, humanData, aiData, playingTable)
			end
		end
	end)
end

function AiMatch:HandleMoveMade(player, orderNamesArray, playingTable)
	local data = playingTable[player.UserId]
	if not data or data.Mode ~= "AI" or data.Turn ~= "Human" or data.MatchEnding then return end

	local aiData = playingTable[data.OpponentId]
	if not aiData then return end

	local maxTurnTime = data.IsHardMode and HARD_MODE_TIME or NORMAL_MODE_TIME
	local elapsed = tick() - data.TurnStartTime

	if elapsed >= maxTurnTime then
		return
	end

	local oldOrder = data.CurrentLowerOrder or table.clone(data.StartingColorsList)
	if not BottleUtils:IsSameMultiset(oldOrder, orderNamesArray) then return end
	if not BottleUtils:IsValidSingleSwap(oldOrder, orderNamesArray) then return end

	local idx1, idx2 = nil, nil
	for i = 1, data.BottleCount do
		if oldOrder[i] ~= orderNamesArray[i] then
			if not idx1 then idx1 = i else idx2 = i end
		end
	end

	data.CurrentLowerOrder = table.clone(orderNamesArray)

	local matched = 0
	local targetOrder = data.GivenBottleOrder
	for i = 1, data.BottleCount do
		if data.CurrentLowerOrder[i] == targetOrder[i] then matched += 1 end
	end

	if idx1 and idx2 then
		SwapVisual_RE:FireClient(player, player, data.BottleStand, "LowerPart", idx1, idx2)
		SwapVisual_RE:FireAllClients(player, data.BottleStand, "LowerPart", idx1, idx2)
	end

	TopBarTextChange_RE:FireClient(player, true, matched .. " / " .. data.BottleCount .. " bottles matched! ⌛")

	if matched == data.BottleCount then
		if data.TurnThread then
			task.cancel(data.TurnThread)
			data.TurnThread = nil
		end

		data.CompletedTime = math.min(elapsed, maxTurnTime)
		ConnectBottleToUtility_RE:FireClient(player, data.BottleStand, "LowerPart", false)
		TimerEnded_RE:FireClient(player)

		if aiData.CompletedTime == 999 then
			self:RunAiTurn(player, aiData, data, playingTable)
		else
			self:EndMatch(player, data, aiData, playingTable)
		end
	end
end

function AiMatch:GiveUp(player, playingTable)
	local humanData = playingTable[player.UserId]
	if not humanData or humanData.Mode ~= "AI" or humanData.MatchEnding then return end

	local maxTurnTime = humanData.IsHardMode and HARD_MODE_TIME or NORMAL_MODE_TIME
	local aiData = playingTable[humanData.OpponentId]

	if humanData.CompletedTime == 999 then
		humanData.CompletedTime = humanData.TurnStartTime and math.min(tick() - humanData.TurnStartTime, maxTurnTime) or maxTurnTime
	end

	if aiData and aiData.CompletedTime == 999 then
		aiData.CompletedTime = aiData.TurnStartTime and math.min(tick() - aiData.TurnStartTime, maxTurnTime) or maxTurnTime
	end

	humanData.GaveUp = true
	self:EndMatch(player, humanData, aiData, playingTable)
end

function AiMatch:LeaveMatch(player, playingTable)
	DataHandler.AwardLeave(player)
	self:CleanupMatch(player, playingTable, true)
end

function AiMatch:EndMatch(humanPlayer, humanData, aiData, playingTable)
	if not humanData or humanData.MatchEnding then return end
	humanData.MatchEnding = true
	if aiData then aiData.MatchEnding = true end

	local isHardMode = humanData.IsHardMode or false
	local humanWon = not humanData.GaveUp and (humanData.CompletedTime < (aiData and aiData.CompletedTime or 999))
	local hasDoubleCash = DataService:get(humanPlayer, "DoubleCash") or false	

	local baseAward = humanWon and (isHardMode and 100 or 30) or 0
	local defaultAward = hasDoubleCash and (baseAward * 2) or baseAward

	if humanWon then
		TopBarTextChange_RE:FireClient(humanPlayer, true, "You Won against AI!")
		DataHandler.AwardWin(humanPlayer, isHardMode, true)	
		QuestsHandler.OnMatchEnded(humanPlayer, nil)

		if humanData.Model then 
			StandManager:AnnounceWinnerOnBillboard(humanData.Model, humanPlayer.Name) 
		end
	else
		TopBarTextChange_RE:FireClient(humanPlayer, true, "AI Won the Match!")
		DataHandler.AwardLoss(humanPlayer, isHardMode, true)

		if humanData.Model then 
			StandManager:AnnounceWinnerOnBillboard(humanData.Model, "AI Opponent") 
		end
	end

	local resultData = {
		IsWinner = humanWon,
		MyTime = humanData.CompletedTime < 999 and humanData.CompletedTime or 0,
		MyStreak = DataService:get(humanPlayer, "Streak") or 0,
		MyReward = defaultAward,
		OpponentUserId = humanData.OpponentId,
		OpponentDisplayName = "AI Opponent",
		OpponentTime = (aiData and aiData.CompletedTime < 999) and aiData.CompletedTime or 0,
		OpponentStreak = 0,
	}

	GiveUpButton_RE:FireClient(humanPlayer, false)
	ConnectBottleToUtility_RE:FireClient(humanPlayer, humanData.BottleStand, "LowerPart", false)
	TimerEnded_RE:FireClient(humanPlayer)

	if not DataService:get(humanPlayer, "hasCompletedTutorial") then
		DataService:set(humanPlayer, "hasCompletedTutorial", true)
		CheckTutorial_RE:FireClient(humanPlayer, true)
	end	

	ShowMatchResults_RE:FireClient(humanPlayer, resultData)
	EndMatch_RE:FireClient(humanPlayer, humanWon)

	task.wait(0.5)
	self:CleanupMatch(humanPlayer, playingTable, false)
end

return AiMatch
