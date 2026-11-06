class_name ClassroomView
extends Control

# 点击只请求根界面查看对象或课表，不在场景内执行角色指令。
signal student_selected(student_index: int)
signal blackboard_selected

# 场景按原生网格绘制，字体和姓名标签在界面坐标中保持清楚。
const ROOM_SIZE = Vector2(384, 256)
const STUDENT_ANCHOR = Vector2(16, 44)
const SEATS = [Vector2(112, 140), Vector2(272, 140), Vector2(112, 220), Vector2(272, 220)]
const ACCENTS = [Color("2485a5"), Color("bb745b"), Color("698151"), Color("8971a0")]
const BLACKBOARD_RECT = Rect2(109, 6, 166, 34)
const LABEL_MAX_WIDTH = 136.0

# 素材只从已经验收的真实PNG加载；缺失会在导入或加载时明确报错。
var room_texture: Texture2D
var poses: Dictionary = {}

# 模拟器是唯一权威状态；选中索引只决定当前查看对象。
var simulation: ClassroomSimulation
var selected_index: int = 0

# 原画与界面文字分别定位，动画时钟仅用于选择已有像素帧。
var room_origin: Vector2 = Vector2.ZERO
var pixel_scale: int = 1
var animation_seconds: float = 0.0

# 缓存只保存呈现所需的真实姓名、动作和地点，不拥有独立的业务资源状态。
var visual_students: Array[Dictionary] = []
var rendered_selection: int = -1
var rendered_frames: PackedInt32Array = []
var animation_enabled: bool = true

# 姓名和状态由原生文字控件裁切，长名字不会挤入相邻座位。
var name_labels: Array[Label] = []
var status_labels: Array[Label] = []
var name_styles: Array[StyleBoxFlat] = []


# 载入教室和专用坐姿，不通过隐藏站姿腿部冒充坐姿。
func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = ROOM_SIZE
	room_texture = load("res://assets/pixel/classroom/classroom.png")
	for pose_name in ["study", "daydream", "sleep"]:
		var frames: Array[Texture2D] = []
		for frame_index in 2:
			frames.append(load("res://assets/pixel/student01/poses/%s_%d.png" % [pose_name, frame_index]))
		poses[pose_name] = frames
	for index in SEATS.size():
		name_labels.append(_create_seat_label(12, Color("186d85") if index == 0 else Color("263e35")))
		status_labels.append(_create_seat_label(11, Color("597269")))
	name_styles = [_name_style(false), _name_style(true)]
	queue_redraw()


# 场景读取同一份权威状态，选中同学不会改变玩家控制权。
func bind_game(value: ClassroomSimulation) -> void:
	simulation = value
	refresh_state()


# 根界面在真实状态更新后调用；相同呈现内容不会触发多余的场景重绘。
func refresh_state() -> void:
	var next_students: Array[Dictionary] = []
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		var action: Dictionary = student.current_action
		var action_id = "" if action.is_empty() else String(action.action_id)
		var location = _location_name(student)
		var action_name = "等待活动" if action.is_empty() else String(simulation.config.actions[action_id].name)
		var name_text = String(student.name) + (" · 我" if index == 0 and student.name != "我" else "")
		next_students.append({
			"name": name_text,
			"status": action_name if location == "教室" else location,
			"action": action_name,
			"location": location,
			"pose": _pose_name(action_id),
			"in_room": location == "教室",
		})
	if next_students != visual_students or selected_index != rendered_selection:
		visual_students = next_students
		rendered_selection = selected_index
		rendered_frames = _animation_frames()
		for index in visual_students.size():
			name_labels[index].text = visual_students[index].name
			status_labels[index].text = visual_students[index].status
		if animation_enabled:
			queue_redraw()


# 托盘隐藏时只停视觉帧，游戏时钟和动作结算继续由唯一模拟器推进。
func set_animation_enabled(value: bool) -> void:
	animation_enabled = value
	set_process(value)
	if value:
		queue_redraw()


# 只推进轻微像素动画；动作完成和收益由核心执行器负责。
func _process(delta: float) -> void:
	animation_seconds += delta
	var next_frames = _animation_frames()
	if next_frames != rendered_frames:
		rendered_frames = next_frames
		queue_redraw()


# 整数缩放教室并绘制姓名、状态和真实所在地点。
func _draw() -> void:
	if not is_instance_valid(room_texture):
		return
	_update_geometry()
	var room_pixels = ROOM_SIZE * pixel_scale
	draw_texture_rect(room_texture, Rect2(room_origin, room_pixels), false)
	var font = get_theme_default_font()
	for index in visual_students.size():
		var student: Dictionary = visual_students[index]
		var foot: Vector2 = room_origin + SEATS[index] * pixel_scale
		if student.in_room:
			var texture: Texture2D = poses[String(student.pose)][rendered_frames[index]]
			# 完整坐姿帧已经含桌上手部，按素材约定在家具之后绘制一次。
			draw_texture_rect(texture, Rect2(foot - STUDENT_ANCHOR * pixel_scale, Vector2(32, 48) * pixel_scale), false)
		if index == selected_index:
			_draw_selection(foot, ACCENTS[index])
		var text_width = maxf(font.get_string_size(student.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x, font.get_string_size(student.status, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x)
		var label_width = minf(text_width + 12.0, LABEL_MAX_WIDTH)
		# 中文字体实际行高大于字号，按测得行高排列两行，避免小窗中上下重叠。
		var name_height = ceilf(font.get_height(12))
		var status_height = ceilf(font.get_height(11))
		var label_rect = Rect2(foot + Vector2(-label_width * 0.5, 1), Vector2(label_width, name_height + status_height + 2))
		draw_style_box(name_styles[1 if index == selected_index else 0], label_rect)
		name_labels[index].position = label_rect.position + Vector2(6, 1)
		name_labels[index].size = Vector2(label_width - 12, name_height)
		status_labels[index].position = label_rect.position + Vector2(6, name_height + 1)
		status_labels[index].size = Vector2(label_width - 12, status_height)


# 短标签采用原生文本溢出处理，完整姓名与动作仍可通过角色详情查看。
func _create_seat_label(font_size: int, color: Color) -> Label:
	var label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	add_child(label)
	return label


# 真实动作仅映射到已有三种坐姿，资源和动作时长不在画面层计算。
func _pose_name(action_id: String) -> String:
	if action_id in ["sleep", "rest", "dorm_rest"]:
		return "sleep"
	if action_id in ["daydream", "break_rest", "music_class", "eye_exercise"]:
		return "daydream"
	return "study"


# 离开教室的角色没有可见动画帧，空教室不因计时产生无效重绘。
func _animation_frames() -> PackedInt32Array:
	var frames: PackedInt32Array = []
	for index in visual_students.size():
		var student: Dictionary = visual_students[index]
		var duration = 0.9 if student.pose == "sleep" else 0.45
		frames.append(int(animation_seconds / duration + index) % 2 if student.in_room else -1)
	return frames


# 场景只接受原画的整数倍画布，窗口管理层负责提供对应的精确尺寸。
func _update_geometry() -> void:
	pixel_scale = int(floor(min(size.x / ROOM_SIZE.x, size.y / ROOM_SIZE.y)))
	assert(pixel_scale >= 1, "教室画布不得小于384×256原画")
	room_origin = ((size - ROOM_SIZE * pixel_scale) * 0.5).floor()


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
		var point = foot + Vector2(direction * x, 0)
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
		_update_geometry()
		if BLACKBOARD_RECT.has_point((event.position - room_origin) / pixel_scale):
			blackboard_selected.emit()
			accept_event()
			return
		var index = _student_at(event.position)
		if index >= 0:
			selected_index = index
			student_selected.emit(index)
			if simulation != null:
				refresh_state()
			accept_event()


# 座位命中同时覆盖真实人物与下方标签，离开教室后仍能点座位查看去向。
func _student_at(position_value: Vector2) -> int:
	for index in SEATS.size():
		var foot: Vector2 = room_origin + SEATS[index] * pixel_scale
		var hit = Rect2(foot - Vector2(34, 44) * pixel_scale, Vector2(68 * pixel_scale, 44 * pixel_scale + 36))
		if hit.has_point(position_value):
			return index
	return -1


# 黑板与人物提供准确的查看提示，空地不会显示不存在的游戏命令。
func _get_tooltip(at_position: Vector2) -> String:
	_update_geometry()
	if BLACKBOARD_RECT.has_point((at_position - room_origin) / pixel_scale):
		return "查看当天课表"
	var index = _student_at(at_position)
	if index >= 0 and not visual_students.is_empty():
		var student: Dictionary = visual_students[index]
		return "%s\n%s · %s" % [student.name, student.location, student.action]
	return ""
