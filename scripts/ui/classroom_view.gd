class_name ClassroomView
extends Control

# 点击只请求根界面查看对象、互动菜单或课表，不在场景内执行角色指令。
signal student_selected(student_index: int)
signal student_context_requested(student_index: int, local_position: Vector2)
signal blackboard_selected
# 观察场景真实变化时通知根界面关闭旧坐标上的菜单，不更改任何角色地点。
signal view_location_changed(location: String)

# 场景按原生网格绘制，字体和姓名标签在界面坐标中保持清楚。
const ROOM_SIZE = Vector2(384, 256)
const STUDENT_ANCHOR = Vector2(16, 44)
const SEATS = [Vector2(112, 140), Vector2(272, 140), Vector2(112, 220), Vector2(272, 220)]
const ACCENTS = [Color("2485a5"), Color("bb745b"), Color("698151"), Color("8971a0")]
const BLACKBOARD_RECT = Rect2(109, 6, 166, 34)
const LABEL_MAX_WIDTH = 136.0
# 短暂送达、受击、互动结果和举报提示只有视觉时长，不参与业务结算。
const DELIVERY_VISUAL_SECONDS = 0.9
const IMPACT_VISUAL_SECONDS = 0.8
const OUTCOME_VISUAL_SECONDS = 1.2
const REPORT_VISUAL_SECONDS = 1.2
const PIXEL_INK = Color("374c4c")
const NOTE_COLOR = Color("fff3cf")
const ERASER_COLOR = Color("e49a9a")
const LOCATION_NAMES = {"classroom": "教室", "playground": "操场", "canteen": "食堂", "dorm": "宿舍"}

# 素材只从已经验收的真实PNG加载；缺失会在导入或加载时明确报错。
var room_texture: Texture2D
var poses: Dictionary = {}
# 教室外使用已有真实方向站姿，不能把站姿当作跑步、吃饭或卧床动画。
var standing_poses: Dictionary = {}

# 观察模式属于画面状态；auto只跟随玩家真实地点，切换镜头不启动动作或推进时间。
var _view_location: String = "classroom"
var _rendered_location: String = "classroom"

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

# 所有互动缓存都由权威记录派生；progress 保留真实执行比例，坐标按原画像素取整。
var visual_interactions: Array[Dictionary] = []
var visual_impacts: Array[Dictionary] = []
var visual_outcomes: Array[Dictionary] = []
var visual_reports: Array[Dictionary] = []
var _interaction_sources: Array[Dictionary] = []
var _report_sources: Array[Dictionary] = []
# 重绘比较只使用可见像素与闪烁相位，避免进度的小数变化造成无效逐帧重绘。
var _overlay_draw_state: Array[Dictionary] = []

# 姓名和状态由原生文字控件裁切，长名字不会挤入相邻座位。
var name_labels: Array[Label] = []
var status_labels: Array[Label] = []
var name_styles: Array[StyleBoxFlat] = []


# 载入教室、专用坐姿与方向站姿，不通过遮住腿部冒充新的动作素材。
func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = ROOM_SIZE
	room_texture = load("res://assets/pixel/classroom/classroom.png")
	for pose_name in ["study", "daydream", "sleep"]:
		var frames: Array[Texture2D] = []
		for frame_index in 2:
			frames.append(load("res://assets/pixel/student01/poses/%s_%d.png" % [pose_name, frame_index]))
		poses[pose_name] = frames
	for direction in ["south", "east", "north", "west"]:
		standing_poses[direction] = load("res://assets/pixel/student01/%s.png" % direction)
	for index in SEATS.size():
		name_labels.append(_create_seat_label(12, Color("186d85") if index == 0 else Color("263e35")))
		status_labels.append(_create_seat_label(11, Color("597269")))
	name_styles = [_name_style(false), _name_style(true)]
	queue_redraw()


# 场景读取同一份权威状态，选中同学不会改变玩家控制权。
func bind_game(value: ClassroomSimulation) -> void:
	simulation = value
	refresh_state()


# 镜头仅选择一个已定义地点；角色位置仍逐人读取唯一模拟器。
func set_view_location(value: String) -> void:
	assert(value == "auto" or LOCATION_NAMES.has(value), "未知观察场景：" + value)
	_view_location = value
	if simulation != null:
		refresh_state()
	elif animation_enabled:
		queue_redraw()


# 返回实际观察地点，自动跟随也不会向外泄漏非业务地点auto。
func get_view_location() -> String:
	var location: String = simulation.student_location(0) if _view_location == "auto" and simulation != null else ("classroom" if _view_location == "auto" else _view_location)
	assert(LOCATION_NAMES.has(location), "玩家真实地点无法呈现：" + location)
	return location


# 设置入口可读取原始模式，避免把自动跟随误显示成一次手动选地。
func get_view_mode() -> String:
	return _view_location


# 根界面在真实状态更新后调用；相同呈现内容不会触发多余的场景重绘。
func refresh_state() -> void:
	var location_id: String = get_view_location()
	var location_changed: bool = location_id != _rendered_location
	_rendered_location = location_id
	_refresh_interaction_sources()
	var next_students: Array[Dictionary] = []
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		var action: Dictionary = student.current_action
		var action_id = "" if action.is_empty() else String(action.action_id)
		var location = _location_name(student)
		var student_location_id: String = simulation.student_location(index)
		var visible_here: bool = student_location_id == location_id
		var action_name = ("本局已结束" if simulation.is_round_finished() else "等待活动") if action.is_empty() else String(simulation.config.actions[action_id].name)
		var name_text = String(student.name) + (" · 我" if index == 0 and student.name != "我" else "")
		var interaction: Dictionary = _active_interaction_for_student(index)
		var relationship: String = _interaction_relationship(interaction)
		var short_status: String = action_name
		if not action.is_empty() and simulation.config.actions[action_id].knowledge_source == "dorm":
			short_status += " · " + String(simulation.config.subjects[action.subject_id].name)
		if not interaction.is_empty():
			var other_index: int = int(interaction.target_index) if int(interaction.initiator_index) == index else int(interaction.initiator_index)
			short_status += (" → " if int(interaction.initiator_index) == index else " ← ") + String(simulation.students[other_index].name)
		next_students.append({
			"name": name_text,
			"status": short_status if visible_here else location,
			"action": action_name,
			"location": location,
			"location_id": student_location_id,
			"pose": _pose_name(action_id),
			"in_room": location == "教室",
			"visible": visible_here,
			"interaction": relationship,
		})
	var students_changed: bool = location_changed or next_students != visual_students or selected_index != rendered_selection
	if students_changed:
		visual_students = next_students
		rendered_selection = selected_index
		rendered_frames = _animation_frames()
		for index in visual_students.size():
			name_labels[index].text = visual_students[index].name
			status_labels[index].text = visual_students[index].status
			name_labels[index].visible = visual_students[index].visible
			status_labels[index].visible = visual_students[index].visible
	var overlays_changed: bool = _refresh_interaction_visuals()
	if animation_enabled and (students_changed or overlays_changed):
		queue_redraw()
	if location_changed:
		view_location_changed.emit(location_id)


# 托盘隐藏时只停视觉帧，游戏时钟和动作结算继续由唯一模拟器推进。
func set_animation_enabled(value: bool) -> void:
	animation_enabled = value
	set_process(value)
	if value:
		# 恢复时直接读取当前权威时间，不能重播隐藏期间已经过去的送达或受击。
		if simulation != null:
			refresh_state()
		queue_redraw()


# 只推进轻微像素动画；动作完成和收益由核心执行器负责。
func _process(delta: float) -> void:
	if not animation_enabled:
		return
	animation_seconds += delta
	var next_frames = _animation_frames()
	var overlays_changed: bool = _refresh_interaction_visuals()
	if next_frames != rendered_frames or overlays_changed:
		rendered_frames = next_frames
		queue_redraw()


# 整数缩放当前场景，只绘制权威地点与镜头相符的人物、姓名和状态。
func _draw() -> void:
	if not is_instance_valid(room_texture):
		return
	_update_geometry()
	var room_pixels = ROOM_SIZE * pixel_scale
	if _rendered_location == "classroom":
		draw_texture_rect(room_texture, Rect2(room_origin, room_pixels), false)
	else:
		CampusSceneRenderer.draw_background(self, _rendered_location, room_origin, pixel_scale)
	_draw_interaction_paths()
	for index in visual_students.size():
		var student: Dictionary = visual_students[index]
		if not student.visible:
			continue
		var foot: Vector2 = room_origin + _student_anchor(index) * pixel_scale
		var texture: Texture2D
		if _rendered_location == "classroom" and student.pose != "standing":
			texture = poses[String(student.pose)][rendered_frames[index]]
			# 完整坐姿帧已经含桌上手部，按素材约定在家具之后绘制一次。
		else:
			# 站立类动作仅复用真实静态站姿，不把站姿帧伪装成清扫或走动动画。
			var direction: String = "south" if _rendered_location == "classroom" else CampusSceneRenderer.standing_direction(_rendered_location, index)
			texture = standing_poses[direction]
		draw_texture_rect(texture, Rect2(foot - STUDENT_ANCHOR * pixel_scale, Vector2(32, 48) * pixel_scale), false, _student_tint(index))
		if index == selected_index:
			_draw_selection(foot, ACCENTS[index])
	if _rendered_location != "classroom":
		CampusSceneRenderer.draw_foreground(self, _rendered_location, room_origin, pixel_scale)
	_draw_interaction_objects()
	var font = get_theme_default_font()
	for index in visual_students.size():
		var student: Dictionary = visual_students[index]
		if not student.visible:
			continue
		var foot: Vector2 = room_origin + _student_anchor(index) * pixel_scale
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


# 只保留活动互动和短暂完成或中断记录，不能从动画反推业务结果。
func _refresh_interaction_sources() -> void:
	_interaction_sources.clear()
	for interaction in simulation.interactions:
		if interaction.status == "active":
			_interaction_sources.append(interaction)
		elif interaction.status in ["completed", "interrupted"] and simulation.elapsed_s - float(interaction.finished_at) < maxf(OUTCOME_VISUAL_SECONDS, maxf(DELIVERY_VISUAL_SECONDS, IMPACT_VISUAL_SECONDS)):
			_interaction_sources.append(interaction)
	_report_sources.clear()
	# 日志按权威执行时间追加；超过提示时间的旧日志不再扫描和重播。
	for index in range(simulation.logs.size() - 1, -1, -1):
		var entry: Dictionary = simulation.logs[index]
		if simulation.elapsed_s - float(entry.elapsed_s) >= REPORT_VISUAL_SECONDS:
			break
		if entry.type == "report":
			_report_sources.append(entry)


# 姓名与方向来自正在执行的共享互动；查看别人不改变参与者和主动指令目标。
func _active_interaction_for_student(index: int) -> Dictionary:
	var action: Dictionary = simulation.students[index].current_action
	if not action.has("interaction_id"):
		return {}
	for interaction in _interaction_sources:
		if interaction.status == "active" and interaction.interaction_id == action.interaction_id:
			return interaction
	return {}


# 活动名称来自配表，胜负快照和选定科目来自记录，未完成纸条不显示正文。
func _interaction_relationship(interaction: Dictionary) -> String:
	if interaction.is_empty():
		return ""
	var initiator: String = String(simulation.students[int(interaction.initiator_index)].name)
	var target: String = String(simulation.students[int(interaction.target_index)].name)
	var activity: String = "%s进行中，尚未结算完成效果" % simulation.config.actions[interaction.action_id].name
	if interaction.action_id == "send_note":
		activity = "纸条传递中，尚未送达"
	elif interaction.action_id in ["eraser_prank", "use_eraser"]:
		activity += "与受击"
	activity += "（剩余%d秒）" % ceili(float(interaction.ends_at) - simulation.elapsed_s)
	activity += _interaction_specific_detail(interaction)
	return "%s → %s\n%s" % [initiator, target, activity]


# 特殊互动只展示真实选择和扣费前快照，不在画面中另算知识或胜负。
func _interaction_specific_detail(interaction: Dictionary) -> String:
	if interaction.action_id in ["swap_book", "swap_book_boost"]:
		return "\n选定科目：" + String(simulation.config.subjects[interaction.selected_subject_id].name)
	if interaction.action_id == "arm_wrestle":
		return "\n发动时体力：%s %.2f / %s %.2f" % [
			simulation.students[int(interaction.initiator_index)].name, float(interaction.stamina_snapshot.initiator),
			simulation.students[int(interaction.target_index)].name, float(interaction.stamina_snapshot.target),
		]
	return ""


# 结束提示服从真实记录；打断不显示完成收益，平局不虚构胜者。
func _interaction_outcome_summary(interaction: Dictionary) -> String:
	var action_name: String = simulation.config.actions[interaction.action_id].name
	if interaction.status == "interrupted":
		return "%s已中断，%s" % [action_name, "纸条未送达" if interaction.action_id == "send_note" else "未结算完成效果"]
	var summary: String = "%s已完成" % action_name
	if interaction.action_id == "send_note":
		summary = "纸条已送达"
	elif interaction.action_id == "arm_wrestle":
		var result: Dictionary = interaction.result
		if result.outcome == "tie":
			summary += "：平局"
		else:
			summary += "：%s胜，%s负" % [simulation.students[int(result.winner_index)].name, simulation.students[int(result.loser_index)].name]
	return summary + _interaction_specific_detail(interaction)


# 读取最近结束的互动供提示查阅，新动作仍保留当前真实名称和方向。
func _recent_interaction_for_student(index: int) -> Dictionary:
	for position in range(_interaction_sources.size() - 1, -1, -1):
		var interaction: Dictionary = _interaction_sources[position]
		if interaction.status != "active" and index in [int(interaction.initiator_index), int(interaction.target_index)]:
			var age: float = simulation.elapsed_s - float(interaction.finished_at)
			if age >= 0.0 and age < OUTCOME_VISUAL_SECONDS:
				return interaction
	return {}


# 飞行、送达标记和闪烁只读模拟器时间；隐藏后不累积一套独立的互动动画时钟。
func _refresh_interaction_visuals() -> bool:
	if simulation == null:
		return false
	var next_interactions: Array[Dictionary] = []
	var next_impacts: Array[Dictionary] = []
	var next_outcomes: Array[Dictionary] = []
	var next_reports: Array[Dictionary] = []
	var next_draw_state: Array[Dictionary] = []
	for interaction in _interaction_sources:
		var initiator: int = int(interaction.initiator_index)
		var target: int = int(interaction.target_index)
		if interaction.status != "active":
			var outcome_age: float = simulation.elapsed_s - float(interaction.finished_at)
			if outcome_age >= 0.0 and outcome_age < OUTCOME_VISUAL_SECONDS and (visual_students[initiator].visible or visual_students[target].visible):
				var outcome: Dictionary = {
					"interaction_id": interaction.interaction_id, "action_id": interaction.action_id,
					"action_name": simulation.config.actions[interaction.action_id].name,
					"initiator_index": initiator, "target_index": target, "status": interaction.status,
					"summary": _interaction_outcome_summary(interaction),
					"result": interaction.result.duplicate(true),
				}
				next_outcomes.append(outcome)
				next_draw_state.append(outcome)
		# 只有双方真实处在当前场景才画轨迹，跨地点关系仍由可见角色提示准确说明。
		if not visual_students[initiator].visible or not visual_students[target].visible:
			continue
		var source: Vector2 = _student_anchor(initiator) + Vector2(7, -31)
		var destination: Vector2 = _student_anchor(target) + Vector2(-7, -31)
		var path: PackedVector2Array = _interaction_path(source, destination)
		if interaction.status == "active":
			var progress: float = clampf((simulation.elapsed_s - float(interaction.started_at)) / float(interaction.duration_s), 0.0, 1.0)
			var point: Vector2 = _position_on_path(path, progress)
			if interaction.action_id in ["eraser_prank", "use_eraser"]:
				point.y -= sin(progress * PI) * 12.0
			point = point.round()
			next_interactions.append({"interaction_id": interaction.interaction_id, "action_id": interaction.action_id, "initiator_index": initiator, "target_index": target, "progress": progress, "source_position": source, "target_position": destination, "path": path, "pixel_position": point, "delivered": false})
			next_draw_state.append({"interaction_id": interaction.interaction_id, "point": point, "delivered": false})
		elif interaction.status == "completed":
			var age: float = simulation.elapsed_s - float(interaction.finished_at)
			if interaction.action_id == "send_note" and age >= 0.0 and age < DELIVERY_VISUAL_SECONDS:
				next_interactions.append({"interaction_id": interaction.interaction_id, "action_id": interaction.action_id, "initiator_index": initiator, "target_index": target, "progress": 1.0, "source_position": source, "target_position": destination, "pixel_position": destination, "delivered": true})
				next_draw_state.append({"interaction_id": interaction.interaction_id, "point": destination, "delivered": true})
			elif interaction.action_id in ["eraser_prank", "use_eraser"] and age >= 0.0 and age < IMPACT_VISUAL_SECONDS:
				var phase: int = int(age / 0.1) % 2
				next_impacts.append({"interaction_id": interaction.interaction_id, "target_index": target, "age_s": age, "phase": phase})
				next_draw_state.append({"interaction_id": interaction.interaction_id, "target_index": target, "phase": phase})
	for entry in _report_sources:
		var age: float = simulation.elapsed_s - float(entry.elapsed_s)
		var reporter: int = int(entry.student_index)
		var target: int = int(entry.details.target_index)
		if age >= 0.0 and age < REPORT_VISUAL_SECONDS and visual_students[reporter].visible and visual_students[target].visible:
			next_reports.append({"reporter_index": reporter, "target_index": target, "at": entry.elapsed_s})
			next_draw_state.append({"reporter_index": reporter, "target_index": target, "at": entry.elapsed_s})
	visual_interactions = next_interactions
	visual_impacts = next_impacts
	visual_outcomes = next_outcomes
	visual_reports = next_reports
	var changed: bool = next_draw_state != _overlay_draw_state
	_overlay_draw_state = next_draw_state
	return changed


# 连线先于人物和姓名绘制，方向与颜色明确对应发起者，避免遮挡真实状态标签。
func _draw_interaction_paths() -> void:
	for interaction in visual_interactions:
		if not interaction.delivered:
			var color: Color = ACCENTS[int(interaction.initiator_index)]
			color.a = 0.6
			var path: PackedVector2Array = interaction.path
			for index in range(1, path.size()):
				_draw_pixel_line(path[index - 1], path[index], color, true)
	for report in visual_reports:
		var path: PackedVector2Array = _interaction_path(_student_anchor(int(report.reporter_index)) + Vector2(7, -39), _student_anchor(int(report.target_index)) + Vector2(12, -39))
		for index in range(1, path.size()):
			_draw_pixel_line(path[index - 1], path[index], Color("bd6a45"), true)


# 同一列的飞行绕到两列之间的空隙，避免人物姓名把纸条整段遮住。
func _interaction_path(source: Vector2, destination: Vector2) -> PackedVector2Array:
	if absf(source.x - destination.x) < 32.0:
		return PackedVector2Array([source, Vector2(192, source.y), Vector2(192, destination.y), destination])
	return PackedVector2Array([source, destination])


# 沿可见路径按真实进度移动；拐点只影响画面路线，不延长或结算业务动作。
func _position_on_path(path: PackedVector2Array, progress: float) -> Vector2:
	var length: float = 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	var remaining: float = length * progress
	for index in range(1, path.size()):
		var segment_length: float = path[index - 1].distance_to(path[index])
		if remaining <= segment_length:
			return path[index - 1].lerp(path[index], remaining / segment_length)
		remaining -= segment_length
	return path[path.size() - 1]


# 只有纸条与橡皮绘制对应小道具；其他互动用方向符号，不伪造专用动画。
func _draw_interaction_objects() -> void:
	for interaction in visual_interactions:
		var point: Vector2 = interaction.pixel_position
		if interaction.action_id == "send_note":
			_draw_native_rect(Rect2(point - Vector2(5, 3), Vector2(10, 7)), PIXEL_INK)
			_draw_native_rect(Rect2(point - Vector2(4, 2), Vector2(8, 5)), NOTE_COLOR)
			_draw_pixel_line(point + Vector2(-4, -2), point + Vector2(0, 1), Color("c8aa6f"))
			_draw_pixel_line(point + Vector2(0, 1), point + Vector2(3, -2), Color("c8aa6f"))
			if interaction.delivered:
				_draw_pixel_line(point + Vector2(3, 4), point + Vector2(5, 6), Color("4b9163"))
				_draw_pixel_line(point + Vector2(5, 6), point + Vector2(9, 2), Color("4b9163"))
		elif interaction.action_id in ["eraser_prank", "use_eraser"]:
			_draw_native_rect(Rect2(point - Vector2(4, 2), Vector2(8, 5)), PIXEL_INK)
			_draw_native_rect(Rect2(point - Vector2(3, 1), Vector2(4, 3)), ERASER_COLOR)
			_draw_native_rect(Rect2(point + Vector2(1, -1), Vector2(2, 3)), Color("dce7e1"))
			# 手臂只按真实飞行进度展示准备和抛出两段，不靠视觉提前命中。
			var hand: Vector2 = interaction.source_position
			var direction: int = 1 if interaction.target_position.x >= hand.x else -1
			var reach: int = 4 if float(interaction.progress) < 0.25 else 2
			_draw_pixel_line(hand, hand + Vector2(direction * reach, -2), PIXEL_INK)
			_draw_native_rect(Rect2(hand + Vector2(direction * reach, -2), Vector2(2, 2)), Color("e0b68a"))
		else:
			# 箭头仅表示真实发起方向和动作进度，不把协作、邀请或胜负互动画成投掷。
			var marker_direction: Vector2 = (interaction.target_position - interaction.source_position).normalized()
			var along: Vector2 = Vector2(signf(marker_direction.x), 0.0) if absf(marker_direction.x) >= absf(marker_direction.y) else Vector2(0.0, signf(marker_direction.y))
			var across: Vector2 = Vector2(-along.y, along.x)
			_draw_pixel_line(point - along * 4.0, point + along * 4.0, PIXEL_INK)
			_draw_pixel_line(point + along * 4.0, point + across * 3.0, ACCENTS[int(interaction.initiator_index)])
			_draw_pixel_line(point + along * 4.0, point - across * 3.0, ACCENTS[int(interaction.initiator_index)])
	for outcome in visual_outcomes:
		for index in [int(outcome.initiator_index), int(outcome.target_index)]:
			if not visual_students[index].visible:
				continue
			# 同刻连续切换可能产生多条历史，只画该角色最近的一条，避免结果符号叠在一起。
			var recent: Dictionary = _recent_interaction_for_student(index)
			if recent.is_empty() or recent.interaction_id != outcome.interaction_id:
				continue
			var point: Vector2 = _student_anchor(index) + Vector2(18, -48)
			if outcome.status == "interrupted":
				_draw_pixel_line(point + Vector2(-3, -3), point + Vector2(3, 3), Color("bd6b55"))
				_draw_pixel_line(point + Vector2(-3, 3), point + Vector2(3, -3), Color("bd6b55"))
			elif outcome.action_id == "arm_wrestle" and outcome.result.outcome == "tie":
				_draw_pixel_line(point + Vector2(-3, -1), point + Vector2(3, -1), Color("527a88"))
				_draw_pixel_line(point + Vector2(-3, 2), point + Vector2(3, 2), Color("527a88"))
			elif outcome.action_id == "arm_wrestle" and int(outcome.result.loser_index) == index:
				_draw_pixel_line(point + Vector2(-3, -2), point + Vector2(0, 2), Color("bd6b55"))
				_draw_pixel_line(point + Vector2(0, 2), point + Vector2(3, -2), Color("bd6b55"))
			else:
				_draw_pixel_line(point + Vector2(-4, 0), point + Vector2(-1, 3), Color("4b9163"))
				_draw_pixel_line(point + Vector2(-1, 3), point + Vector2(4, -3), Color("4b9163"))
	for impact in visual_impacts:
		var center: Vector2 = _student_anchor(int(impact.target_index)) + Vector2(14, -38)
		var color: Color = Color("e0a347") if int(impact.phase) == 0 else Color("f6d88c")
		_draw_pixel_line(center + Vector2(-4, 0), center + Vector2(4, 0), color)
		_draw_pixel_line(center + Vector2(0, -4), center + Vector2(0, 4), color)
		_draw_pixel_line(center + Vector2(-2, -2), center + Vector2(2, 2), color)
	for report in visual_reports:
		var point: Vector2 = _student_anchor(int(report.target_index)) + Vector2(17, -43)
		_draw_native_rect(Rect2(point - Vector2(1, 1), Vector2(4, 10)), PIXEL_INK)
		_draw_native_rect(Rect2(point, Vector2(2, 5)), Color("e08a67"))
		_draw_native_rect(Rect2(point + Vector2(0, 7), Vector2(2, 1)), Color("e08a67"))


# 只有真实完成的橡皮互动才给目标现有精灵叠加短暂受击色。
func _student_tint(index: int) -> Color:
	for impact in visual_impacts:
		if int(impact.target_index) == index and int(impact.phase) == 0:
			return Color(1.0, 0.72, 0.68)
	return Color.WHITE


# 所有附加图形先在384×256原画网格定位，再扩大为对应整数像素块。
func _draw_native_rect(rectangle: Rect2, color: Color) -> void:
	draw_rect(Rect2(room_origin + rectangle.position * pixel_scale, rectangle.size * pixel_scale), color)


# Bresenham逐像素绘制确保2倍只是原画像素放大，不重新栅格化斜线或产生抗锯齿。
func _draw_pixel_line(from: Vector2, to: Vector2, color: Color, dashed: bool = false) -> void:
	var point := Vector2i(from.round())
	var finish := Vector2i(to.round())
	var distance_x: int = absi(finish.x - point.x)
	var distance_y: int = -absi(finish.y - point.y)
	var step_x: int = 1 if point.x < finish.x else -1
	var step_y: int = 1 if point.y < finish.y else -1
	var error: int = distance_x + distance_y
	var offset: int = 0
	while true:
		if not dashed or offset % 6 < 3:
			_draw_native_rect(Rect2(Vector2(point), Vector2.ONE), color)
		if point == finish:
			break
		var doubled_error: int = 2 * error
		if doubled_error >= distance_y:
			error += distance_y
			point.x += step_x
		if doubled_error <= distance_x:
			error += distance_x
			point.y += step_y
		offset += 1


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


# 真实动作只复用已有坐姿或静态站姿，动作名称始终读取权威配表。
func _pose_name(action_id: String) -> String:
	if action_id in ["standing_study", "chores", "dorm_workout", "dorm_wash"]:
		return "standing"
	if action_id in ["sleep", "rest", "dorm_rest", "lunch_rest"]:
		return "sleep"
	if action_id in ["daydream", "break_rest", "music_class", "eye_exercise", "dorm_game"]:
		return "daydream"
	return "study"


# 只有当前场景的教室坐姿切换现有帧；真实站姿保持静止，空场景不逐帧重绘。
func _animation_frames() -> PackedInt32Array:
	var frames: PackedInt32Array = []
	for index in visual_students.size():
		var student: Dictionary = visual_students[index]
		var duration = 0.9 if student.pose == "sleep" else 0.45
		frames.append((int(animation_seconds / duration + index) % 2 if _rendered_location == "classroom" and student.pose != "standing" else 0) if student.visible else -1)
	return frames


# 场景只接受原画的整数倍画布，窗口管理层负责提供对应的精确尺寸。
func _update_geometry() -> void:
	pixel_scale = int(floor(min(size.x / ROOM_SIZE.x, size.y / ROOM_SIZE.y)))
	assert(pixel_scale >= 1, "校园场景画布不得小于384×256原画")
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
	var student_index: int = -1
	for index in simulation.students.size():
		if simulation.students[index].id == student.id:
			student_index = index
			break
	assert(student_index >= 0, "场景角色必须属于当前权威班级")
	var location: String = simulation.student_location(student_index)
	assert(LOCATION_NAMES.has(location), "未知动作场景：" + location)
	return LOCATION_NAMES[location]


# 人物、姓名、命中和互动共用同一原画脚点，避免换背景后仍点到旧教室座位。
func _student_anchor(index: int) -> Vector2:
	return CampusSceneRenderer.student_anchor(_rendered_location, index)


# 左键查看角色或课表；右键只请求其他同学的互动菜单，不改变当前查看对象。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_update_geometry()
		var context_index = _student_at(event.position)
		if context_index > 0:
			student_context_requested.emit(context_index, event.position)
			accept_event()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_update_geometry()
		if _rendered_location == "classroom" and BLACKBOARD_RECT.has_point((event.position - room_origin) / pixel_scale):
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


# 命中同时覆盖当前真实人物与下方标签，离场角色只能经根界面名单查看。
func _student_at(position_value: Vector2) -> int:
	for index in visual_students.size():
		if not visual_students[index].visible:
			continue
		var foot: Vector2 = room_origin + _student_anchor(index) * pixel_scale
		var hit = Rect2(foot - Vector2(34, 44) * pixel_scale, Vector2(68 * pixel_scale, 44 * pixel_scale + 36))
		if hit.has_point(position_value):
			return index
	return -1


# 黑板与人物提供准确的查看提示，空地不会显示不存在的游戏命令。
func _get_tooltip(at_position: Vector2) -> String:
	_update_geometry()
	if _rendered_location == "classroom" and BLACKBOARD_RECT.has_point((at_position - room_origin) / pixel_scale):
		return "查看当天课表"
	var index = _student_at(at_position)
	if index >= 0 and not visual_students.is_empty():
		var student: Dictionary = visual_students[index]
		var tooltip: String = "%s\n%s · %s" % [student.name, student.location, student.action]
		var action: Dictionary = simulation.students[index].current_action
		if not action.is_empty() and simulation.config.actions[action.action_id].knowledge_source == "dorm":
			tooltip += "\n%s · 已获%.2f知识" % [simulation.config.subjects[action.subject_id].name, action.knowledge_gain]
		if not String(student.interaction).is_empty():
			tooltip += "\n" + String(student.interaction)
		var recent: Dictionary = _recent_interaction_for_student(index)
		if not recent.is_empty():
			tooltip += "\n最近互动：" + _interaction_outcome_summary(recent)
		for instance in simulation.students[index].buffs:
			tooltip += "\n状态：" + String(simulation.config.buffs[instance.buff_id].name)
			if simulation.config.buffs[instance.buff_id].knowledge_redirect == "selected_subject":
				tooltip += " → " + String(simulation.config.subjects[instance.selected_subject_id].name)
			if instance.expires_at != null:
				tooltip += "（剩余%d秒）" % ceili(float(instance.expires_at) - simulation.elapsed_s)
		if index > 0:
			tooltip += "\n右键互动"
		return tooltip
	return ""
