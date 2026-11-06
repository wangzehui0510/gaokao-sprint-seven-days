-- 将 PixelLab 四方向角色组装为可编辑工程，只对北向进行已确认的 1 像素下移。
local projectRoot = assert(app.params["project_root"], "缺少 project_root 参数")
local outputDirectory = projectRoot .. "/assets/pixel/student01/"
local rawDirectory = outputDirectory .. "pixellab_raw/Idle/rotations/"
local directions = { "south", "east", "north", "west" }
local expectedSourceBounds = {
  south = { 6, 4, 26, 44 },
  east = { 7, 5, 25, 44 },
  north = { 6, 5, 26, 43 },
  west = { 7, 5, 24, 44 }
}
local alignedImages = {}

-- 将 PNG 的图层位置还原到完整画布，避免透明裁边改变角色的脚底坐标。
local function readCanvas(path)
  local source = assert(app.open(path), "无法打开角色图片：" .. path)
  assert(source.width == 32 and source.height == 48, "角色画布必须为 32×48 像素")
  assert(source.colorMode == ColorMode.RGB, "角色图片必须为 RGBA 真彩色")
  assert(#source.layers == 1 and #source.cels == 1, "角色 PNG 必须只有一个图层和一帧")
  local canvas = Image(32, 48, ColorMode.RGB)
  canvas:drawImage(source.cels[1].image, source.cels[1].position)
  source:close()
  return canvas
end

-- 在写入工程前验证所有源图，轮廓变化必须明确暴露，不能自动缩放或猜测对齐。
for _, direction in ipairs(directions) do
  local sourceImage = readCanvas(rawDirectory .. direction .. ".png")
  local bounds = sourceImage:shrinkBounds()
  local expected = expectedSourceBounds[direction]
  assert(bounds.x == expected[1] and bounds.y == expected[2]
    and bounds.x + bounds.width == expected[3] and bounds.y + bounds.height == expected[4],
    direction .. " 的源图包围盒与已检查版本不符")
  local alignedImage = Image(32, 48, ColorMode.RGB)
  local shiftY = direction == "north" and 1 or 0
  alignedImage:drawImage(sourceImage, Point(0, shiftY))
  alignedImages[direction] = alignedImage
end

-- 南向是此前确认的尺寸母版，生成版本必须逐像素一致，原 PNG 不重写。
local canonicalSouth = readCanvas(outputDirectory .. "south.png")
for y = 0, 47 do
  for x = 0, 31 do
    assert(canonicalSouth:getPixel(x, y) == alignedImages.south:getPixel(x, y),
      "PixelLab 南向与已确认的 south.png 存在像素差异")
  end
end

local sprite = assert(app.open(outputDirectory .. "student01.aseprite"), "无法打开角色 Aseprite 工程")
assert(#sprite.layers == 2 and #sprite.frames == 1, "组装前工程必须保留原始层和单帧规范层")
assert(sprite.layers[1].name == "PixelLab原始_44px_保留", "原始保留层名称与预期不符")
local originalLayer = sprite.layers[1]
local directionLayer = sprite.layers[2]
local originalCel = assert(originalLayer:cel(1), "原始保留层缺少首帧")
local originalImage = Image(originalCel.image)
local originalPosition = Point(originalCel.position.x, originalCel.position.y)

app.transaction("组装学生四方向", function()
  originalLayer.isVisible = false
  directionLayer.name = "学生_四方向"
  directionLayer.isVisible = true
  sprite:deleteCel(assert(directionLayer:cel(1), "规范层缺少首帧"))
  for frame = 2, 4 do
    sprite:newEmptyFrame(frame)
  end
  for frame, direction in ipairs(directions) do
    sprite:newCel(directionLayer, frame, alignedImages[direction], Point(0, 0))
    sprite.frames[frame].duration = 0.2
    local tag = sprite:newTag(frame, frame)
    tag.name = direction
  end
end)

-- 原始南向只保留于第一帧隐藏层，四个方向均采用统一的鞋底下方锚点 (16,44)。
assert(#sprite.frames == 4 and #sprite.tags == 4, "四方向帧或标签数量错误")
assert(#originalLayer.cels == 1 and not originalLayer.isVisible, "原始隐藏层不应复制到其他方向")
local savedOriginal = assert(originalLayer:cel(1), "原始隐藏层丢失")
assert(savedOriginal.position == originalPosition, "原始隐藏层位置被改变")
for y = 0, originalImage.height - 1 do
  for x = 0, originalImage.width - 1 do
    assert(savedOriginal.image:getPixel(x, y) == originalImage:getPixel(x, y), "原始隐藏层像素被改变")
  end
end
for _, direction in ipairs({ "east", "north", "west" }) do
  alignedImages[direction]:saveAs(outputDirectory .. direction .. ".png")
end
sprite:saveAs(outputDirectory .. "student01.aseprite")

-- 使用右、下边界不包含在内的包围盒，记录源图到游戏素材的唯一坐标变换。
local records = {}
for frame, direction in ipairs(directions) do
  local bounds = alignedImages[direction]:shrinkBounds()
  local source = expectedSourceBounds[direction]
  records[#records + 1] = string.format(
    '    { "direction": "%s", "frame": %d, "source": "pixellab_raw/Idle/rotations/%s.png", "output": "%s.png", "source_bbox": [%d,%d,%d,%d], "output_bbox": [%d,%d,%d,%d], "offset": [0,%d], "foot_anchor": [16,44], "visible_height": %d }',
    direction, frame, direction, direction, source[1], source[2], source[3], source[4],
    bounds.x, bounds.y, bounds.x + bounds.width, bounds.y + bounds.height,
    direction == "north" and 1 or 0, bounds.height)
end
local metadata = '{\n  "schema_version": 1,\n  "pixellab_character_id": "a8e45275-522e-4afa-ac11-e00c05c684a8",\n  "editable": "student01.aseprite",\n  "canvas": { "width": 32, "height": 48 },\n  "bbox_convention": "left_top_inclusive_right_bottom_exclusive",\n  "method": "copy_source_pixels_north_shift_down_one_pixel_no_resampling",\n  "south_png_rewritten": false,\n  "original_south_layer_preserved": true,\n  "directions": [\n'
  .. table.concat(records, ",\n") .. '\n  ]\n}\n'
local metadataFile = assert(io.open(outputDirectory .. "direction_alignment.json", "wb"), "无法写入四方向对齐记录")
metadataFile:write(metadata)
metadataFile:close()
app.refresh()
print("已保存学生四方向 PNG、4 帧 Aseprite 工程及对齐记录；北向下移 1px，其他方向像素不变")
