-- Hood Customs Free For All — Autokill
-- UI: LinoriaLib (violin-suzutsuki fork)
-- Combat routes through a single remote: ReplicatedStorage.MainEvent:FireServer(action, ...)
--   "Shoot"  -> {ORIGIN=Vector3, AIM=Vector3, INDEX=number, HITS={[pellet]=hitcode}}   hitcode 1 = landed
--   "Reload" -> reloads the equipped gun
--   "Stomp"  -> finisher; server resolves the KO'd player beneath your LowerTorso
-- Kill model in this framework: gun damage drops the target to K.O, Stomp finishes.

local repo = 'https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/'
local Library      = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager  = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()

local Players          = game:GetService('Players')
local RunService       = game:GetService('RunService')
local ReplicatedStorage= game:GetService('ReplicatedStorage')

local LocalPlayer = Players.LocalPlayer
local MainEvent   = ReplicatedStorage:WaitForChild('MainEvent')

-- kill any previous instance before building a new one (safe re-execute)
if getgenv().HoodCustoms_Unload then
    pcall(getgenv().HoodCustoms_Unload)
end

local Connections = {}   -- every connection we make lives here so teardown can drop them all
local Unloaded    = false -- the loop checks this and bails the instant we tear down

-- ============================================================= helpers

-- The gun framework keeps ONE shared state table that owns the shot counter (INDEX).
-- The server stays synced to that counter. If we invent our own index the server rejects
-- the shot with ERROR_CLIENT_UNSYNCED_SERVER, so we grab the real table out of the GC and
-- mirror its INDEX — incrementing it the same way the game's own gun script does.
local GunState = nil
local function getGunState()
    if GunState and type(GunState) == 'table' and rawget(GunState, 'INDEX') ~= nil then
        return GunState
    end
    GunState = nil
    local ok, gc = pcall(getgc, true)
    if not ok then return nil end
    for _, v in ipairs(gc) do
        if type(v) == 'table'
            and rawget(v, 'PENDING') ~= nil
            and rawget(v, 'INDEX')   ~= nil
            and rawget(v, 'KNIVES')  ~= nil then
            GunState = v
            break
        end
    end
    return GunState
end

local function nextShotIndex()
    local st = getGunState()
    if not st then return nil end
    st.INDEX += 1          -- advance the real counter so the game's own script stays synced too
    return st.INDEX
end

local function alive(char)
    if not char then return false end
    local hum = char:FindFirstChildOfClass('Humanoid')
    return hum and hum.Health > 0 and char:FindFirstChild('HumanoidRootPart') ~= nil
end

local function isKO(char)
    local be = char and char:FindFirstChild('BodyEffects')
    local ko = be and be:FindFirstChild('K.O')
    return ko and ko.Value == true
end

-- my own gate for firing Stomp (mirrors the game's client stomp() checks)
local function canStomp()
    local char = LocalPlayer.Character
    local be = char and char:FindFirstChild('BodyEffects')
    if not be then return false end
    return be['K.O'].Value == false
        and be.Reloading_CLIENT.Value == false
        and be.Attacking_CLIENT.Value == false
        and be.Grabbed.Value == nil
        and char:FindFirstChild('GRABBING_CONSTRAINT') == nil
end

-- find a usable gun (Tool holding a GunData module) in character or backpack
local function findGun()
    local char = LocalPlayer.Character
    if char then
        local t = char:FindFirstChildOfClass('Tool')
        if t and t:FindFirstChild('GunData') then return t, true end
    end
    for _, t in ipairs(LocalPlayer.Backpack:GetChildren()) do
        if t:IsA('Tool') and t:FindFirstChild('GunData') then return t, false end
    end
    return nil, false
end

local function gunAmmo(tool)
    local s = tool and tool:FindFirstChild('Script')
    local ammo = s and s:FindFirstChild('Ammo')
    local client = ammo and ammo:FindFirstChild('CLIENT')
    return client and client.Value or 0
end

local function targetParts(char)
    local hrp  = char:FindFirstChild('HumanoidRootPart')
    local torso= char:FindFirstChild('Torso') or char:FindFirstChild('LowerTorso') or hrp
    return hrp, torso
end

-- resolve the player we're attacking: selected in dropdown, or nearest if enabled
local function resolveTarget()
    local myChar = LocalPlayer.Character
    local myHRP = myChar and myChar:FindFirstChild('HumanoidRootPart')
    if not myHRP then return nil end

    -- an explicit dropdown pick always wins; "Nearest" is only the fallback
    local name = Options.TargetPlayer.Value
    if name and name ~= '' then
        local plr = Players:FindFirstChild(name)
        if plr and alive(plr.Character) then return plr end
        -- selected player is dead/gone; fall through to Nearest only if it's enabled
    end

    if Toggles.Nearest.Value then
        local best, bestD = nil, math.huge
        local maxD = Options.MaxDistance.Value
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and alive(plr.Character) then
                local hrp = plr.Character:FindFirstChild('HumanoidRootPart')
                local d = (hrp.Position - myHRP.Position).Magnitude
                if d < bestD and d <= maxD then best, bestD = plr, d end
            end
        end
        return best
    end

    return nil
end

-- ============================================================= combat actions

local function equipGun(tool, inChar)
    if inChar then return end
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass('Humanoid')
    if hum then pcall(function() hum:EquipTool(tool) end) end
end

local function fireShot(tool, targetChar)
    local handle = tool:FindFirstChild('Handle')
    local _, torso = targetParts(targetChar)
    if not handle or not torso then return end

    local idx = nextShotIndex()
    if not idx then return end   -- no synced gun state yet; skip rather than desync the server

    -- single pellet straight at the torso, flagged as a landed hit (code 1)
    MainEvent:FireServer('Shoot', {
        ORIGIN = handle.Position,
        AIM    = torso.Position,
        INDEX  = idx,
        HITS   = { [1] = 1 },
    })
end

local function doStomp()
    MainEvent:FireServer('Stomp')
end

-- ============================================================= teleport

local SavedCFrame = nil

local function tpTo(targetChar, offset)
    local myChar = LocalPlayer.Character
    local myHRP  = myChar and myChar:FindFirstChild('HumanoidRootPart')
    local tHRP   = targetChar and targetChar:FindFirstChild('HumanoidRootPart')
    if not myHRP or not tHRP then return end
    if not SavedCFrame then SavedCFrame = myHRP.CFrame end
    myHRP.CFrame = tHRP.CFrame * offset
    myHRP.AssemblyLinearVelocity = Vector3.zero
end

local function tpBack()
    local myChar = LocalPlayer.Character
    local myHRP  = myChar and myChar:FindFirstChild('HumanoidRootPart')
    if myHRP and SavedCFrame then
        myHRP.CFrame = SavedCFrame
        myHRP.AssemblyLinearVelocity = Vector3.zero
    end
    SavedCFrame = nil
end

-- ============================================================= UI

local Window = Library:CreateWindow({
    Title = 'Hood Customs — Autokill',
    Center = true,
    AutoShow = true,
    TabPadding = 8,
    MenuFadeTime = 0.2,
})

local Tabs = {
    Main = Window:AddTab('Main'),
    Settings = Window:AddTab('UI Settings'),
}

local Box = Tabs.Main:AddLeftGroupbox('Autokill')

Box:AddToggle('Enabled', { Text = 'Autokill enabled', Default = false, Tooltip = 'Master switch for the kill loop' })

Box:AddDropdown('TargetPlayer', {
    SpecialType = 'Player',
    Text = 'Target player',
    Tooltip = 'Who to kill (ignored when Nearest is on)',
    ExcludeLocalPlayer = true,
})

Box:AddToggle('Nearest', { Text = 'Fallback to nearest', Default = true, Tooltip = 'When no dropdown target is picked (or it died), auto-target the closest living player' })
Box:AddToggle('UseGun',  { Text = 'Shoot to down',  Default = true, Tooltip = 'Fire the gun at the target until they K.O' })
Box:AddToggle('UseStomp',{ Text = 'Stomp to finish',Default = true, Tooltip = 'Fire the finisher once the target is downed' })
Box:AddToggle('AutoEquip',{ Text = 'Auto-equip gun', Default = true, Tooltip = 'Pull a gun from the backpack if none is held' })
Box:AddToggle('AutoReload',{ Text = 'Auto-reload',  Default = true, Tooltip = 'Reload when the clip is empty' })
Box:AddToggle('TPKill',  { Text = 'Teleport to target', Default = true, Tooltip = 'Blink onto the target to guarantee range + stomp alignment' })
Box:AddToggle('Return',  { Text = 'Return after kill',  Default = false, Tooltip = 'Teleport back to your original spot after each finish' })

Box:AddSlider('MaxDistance', { Text = 'Max distance', Default = 300, Min = 10, Max = 2000, Rounding = 0, Suffix = ' studs' })
Box:AddSlider('FireDelay',   { Text = 'Action delay', Default = 0.08, Min = 0.03, Max = 0.6, Rounding = 2, Suffix = 's' })

local FarmBox = Tabs.Main:AddRightGroupbox('Stomp farm')
FarmBox:AddToggle('StompFarm', { Text = 'Stomp anyone under me', Default = false, Tooltip = 'Pure finisher spam — stomps any downed body beneath you' })

Box:AddLabel('Toggle autokill'):AddKeyPicker('AutokillKey', { Default = 'K', Mode = 'Toggle', Text = 'Autokill', SyncToggleState = true })

Box:AddDivider()
Box:AddButton('Unload', function() Library:Unload() end)  -- routes through Library:OnUnload below

-- ============================================================= logic

local busy = false

local function step()
    if Unloaded or busy then return end

    -- pure stomp farm: stomp whatever downed body is under us
    if Toggles.StompFarm.Value and canStomp() then
        doStomp()
    end

    if not Toggles.Enabled.Value then
        if SavedCFrame then tpBack() end
        return
    end

    local target = resolveTarget()
    if not target or not alive(target.Character) then
        if Toggles.Return.Value and SavedCFrame then tpBack() end
        return
    end

    busy = true
    local ok = pcall(function()
        local tChar = target.Character
        local delayT = Options.FireDelay.Value

        if isKO(tChar) then
            -- finisher phase
            if Toggles.UseStomp.Value then
                if Toggles.TPKill.Value then tpTo(tChar, CFrame.new(0, 3, 0)) end
                task.wait(0.05)
                if canStomp() then doStomp() end
                task.wait(0.15)
                if Toggles.Return.Value then tpBack() end
            end
            return
        end

        -- damage phase
        if Toggles.UseGun.Value then
            local gun, inChar = findGun()
            if gun then
                if not inChar and Toggles.AutoEquip.Value then
                    equipGun(gun, inChar)
                    task.wait(0.1)
                    gun, inChar = findGun()
                end
                if gun and inChar then
                    if gunAmmo(gun) <= 0 then
                        if Toggles.AutoReload.Value then MainEvent:FireServer('Reload') ; task.wait(0.25) end
                    else
                        if Toggles.TPKill.Value then tpTo(tChar, CFrame.new(0, 0, 4)) end
                        fireShot(gun, tChar)
                    end
                end
            end
        end
        task.wait(delayT)
    end)
    busy = false
    if not ok then task.wait(0.1) end
end

Connections.Heartbeat = RunService.Heartbeat:Connect(function()
    pcall(step)
end)

-- ============================================================= teardown

-- Full unload: stop the loop, drop every connection, restore position, free the global.
-- The Unload button and the menu's X both call Library:Unload(), which fires this.
local function teardown()
    if Unloaded then return end
    Unloaded = true

    for key, conn in pairs(Connections) do
        if typeof(conn) == 'RBXScriptConnection' then
            pcall(function() conn:Disconnect() end)
        end
        Connections[key] = nil
    end

    -- put us back where we started if a teleport left us parked on someone
    pcall(tpBack)

    getgenv().HoodCustoms_Unload = nil
end

getgenv().HoodCustoms_Unload = function()
    teardown()
    pcall(function() Library:Unload() end)
end

Library:OnUnload(teardown)

-- ============================================================= addons / config

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)

SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ 'AutokillKey' })

ThemeManager:SetFolder('HoodCustomsAutokill')
SaveManager:SetFolder('HoodCustomsAutokill/configs')

SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)

SaveManager:LoadAutoloadConfig()

Library:Notify('Hood Customs Autokill loaded — press RightShift for menu, K to toggle.')
