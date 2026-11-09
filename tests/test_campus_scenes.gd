extends SceneTree
## 四场景只使用真实配置、行为树与动作入口，不读取或写入正式存档。

var checks: int = 0
var failures: Array[String] = []
var configuration: GameConfig
var blackboard_events: int = 0
var context_events: Array[int] = []


## 等待场景树可用后创建独立班级，依赖编译失败必须明确退出。
func _initialize() -> void:
	call_deferred("_run")


## 场景切换、真实地点分散、命中和互动都必须经过实际生产入口验收。
func _run() -> void:
	for dependency in ["res://scripts/core/classroom_simulation.gd", "res://scripts/ui/classroom_view.gd", "res://scripts/ui/campus_scene_renderer.gd"]:
		var script: Script = load(dependency)
		if script == null or not script.can_instantiate():
			_check(false, "校园场景依赖无法实例化：" + dependency)
			_finish()
			return
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "载入真实场景配表"):
		_finish()
		return
	_test_timetable_locations()
	_test_individual_locations()
	_test_new_personal_actions()
	_test_real_scene_interactions()
	_test_hidden_follow()
	_test_final_scene()
	_finish()


## 每个场景只定位开发时钟，动作和地点仍由真实共享行为树选择。
func _fixture(seconds: float, seed_value: int = 261107) -> Dictionary:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, seed_value), "建立独立真实校园局"):
		return {}
	var behavior := ClassroomBehaviorController.new()
	root.add_child(behavior)
	behavior.setup(simulation)
	simulation.decision_handler = behavior.decide
	if not _result(simulation.set_debug_time(1, seconds), "定位真实课表") or not _result(simulation.advance(0.0), "行为树选择真实活动"):
		behavior.free()
		return {}
	var room := ClassroomView.new()
	room.size = Vector2(384, 256)
	root.add_child(room)
	room.set_process(false)
	room.bind_game(simulation)
	return {"simulation": simulation, "behavior": behavior, "room": room}


## 覆盖早课、课间操、午餐、午休、体育与晚间，不从课程名推测全班位置。
func _test_timetable_locations() -> void:
	var cases: Array[Dictionary] = [
		{"time": 28800.0, "location": "classroom"},
		{"time": 34800.0, "location": "playground"},
		{"time": 42000.0, "location": "canteen"},
		{"time": 42600.0, "location": "dorm"},
		{"time": 50400.0, "location": "playground"},
		{"time": 77400.0, "location": "dorm"},
	]
	for scenario in cases:
		var fixture: Dictionary = _fixture(scenario.time)
		if fixture.is_empty():
			continue
		var simulation: ClassroomSimulation = fixture.simulation
		var room: ClassroomView = fixture.room
		_check(room.get_view_mode() == "classroom", "直接创建视图默认固定教室，兼容旧接入")
		room.set_view_location("auto")
		_check(room.get_view_mode() == "auto" and room.get_view_location() == scenario.location, "自动镜头遵循玩家真实地点")
		var before: Dictionary = _snapshot(simulation)
		for location: String in ClassroomView.LOCATION_NAMES:
			room.set_view_location(location)
			_check(room.get_view_location() == location, "手动镜头准确切到" + location)
			room._update_geometry()
			for index in 4:
				var here: bool = simulation.student_location(index) == location
				_check(room.visual_students[index].visible == here, "只呈现真实位于当前场景的角色")
				_check(room.name_labels[index].visible == here and room.status_labels[index].visible == here, "姓名和状态与人物一同显示或隐藏")
				var anchor: Vector2 = CampusSceneRenderer.student_anchor(location, index)
				_check(room._student_at(anchor) == (index if here else -1), "脚点命中与真实可见性一致")
				if here:
					var action: Dictionary = simulation.students[index].current_action
					var expected_status: String = String(configuration.actions[action.action_id].name)
					# 产知识宿舍活动必须显示权威实例科目，其他活动仍只显示真实动作名。
					if configuration.actions[action.action_id].knowledge_source == "dorm":
						expected_status += " · " + String(configuration.subjects[action.subject_id].name)
					_check(room.visual_students[index].status == expected_status, "可见角色显示真实动作名及宿舍知识科目")
			_check(room._get_tooltip(Vector2(170, 20)) == ("查看当天课表" if location == "classroom" else ""), "只有教室保留黑板入口提示")
			for scale_value in [1, 2]:
				room.size = Vector2(384, 256) * scale_value
				room._update_geometry()
				_check(room.pixel_scale == scale_value and room.room_origin == Vector2.ZERO, "四场景都采用原画整数缩放")
				for index in 4:
					var expected: int = index if simulation.student_location(index) == location else -1
					_check(room._student_at(CampusSceneRenderer.student_anchor(location, index) * scale_value) == expected, "1x/2x命中使用相同原画脚点")
			room.size = Vector2(384, 256)
		room._process(200.0)
		_check(_snapshot(simulation) == before, "观察四场景和播放画面不能改时间、资源、随机流、日志或榜单")
		_free(fixture)


## 体育中独立睡觉仍留教室，不能把真实分散的同学整班搬去操场。
func _test_individual_locations() -> void:
	var fixture: Dictionary = _fixture(50400.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	_check(_result(simulation.start_action(1, "sleep", false), "体育时通过真实入口让小林睡觉"), "独立睡觉入口完整返回")
	_check(simulation.student_location(0) == "playground" and simulation.student_location(1) == "classroom", "真实动作配置允许人物分处教室与操场")
	room.blackboard_selected.connect(func(): blackboard_events += 1)
	room.student_context_requested.connect(func(index: int, _position: Vector2): context_events.append(index))
	var event := InputEventMouseButton.new()
	event.pressed = true
	event.button_index = MOUSE_BUTTON_RIGHT
	room.set_view_location("playground")
	room._update_geometry()
	event.position = CampusSceneRenderer.student_anchor("playground", 1)
	room._gui_input(event)
	_check(context_events.is_empty() and room._get_tooltip(event.position).is_empty(), "不在当前场景的人物不可右键，空位没有幽灵提示")
	event.position = CampusSceneRenderer.student_anchor("playground", 2)
	room._gui_input(event)
	_check(context_events == [2], "当前操场中的真实同学可请求右键互动")
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = Vector2(170, 20)
	room._gui_input(event)
	_check(blackboard_events == 0, "操场旧黑板坐标不会打开课表")
	room.set_view_location("classroom")
	event.button_index = MOUSE_BUTTON_RIGHT
	event.position = CampusSceneRenderer.student_anchor("classroom", 1)
	room._gui_input(event)
	_check(context_events == [2, 1], "固定教室可右键仍在教室睡觉的真实同学")
	_check(not room.name_labels[0].visible and room.name_labels[1].visible, "人物分散时只保留当前场景标签")
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = Vector2(170, 20)
	room._gui_input(event)
	_check(blackboard_events == 1, "切回教室后恢复真实黑板入口")
	room.set_view_location("auto")
	_check(room.get_view_location() == "playground", "观察别人后自动模式仍跟随玩家")
	var before: Dictionary = _snapshot(simulation)
	room.selected_index = 1
	room.refresh_state()
	_check(room.get_view_location() == "playground" and _snapshot(simulation) == before, "详情选择不自动改玩家位置或镜头模式")
	_free(fixture)


## 新增个人动作真实启动后只读呈现名称与地点，物品前置来自真实课程抽奖。
func _test_new_personal_actions() -> void:
	var cases: Array[Dictionary] = [
		{"id": "snack_self", "seed": 1, "item": "snack"},
		{"id": "lunch_rest"},
		{"id": "read_comic"},
		{"id": "bathroom"},
		{"id": "linger_break"},
		{"id": "sprint_study"},
		{"id": "preview"},
		{"id": "notes"},
		{"id": "self_test"},
		{"id": "standing_study"},
		{"id": "chores"},
		{"id": "exercise_slack"},
		{"id": "remind_self"},
		{"id": "wake_self"},
		{"id": "recall_classroom"},
		{"id": "read_comic_item", "seed": 2, "item": "comic"},
		{"id": "eat_candy_item", "seed": 6, "item": "candy"},
	]
	for scenario: Dictionary in cases:
		var fixture: Dictionary = _fixture(28800.0, int(scenario.get("seed", 261107)))
		if fixture.is_empty():
			continue
		var simulation: ClassroomSimulation = fixture.simulation
		var room: ClassroomView = fixture.room
		if scenario.has("item"):
			_check(int(simulation.students[0].inventory.get(scenario.item, 0)) > 0, "动作物品来自真实课程抽奖：" + scenario.id)
		if not _result(simulation.start_action(0, scenario.id), "真实启动场景个人动作：" + scenario.id):
			_free(fixture)
			continue
		var before: Dictionary = _snapshot(simulation)
		room.set_view_location("auto")
		_check(room.get_view_location() == simulation.student_location(0), "新增动作镜头跟随真实地点：" + scenario.id)
		_check(room.visual_students[0].visible and room.visual_students[0].status == configuration.actions[scenario.id].name, "场景显示实际动作名称：" + scenario.id)
		if scenario.id in ["standing_study", "chores"]:
			_check(room.visual_students[0].pose == "standing" and room.rendered_frames[0] == 0, "站立类动作使用已有静态站姿：" + scenario.id)
			room._process(0.7)
			_check(room.rendered_frames[0] == 0, "静态站姿不冒充清扫或走动动画：" + scenario.id)
		elif scenario.id == "lunch_rest":
			_check(room.visual_students[0].pose == "sleep", "午间休息复用已有休息坐姿")
		for location: String in ClassroomView.LOCATION_NAMES:
			room.set_view_location(location)
			room._update_geometry()
			var expected: int = 0 if simulation.student_location(0) == location else -1
			_check(room._student_at(CampusSceneRenderer.student_anchor(location, 0)) == expected, "新动作换镜头只命中真实所在地点：" + scenario.id)
		_check(_snapshot(simulation) == before, "新增动作的观察与动画不能旁路修改业务状态：" + scenario.id)
		_free(fixture)


## 食堂与宿舍纸条沿同场景真实脚点绘制，换镜头不会伪造送达。
func _test_real_scene_interactions() -> void:
	for seconds in [42000.0, 77400.0]:
		var fixture: Dictionary = _fixture(seconds)
		if fixture.is_empty():
			continue
		var simulation: ClassroomSimulation = fixture.simulation
		var room: ClassroomView = fixture.room
		room.set_view_location("auto")
		var location: String = room.get_view_location()
		if not _result(simulation.start_interaction(0, 2, "send_note", "真实校园纸条"), "教室外真实纸条开始"):
			_free(fixture)
			continue
		var interaction: Dictionary = simulation.interactions.back()
		room.refresh_state()
		_check(room.visual_interactions.size() == 1 and not room.visual_interactions[0].delivered, "当前真实场景呈现在途纸条")
		_check(room.visual_interactions[0].source_position == CampusSceneRenderer.student_anchor(location, 0) + Vector2(7, -31), "纸条起点与当前场景人物脚点一致")
		_check(room._get_tooltip(CampusSceneRenderer.student_anchor(location, 0)).contains("尚未送达"), "同场景提示仍保留真实在途语义")
		room.set_view_location("classroom")
		_check(room.visual_interactions.is_empty() and room._student_at(ClassroomView.SEATS[0]) == -1, "切到空教室不残留异地人物与飞行")
		room.set_view_location("auto")
		_check(_result(simulation.advance(float(interaction.duration_s)), "真实执行完成教室外纸条"), "教室外动作完整执行")
		room.refresh_state()
		_check(interaction.status == "completed" and room.visual_interactions.size() == 1 and room.visual_interactions[0].delivered, "只有权威完成记录才能绘制送达")
		_free(fixture)


## 隐藏期间仍由唯一执行器跨时段，恢复后直达当前真实场景，不补播过去动画。
func _test_hidden_follow() -> void:
	var fixture: Dictionary = _fixture(41990.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	room.set_view_location("auto")
	room.set_animation_enabled(false)
	var animation_before: float = room.animation_seconds
	_check(_result(simulation.advance(40.0), "隐藏期间跨午餐边界"), "真实跨时段完整返回")
	room._process(100.0)
	_check(room.animation_seconds == animation_before, "隐藏只停止视觉动画时钟")
	room.set_animation_enabled(true)
	room.set_process(false)
	_check(room.get_view_location() == simulation.student_location(0) and room.get_view_location() == "canteen", "恢复后自动镜头直接读取当前权威食堂地点")
	_check(room.visual_students.all(func(student: Dictionary) -> bool: return student.visible), "恢复后的四人可见性与当前食堂一致")
	_free(fixture)


## 本局结束只保留真实最终地点与只读画面，切镜头不会复活动作。
func _test_final_scene() -> void:
	var fixture: Dictionary = _fixture(28800.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	if not _result(simulation.set_debug_time(7, 59999.0), "定位真实末日终局前") or not _result(simulation.advance(1.0), "执行至权威终局"):
		_free(fixture)
		return
	_check(simulation.is_round_finished(), "七天局真实结束")
	var before: Dictionary = _snapshot(simulation)
	room.set_view_location("auto")
	for location: String in ClassroomView.LOCATION_NAMES:
		room.set_view_location(location)
		room.refresh_state()
		for student: Dictionary in room.visual_students:
			if student.visible:
				_check(student.status == "本局已结束", "终局场景中的真实人物明确显示本局已结束")
	_check(simulation.students.all(func(student: Dictionary) -> bool: return student.current_action.is_empty()), "终局换镜头不恢复已停止动作")
	_check(_snapshot(simulation) == before, "终局查四处场景不改历史和人物")
	_free(fixture)


## 深拷贝所有业务来源并保留随机流，验证画面没有旁路写入。
func _snapshot(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"day": simulation.day, "seconds": simulation.clock_seconds, "elapsed": simulation.elapsed_s,
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true),
		"rng_seed": str(simulation.rng.seed), "rng_state": str(simulation.rng.state),
		"round": simulation.get_round_summary(), "final": simulation.get_final_board(),
	}


## 只释放当前夹具，不操作正式场景和用户目录。
func _free(fixture: Dictionary) -> void:
	fixture.room.free()
	fixture.behavior.free()


## 生产入口失败记录真实错误并让调用方结束当前场景。
func _result(result: Error, message: String) -> bool:
	_check(result == OK, "%s，错误码%s" % [message, result] if result != OK else message)
	return result == OK


## 记录实际执行断言，退出结果由全部失败汇总决定。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 明确输出失败和非零退出码，不让脚本中途失败假装验收通过。
func _finish() -> void:
	if failures.is_empty():
		print("CAMPUS_SCENES_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("CAMPUS_SCENES_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
