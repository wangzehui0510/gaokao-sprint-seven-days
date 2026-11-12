extends SceneTree

# 场景验收只实例化真实配表、行为树和画面，不读取或写入正式存档。
var checks: int = 0
var failures: Array[String] = []
var selected_events: Array[int] = []
# 右键只记录真实入口传出的对象与控件局部坐标。
var context_events: Array[Dictionary] = []
var blackboard_events: int = 0


# 场景树就绪后再建立真实教室控件与单人班级。
func _initialize() -> void:
	call_deferred("_run")


# 验证桌面画面状态、整数缩放、点击目标和动画节流的真实生产入口。
func _run() -> void:
	var configuration := GameConfig.new()
	_check(configuration.load_file() == OK, "读取正式配表")
	var simulation := ClassroomSimulation.new()
	_check(simulation.setup(configuration, 41) == OK, "建立独立真实状态")
	var behavior := ClassroomBehaviorController.new()
	root.add_child(behavior)
	behavior.setup(simulation)
	simulation.decision_handler = behavior.decide
	_check(simulation.set_debug_time(1, 28800.0) == OK, "进入上课时间")
	_check(simulation.advance(0.0) == OK, "真实行为树选择上课动作")
	var room := ClassroomView.new()
	room.size = Vector2(384, 256)
	root.add_child(room)
	room.set_process(false)
	room.bind_game(simulation)
	_check(room.visual_students.size() == 4, "呈现四名真实同学")
	_check(room.name_labels[0].text == "我", "自己有清楚姓名标记")
	_check(room.visual_students[0].status == configuration.actions[String(simulation.students[0].current_action.action_id)].name, "状态来自当前权威动作")
	room._update_geometry()
	_check(room.pixel_scale == 1 and room.room_origin == Vector2.ZERO, "384x256按1倍绘制")
	room.size = Vector2(768, 512)
	room._update_geometry()
	_check(room.pixel_scale == 2 and room.room_origin == Vector2.ZERO, "768x512按2倍绘制")
	room.size = Vector2(384, 256)
	room._update_geometry()
	room.student_selected.connect(func(index: int): selected_events.append(index))
	room.student_context_requested.connect(func(index: int, local_position: Vector2): context_events.append({"index": index, "position": local_position}))
	room.blackboard_selected.connect(func(): blackboard_events += 1)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = Vector2(272, 220)
	room._gui_input(event)
	_check(selected_events == [3] and room.selected_index == 3, "点击角色只选择对应同学")
	event.position = Vector2(170, 20)
	room._gui_input(event)
	_check(blackboard_events == 1, "黑板真实边界发出课表入口")
	_check(room._get_tooltip(Vector2(170, 20)) == "查看当天课表", "黑板提示准确")
	_check(room._get_tooltip(Vector2(272, 220)).contains("小周"), "角色提示保留完整姓名")
	_check(room._get_tooltip(Vector2(272, 220)).contains("右键互动"), "其他同学提示提供右键互动入口")
	_check(not room._get_tooltip(Vector2(112, 140)).contains("右键互动"), "自己不显示右键互动提示")
	event.button_index = MOUSE_BUTTON_RIGHT
	event.position = Vector2(272, 120)
	room._gui_input(event)
	_check(context_events == [{"index": 1, "position": Vector2(272, 120)}], "右键其他同学人物发出准确目标和局部坐标")
	_check(room.selected_index == 3 and selected_events == [3] and blackboard_events == 1, "右键互动不改变详情选中或触发左键入口")
	event.position = Vector2(112, 248)
	room._gui_input(event)
	_check(context_events.size() == 2 and context_events[1] == {"index": 2, "position": Vector2(112, 248)}, "右键其他同学下方姓名座位区域可互动")
	for ignored_position in [Vector2(112, 120), Vector2(30, 210), Vector2(170, 20)]:
		event.position = ignored_position
		room._gui_input(event)
	_check(context_events.size() == 2 and blackboard_events == 1, "右键自己空地与黑板不请求互动或课表")
	event.position = Vector2(272, 120)
	event.pressed = false
	room._gui_input(event)
	_check(context_events.size() == 2, "右键松开不重复请求互动")
	room.size = Vector2(800, 560)
	room._update_geometry()
	event.position = Vector2(560, 304)
	event.pressed = true
	room._gui_input(event)
	_check(room.pixel_scale == 2 and room.room_origin == Vector2(16, 24), "两倍居中画面采用真实缩放偏移")
	_check(context_events.size() == 3 and context_events[2] == {"index": 1, "position": Vector2(560, 304)}, "两倍画面右键传出原始控件局部坐标")
	_check(room.selected_index == 3 and selected_events == [3], "两倍右键同样不切换角色详情")
	room.size = Vector2(384, 256)
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = Vector2(112, 220)
	room._gui_input(event)
	_check(selected_events == [3, 2] and room.selected_index == 2 and context_events.size() == 3, "右键请求后左键仍能正常查看其他同学")
	event.position = Vector2(170, 20)
	room._gui_input(event)
	_check(blackboard_events == 2 and context_events.size() == 3, "右键请求后左键黑板仍只打开课表")
	var first_frames: PackedInt32Array = room.rendered_frames.duplicate()
	room._process(0.1)
	_check(room.rendered_frames == first_frames, "未跨动画帧时保留帧缓存")
	room._process(0.45)
	_check(room.rendered_frames != first_frames, "跨真实动画时长切换帧")
	room.set_animation_enabled(false)
	_check(not room.is_processing(), "隐藏时关闭画面帧回调")
	var previous_elapsed: float = simulation.elapsed_s
	_check(simulation.advance(10.0) == OK and simulation.elapsed_s > previous_elapsed, "画面停用不阻断核心在线推进")
	room.set_animation_enabled(true)
	_check(room.is_processing(), "恢复窗口重新启用画面帧")
	room.set_process(false)
	_check(simulation.set_debug_time(1, 77400.0) == OK, "切换到真实晚间课表")
	_check(simulation.advance(0.0) == OK, "真实行为树选择宿舍活动")
	room.refresh_state()
	_check(room.visual_students[0].location == "宿舍" and not room.visual_students[0].in_room, "离开教室只显示真实去向")
	_check(room.rendered_frames == PackedInt32Array([-1, -1, -1, -1]), "全班离开后不保留虚假坐姿帧")
	# 飘字是纯视觉提示：展示期间保留，寿命耗尽后由帧回调移除，不改变任何业务状态。
	room.show_floating_text("已获得属性点+1")
	_check(room.floating_texts.size() == 1 and String(room.floating_texts[0].text) == "已获得属性点+1", "发点飘字进入真实绘制队列")
	room._process(1.0)
	_check(room.floating_texts.size() == 1, "寿命未耗尽的飘字继续展示")
	room._process(3.0)
	_check(room.floating_texts.is_empty(), "飘字寿命耗尽后自动移除")
	room.free()
	behavior.free()
	if failures.is_empty():
		print("DESKTOP_CLASSROOM_VIEW_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


# 断言失败保留原因并以非零退出码汇总，不伪造验证成功。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
