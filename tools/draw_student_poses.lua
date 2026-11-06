-- 使用真实 Aseprite 绘制专用北向坐姿，不以遮住站姿双腿代替坐姿。
local root = assert(app.params.project_root, "必须提供 project_root 参数")
local output = root .. "/assets/pixel/student01/poses/"
app.fs.makeAllDirectories(output)

-- 角色沿用原始北向头发像素和校服调色板；各动作独立绘制身体与弯曲四肢。
local colors = {
  ink = {0, 0, 0}, hair = {35, 39, 55}, hairLight = {79, 83, 109},
  white = {248, 247, 250}, shade = {203, 209, 234}, blue = {23, 48, 227},
  blueDark = {4, 20, 143}, navy = {0, 2, 22}, green = {7, 144, 128},
  skin = {255, 216, 177}, skinShade = {250, 111, 71}, shoeShade = {169, 169, 182},
  pencil = {226, 197, 110}, paper = {241, 240, 218}, graphite = {67, 90, 86},
}
for name, value in pairs(colors) do
  colors[name] = app.pixelColor.rgba(value[1], value[2], value[3], 255)
end

-- 以整像素矩形绘制结构明确的袖口、衣摆和弯腿，所有坐标均在32×48画布内。
local function rect(image, x, y, width, height, color)
  for py = y, y + height - 1 do
    for px = x, x + width - 1 do image:drawPixel(px, py, colors[color]) end
  end
end

-- 绘制单像素连线；关节外轮廓由多层平行线构成，不使用抗锯齿。
local function line(image, x0, y0, x1, y1, color)
  local dx, sx = math.abs(x1 - x0), x0 < x1 and 1 or -1
  local dy, sy = -math.abs(y1 - y0), y0 < y1 and 1 or -1
  local error = dx + dy
  while true do
    image:drawPixel(x0, y0, colors[color])
    if x0 == x1 and y0 == y1 then break end
    local twice = error * 2
    if twice >= dy then error = error + dy; x0 = x0 + sx end
    if twice <= dx then error = error + dx; y0 = y0 + sy end
  end
end

-- 从PNG完整画布读取原始头部，透明裁边不改变采样坐标。
local function readCanvas(path)
  local source = assert(app.open(path), "无法打开角色北向PNG")
  assert(source.width == 32 and source.height == 48, "北向角色画布必须为32×48")
  local image = Image(32, 48, ColorMode.RGB)
  image:drawImage(source.cels[1].image, source.cels[1].position)
  source:close()
  return image
end

local north = readCanvas(root .. "/assets/pixel/student01/north.png")

-- 学习与发呆保留完整头部，趴睡按明确像素行重绘俯伏头型。
local function head(image, pose, phase)
  local shiftX = pose == "daydream" and (phase == 0 and -1 or 0) or 0
  if pose == "sleep" then
    local rows = {6, 7, 8, 10, 11, 13, 15, 17, 19, 21}
    for destination, sourceY in ipairs(rows) do
      for x = 6, 26 do
        local pixel = north:getPixel(x, sourceY)
        if app.pixelColor.rgbaA(pixel) > 0 then image:drawPixel(x, 9 + destination, pixel) end
      end
    end
  else
    for y = 6, 21 do
      for x = 6, 26 do
        local pixel = north:getPixel(x, y)
        if app.pixelColor.rgbaA(pixel) > 0 then image:drawPixel(x + shiftX, y + 6, pixel) end
      end
    end
  end
end

-- 坐姿的衣摆更短、膝盖向两侧弯折、鞋朝两边收起，与站姿腿形不同。
local function seatedBody(image, pose, phase)
  local jacketTop = pose == "sleep" and 22 or 27
  rect(image, 8, jacketTop, 17, 12 + (27 - jacketTop), "ink")
  rect(image, 9, jacketTop + 1, 15, 10 + (27 - jacketTop), "blue")
  rect(image, 11, jacketTop + 2, 11, 9 + (27 - jacketTop), "white")
  rect(image, 11, 35, 11, 2, "shade")
  rect(image, 10, 37, 13, 2, "blueDark")
  rect(image, 12, jacketTop, 9, 2, "green")
  -- 两条大腿水平展开再折回鞋边，腰下不再保留站姿长腿。
  rect(image, 8, 38, 16, 3, "navy")
  rect(image, 6, 39, 8, 3, "ink")
  rect(image, 19, 39, 8, 3, "ink")
  rect(image, 7, 39, 6, 2, "blueDark")
  rect(image, 20, 39, 6, 2, "blueDark")
  rect(image, 5, 41, 8, 3, "ink")
  rect(image, 20, 41, 8, 3, "ink")
  rect(image, 6, 41, 6, 2, "white")
  rect(image, 21, 41, 6, 2, "white")
  rect(image, 6, 42, 6, 1, "shoeShade")
  rect(image, 21, 42, 6, 1, "shoeShade")
  -- 袖子先画在头部后方，前伸手臂稍后与桌上手部层相接。
  if pose == "study" then
    for offset = -1, 1 do
      line(image, 9 + offset, 29, 5 + offset, 24, "ink")
      line(image, 5 + offset, 24, 7 + offset, 18, "ink")
      line(image, 23 + offset, 29, 27 + offset, 24, "ink")
      line(image, 27 + offset, 24, 25 + offset, 17, "ink")
    end
    line(image, 9, 29, 5, 24, "blue")
    line(image, 5, 24, 7, 18, "blue")
    line(image, 23, 29, 27, 24, "blue")
    line(image, 27, 24, 25, 17, "blue")
  elseif pose == "daydream" then
    rect(image, 5, 29, 4, 8, "ink")
    rect(image, 6, 29, 2, 6, "blue")
    rect(image, 6, 35, 3, 2, "skin")
    for offset = -1, 1 do
      line(image, 24 + offset, 30, 27 + offset, 24, "ink")
      line(image, 27 + offset, 24, 26 + offset, 17, "ink")
    end
    line(image, 24, 30, 27, 24, "blue")
    line(image, 27, 24, 26, 17, "blue")
  else
    rect(image, 5, 20, 5, 13, "ink")
    rect(image, 23, 20, 5, 13, "ink")
    rect(image, 6, 21, 3, 10, "blue")
    rect(image, 24, 21, 3, 10, "blue")
    rect(image, 6, 20, 21, 4, "ink")
    rect(image, 7, 21, 19, 2, "blue")
  end
  head(image, pose, phase)
end

-- 桌上手部单独导出，玩家可在家具之后叠加；完整PNG也已包含此层。
local function deskHands(image, pose, phase)
  if pose == "study" then
    rect(image, 20, 10, 9, 6, "graphite")
    rect(image, 20, 10, 8, 5, "paper")
    rect(image, 21, 12, 3, 1, "shade")
    rect(image, 21, 14, 4, 1, "shade")
    rect(image, 6, 16, 3, 3, "skinShade")
    rect(image, 6, 16, 3, 2, "skin")
    rect(image, 24, 15 + phase, 3, 3, "skinShade")
    rect(image, 24, 15 + phase, 3, 2, "skin")
    line(image, 25, 15 + phase, 24 - phase, 11 + phase, "pencil")
    image:drawPixel(24 - phase, 11 + phase, colors.graphite)
  elseif pose == "daydream" then
    rect(image, 25, 15, 3, 3, "skinShade")
    rect(image, 25, 15, 3, 2, "skin")
    if phase == 0 then
      line(image, 24, 13, 29, 17, "graphite")
      line(image, 24, 12, 29, 16, "pencil")
    else
      line(image, 25, 17, 28, 10, "graphite")
      line(image, 26, 17, 29, 10, "pencil")
    end
  else
    rect(image, 8, 18, 6, 3, "skinShade")
    rect(image, 19, 18, 6, 3, "skinShade")
    rect(image, 8, 18, 5, 2, "skin")
    rect(image, 20, 18, 5, 2, "skin")
    -- 细小呼吸变化仅移动一行后背高光，不改变脚点和伏桌轮廓。
    if phase == 1 then rect(image, 13, 24, 6, 1, "shade") end
  end
end

local poses = {"study", "daydream", "sleep"}
local frames = {}
local sprite = Sprite(32, 48, ColorMode.RGB)
sprite.layers[1].name = "北向专用坐姿身体"
local bodyLayer = sprite.layers[1]
local handsLayer = sprite:newLayer()
handsLayer.name = "桌上手部与道具"

-- 六帧由三个动作各两帧组成，源文件保留身体和桌上手部两个独立层。
for poseIndex, pose in ipairs(poses) do
  local first = (poseIndex - 1) * 2 + 1
  for phase = 0, 1 do
    local frameNumber = first + phase
    if frameNumber > 1 then sprite:newEmptyFrame(frameNumber) end
    local body = Image(32, 48, ColorMode.RGB)
    local hands = Image(32, 48, ColorMode.RGB)
    seatedBody(body, pose, phase)
    deskHands(hands, pose, phase)
    sprite:newCel(bodyLayer, frameNumber, body, Point(0, 0))
    sprite:newCel(handsLayer, frameNumber, hands, Point(0, 0))
    sprite.frames[frameNumber].duration = pose == "sleep" and 0.9 or 0.45
    local combined = Image(body)
    combined:drawImage(hands, Point(0, 0))
    combined:saveAs(output .. pose .. "_" .. phase .. ".png")
    body:saveAs(output .. pose .. "_" .. phase .. "_body.png")
    hands:saveAs(output .. pose .. "_" .. phase .. "_hands.png")
    frames[#frames + 1] = {pose = pose, phase = phase, image = combined}
  end
  local tag = sprite:newTag(first, first + 1)
  tag.name = pose
end
sprite:saveAs(output .. "student01_seated.aseprite")

-- 将每帧从保存后的Aseprite重新读取合成，与PNG逐像素比较，确保源文件可复现。
sprite:close()
local reopened = assert(app.open(output .. "student01_seated.aseprite"), "无法回读坐姿源文件")
assert(#reopened.frames == 6 and #reopened.layers == 2 and #reopened.tags == 3, "坐姿源文件结构错误")
for index, record in ipairs(frames) do
  local rendered = Image(32, 48, ColorMode.RGB)
  for _, layer in ipairs(reopened.layers) do
    local cel = assert(layer:cel(index), "坐姿图层缺少帧")
    rendered:drawImage(cel.image, cel.position)
  end
  for y = 0, 47 do
    for x = 0, 31 do
      assert(rendered:getPixel(x, y) == record.image:getPixel(x, y), "坐姿源文件回读像素不一致")
    end
  end
end

-- 素材自带准确脚点及桌面叠加说明，避免接入时根据裁边猜测位置。
local metadata = {
  version = "0.1.0", canvas = {width = 32, height = 48},
  anchor = {x = 16, y = 44}, direction = "north", stance = "seated",
  editable = "student01_seated.aseprite", render_after_furniture = true,
  placement = "将PNG左上角放在seat_anchor-(16,44)，完整PNG已含桌上手部；不能再重复画hands层。",
  layers = {"北向专用坐姿身体", "桌上手部与道具"},
  state_map = {study = "study", physical_study = "study", music_class = "daydream", art_class = "study", daydream = "daydream", sleep = "sleep", rest = "sleep", break_rest = "daydream"},
  poses = {},
  source = "沿用PixelLab北向头部像素，在Aseprite专门重绘短衣摆、弯腿与前伸手臂",
  roundtrip_verified = true,
}
for index, pose in ipairs(poses) do
  metadata.poses[pose] = {
    frames = {pose .. "_0.png", pose .. "_1.png"},
    frame_duration_s = pose == "sleep" and 0.9 or 0.45,
    body_frames = {pose .. "_0_body.png", pose .. "_1_body.png"},
    hands_frames = {pose .. "_0_hands.png", pose .. "_1_hands.png"},
    animation_tag = pose,
  }
end
local file = assert(io.open(output .. "poses.json", "wb"))
file:write(json.encode(metadata)); file:write("\n"); file:close()

-- 最近邻放大只复制原生像素，不给角色添加模糊或抗锯齿。
local function enlarge(image, scale)
  local result = Image(image.width * scale, image.height * scale, ColorMode.RGB)
  for y = 0, image.height - 1 do
    for x = 0, image.width - 1 do
      local pixel = image:getPixel(x, y)
      for oy = 0, scale - 1 do
        for ox = 0, scale - 1 do result:drawPixel(x * scale + ox, y * scale + oy, pixel) end
      end
    end
  end
  return result
end
local sheet = Image(64, 144, ColorMode.RGB)
for index, record in ipairs(frames) do
  sheet:drawImage(record.image, Point(((index - 1) % 2) * 32, math.floor((index - 1) / 2) * 48))
end
enlarge(sheet, 6):saveAs(output .. "poses_preview_6x.png")
local classroom = readCanvas
local classroomSprite = assert(app.open(root .. "/assets/pixel/classroom/classroom.png"))
local scene = Image(384, 256, ColorMode.RGB)
scene:drawImage(classroomSprite.cels[1].image, classroomSprite.cels[1].position)
classroomSprite:close()
local seatPoints = {{112, 140}, {272, 140}, {112, 220}, {272, 220}}
local sceneFrames = {1, 3, 5, 2}
for index, point in ipairs(seatPoints) do
  scene:drawImage(frames[sceneFrames[index]].image, Point(point[1] - 16, point[2] - 44))
end
scene:saveAs(output .. "classroom_seated_preview.png")
enlarge(scene, 3):saveAs(output .. "classroom_seated_preview_3x.png")
print(json.encode({poses = 3, frames = 6, layers = 2, roundtrip_verified = true, output = output}))
