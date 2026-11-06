-- 使用真实 Aseprite 绘制固定正交斜俯视教室；不调用图像生成器或外部绘图库。
-- 坐标均为原生像素，桌椅大小不会随纵深收缩，便于后续按脚底排序。

local W, H = 384, 256
local output = assert(app.params.output, "必须通过 --script-param output=目录 指定输出路径")
app.fs.makeAllDirectories(output)

-- 调色板保持冷暖平衡：灰绿地面、薄荷墙体、少量浅木色家具。
local hex = {
  ink = "435A56", deep = "34554B", wall = "E5F0E8", wallLight = "F3F7EE",
  wallBand = "BCD5C6", wallBandLight = "CEE2D3", trim = "76998B",
  floor = "DCE4DF", floorAlt = "E1E8E3", grout = "CAD6CE", tileLight = "E9EEEA",
  shadow = "BFCFC5", shadowDark = "ACBFB4", mint = "94B8A5", mintLight = "BDDAC5",
  board = "356354", boardLight = "3D6F5C", boardShade = "2C5548", chalk = "DFEBDD",
  wood = "CFB27E", woodLight = "E9D29F", woodDark = "A88D63", woodShade = "BE9F6D",
  steel = "8D9D94", steelLight = "C5D0C6", blue = "78A9BE", blueLight = "B8D8DF",
  blueDark = "477E94", coral = "D47B6B", yellow = "E2C56E", paper = "F1F0DA",
  leaf = "528B65", leafLight = "83B284", leafDark = "3D7155", pot = "C78470",
}
local palette = {}
for key, value in pairs(hex) do
  palette[key] = app.pixelColor.rgba(tonumber(value:sub(1, 2), 16), tonumber(value:sub(3, 4), 16), tonumber(value:sub(5, 6), 16), 255)
end

-- 填充像素矩形；所有调用由固定布局提供合法坐标。
local function rect(image, x, y, width, height, color)
  for py = y, y + height - 1 do
    for px = x, x + width - 1 do image:drawPixel(px, py, palette[color]) end
  end
end

-- 绘制一像素直线，保持轮廓锐利而不引入抗锯齿。
local function line(image, x0, y0, x1, y1, color)
  local dx, sx = math.abs(x1 - x0), x0 < x1 and 1 or -1
  local dy, sy = -math.abs(y1 - y0), y0 < y1 and 1 or -1
  local error = dx + dy
  while true do
    image:drawPixel(x0, y0, palette[color])
    if x0 == x1 and y0 == y1 then break end
    local twice = 2 * error
    if twice >= dy then error = error + dy; x0 = x0 + sx end
    if twice <= dx then error = error + dx; y0 = y0 + sy end
  end
end

-- 用整像素椭圆绘制钟面、叶片和接地阴影。
local function ellipse(image, x, y, width, height, color)
  local cx, cy = x + (width - 1) / 2, y + (height - 1) / 2
  local rx, ry = width / 2, height / 2
  for py = y, y + height - 1 do
    for px = x, x + width - 1 do
      if ((px - cx) / rx) ^ 2 + ((py - cy) / ry) ^ 2 <= 1 then image:drawPixel(px, py, palette[color]) end
    end
  end
end

-- 为每个部件创建独立透明图层，源文件可直接在 Aseprite 中编辑。
local sprite = Sprite(W, H, ColorMode.RGB)
sprite.gridBounds = Rectangle(0, 0, 16, 16)
local parts = {}
local function layer(name)
  local item = #parts == 0 and sprite.layers[1] or sprite:newLayer()
  item.name = name
  local image = Image(W, H, ColorMode.RGB)
  local cel = sprite:newCel(item, 1, image, Point(0, 0))
  -- 后续直接绘制实际图层图像，避免 newCel 复制传入图像后源文件仍为空白。
  image = cel.image
  parts[#parts + 1] = {name = name, layer = item, image = image}
  return image
end

-- 地砖严格沿 16 像素正交网格铺设，纵深方向与横向使用相同格距。
local floor = layer("floor")
rect(floor, 0, 48, W, H - 48, "floor")
for row = 3, 15 do
  for column = 0, 23 do
    local x, y = column * 16, row * 16
    rect(floor, x, y, 16, 16, (row + column) % 2 == 0 and "floor" or "floorAlt")
    line(floor, x, y, x + 15, y, "grout")
    line(floor, x, y, x, y + 15, "grout")
    line(floor, x + 1, y + 1, x + 14, y + 1, "tileLight")
  end
end

-- 北墙仅占 y=0..47；左右与前缘采用低矮切面，不遮住角色活动区。
local walls = layer("walls")
rect(walls, 0, 0, W, 48, "wall")
rect(walls, 0, 0, W, 3, "trim")
rect(walls, 0, 3, W, 2, "wallLight")
rect(walls, 0, 35, W, 9, "wallBand")
rect(walls, 0, 35, W, 2, "wallBandLight")
rect(walls, 0, 44, W, 3, "trim")
rect(walls, 0, 47, W, 1, "ink")
rect(walls, 0, 48, 5, H - 48, "trim")
rect(walls, W - 5, 48, 5, H - 48, "trim")
rect(walls, 5, 48, 2, H - 48, "wallBandLight")
rect(walls, W - 7, 48, 2, H - 48, "wallBandLight")
rect(walls, 0, 252, W, 4, "trim")
rect(walls, 7, 251, W - 14, 2, "wallLight")

-- 门窗、黑板与细小生活道具集中在边缘，中央保留清楚的四人舞台。
local decor = layer("decor")
rect(decor, 7, 48, W - 14, 3, "shadow")

-- 左侧双扇窗，玻璃、窗框、窗台各以有限色块表达材质。
rect(decor, 15, 7, 62, 30, "trim")
rect(decor, 17, 9, 58, 26, "blueDark")
rect(decor, 19, 11, 25, 21, "blue")
rect(decor, 48, 11, 25, 21, "blue")
rect(decor, 19, 11, 25, 7, "blueLight")
rect(decor, 48, 11, 25, 7, "blueLight")
rect(decor, 19, 26, 25, 6, "mintLight")
rect(decor, 48, 26, 25, 6, "mintLight")
line(decor, 20, 23, 31, 12, "blueLight")
line(decor, 50, 23, 61, 12, "blueLight")
rect(decor, 44, 9, 4, 26, "wallLight")
rect(decor, 17, 20, 58, 2, "wallLight")
rect(decor, 13, 36, 66, 3, "wallLight")
rect(decor, 14, 39, 64, 2, "shadowDark")

-- 黑板居中，无文字或伪字，仅保留粉笔擦痕和简单几何图案。
rect(decor, 109, 6, 166, 32, "woodDark")
rect(decor, 111, 8, 162, 28, "boardShade")
rect(decor, 113, 10, 158, 24, "board")
rect(decor, 114, 11, 155, 1, "boardLight")
rect(decor, 113, 32, 158, 2, "boardShade")
rect(decor, 109, 6, 166, 1, "woodLight")
line(decor, 126, 27, 126, 17, "chalk")
line(decor, 126, 27, 146, 27, "chalk")
line(decor, 130, 24, 137, 20, "chalk")
line(decor, 137, 20, 144, 22, "chalk")
line(decor, 144, 22, 152, 15, "chalk")
rect(decor, 180, 17, 16, 1, "boardLight")
rect(decor, 178, 20, 27, 1, "boardLight")
rect(decor, 202, 28, 31, 1, "boardLight")
rect(decor, 108, 37, 168, 3, "steel")
rect(decor, 108, 37, 168, 1, "steelLight")
rect(decor, 120, 36, 8, 1, "chalk")
rect(decor, 133, 36, 5, 1, "coral")
rect(decor, 248, 34, 13, 3, "woodDark")
rect(decor, 249, 34, 11, 1, "woodLight")

-- 门外框高 46 像素、净门高 42 像素，底部仍与 y=48 地面接缝对齐。
rect(decor, 337, 2, 32, 46, "ink")
rect(decor, 339, 4, 28, 42, "mint")
rect(decor, 341, 6, 24, 38, "trim")
rect(decor, 342, 7, 22, 36, "mint")
rect(decor, 345, 9, 16, 14, "ink")
rect(decor, 346, 10, 14, 12, "blue")
rect(decor, 346, 10, 14, 4, "blueLight")
rect(decor, 348, 27, 12, 12, "mintLight")
rect(decor, 359, 26, 3, 2, "woodDark")
rect(decor, 358, 25, 3, 1, "yellow")
rect(decor, 338, 46, 30, 2, "steelLight")
rect(decor, 339, 48, 28, 1, "shadowDark")

-- 像素钟与插座均不使用文字，作为校园环境的小尺度参照物。
ellipse(decor, 291, 7, 20, 20, "ink")
ellipse(decor, 293, 9, 16, 16, "paper")
rect(decor, 300, 10, 2, 2, "trim")
rect(decor, 300, 22, 2, 2, "trim")
rect(decor, 294, 16, 2, 2, "trim")
rect(decor, 306, 16, 2, 2, "trim")
line(decor, 301, 17, 301, 12, "ink")
line(decor, 301, 17, 305, 19, "ink")
rect(decor, 297, 38, 8, 6, "wallLight")
rect(decor, 299, 40, 1, 2, "trim")
rect(decor, 302, 40, 1, 2, "trim")

-- 盆栽安排在边角，不侵入桌间通道。
ellipse(decor, 20, 76, 24, 6, "shadowDark")
rect(decor, 25, 66, 14, 11, "woodDark")
rect(decor, 26, 66, 12, 10, "pot")
rect(decor, 24, 64, 16, 3, "woodDark")
rect(decor, 25, 64, 14, 1, "coral")
rect(decor, 31, 51, 2, 14, "leafDark")
ellipse(decor, 20, 52, 13, 8, "leaf")
ellipse(decor, 31, 49, 13, 8, "leafLight")
ellipse(decor, 23, 44, 12, 10, "leaf")
rect(decor, 25, 46, 4, 2, "leafLight")
rect(decor, 36, 52, 4, 2, "leaf")

-- 四张课桌使用同一个精确模块；图层分开以便各自移动和遮挡角色。
local deskSpecs = {
  {id = "desk_01", cx = 112, top = 96, accent = "blue"},
  {id = "desk_02", cx = 272, top = 96, accent = "coral"},
  {id = "desk_03", cx = 112, top = 176, accent = "leaf"},
  {id = "desk_04", cx = 272, top = 176, accent = "yellow"},
}
local deskParts = {}
for index, spec in ipairs(deskSpecs) do
  local cx, y = spec.cx, spec.top
  local body = layer(spec.id .. "_body")
  local front = layer(spec.id .. "_foreground")
  local chair = layer(spec.id .. "_chair")
  deskParts[index] = {body = body, front = front, chair = chair}

  -- 桌与椅的阴影分别随各自主体移动，运行时可独立按脚底排序。
  rect(body, cx - 24, y + 24, 48, 3, "shadow")
  rect(chair, cx - 12, y + 46, 28, 2, "shadow")
  rect(chair, cx - 10, y + 34, 3, 13, "ink")
  rect(chair, cx + 8, y + 34, 3, 13, "ink")
  rect(chair, cx - 9, y + 35, 1, 10, "steelLight")
  rect(chair, cx + 9, y + 35, 1, 10, "steel")
  rect(chair, cx - 13, y + 29, 26, 10, "ink")
  rect(chair, cx - 12, y + 30, 24, 7, "woodDark")
  rect(chair, cx - 11, y + 30, 22, 4, "wood")
  rect(chair, cx - 11, y + 30, 22, 1, "woodLight")
  rect(chair, cx - 13, y + 38, 26, 4, "ink")
  rect(chair, cx - 12, y + 38, 24, 2, "trim")
  rect(chair, cx - 10, y + 38, 20, 1, "mintLight")

  -- 主桌面为 48x16，左右轮廓一致；前挡板和桌腿另放前景层。
  rect(body, cx - 24, y, 48, 16, "ink")
  rect(body, cx - 23, y + 1, 46, 13, "wood")
  rect(body, cx - 22, y + 1, 44, 2, "woodLight")
  rect(body, cx - 23, y + 13, 46, 1, "woodShade")
  rect(body, cx - 21, y + 5, 13, 1, "woodLight")
  rect(body, cx + 11, y + 10, 9, 1, "woodShade")
  rect(body, cx - 19, y + 11, 6, 1, "woodShade")

  -- 书与笔只是独立的桌面道具色块，不绘制任何文字。
  local bookX = index % 2 == 0 and cx + 3 or cx - 14
  rect(body, bookX, y + 4, 13, 8, "ink")
  rect(body, bookX + 1, y + 4, 11, 6, spec.accent)
  rect(body, bookX + 2, y + 5, 8, 1, "paper")
  rect(body, bookX + 1, y + 10, 11, 1, "paper")
  rect(body, bookX + 2, y + 11, 10, 1, "woodDark")
  local pencilX = index % 2 == 0 and cx - 12 or cx + 7
  line(body, pencilX, y + 8, pencilX + 8, y + 5, "woodDark")
  line(body, pencilX, y + 7, pencilX + 7, y + 4, "yellow")
  body:drawPixel(pencilX + 8, y + 4, palette.ink)

  rect(front, cx - 23, y + 15, 46, 5, "woodDark")
  rect(front, cx - 22, y + 15, 44, 2, "woodShade")
  rect(front, cx - 16, y + 18, 32, 1, "wood")
  rect(front, cx - 22, y + 20, 3, 4, "ink")
  rect(front, cx + 19, y + 20, 3, 4, "ink")
  rect(front, cx - 21, y + 20, 1, 3, "steelLight")
  rect(front, cx + 20, y + 20, 1, 3, "steel")
  rect(front, cx - 21, y + 19, 42, 1, "steel")
end

-- 导出原生透明层，不经缩放；完整预览与背景使用同一套真实绘图结果。
local function saveComposite(filename, include)
  local image = Image(W, H, ColorMode.RGB)
  for _, part in ipairs(parts) do
    if include(part.name) then image:drawImage(part.image, Point(0, 0)) end
  end
  image:saveAs(app.fs.joinPath(output, filename))
end

sprite:saveAs(app.fs.joinPath(output, "classroom.aseprite"))
saveComposite("classroom.png", function() return true end)
saveComposite("classroom_background.png", function(name) return name == "floor" or name == "walls" or name == "decor" end)
saveComposite("classroom_foreground.png", function(name) return name:match("_foreground$") ~= nil end)
for index, spec in ipairs(deskSpecs) do
  local pieces = deskParts[index]
  pieces.body:saveAs(app.fs.joinPath(output, spec.id .. "_body.png"))
  pieces.front:saveAs(app.fs.joinPath(output, spec.id .. "_foreground.png"))
  pieces.chair:saveAs(app.fs.joinPath(output, spec.id .. "_chair.png"))
  saveComposite(spec.id .. ".png", function(name) return name == spec.id .. "_body" or name == spec.id .. "_foreground" or name == spec.id .. "_chair" end)
end

-- 布局记录绘图锚点、碰撞与坐姿预留；坐姿应使用专用素材，不能直接把站姿压进椅子。
local desks = {}
for _, spec in ipairs(deskSpecs) do
  desks[#desks + 1] = {
    id = spec.id,
    module_bounds = {x = spec.cx - 32, y = spec.top, width = 64, height = 48},
    art_bounds = {x = spec.cx - 24, y = spec.top, width = 48, height = 48},
    desk_bounds = {x = spec.cx - 24, y = spec.top, width = 48, height = 24},
    chair_bounds = {x = spec.cx - 13, y = spec.top + 29, width = 26, height = 18},
    depth_anchor = {x = spec.cx, y = spec.top + 24},
    chair_depth_anchor = {x = spec.cx, y = spec.top + 47},
    seat_anchor = {x = spec.cx, y = spec.top + 44},
    seat_facing = "north",
    seated_sprite_recommended_size = {width = 32, height = 32},
    seated_head_reserved = {x = spec.cx - 8, y = spec.top + 24, width = 16, height = 12},
    interaction_anchor = {x = spec.cx, y = spec.top + 56},
    collision = {x = spec.cx - 24, y = spec.top + 8, width = 48, height = 16},
    chair_collision = {x = spec.cx - 11, y = spec.top + 31, width = 22, height = 14},
    body_image = spec.id .. "_body.png",
    foreground_image = spec.id .. "_foreground.png",
    chair_image = spec.id .. "_chair.png",
    image_origin = {x = 0, y = 0},
  }
end
local layout = {
  version = "0.1.1", generator = "Aseprite 1.3.18.6 Lua hand-drawn",
  canvas = {width = W, height = H}, grid = {width = 16, height = 16},
  projection = "orthographic_low_top_down", north_wall_height = 48,
  walkable_bounds = {x = 8, y = 48, width = 368, height = 200},
  door = {bounds = {x = 337, y = 2, width = 32, height = 46}, inner_bounds = {x = 339, y = 4, width = 28, height = 42}, ground_anchor = {x = 353, y = 48}, entry_anchor = {x = 353, y = 64}},
  blackboard = {x = 109, y = 6, width = 166, height = 34},
  standing_sprite = {width = 32, height = 48, visible_height = 40, foot_anchor = {x = 16, y = 44}},
  recommended_character_spawns = {{x = 68, y = 144}, {x = 316, y = 144}, {x = 68, y = 224}, {x = 316, y = 224}},
  aisles = {
    {id = "left", bounds = {x = 48, y = 80, width = 40, height = 168}},
    {id = "middle", bounds = {x = 136, y = 80, width = 112, height = 168}},
    {id = "right", bounds = {x = 296, y = 80, width = 40, height = 168}},
    {id = "between_rows", bounds = {x = 88, y = 144, width = 208, height = 32}},
  },
  furniture = desks,
  layer_order = {"floor", "walls", "decor", "desk_01_body", "desk_01_foreground", "desk_01_chair", "desk_02_body", "desk_02_foreground", "desk_02_chair", "desk_03_body", "desk_03_foreground", "desk_03_chair", "desk_04_body", "desk_04_foreground", "desk_04_chair"},
  runtime_render_rule = "背景先绘制；桌按depth_anchor、椅按chair_depth_anchor、角色按脚底Y独立排序；所有家具PNG使用image_origin定位；坐姿使用专门素材并按每桌foreground遮挡，不能把整张foreground无条件置于所有角色上方。",
}
local file = assert(io.open(app.fs.joinPath(output, "layout.json"), "wb"))
file:write(json.encode(layout))
file:write("\n")
file:close()
print(json.encode({created = true, width = W, height = H, layers = #parts, desks = #desks, output = output}))
