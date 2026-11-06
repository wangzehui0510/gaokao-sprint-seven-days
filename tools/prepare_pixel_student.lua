-- 将 PixelLab 南向角色整理为统一的 40 像素身高，原始图层完整保留。
-- 运行时必须显式传入 project_root，避免从其他目录读取同名素材。
local projectRoot = assert(app.params["project_root"], "缺少 project_root 参数")
local sourcePath = projectRoot .. "/assets/pixel/student01/south_source.png"
local outputDirectory = projectRoot .. "/assets/pixel/student01/"
local sprite = assert(app.open(sourcePath), "无法打开 PixelLab 原始南向角色")

assert(sprite.width == 32 and sprite.height == 48, "原始画布必须为 32×48 像素")
assert(sprite.colorMode == ColorMode.RGB, "原始图片必须为 RGBA 真彩色")
assert(#sprite.layers == 1 and #sprite.cels == 1, "原始 PNG 必须只有一个图层和一帧")

local sourceLayer = sprite.layers[1]
local sourceImage = Image(sprite.cels[1].image)
local sourceBounds = sourceImage:shrinkBounds()
assert(sourceBounds.x == 6 and sourceBounds.y == 3 and sourceBounds.width == 20 and sourceBounds.height == 44,
  "原始角色包围盒与已检查版本不符，停止处理以保护头脸与鞋")

-- 删除衣服中的两行和裤腿中的两行；其余像素逐点复制，不插值、不重绘头脸和鞋。
local deletedRows = { [23] = true, [27] = true, [36] = true, [39] = true }
local normalizedImage = Image(32, 48, ColorMode.RGB)
local destinationY = 4
for sourceY = sourceBounds.y, sourceBounds.y + sourceBounds.height - 1 do
  if not deletedRows[sourceY] then
    for x = 0, sourceImage.width - 1 do
      normalizedImage:drawPixel(x, destinationY, sourceImage:getPixel(x, sourceY))
    end
    destinationY = destinationY + 1
  end
end

local normalizedBounds = normalizedImage:shrinkBounds()
assert(normalizedBounds.x == 6 and normalizedBounds.y == 4 and normalizedBounds.width == 20 and normalizedBounds.height == 40,
  "规范化后应为 20×40 像素轮廓，脚底边界位于 y44")

app.transaction("整理学生角色尺寸", function()
  sourceLayer.name = "PixelLab原始_44px_保留"
  sourceLayer.isVisible = false
  local normalizedLayer = sprite:newLayer()
  normalizedLayer.name = "规范化南向_40px"
  normalizedLayer.isVisible = true
  sprite:newCel(normalizedLayer, 1, normalizedImage, Point(0, 0))
end)

-- PNG 只导出可见规范层；可编辑工程同时保留关闭显示的原始层。
sprite:saveCopyAs(outputDirectory .. "south.png")
sprite:saveAs(outputDirectory .. "student01.aseprite")

-- 包围盒采用右、下边界不含在内的坐标约定，锚点位于鞋底正下方。
local metadata = string.format([[
{
  "schema_version": 1,
  "source": "south_source.png",
  "output": "south.png",
  "editable": "student01.aseprite",
  "canvas": { "width": 32, "height": 48 },
  "source_bbox": [%d, %d, %d, %d],
  "normalized_bbox": [%d, %d, %d, %d],
  "bbox_convention": "left_top_inclusive_right_bottom_exclusive",
  "visible_width": %d,
  "visible_height": %d,
  "foot_anchor": { "x": 16, "y": 44 },
  "removed_source_rows_zero_based": [23, 27, 36, 39],
  "removed_region_counts": { "shirt": 2, "trousers": 2 },
  "method": "copy_source_pixels_after_removing_rows_no_resampling",
  "original_preserved": true,
  "head_and_shoes_preserved": true,
  "layers": ["PixelLab原始_44px_保留", "规范化南向_40px"]
}
]], sourceBounds.x, sourceBounds.y, sourceBounds.x + sourceBounds.width, sourceBounds.y + sourceBounds.height,
  normalizedBounds.x, normalizedBounds.y, normalizedBounds.x + normalizedBounds.width, normalizedBounds.y + normalizedBounds.height,
  normalizedBounds.width, normalizedBounds.height)
local metadataFile = assert(io.open(outputDirectory .. "south_normalization.json", "wb"), "无法写入角色尺寸记录")
metadataFile:write(metadata)
metadataFile:close()
app.refresh()
print("已保存：south.png、student01.aseprite、south_normalization.json；实际角色 20×40 px，脚底锚点 (16,44)")
