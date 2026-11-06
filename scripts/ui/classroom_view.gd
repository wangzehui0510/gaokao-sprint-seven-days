class_name ClassroomView
extends Control

signal student_selected(student_index: int)

# 场景按原生网格绘制，字体和姓名标签在界面坐标中保持清楚。
const ROOM_SIZE = Vector2(384, 256)
const STUDENT_ANCHOR = Vector2(16, 44)
const SEATS = [Vector2(112, 140), Vector2(272, 140), Vector2(112, 220), Vector2(272, 220)]
const ACCENTS = [Color("2485a5"), Color("bb745b"), Color("698151"), Color("8971a0")]

# 素材只从已经验收的真实PNG加载；缺失会在导入或加载时明确报错。
var room_texture: Texture2D
var poses: Dictionary = {}
var simulation: ClassroomSimulation
var selected_index: int = 0
var room_origin: Vector2 = Vector2.ZERO
var pixel_scale: int = 2
var animation_seconds: float = 0.0


# 载入教室和专用坐姿，不通过隐藏站姿腿部冒充坐姿。
func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	room_texture = load("res://assets/pixel/classroom/classroom.png")
	for pose_name in ["study", "daydream", "sleep"]:
		var frames: Array[Texture2D] = []
		for frame_index in 2:
			frames.append(load("res://assets/pixel/student01/poses/%s_%d.png" % [pose_name, frame_index]))
		poses[pose_name] = frames
	queue_redraw()


# 场景读取同一份权威状态，选中同学不会改变玩家控制权。
func bind_game(value: ClassroomSimulation) -> void:
	simulation = value
	queue_redraw()


# 只推进轻微像素动画；动作完成和收益由核心执行器负责。
func _process(delta: float) -> void:
	animation_seconds += delta
	queue_redraw()


# 整数缩放教室并绘制姓名、状态和真实所在地点。
func _draw() -> void:
	if not is_instance_valid(room_texture):
		return
	pixel_scale = int(floor(min(size.x / ROOM_SIZE.x, size.y / ROOM_SIZE.y)))
	pixel_scale = maxi(pixel_scale, 1)
	var room_pixels = ROOM_SIZE * pixel_scale
	room_origin = ((size - room_pixels) * 0.5).floor()
	draw_rect(Rect2(Vector2.ZERO, size), Color("d6e2dc"))
	draw_texture_rect(room_texture, Rect2(room_origin, room_pixels), false)
	if simulation == null:
		return
	var font = get_theme_default_font()
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		var action: Dictionary = student.current_action
		var foot: Vector2 = room_origin + SEATS[index] * pixel_scale
		var in_room = _is_in_room(student)
		if in_room:
			var action_id = String(action.get("action_id", ""))
			var pose_name = "study"
			if action_id in ["sleep", "rest", "dorm_rest"]:
				pose_name = "sleep"
			elif action_id in ["daydream", "break_rest", "music_class", "eye_exercise"]:
				pose_name = "daydream"
			var frame_duration = 0.9 if pose_name == "sleep" else 0.45
			var frame_index = int(animation_seconds / frame_duration + index) % 2
			var texture: Texture2D = poses[pose_name][frame_index]
			draw_texture_rect(texture, Rect2(foot - STUDENT_ANCHOR * pixel_scale, Vector2(32, 48) * pixel_scale), false)
		if index == selected_index:
			_draw_selection(foot, ACCENTS[index])
		var name_text = String(student.name) + (" · 我" if index == 0 and student.name != "我" else "")
		var name_width = font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		var label_rect = Rect2(foot + Vector2(-name_width * 0.5 - 7, 10), Vector2(name_width + 14, 22))
		draw_style_box(_name_style(index == selected_index), label_rect)
		draw_string(font, label_rect.position + Vector2(7, 16), name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("263e35"))
		if not in_room:
			var location_text = _location_name(student)
			var width = font.get_string_size(location_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			draw_string(font, foot + Vector2(-width * 0.5, -12), location_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("597269"))


# 姓名底色只标识选择，不依靠更换人物外观制造不同角色素材。
func _name_style(selected: bool) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = Color("e6f3f6") if selected else Color("f5f8f3")
	style.border_color = Color("2683a1") if selected else Color("b4c8bb")
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	return style


# 选中标记使用明确的地面边角，不遮盖角色动作。
func _draw_selection(foot: Vector2, color: Color) -> void:
	var x = 18.0 * pixel_scale
	var y = 6.0 * pixel_scale
	for direction in [-1, 1]:
		var point = foot + Vector2(direction * x, 4)
		draw_line(point, point + Vector2(-direction * 7, 0), color, 2)
		draw_line(point, point + Vector2(0, -y), color, 2)


# 地点来自动作与课表，离开教室的人不伪装成仍在教室学习。
func _is_in_room(student: Dictionary) -> bool:
	return _location_name(student) == "教室"


# 将已定义场景映射为玩家能直接理解的地点名称。
func _location_name(student: Dictionary) -> String:
	var action: Dictionary = student.current_action
	if action.is_empty():
		return "教室"
	var definition: Dictionary = simulation.config.actions[String(action.action_id)]
	var location = String(definition.scene)
	if location == "course":
		location = "playground" if simulation.course_context().subject_id == "physical" else "classroom"
	if location == "any":
		var context = simulation.course_context()
		location = "dorm" if context.kind == "outside" else ("playground" if context.subject_id == "physical" else "classroom")
	var names = {"classroom": "教室", "playground": "操场", "dorm": "宿舍", "canteen": "食堂"}
	assert(names.has(location), "未知动作场景：" + location)
	return names[location]


# 点击角色或座位姓名只更新查看对象，所有主动命令仍固定发给玩家。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		for index in SEATS.size():
			var foot: Vector2 = room_origin + SEATS[index] * pixel_scale
			var hit = Rect2(foot - Vector2(30, 42) * pixel_scale, Vector2(60, 60) * pixel_scale)
			if hit.has_point(event.position):
				selected_index = index
				student_selected.emit(index)
				queue_redraw()
				accept_event()
				return
