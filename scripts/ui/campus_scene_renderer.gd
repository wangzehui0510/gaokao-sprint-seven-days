class_name CampusSceneRenderer
extends RefCounted
## 校园场景只负责384×256原生像素构图，不读取角色状态、不拥有时钟或随机流。

# 四处地点保持相同人物尺寸；脚点也供命中、姓名和互动使用。
const ANCHORS = {
	"classroom": [Vector2(112, 140), Vector2(272, 140), Vector2(112, 220), Vector2(272, 220)],
	"playground": [Vector2(112, 140), Vector2(272, 140), Vector2(112, 220), Vector2(272, 220)],
	"canteen": [Vector2(112, 140), Vector2(272, 140), Vector2(112, 220), Vector2(272, 220)],
	"dorm": [Vector2(112, 140), Vector2(272, 140), Vector2(112, 220), Vector2(272, 220)],
}
const INK = Color("53635b")
const WALL = Color("d8e5d9")
const WALL_LIGHT = Color("e8eee0")
const FLOOR = Color("d4d8c7")
const GROUT = Color("bfcbbd")
const WOOD = Color("c89c65")
const WOOD_LIGHT = Color("e5c494")
const WOOD_SHADOW = Color("a87b50")
const LEAF = Color("7b9c68")
const LEAF_DARK = Color("58795a")


## 返回当前场景的原画脚点，不根据动作名称推测或改变实际地点。
static func student_anchor(location: String, index: int) -> Vector2:
	assert(ANCHORS.has(location), "未知校园场景：" + location)
	assert(index >= 0 and index < ANCHORS[location].size(), "校园场景人物索引越界")
	return ANCHORS[location][index]


## 背景和家具统一使用整数像素绘制；教室继续保留已有正式位图。
static func draw_background(canvas: CanvasItem, location: String, origin: Vector2, pixel_scale: int, occupied_beds: Array[int] = []) -> void:
	assert(location in ["playground", "canteen", "dorm"], "此入口只绘制教室外校园场景")
	if location == "playground":
		_draw_playground(canvas, origin, pixel_scale)
	elif location == "canteen":
		_draw_canteen(canvas, origin, pixel_scale)
	else:
		_draw_dorm(canvas, origin, pixel_scale, occupied_beds)


## 当前构图让角色站在家具前或侧面，没有覆盖身体的假前景遮挡。
static func draw_foreground(_canvas: CanvasItem, _location: String, _origin: Vector2, _pixel_scale: int) -> void:
	pass


## 操场包含跑道、球场、校舍和器械，静态标线不代表角色正在移动。
static func _draw_playground(c: CanvasItem, o: Vector2, s: int) -> void:
	_rect(c, o, s, Rect2(0, 0, 384, 256), Color("a7bd8b"))
	_rect(c, o, s, Rect2(0, 0, 384, 44), WALL)
	_rect(c, o, s, Rect2(0, 0, 384, 5), WALL_LIGHT)
	for x in range(48, 336, 48):
		_window(c, o, s, Vector2(x, 10), Vector2(28, 24))
	_rect(c, o, s, Rect2(0, 40, 384, 4), INK)
	_rect(c, o, s, Rect2(0, 44, 384, 16), Color("d4d2b6"))
	for x in range(0, 384, 16):
		_line(c, o, s, Vector2(x, 44), Vector2(x, 59), Color("c0c0a6"))
	# 跑道在四边保留清楚的多圈层次，球场和真实人物脚点位于内场。
	_rect(c, o, s, Rect2(16, 68, 352, 180), Color("a96859"))
	_rect(c, o, s, Rect2(21, 73, 342, 170), Color("c18b72"))
	_rect(c, o, s, Rect2(29, 81, 326, 154), Color("ad745f"))
	_rect(c, o, s, Rect2(37, 89, 310, 138), Color("c18b72"))
	_rect(c, o, s, Rect2(45, 97, 294, 122), Color("abc187"))
	for border in [Rect2(24, 76, 336, 164), Rect2(32, 84, 320, 148), Rect2(40, 92, 304, 132)]:
		_outline(c, o, s, border, Color("e6c6a4"))
	_rect(c, o, s, Rect2(58, 108, 268, 103), Color("91ad73"))
	for row in range(0, 6):
		if row % 2 == 0:
			_rect(c, o, s, Rect2(58, 108 + row * 17, 268, 17), Color("9bb77b"))
	_outline(c, o, s, Rect2(62, 112, 260, 95), Color("e1e4bb"))
	_line(c, o, s, Vector2(192, 112), Vector2(192, 206), Color("e1e4bb"))
	_outline(c, o, s, Rect2(172, 142, 40, 32), Color("e1e4bb"))
	_outline(c, o, s, Rect2(62, 137, 28, 44), Color("e1e4bb"))
	_outline(c, o, s, Rect2(294, 137, 28, 44), Color("e1e4bb"))
	for x in [52, 322]:
		_rect(c, o, s, Rect2(x, 143, 10, 28), Color("dce5d6"))
		_outline(c, o, s, Rect2(x, 143, 10, 28), INK)
		_line(c, o, s, Vector2(x + 4, 144), Vector2(x + 4, 169), Color("a9bbaa"))
	for x in [8, 360]:
		_tree(c, o, s, Vector2(x, 21))
	for x in [10, 358]:
		_rect(c, o, s, Rect2(x, 108, 12, 52), Color("8c8e79"))
		_rect(c, o, s, Rect2(x + 2, 110, 8, 48), Color("b7b6a0"))
		for y in range(114, 156, 8):
			_line(c, o, s, Vector2(x + 2, y), Vector2(x + 9, y), Color("e4e1c2"))
	# 跑道角落的锥桶、球和跳绳只作为环境道具，不结算任何训练结果。
	for x in [68, 84, 300, 316]:
		_rect(c, o, s, Rect2(x, 60, 6, 7), Color("c9894b"))
		_rect(c, o, s, Rect2(x - 1, 66, 8, 2), Color("e2be80"))
	_rect(c, o, s, Rect2(184, 54, 16, 10), Color("596c58"))
	_rect(c, o, s, Rect2(186, 56, 12, 6), Color("e5dba2"))


## 食堂以窗口、餐桌和凳子区分空间，进食完整帧在桌旁原生工位绘制。
static func _draw_canteen(c: CanvasItem, o: Vector2, s: int) -> void:
	_room_floor(c, o, s, FLOOR)
	for x in [24, 136, 248]:
		_rect(c, o, s, Rect2(x, 10, 96, 30), INK)
		_rect(c, o, s, Rect2(x + 2, 12, 92, 25), Color("9eb9a1"))
		_rect(c, o, s, Rect2(x + 4, 14, 88, 6), Color("bbd1b4"))
		for dish_x in range(x + 10, x + 88, 24):
			_rect(c, o, s, Rect2(dish_x, 30, 17, 5), Color("e8deba"))
			_rect(c, o, s, Rect2(dish_x + 2, 28, 13, 3), Color("bd9265"))
		_rect(c, o, s, Rect2(x - 2, 38, 100, 6), WOOD_LIGHT)
		_rect(c, o, s, Rect2(x, 44, 96, 14), WOOD)
		_rect(c, o, s, Rect2(x, 56, 96, 2), WOOD_SHADOW)
	for table_origin in [Vector2(72, 84), Vector2(232, 84), Vector2(72, 164), Vector2(232, 164)]:
		_dining_table(c, o, s, table_origin)
	_plant(c, o, s, Vector2(20, 72))
	_plant(c, o, s, Vector2(352, 72))
	for x in [20, 352]:
		_rect(c, o, s, Rect2(x, 184, 12, 26), Color("7e9c95"))
		_rect(c, o, s, Rect2(x - 1, 182, 14, 4), Color("50746c"))
		_rect(c, o, s, Rect2(x + 3, 188, 6, 2), Color("dce8d5"))
	# 中央走道保持畅通，餐盘收集车靠北墙而不覆盖角色或姓名区域。
	_rect(c, o, s, Rect2(172, 66, 40, 20), Color("869d93"))
	_rect(c, o, s, Rect2(174, 65, 36, 4), Color("c4d4c3"))
	for x in [176, 202]:
		_rect(c, o, s, Rect2(x, 86, 4, 4), INK)


## 四床围绕走道布置；卧床动画自带床体，替换该床而不叠成两张床。
static func _draw_dorm(c: CanvasItem, o: Vector2, s: int, occupied_beds: Array[int]) -> void:
	_room_floor(c, o, s, Color("d9d4bf"))
	_window(c, o, s, Vector2(160, 8), Vector2(64, 32))
	for x in [24, 280]:
		_rect(c, o, s, Rect2(x, 8, 72, 43), INK)
		_rect(c, o, s, Rect2(x + 2, 10, 68, 39), WOOD)
		_line(c, o, s, Vector2(x + 36, 11), Vector2(x + 36, 48), WOOD_SHADOW)
		for handle_x in [x + 30, x + 40]:
			_rect(c, o, s, Rect2(handle_x, 27, 2, 7), WOOD_LIGHT)
	var bed_origins: Array[Vector2] = [Vector2(24, 78), Vector2(296, 78), Vector2(24, 158), Vector2(296, 158)]
	for index in bed_origins.size():
		if index not in occupied_beds:
			_bed(c, o, s, bed_origins[index])
	# 学习桌由当前坐姿工位绘制；电脑和洗手台使用完整PNG，不再叠旧中央桌。
	_plant(c, o, s, Vector2(368, 64))
	_rect(c, o, s, Rect2(176, 232, 32, 16), Color("b2bfa0"))
	for x in range(178, 208, 4):
		_line(c, o, s, Vector2(x, 234), Vector2(x, 246), Color("c8d1b8"))


## 室内共享北墙48像素和16像素地砖，不产生透视缩小。
static func _room_floor(c: CanvasItem, o: Vector2, s: int, floor_color: Color) -> void:
	_rect(c, o, s, Rect2(0, 0, 384, 256), floor_color)
	for x in range(0, 385, 16):
		_line(c, o, s, Vector2(x, 48), Vector2(x, 255), GROUT)
	for y in range(48, 256, 16):
		_line(c, o, s, Vector2(0, y), Vector2(383, y), GROUT)
	_rect(c, o, s, Rect2(0, 0, 384, 48), WALL)
	_rect(c, o, s, Rect2(0, 0, 384, 4), WALL_LIGHT)
	_rect(c, o, s, Rect2(0, 45, 384, 3), Color("8eaa96"))


## 餐桌四人分区与现有脚点对应，桌边餐盘只是环境摆设。
static func _dining_table(c: CanvasItem, o: Vector2, s: int, p: Vector2) -> void:
	_rect(c, o, s, Rect2(p + Vector2(3, 23), Vector2(74, 6)), Color("b7baa6"))
	for x in [4, 70]:
		_rect(c, o, s, Rect2(p + Vector2(x, 16), Vector2(5, 22)), WOOD_SHADOW)
	_rect(c, o, s, Rect2(p, Vector2(80, 22)), WOOD_SHADOW)
	_rect(c, o, s, Rect2(p + Vector2(1, 1), Vector2(78, 17)), WOOD_LIGHT)
	_rect(c, o, s, Rect2(p + Vector2(28, 4), Vector2(24, 11)), Color("789589"))
	_rect(c, o, s, Rect2(p + Vector2(31, 6), Vector2(9, 7)), Color("f3ebcc"))
	_rect(c, o, s, Rect2(p + Vector2(43, 6), Vector2(6, 7)), Color("b98c61"))
	for x in [0, 62]:
		_rect(c, o, s, Rect2(p + Vector2(x, 31), Vector2(18, 5)), WOOD)
		_rect(c, o, s, Rect2(p + Vector2(x + 2, 36), Vector2(3, 7)), WOOD_SHADOW)
		_rect(c, o, s, Rect2(p + Vector2(x + 13, 36), Vector2(3, 7)), WOOD_SHADOW)


## 空床沿卧床动画64像素画布的同一床体范围绘制，切换休息时家具尺度不跳变。
static func _bed(c: CanvasItem, o: Vector2, s: int, p: Vector2) -> void:
	_rect(c, o, s, Rect2(p + Vector2(17, 5), Vector2(30, 55)), Color("684728"))
	_rect(c, o, s, Rect2(p + Vector2(18, 6), Vector2(28, 7)), Color("b58a58"))
	_rect(c, o, s, Rect2(p + Vector2(19, 12), Vector2(26, 12)), Color("e8dfb4"))
	_rect(c, o, s, Rect2(p + Vector2(19, 24), Vector2(26, 29)), Color("3b9a8c"))
	_rect(c, o, s, Rect2(p + Vector2(20, 25), Vector2(24, 3)), Color("60b19b"))
	_rect(c, o, s, Rect2(p + Vector2(18, 53), Vector2(28, 4)), Color("b58a58"))


## 窗框保留无平滑的玻璃高光和中间横梁。
static func _window(c: CanvasItem, o: Vector2, s: int, p: Vector2, dimensions: Vector2) -> void:
	_rect(c, o, s, Rect2(p, dimensions), Color("78988b"))
	_rect(c, o, s, Rect2(p + Vector2.ONE * 2, dimensions - Vector2.ONE * 4), Color("b8d5cf"))
	_line(c, o, s, p + Vector2(3, 3), p + Vector2(dimensions.x - 4, 3), Color("e8f0d8"))
	_rect(c, o, s, Rect2(p + Vector2(int(dimensions.x / 2), 1), Vector2(2, dimensions.y - 2)), Color("78988b"))
	_rect(c, o, s, Rect2(p + Vector2(1, dimensions.y - 3), Vector2(dimensions.x - 2, 3)), Color("9ab1a0"))


## 盆栽与树都沿整像素轮廓绘制，不使用抗锯齿圆形。
static func _plant(c: CanvasItem, o: Vector2, s: int, p: Vector2) -> void:
	_rect(c, o, s, Rect2(p + Vector2(-5, -8), Vector2(10, 9)), WOOD_SHADOW)
	_rect(c, o, s, Rect2(p + Vector2(-6, -10), Vector2(12, 3)), WOOD_LIGHT)
	_rect(c, o, s, Rect2(p + Vector2(-1, -23), Vector2(2, 14)), LEAF_DARK)
	_rect(c, o, s, Rect2(p + Vector2(-9, -23), Vector2(10, 8)), LEAF)
	_rect(c, o, s, Rect2(p + Vector2(0, -28), Vector2(8, 10)), LEAF_DARK)
	_rect(c, o, s, Rect2(p + Vector2(1, -26), Vector2(5, 6)), LEAF)


## 树冠不遮住跑道入口，树干脚点固定在北侧绿化带。
static func _tree(c: CanvasItem, o: Vector2, s: int, p: Vector2) -> void:
	_rect(c, o, s, Rect2(p + Vector2(6, 15), Vector2(4, 23)), WOOD_SHADOW)
	_rect(c, o, s, Rect2(p + Vector2(-2, 2), Vector2(24, 19)), LEAF_DARK)
	_rect(c, o, s, Rect2(p + Vector2(1, -4), Vector2(18, 25)), LEAF)
	_rect(c, o, s, Rect2(p + Vector2(4, -2), Vector2(10, 8)), Color("93b278"))


## 原画矩形只按整数倍映射到控件，不拉伸角色或重新采样像素。
static func _rect(c: CanvasItem, o: Vector2, s: int, rectangle: Rect2, color: Color) -> void:
	c.draw_rect(Rect2(o + rectangle.position * s, rectangle.size * s), color)


## 边框由四条整像素矩形组成，2倍显示仍与原图逐像素对应。
static func _outline(c: CanvasItem, o: Vector2, s: int, rectangle: Rect2, color: Color) -> void:
	_rect(c, o, s, Rect2(rectangle.position, Vector2(rectangle.size.x, 1)), color)
	_rect(c, o, s, Rect2(rectangle.position + Vector2(0, rectangle.size.y - 1), Vector2(rectangle.size.x, 1)), color)
	_rect(c, o, s, Rect2(rectangle.position, Vector2(1, rectangle.size.y)), color)
	_rect(c, o, s, Rect2(rectangle.position + Vector2(rectangle.size.x - 1, 0), Vector2(1, rectangle.size.y)), color)


## 本构图只用横纵直线，矩形描线避免非整数描边落在半像素。
static func _line(c: CanvasItem, o: Vector2, s: int, from: Vector2, to: Vector2, color: Color) -> void:
	assert(from.x == to.x or from.y == to.y, "校园静态场景只使用横纵原生像素线")
	_rect(c, o, s, Rect2(Vector2(minf(from.x, to.x), minf(from.y, to.y)), (to - from).abs() + Vector2.ONE), color)
