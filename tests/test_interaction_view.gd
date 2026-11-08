extends SceneTree

# 只创建独立真实模拟器和画面，不启动正式主场景、不读取或写入玩家存档。
var checks: int = 0
var failures: Array[String] = []
var configuration: GameConfig


# 等待场景树就绪后验收互动视觉，所有动作结果都必须由生产执行器产生。
func _initialize() -> void:
	call_deferred("_run")


# 逐项验证真实进度、完成与打断、隐藏恢复、举报记录及教室外的正确去向。
func _run() -> void:
	# 依赖脚本编译失败时提前判为失败，不能让构造器中断后跳过所有场景却打印PASS。
	for dependency in ["res://scripts/core/classroom_simulation.gd", "res://scripts/ai/classroom_behavior_controller.gd", "res://scripts/ui/classroom_view.gd"]:
		var script: Script = load(dependency)
		if script == null or not script.can_instantiate():
			_check(false, "互动视图依赖无法实例化：" + dependency)
			_finish()
			return
	configuration = GameConfig.new()
	if not _check_result(configuration.load_file(), "载入正式配表", configuration.error_message):
		_finish()
		return
	_test_note_progress_and_delivery()
	_test_interrupted_note()
	_test_eraser_impact()
	_test_report_and_hidden_expiry()
	_test_report_partner_interrupts_note()
	_test_hidden_completion()
	_test_interaction_outside_classroom()
	_finish()


# 真实共享树建立四个独立角色，测试只改变开发时钟，不替换互动或结算逻辑。
func _make_fixture() -> Dictionary:
	var simulation := ClassroomSimulation.new()
	if not _check_result(simulation.setup(configuration, 517), "建立互动场景独立局", simulation.error_message):
		return {}
	var behavior := ClassroomBehaviorController.new()
	root.add_child(behavior)
	behavior.setup(simulation)
	simulation.decision_handler = behavior.decide
	if not _check_result(simulation.set_debug_time(1, 28800.0), "场景进入真实早课", simulation.error_message):
		behavior.free()
		return {}
	if not _check_result(simulation.advance(0.0), "四人按真实课表开始动作", simulation.error_message):
		behavior.free()
		return {}
	var room := ClassroomView.new()
	room.size = Vector2(384, 256)
	root.add_child(room)
	room.set_process(false)
	room.bind_game(simulation)
	return {"simulation": simulation, "behavior": behavior, "room": room}


# 纸条只有生产记录完成后才出现送达标记，视觉时钟无法提前推动它。
func _test_note_progress_and_delivery() -> void:
	var fixture: Dictionary = _make_fixture()
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	var body: String = "只有完成后才能收到的测试纸条"
	if not _check_result(simulation.start_interaction(0, 1, "send_note", body), "通过真实入口向小林传纸条", simulation.error_message):
		_free_fixture(fixture)
		return
	var interaction: Dictionary = simulation.interactions.back()
	room.refresh_state()
	_check(room.visual_interactions.size() == 1 and not room.visual_interactions[0].delivered, "活动纸条显示在途且没有送达标记")
	_check(room.visual_students[0].status.contains("→ 小林") and room.visual_students[1].status.contains("← 我"), "两端状态标明真实参与方向")
	var tooltip: String = room._get_tooltip(Vector2(112, 120))
	_check(tooltip.contains("我 → 小林") and tooltip.contains("尚未送达") and not tooltip.contains(body), "场景提示关系和未送达，不提前泄露正文")
	if not _check_result(simulation.advance(5.0), "权威执行器推进纸条五秒", simulation.error_message):
		_free_fixture(fixture)
		return
	room.refresh_state()
	var display: Dictionary = room.visual_interactions[0]
	_check(is_equal_approx(display.progress, 5.0 / float(interaction.duration_s)), "飞行比例取真实动作时间")
	_check(display.pixel_position != display.source_position and display.pixel_position == display.pixel_position.round(), "纸条移动且保持原画像素网格")
	var real_elapsed: float = simulation.elapsed_s
	var real_record: Dictionary = interaction.duplicate(true)
	var old_focus: float = simulation.students[0].focus
	var old_position: Vector2 = display.pixel_position
	room._process(200.0)
	_check(is_equal_approx(simulation.elapsed_s, real_elapsed) and interaction == real_record and is_equal_approx(simulation.students[0].focus, old_focus), "画面帧不能推进动作、改资源或伪造送达")
	_check(room.visual_interactions[0].pixel_position == old_position and not room.visual_interactions[0].delivered, "动画秒数增加不会让纸条越过真实进度")
	room.size = Vector2(768, 512)
	room._update_geometry()
	_check(room.pixel_scale == 2 and room.room_origin == Vector2.ZERO and room.visual_interactions[0].pixel_position == old_position, "二倍画布只扩大原画像素，不重算飞行进度")
	if not _check_result(simulation.advance(float(interaction.ends_at) - simulation.elapsed_s), "真实执行到纸条结束边界", simulation.error_message):
		_free_fixture(fixture)
		return
	room.refresh_state()
	_check(interaction.status == "completed" and room.visual_interactions.size() == 1 and room.visual_interactions[0].delivered, "完成记录才允许显示纸条送达")
	_check(room.visual_impacts.is_empty(), "纸条完成不会冒充橡皮受击")
	_check_result(simulation.advance(ClassroomView.DELIVERY_VISUAL_SECONDS + 0.1), "继续真实时间清除送达短提示", simulation.error_message)
	room.refresh_state()
	_check(room.visual_interactions.is_empty(), "旧送达提示到期后消失")
	_free_fixture(fixture)


# 主动打断走真实动作切换入口，画面不能把未送达纸条画成收件成功。
func _test_interrupted_note() -> void:
	var fixture: Dictionary = _make_fixture()
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	if not _check_result(simulation.start_interaction(0, 2, "send_note", "将被真实打断"), "建立向小陈的纸条", simulation.error_message):
		_free_fixture(fixture)
		return
	var interaction: Dictionary = simulation.interactions.back()
	_check_result(simulation.advance(3.0), "推进尚未完成的纸条", simulation.error_message)
	_check_result(simulation.start_action(0, "rest", false), "真实休息指令打断互动", simulation.error_message)
	room.refresh_state()
	_check(interaction.status == "interrupted" and room.visual_interactions.is_empty(), "打断记录不产生飞行或送达残影")
	_check(room.visual_impacts.is_empty() and not room.visual_students[0].status.contains("→"), "打断后恢复真实状态且没有虚假受击")
	_free_fixture(fixture)


# 橡皮在真实执行期间飞行，只有完成记录才给正确目标短暂受击色与星点。
func _test_eraser_impact() -> void:
	var fixture: Dictionary = _make_fixture()
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	if not _check_result(simulation.start_interaction(0, 3, "eraser_prank"), "真实发动朝小周弹橡皮", simulation.error_message):
		_free_fixture(fixture)
		return
	var interaction: Dictionary = simulation.interactions.back()
	_check_result(simulation.advance(float(interaction.duration_s) * 0.5), "橡皮执行至一半", simulation.error_message)
	room.refresh_state()
	var display: Dictionary = room.visual_interactions[0]
	_check(display.action_id == "eraser_prank" and display.target_index == 3 and is_equal_approx(display.progress, 0.5), "橡皮使用真实目标及半程进度")
	_check(display.pixel_position.y < display.source_position.lerp(display.target_position, 0.5).y and display.pixel_position == display.pixel_position.round(), "橡皮弧线仍落在原画像素网格")
	_check(room.visual_impacts.is_empty() and room._student_tint(3) == Color.WHITE, "执行中不提前出现命中与受击色")
	_check_result(simulation.advance(float(interaction.ends_at) - simulation.elapsed_s), "橡皮到达真实完成边界", simulation.error_message)
	room.refresh_state()
	_check(interaction.status == "completed" and room.visual_interactions.is_empty(), "橡皮完成后不再显示在途物体")
	_check(room.visual_impacts.size() == 1 and room.visual_impacts[0].target_index == 3 and room._student_tint(3) != Color.WHITE, "受击只叠加到真实目标")
	_check(room._student_tint(0) == Color.WHITE and room._student_tint(1) == Color.WHITE, "发起者和旁观者不冒充受击")
	var first_phase: int = room.visual_impacts[0].phase
	room._process(9.0)
	_check(room.visual_impacts[0].phase == first_phase, "受击相位不会被独立画面秒数推进")
	_check_result(simulation.advance(ClassroomView.IMPACT_VISUAL_SECONDS + 0.1), "真实时间经过受击提示期限", simulation.error_message)
	room.refresh_state()
	_check(room.visual_impacts.is_empty() and room._student_tint(3) == Color.WHITE, "受击结束后恢复原有角色素材颜色")
	_free_fixture(fixture)


# 举报标记只来自真实举报日志；隐藏期间经过的旧举报在恢复时不能重播。
func _test_report_and_hidden_expiry() -> void:
	var fixture: Dictionary = _make_fixture()
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	_check_result(simulation.start_action(1, "daydream", false), "小林真实进入可举报开小差", simulation.error_message)
	var violation: Dictionary = simulation.get_open_violation(1)
	_check(not violation.is_empty(), "真实开小差形成待处理违纪")
	if violation.is_empty():
		_free_fixture(fixture)
		return
	if not _check_result(simulation.report_violation(1, violation.violation_id), "通过生产举报入口处理小林", simulation.error_message):
		_free_fixture(fixture)
		return
	room.refresh_state()
	_check(room.visual_reports.size() == 1 and room.visual_reports[0].reporter_index == 0 and room.visual_reports[0].target_index == 1, "举报视觉读取日志中的真实双方")
	_check(simulation.logs.any(func(entry: Dictionary) -> bool: return entry.type == "report" and entry.details.target_index == 1), "举报提示可追溯到真实日志")
	room.set_animation_enabled(false)
	var animation_before: float = room.animation_seconds
	_check_result(simulation.advance(ClassroomView.REPORT_VISUAL_SECONDS + 0.2), "隐藏时真实模拟器继续前进", simulation.error_message)
	room._process(100.0)
	_check(not room.is_processing() and is_equal_approx(room.animation_seconds, animation_before), "隐藏关闭视觉回调及独立动画计时")
	room.set_animation_enabled(true)
	_check(room.visual_reports.is_empty(), "恢复直接读取现在，不重播隐藏期间过期的举报")
	_free_fixture(fixture)


# 已确认的搭档举报会结束原互动；画面只显示真实举报，不补送未完成纸条。
func _test_report_partner_interrupts_note() -> void:
	var fixture: Dictionary = _make_fixture()
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	if not _check_result(simulation.start_interaction(0, 1, "send_note", "搭档举报后不得送达"), "建立将被搭档举报打断的纸条", simulation.error_message):
		_free_fixture(fixture)
		return
	var interaction: Dictionary = simulation.interactions.back()
	_check_result(simulation.advance(3.0), "纸条真实执行三秒尚未送达", simulation.error_message)
	var violation: Dictionary = simulation.get_open_violation(1)
	_check(not violation.is_empty(), "搭档存在真实待处理违纪")
	if violation.is_empty():
		_free_fixture(fixture)
		return
	if not _check_result(simulation.report_violation(1, violation.violation_id), "真实举报当前纸条搭档", simulation.error_message):
		_free_fixture(fixture)
		return
	room.refresh_state()
	_check(interaction.status == "interrupted" and room.visual_interactions.is_empty(), "举报搭档后原纸条消失且没有送达标记")
	_check(room.visual_reports.size() == 1 and room.visual_reports[0].target_index == 1, "搭档举报显示真实日志目标")
	_check(not room.visual_students[0].status.contains("→") and not room.visual_students[1].status.contains("←"), "双方结束互动后场景不残留参与箭头")
	_free_fixture(fixture)


# 隐藏不会阻止真实互动完成，恢复时也不为早已完成的动作补一段假飞行。
func _test_hidden_completion() -> void:
	var fixture: Dictionary = _make_fixture()
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	if not _check_result(simulation.start_interaction(0, 1, "eraser_prank"), "建立即将隐藏的真实橡皮动作", simulation.error_message):
		_free_fixture(fixture)
		return
	var interaction: Dictionary = simulation.interactions.back()
	room.refresh_state()
	room.set_animation_enabled(false)
	_check_result(simulation.advance(float(interaction.duration_s) + 2.0), "隐藏期间执行器完成橡皮并继续运行", simulation.error_message)
	_check(interaction.status == "completed", "隐藏画面不暂停真实互动")
	room.set_animation_enabled(true)
	_check(room.visual_interactions.is_empty() and room.visual_impacts.is_empty(), "恢复不重播过去的橡皮飞行和命中")
	_free_fixture(fixture)


# 允许的教室外纸条只呈现真实去向，不把宿舍互动硬画在教室空座位之间。
func _test_interaction_outside_classroom() -> void:
	var fixture: Dictionary = _make_fixture()
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: ClassroomView = fixture.room
	_check_result(simulation.set_debug_time(1, 77400.0), "转入真实宿舍时段", simulation.error_message)
	_check_result(simulation.advance(0.0), "四人按真实时段离开教室", simulation.error_message)
	if not _check_result(simulation.start_interaction(0, 2, "send_note", "宿舍纸条"), "通过真实any场景入口在宿舍传纸条", simulation.error_message):
		_free_fixture(fixture)
		return
	var interaction: Dictionary = simulation.interactions.back()
	room.refresh_state()
	_check(room.visual_students[0].location == "宿舍" and room.visual_students[2].location == "宿舍", "互动地点仍遵循正式动作场景")
	_check(room.visual_students[0].status == "宿舍" and not room.visual_students[0].in_room, "教室空座位只显示真实去向")
	_check(room.visual_interactions.is_empty() and room.visual_impacts.is_empty(), "教室外互动不产生教室飞行或受击")
	_check_result(simulation.advance(float(interaction.duration_s)), "权威执行器完成宿舍纸条", simulation.error_message)
	room.refresh_state()
	_check(interaction.status == "completed" and room.visual_interactions.is_empty(), "教室外真实送达也不伪造教室收件画面")
	_free_fixture(fixture)


# 释放只属于当前独立测试的场景节点，引用计数状态随夹具一起回收。
func _free_fixture(fixture: Dictionary) -> void:
	fixture.room.free()
	fixture.behavior.free()


# 错误保留生产入口的实际原因，失败不能悄悄跳过后仍算通过。
func _check_result(result: Error, message: String, detail: String) -> bool:
	_check(result == OK, "%s，错误码%s：%s" % [message, result, detail] if result != OK else message)
	return result == OK


# 只统计真正执行的断言，由最终退出码反映结果。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


# 与原生托盘验收分开汇总，画面测试不会把系统窗口行为算作已验证。
func _finish() -> void:
	if failures.is_empty():
		print("INTERACTION_VIEW_TEST_PASS checks=%s" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("INTERACTION_VIEW_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
