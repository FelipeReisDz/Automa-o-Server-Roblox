--[[
    Server Hopper com painel de UI — criado por Lipe
    - Clique manual: troca de servidor na hora
    - Auto mode: troca automaticamente, com intervalo (em minutos)
      configurável direto no painel
    Cole este script LOGO ABAIXO da sua linha de loadstring.
]]

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local placeId = game.PlaceId

-- forward declaration: a implementação real é definida mais abaixo, na seção de UI,
-- mas algumas funções de lógica (como hopServer) precisam chamá-la antes disso
local setStatus = function(_, _) end

local AUTO_INTERVAL = 120 -- 2 minutos em segundos
local SAFETY_MARGIN = 2 -- ignora servidores a menos de 2 vagas de encher
local autoEnabled = false
local hopping = false -- trava para não disparar teleport duplicado
local candidateQueue = {} -- fila de servidores candidatos, ordenados pela preferência atual
local candidateIndex = 0

-- Preferência de busca: "fewest" (menos jogadores), "most" (mais jogadores), "ping" (mais próximo/responsivo)
local PREFERENCE_ORDER = {"fewest", "most", "ping"}
local PREFERENCE_LABELS = {
    fewest = "Menos jogadores",
    most = "Mais jogadores",
    ping = "Mais próximo (ping)",
}
local currentPreference = "fewest"

-- Busca uma lista de servidores públicos e retorna candidatos ordenados
-- Otimizado para parar assim que achar candidatos suficientes (evita varrer páginas demais)
local MIN_CANDIDATES_TO_STOP = 10
local MAX_PAGES = 3

local function getServerCandidates()
    local cursor = ""
    local candidates = {}

    -- se a preferência é "mais jogadores", já pede a API na ordem decrescente,
    -- assim os primeiros resultados já são os que interessam (menos páginas necessárias)
    local sortOrder = (currentPreference == "most") and "Desc" or "Asc"

    for page = 1, MAX_PAGES do
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&limit=100%s")
            :format(placeId, sortOrder, cursor ~= "" and ("&cursor=" .. cursor) or "")

        local ok, res = pcall(function()
            return HttpService:JSONDecode(game:HttpGet(url))
        end)

        if not ok or not res or not res.data then
            warn("[ServerHop] Falha ao consultar a API de servidores (página " .. page .. ").")
            break
        end

        for _, server in ipairs(res.data) do
            -- só considera servidor com margem de segurança (evita pegar um quase cheio)
            if server.id ~= game.JobId and server.playing < (server.maxPlayers - SAFETY_MARGIN) then
                table.insert(candidates, server)
            end
        end

        -- para de buscar mais páginas assim que já tiver candidatos suficientes
        if #candidates >= MIN_CANDIDATES_TO_STOP then
            break
        end

        if res.nextPageCursor and res.nextPageCursor ~= "" then
            cursor = res.nextPageCursor
        else
            break
        end
    end

    if currentPreference == "most" then
        table.sort(candidates, function(a, b) return a.playing > b.playing end)
    elseif currentPreference == "ping" then
        table.sort(candidates, function(a, b)
            return (a.ping or math.huge) < (b.ping or math.huge)
        end)
    else -- "fewest" (padrão)
        table.sort(candidates, function(a, b) return a.playing < b.playing end)
    end

    return candidates
end

local function tryNextCandidate()
    candidateIndex += 1
    local server = candidateQueue[candidateIndex]

    if not server then
        warn("[ServerHop] Nenhum candidato restante com vaga suficiente. Buscando lista nova...")
        hopping = false
        return
    end

    local logMsg = ("[ServerHop] Tentando servidor %s (%d/%d players"):format(server.id, server.playing, server.maxPlayers)
    if currentPreference == "ping" and server.ping then
        logMsg = logMsg .. (", ping %dms"):format(server.ping)
    end
    print(logMsg .. ")")

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId, server.id, player)
    end)

    if not ok then
        warn("[ServerHop] Erro imediato ao tentar teleportar: " .. tostring(err))
        tryNextCandidate() -- tenta o próximo da fila
    end
    -- se não deu erro imediato, esperamos o resultado assíncrono
    -- (sucesso = o jogo troca sozinho; falha = TeleportInitFailed abaixo)
end

local function hopServer()
    if hopping then return end
    hopping = true

    local startTime = os.clock()
    candidateQueue = getServerCandidates()
    local searchTime = os.clock() - startTime
    candidateIndex = 0

    print(("[ServerHop] Busca levou %.1fs — %d candidato(s) encontrado(s)")
        :format(searchTime, #candidateQueue))

    if #candidateQueue == 0 then
        warn("[ServerHop] Nenhum servidor com vaga suficiente encontrado no momento.")
        setStatus("Nenhum servidor disponível", Color3.fromRGB(230, 80, 80))
        hopping = false
        return
    end

    tryNextCandidate()
end

-- Se a Roblox recusar o teleport (ex: servidor encheu antes de entrarmos), tenta o próximo
TeleportService.TeleportInitFailed:Connect(function(_, teleportResult, errorMessage)
    warn(("[ServerHop] Teleport falhou (%s): %s — tentando próximo servidor")
        :format(tostring(teleportResult), tostring(errorMessage)))
    if hopping then
        tryNextCandidate()
    end
end)

-- ===================== UI =====================

print("[ServerHop] Script iniciado, criando GUI...")

local TweenService = game:GetService("TweenService")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LipeServerHopGui"
screenGui.ResetOnSpawn = false

-- Tenta usar um container "protegido" do executor (evita jogos que limpam a PlayerGui).
-- Se não existir, cai pro CoreGui, e por último pra PlayerGui normal.
local parentContainer
local ok1, hui = pcall(function() return gethui() end)
if ok1 and hui then
    parentContainer = hui
    print("[ServerHop] Usando gethui() como parent.")
else
    local ok2, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and coreGui then
        parentContainer = coreGui
        print("[ServerHop] gethui() indisponível, usando CoreGui como parent.")
    else
        parentContainer = player:WaitForChild("PlayerGui")
        print("[ServerHop] gethui() e CoreGui indisponíveis, usando PlayerGui.")
    end
end

local okParent, parentErr = pcall(function()
    screenGui.Parent = parentContainer
end)

if not okParent then
    warn("[ServerHop] Falha ao dar parent na GUI: " .. tostring(parentErr))
    warn("[ServerHop] Tentando fallback direto pra PlayerGui...")
    screenGui.Parent = player:WaitForChild("PlayerGui")
end

print("[ServerHop] GUI parenteada em: " .. screenGui.Parent:GetFullName())

local ACCENT_GREEN = Color3.fromRGB(80, 250, 123)   -- #50FA7B
local ACCENT_GRAY = Color3.fromRGB(226, 226, 226)   -- #E2E2E2
local BG_DARK = Color3.fromRGB(12, 12, 14)
local CARD_BG = Color3.fromRGB(18, 18, 20)
local PANEL_BG = Color3.fromRGB(22, 22, 26)
local STROKE = Color3.fromRGB(30, 30, 34)
local TEXT_MAIN = Color3.fromRGB(230, 230, 235)
local TEXT_MUTED = Color3.fromRGB(160, 160, 170)

-- Card principal (o Size abaixo é o valor inicial; a altura final real é ajustada
-- mais adiante, depois que todos os elementos internos são criados)
local card = Instance.new("Frame")
card.Name = "Card"
card.Size = UDim2.new(0, 220, 0, 196)
card.Position = UDim2.new(0, 20, 0.5, -137)
card.BackgroundColor3 = CARD_BG
card.BorderSizePixel = 0
card.Parent = screenGui

local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0, 14)
cardCorner.Parent = card


local cardStroke = Instance.new("UIStroke")
cardStroke.Name = "CardStroke"
cardStroke.Color = STROKE
cardStroke.Thickness = 1
cardStroke.Transparency = 0.55
cardStroke.Parent = card

local shadow = Instance.new("ImageLabel")
shadow.Name = "Shadow"
shadow.BackgroundTransparency = 1
shadow.Image = "rbxassetid://1316045217"
shadow.ImageColor3 = Color3.new(0, 0, 0)
shadow.ImageTransparency = 0.55
shadow.ScaleType = Enum.ScaleType.Slice
shadow.SliceCenter = Rect.new(10, 10, 118, 118)
shadow.Size = UDim2.new(1, 40, 1, 40)
shadow.Position = UDim2.new(0, -20, 0, -14)
shadow.ZIndex = -1
shadow.Parent = card

-- Barra de título (com gradiente) — funciona como "alça" de arrasto do card inteiro
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 34)
titleBar.BackgroundColor3 = BG_DARK
titleBar.BorderSizePixel = 0
titleBar.Active = true
titleBar.Parent = card

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 14)
titleCorner.Parent = titleBar

-- corrige o corner "quadrado" só na parte de baixo da titlebar
local titleFix = Instance.new("Frame")
titleFix.BackgroundColor3 = titleBar.BackgroundColor3
titleFix.BorderSizePixel = 0
titleFix.Size = UDim2.new(1, 0, 0, 14)
titleFix.Position = UDim2.new(0, 0, 1, -14)
titleFix.Parent = titleBar

local titleGradient = Instance.new("UIGradient")
titleGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 28, 32)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(22, 22, 26)),
})
titleGradient.Rotation = 20
titleGradient.Parent = titleBar

local titleText = Instance.new("TextLabel")
titleText.BackgroundTransparency = 1
titleText.Size = UDim2.new(1, -16, 1, 0)
titleText.Position = UDim2.new(0, 12, 0, 0)
titleText.Text = "Server Hopper"
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.TextColor3 = ACCENT_GREEN
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 15
titleText.Parent = titleBar

-- Drag manual: arrasta o CARD INTEIRO (não só a titleBar), usando a titleBar como alça
local UserInputService = game:GetService("UserInputService")
local dragging = false
local dragStart
local startCardPos

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startCardPos = card.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        card.Position = UDim2.new(
            startCardPos.X.Scale, startCardPos.X.Offset + delta.X,
            startCardPos.Y.Scale, startCardPos.Y.Offset + delta.Y
        )
    end
end)

local signature = Instance.new("TextLabel")
signature.Name = "Signature"
signature.BackgroundTransparency = 1
signature.Size = UDim2.new(1, -16, 0, 14)
signature.Position = UDim2.new(0, 12, 0, 40)
signature.Text = "criado por Lipe"
signature.TextXAlignment = Enum.TextXAlignment.Left
signature.TextColor3 = Color3.fromRGB(140, 140, 150)
signature.Font = Enum.Font.Gotham
signature.TextSize = 11
signature.Parent = card

-- ================= Mini-caixa (corrigida: mesma largura lógica do card, drag independente, texto visível) =================
local ACCENT_G = ACCENT_GREEN or Color3.fromRGB(80,250,123)    -- #50FA7B
local ACCENT_GARY = ACCENT_GRAY or Color3.fromRGB(226,226,226) -- #E2E2E2
local CARD_BG_COL = CARD_BG or Color3.fromRGB(18,18,20)
local STROKE_COL = STROKE or Color3.fromRGB(30,30,34)

-- remove mini anterior se existir
local existingMini = screenGui:FindFirstChild("MiniBox")
if existingMini then existingMini:Destroy() end

local MINI_H = 28
local MINI_PAD = 8

local miniFrame = Instance.new("Frame")
miniFrame.Name = "MiniBox"
-- largura inicial: copia card.Size.X (Scale+Offset) na primeira aplicação abaixo
miniFrame.Size = UDim2.new(card.Size.X.Scale or 0, card.Size.X.Offset or 220, 0, MINI_H)
-- posição inicial separada do card (ajuste se quiser)
miniFrame.Position = UDim2.new(0, 20, 0, 20)
miniFrame.AnchorPoint = Vector2.new(0,0)
miniFrame.BackgroundColor3 = CARD_BG_COL
miniFrame.BorderSizePixel = 0
miniFrame.ZIndex = 50
miniFrame.Parent = screenGui

local miniCorner = Instance.new("UICorner"); miniCorner.CornerRadius = UDim.new(0,8); miniCorner.Parent = miniFrame
local miniStroke = Instance.new("UIStroke"); miniStroke.Color = STROKE_COL; miniStroke.Thickness = 1; miniStroke.Transparency = 0.6; miniStroke.Parent = miniFrame

local leftAccentMini = Instance.new("Frame")
leftAccentMini.Name = "LeftAccent"
leftAccentMini.Size = UDim2.new(0, 6, 1, 0)
leftAccentMini.Position = UDim2.new(0, 0, 0, 0)
leftAccentMini.BackgroundColor3 = ACCENT_G
leftAccentMini.BorderSizePixel = 0
leftAccentMini.Parent = miniFrame
local leftAccentMiniCorner = Instance.new("UICorner"); leftAccentMiniCorner.CornerRadius = UDim.new(0,8); leftAccentMiniCorner.Parent = leftAccentMini

local miniLabel = Instance.new("TextLabel")
miniLabel.Name = "Label"
miniLabel.BackgroundTransparency = 1
miniLabel.Size = UDim2.new(1, -(MINI_PAD*2 + 6), 1, 0)
miniLabel.Position = UDim2.new(0, 6 + MINI_PAD, 0, 0)
miniLabel.Text = "Server's"
miniLabel.Font = Enum.Font.GothamBold
miniLabel.TextSize = 13
miniLabel.TextXAlignment = Enum.TextXAlignment.Left
miniLabel.TextYAlignment = Enum.TextYAlignment.Center
miniLabel.TextTransparency = 0
miniLabel.TextColor3 = ACCENT_G
miniLabel.ZIndex = miniFrame.ZIndex + 1
miniLabel.Parent = miniFrame

-- Sincroniza a largura do miniFrame para exatamente igual ao componente X de card.Size
local function syncMiniWidthFromCard()
    if not card then return end
    -- copia Scale e Offset do card.Size.X
    local cardSizeX = card.Size.X
    miniFrame.Size = UDim2.new(cardSizeX.Scale or 0, cardSizeX.Offset or 0, 0, MINI_H)
end

-- atualiza quando a propriedade Size do card mudar
if card and card.GetPropertyChangedSignal then
    pcall(function()
        card:GetPropertyChangedSignal("Size"):Connect(syncMiniWidthFromCard)
    end)
end

-- aplica imediatamente (defer para garantir frames calculados)
task.defer(syncMiniWidthFromCard)

-- arrastar MINI (apenas mini; NÃO move o card)
local draggingMini = false
local startMiniPos = miniFrame.Position
local miniDragStart = Vector2.new(0,0)

miniFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if UserInputService:GetFocusedTextBox() then return end
        draggingMini = true
        miniDragStart = input.Position
        startMiniPos = miniFrame.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                draggingMini = false
            end
        end)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if draggingMini and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - miniDragStart
        miniFrame.Position = UDim2.new(
            startMiniPos.X.Scale, startMiniPos.X.Offset + delta.X,
            startMiniPos.Y.Scale, startMiniPos.Y.Offset + delta.Y
        )
    end
end)

-- toggle function (respeita foco TextBox)
local collapsed = false
local function applyMiniVisual(open)
    if open then
        TweenService:Create(leftAccentMini, TweenInfo.new(0.14), {BackgroundColor3 = ACCENT_G}):Play()
        TweenService:Create(miniLabel, TweenInfo.new(0.14), {TextColor3 = ACCENT_G}):Play()
    else
        TweenService:Create(leftAccentMini, TweenInfo.new(0.14), {BackgroundColor3 = ACCENT_GARY}):Play()
        TweenService:Create(miniLabel, TweenInfo.new(0.14), {TextColor3 = ACCENT_GARY}):Play()
    end
end

local function toggleCollapsed()
    if UserInputService:GetFocusedTextBox() then return end
    collapsed = not collapsed
    if card then
        card.Visible = not collapsed
    end
    applyMiniVisual(not collapsed)
    if collapsed then
        setStatus("Fechado", ACCENT_GARY)
    else
        setStatus("Pronto", ACCENT_G)
    end
end

-- LeftAlt toggle (ignora gameProcessed)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.LeftAlt then
        toggleCollapsed()
    end
end)

-- clique na mini-box ABRE o painel (não apenas toggle). mantém debounce curto e respeita drag.
miniFrame.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

    task.delay(0.06, function()
        -- se foi um drag (pressionou e arrastou), ignoramos o "abrir"
        if draggingMini then return end
        if UserInputService:GetFocusedTextBox() then return end

        -- abre o painel (garante estado aberto)
        collapsed = false
        if card then card.Visible = true end
        applyMiniVisual(true)
        setStatus("Pronto", ACCENT_G)
    end)
end)

-- inicializa visual e largura
applyMiniVisual(true)
syncMiniWidthFromCard()

-- Status (bolinha + texto), atualizado durante as buscas
local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.new(0, 8, 0, 8)
statusDot.Position = UDim2.new(0, 14, 0, 60)
statusDot.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
statusDot.BorderSizePixel = 0
statusDot.Parent = card

local statusDotCorner = Instance.new("UICorner")
statusDotCorner.CornerRadius = UDim.new(1, 0)
statusDotCorner.Parent = statusDot

local statusText = Instance.new("TextLabel")
statusText.BackgroundTransparency = 1
statusText.Position = UDim2.new(0, 28, 0, 52)
statusText.Size = UDim2.new(1, -40, 0, 16)
statusText.Text = "Pronto"
statusText.TextXAlignment = Enum.TextXAlignment.Left
statusText.TextColor3 = TEXT_MUTED
statusText.Font = Enum.Font.Gotham
statusText.TextSize = 12
statusText.Parent = card

setStatus = function(text, color)
    statusText.Text = text
    statusDot.BackgroundColor3 = color
end

-- Painel: intervalo do auto-hop, em minutos
local intervalLabel = Instance.new("TextLabel")
intervalLabel.BackgroundTransparency = 1
intervalLabel.Position = UDim2.new(0, 12, 0, 76)
intervalLabel.Size = UDim2.new(1, -24, 0, 14)
intervalLabel.Text = "Intervalo do auto-hop (min)"
intervalLabel.TextXAlignment = Enum.TextXAlignment.Left
intervalLabel.TextColor3 = TEXT_MUTED
intervalLabel.Font = Enum.Font.Gotham
intervalLabel.TextSize = 11
intervalLabel.Parent = card

local intervalBox = Instance.new("TextBox")
intervalBox.Position = UDim2.new(0, 12, 0, 94)
intervalBox.Size = UDim2.new(0, 140, 0, 28)
intervalBox.BackgroundColor3 = PANEL_BG
intervalBox.Text = tostring(AUTO_INTERVAL / 60)
intervalBox.PlaceholderText = "Minutos"
intervalBox.TextColor3 = TEXT_MAIN
intervalBox.Font = Enum.Font.Gotham
intervalBox.TextSize = 13
intervalBox.ClearTextOnFocus = false
intervalBox.Parent = card

local intervalBoxCorner = Instance.new("UICorner")
intervalBoxCorner.CornerRadius = UDim.new(0, 8)
intervalBoxCorner.Parent = intervalBox

local intervalBoxStroke = Instance.new("UIStroke")
intervalBoxStroke.Color = STROKE
intervalBoxStroke.Thickness = 1
intervalBoxStroke.Transparency = 0.6
intervalBoxStroke.Parent = intervalBox

local applyButton = Instance.new("TextButton")
applyButton.Position = UDim2.new(0, 158, 0, 94)
applyButton.Size = UDim2.new(0, 50, 0, 28)
applyButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
applyButton.Text = "OK"
applyButton.TextColor3 = TEXT_MAIN
applyButton.Font = Enum.Font.GothamBold
applyButton.TextSize = 13
applyButton.AutoButtonColor = false
applyButton.Parent = card

local applyButtonCorner = Instance.new("UICorner")
applyButtonCorner.CornerRadius = UDim.new(0, 8)
applyButtonCorner.Parent = applyButton

local applyButtonStroke = Instance.new("UIStroke")
applyButtonStroke.Color = STROKE
applyButtonStroke.Thickness = 1
applyButtonStroke.Transparency = 0.6
applyButtonStroke.Parent = applyButton

local resetElapsed = false -- sinaliza pro loop reiniciar a contagem quando aplicamos um novo valor

local function applyInterval()
    local minutes = tonumber(intervalBox.Text)

    if not minutes or minutes <= 0 then
        intervalBox.Text = tostring(AUTO_INTERVAL / 60)
        setStatus("Valor inválido!", Color3.fromRGB(230, 80, 80))
        return
    end

    -- limite mínimo de 0.5 min (30s) pra evitar spam de teleport
    minutes = math.max(minutes, 0.5)

    AUTO_INTERVAL = math.floor(minutes * 60)
    intervalBox.Text = tostring(minutes)
    resetElapsed = true

    print(("[ServerHop] Intervalo alterado para %d minuto(s) (%ds)"):format(minutes, AUTO_INTERVAL))
    setStatus(("Intervalo definido: %d min"):format(minutes), Color3.fromRGB(120, 180, 255))
end

applyButton.MouseButton1Click:Connect(applyInterval)

-- também aplica ao pressionar Enter dentro do campo
intervalBox.FocusLost:Connect(function(enterPressed)
    if enterPressed then
        applyInterval()
    end
end)

-- Painel: preferência de busca de servidor (menos/mais jogadores ou ping)
local prefLabel = Instance.new("TextLabel")
prefLabel.BackgroundTransparency = 1
prefLabel.Position = UDim2.new(0, 12, 0, 130)
prefLabel.Size = UDim2.new(1, -24, 0, 14)
prefLabel.Text = "Preferência de servidor"
prefLabel.TextXAlignment = Enum.TextXAlignment.Left
prefLabel.TextColor3 = TEXT_MUTED
prefLabel.Font = Enum.Font.Gotham
prefLabel.TextSize = 11
prefLabel.Parent = card

local prefButton = Instance.new("TextButton")
prefButton.Position = UDim2.new(0, 12, 0, 148)
prefButton.Size = UDim2.new(1, -24, 0, 28)
prefButton.BackgroundColor3 = PANEL_BG
prefButton.Text = "🎯  " .. PREFERENCE_LABELS[currentPreference]
prefButton.TextColor3 = TEXT_MAIN
prefButton.Font = Enum.Font.Gotham
prefButton.TextSize = 13
prefButton.AutoButtonColor = false
prefButton.Parent = card

local prefButtonCorner = Instance.new("UICorner")
prefButtonCorner.CornerRadius = UDim.new(0, 8)
prefButtonCorner.Parent = prefButton

local prefButtonStroke = Instance.new("UIStroke")
prefButtonStroke.Color = STROKE
prefButtonStroke.Thickness = 1
prefButtonStroke.Transparency = 0.6
prefButtonStroke.Parent = prefButton

local function cyclePreference()
    local currentIdx = table.find(PREFERENCE_ORDER, currentPreference) or 1
    local nextIdx = (currentIdx % #PREFERENCE_ORDER) + 1
    currentPreference = PREFERENCE_ORDER[nextIdx]
    prefButton.Text = "🎯  " .. PREFERENCE_LABELS[currentPreference]
    setStatus("Preferência: " .. PREFERENCE_LABELS[currentPreference], Color3.fromRGB(120, 180, 255))
    print("[ServerHop] Preferência de busca alterada para: " .. currentPreference)
end

prefButton.MouseButton1Click:Connect(cyclePreference)

-- Botão: trocar agora
local hopButton = Instance.new("TextButton")
hopButton.Size = UDim2.new(1, -24, 0, 30)
hopButton.Position = UDim2.new(0, 12, 0, 194)
hopButton.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
hopButton.Text = "🔄  Trocar agora"
hopButton.TextColor3 = TEXT_MAIN
hopButton.Font = Enum.Font.GothamBold
hopButton.TextSize = 13
hopButton.AutoButtonColor = false
hopButton.Parent = card

local hopCorner = Instance.new("UICorner")
hopCorner.CornerRadius = UDim.new(0, 8)
hopCorner.Parent = hopButton

local hopStroke = Instance.new("UIStroke")
hopStroke.Color = STROKE
hopStroke.Thickness = 1
hopStroke.Transparency = 0.6
hopStroke.Parent = hopButton

-- leve efeito de hover/press (usa pequenas variações, mantendo o tom escuro; accent em verde quando ativo)
local function attachButtonFeel(button, baseColor, hoverColor)
    button.MouseEnter:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = hoverColor}):Play()
    end)
    button.MouseLeave:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = baseColor}):Play()
    end)
end

attachButtonFeel(hopButton, Color3.fromRGB(45,45,55), Color3.fromRGB(60,60,66))
attachButtonFeel(applyButton, Color3.fromRGB(45,45,55), Color3.fromRGB(60,60,66))
attachButtonFeel(prefButton, PANEL_BG, Color3.fromRGB(32,32,36))

hopButton.MouseButton1Click:Connect(function()
    setStatus("Buscando servidor...", Color3.fromRGB(240, 190, 60))
    task.spawn(hopServer) -- roda em coroutine separada, sem travar a UI durante o HTTP
end)

-- Botão: liga/desliga modo automático
local autoButton = Instance.new("TextButton")
autoButton.Size = UDim2.new(1, -24, 0, 30)
autoButton.Position = UDim2.new(0, 12, 0, 230)
autoButton.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
autoButton.Text = "⏱️  Auto: OFF"
autoButton.TextColor3 = TEXT_MAIN
autoButton.Font = Enum.Font.Gotham
autoButton.TextSize = 13
autoButton.AutoButtonColor = false
autoButton.Parent = card

local autoCorner = Instance.new("UICorner")
autoCorner.CornerRadius = UDim.new(0, 8)
autoCorner.Parent = autoButton

local autoStroke = Instance.new("UIStroke")
autoStroke.Color = STROKE
autoStroke.Thickness = 1
autoStroke.Transparency = 0.6
autoStroke.Parent = autoButton

card.Size = UDim2.new(0, 220, 0, 274)

attachButtonFeel(autoButton, Color3.fromRGB(35,35,40), Color3.fromRGB(50,50,54))

autoButton.MouseButton1Click:Connect(function()
    autoEnabled = not autoEnabled
    if autoEnabled then
        autoButton.Text = "⏱️  Auto: ON"
        autoButton.BackgroundColor3 = ACCENT_GREEN
        autoButton.TextColor3 = Color3.fromRGB(18,18,20)
        setStatus("Auto-hop ativado", Color3.fromRGB(80, 220, 130))
    else
        autoButton.Text = "⏱️  Auto: OFF"
        autoButton.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
        autoButton.TextColor3 = TEXT_MAIN
        setStatus("Pronto", Color3.fromRGB(90, 90, 90))
    end
end)

-- Loop do modo automático (também atualiza o status com contagem regressiva)
task.spawn(function()
    local elapsed = 0
    while true do
        task.wait(1)
        if resetElapsed then
            elapsed = 0
            resetElapsed = false
        end
        if autoEnabled and not hopping then
            elapsed += 1
            local remaining = AUTO_INTERVAL - elapsed
            if remaining > 0 then
                setStatus(("Próxima troca em %ds"):format(remaining), Color3.fromRGB(80, 220, 130))
            end
            if elapsed >= AUTO_INTERVAL then
                elapsed = 0
                setStatus("Buscando servidor...", Color3.fromRGB(240, 190, 60))
                task.spawn(hopServer)
            end
        else
            elapsed = 0
        end
    end
end)
