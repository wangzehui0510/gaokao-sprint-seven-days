extends SceneTree

# 场景验收只实例化真实配表、行为树和画面，不读取或写入正式存档。
var checks: int = 0
var failures: Array[String] = []
var selected_events: Array[int] = []
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
