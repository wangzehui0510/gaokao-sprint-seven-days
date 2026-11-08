extends SceneTree
## 以隔离工程、真实配置和四人行为树验证互动、举报及存档不变量。

const CONFIG = preload("res://scripts/core/game_config.gd")
const SIMULATION = preload("res://scripts/core/classroom_simulation.gd")
const CONTROLLER = preload("res://scripts/ai/classroom_behavior_controller.gd")

# 所有夹具都位于本次隔离用户目录，不能读写正式玩家进度。
var checks: int = 0
var failures: Array[String] = []
var owned_controllers: Array[Node] = []


## 等待场景树就绪，再准备独立工程或执行真实规则。
func _initialize() -> void:
	call_deferred("_run")


## 双重确认独立应用名称和用户目录，避免失败夹具覆盖正式存档。
func _run() -> void:
	if "--isolated-interactions" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with("ClassroomInteractionsTest_") or marker not in OS.get_user_data_dir():
		push_error("互动测试用户目录未隔离，拒绝运行。")
		quit(1)
		return
	# 运行时脚本错误仍须结束测试子进程，不能让父进程永久等待。
	create_timer(45.0).timeout.connect(func():
		_check(false, "互动规则验收超时，可能发生未处理脚本错误")
		_finish()
	)
	var probe = SIMULATION.new()
	for method in ["start_interaction", "can_start_interaction", "report_violation", "get_open_violation"]:
		if not probe.has_method(method):
			_check(false, "互动执行器缺少方法：%s" % method)
			_finish()
			return
	_test_note_completion()
	_test_eraser_completion()
	_test_atomic_rejection()
	_test_course_boundaries()
	_test_chain_interruptions()
	_test_focus_breaks_pair()
	_test_report_and_continuous_violation()
	_test_report_current_partner()
	_test_report_outside_classroom()
	_test_pair_save_round_trip()
	_test_restored_pair_control()
	_test_report_save_round_trip()
	_test_no_offline_settlement()
	_test_legacy_save_migration()
	_test_corrupt_pair_rejection()
	_test_config_reload()
	_test_required_config_events()
	_test_violation_config_reload()
	for controller in owned_controllers:
		controller.free()
	print("INTERACTIONS_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	_finish()


## 复制真实源码并导入隔离工程；不改正式工程设置或用户目录。
func _launch_isolated_project() -> void:
	var marker: String = "ClassroomInteractionsTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	for folder in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		var result: Error = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制互动隔离工程失败：%s，错误码%d。" % [folder, result])
			quit(1)
			return
	var project := ConfigFile.new()
	if project.load("res://project.godot") != OK:
		push_error("无法读取真实工程设置。")
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	if project.save(isolated_root.path_join("project.godot")) != OK:
		push_error("无法保存互动隔离工程设置。")
		quit(1)
		return
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--editor", "--path", isolated_root, "--import"], output, true)
	if exit_code != 0:
		for line in output:
			print(line)
		quit(exit_code)
		return
	output.clear()
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", "res://tests/test_interactions.gd", "--", "--isolated-interactions"], output, true)
	for line in output:
		print(line)
	print("INTERACTIONS_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 夹具准备中的文件复制失败直接返回，不静默跳过所需资源。
func _copy_directory(source: String, destination: String) -> Error:
	var directory := DirAccess.open(source)
	if directory == null:
		return ERR_CANT_OPEN
	var result: Error = DirAccess.make_dir_recursive_absolute(destination)
	if result != OK:
		return result
	for folder in directory.get_directories():
		result = _copy_directory(source.path_join(folder), destination.path_join(folder))
		if result != OK:
			return result
	for filename in directory.get_files():
		result = DirAccess.copy_absolute(source.path_join(filename), destination.path_join(filename))
		if result != OK:
			return result
	return OK


## 每个场景都建立四份真实角色及同一蓝图行为树，不使用执行器替身。
func _new_simulation() -> ClassroomSimulation:
	var configuration := CONFIG.new()
	_check(configuration.load_file() == OK, "互动夹具加载正式配置")
	var simulation := SIMULATION.new()
	_check(simulation.setup(configuration, 261107) == OK, "互动夹具建立真实模拟器")
	_check(simulation.set_debug_time(1, 28800.0) == OK, "互动夹具使用第一天早课")
	var controller := CONTROLLER.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	_check(simulation.advance(0.0) == OK, "四棵真实行为树建立课程活动")
	for student in simulation.students:
		student.focus = 80.0
	return simulation


## 纸条按双方各自当前上限恢复，只有完成时才真实送达一次。
func _test_note_completion() -> void:
	var simulation := _new_simulation()
	simulation.students[0].attributes.discipline = 2.0
	simulation.students[1].attributes.discipline = 1.0
	var untouched_instance: int = simulation.students[2].current_action.instance_id
	var knowledge_before: float = simulation.students[0].knowledge.chinese
	_check(simulation.can_start_interaction(0, 1, "send_note"), "纸条具备真实可执行条件")
	_check(simulation.start_interaction(0, 1, "send_note", "下课一起讨论这道题。") == OK, "通过统一入口发起纸条")
	_close(simulation.students[0].focus, 78.0, "只向发起者收取纸条启动费")
	_close(simulation.students[1].focus, 80.0, "目标不重复承担启动费")
	var interaction_id: int = simulation.students[0].current_action.interaction_id
	_check(simulation.students[1].current_action.interaction_id == interaction_id, "双方绑定同一互动")
	_check(simulation.students[0].current_action.instance_id != simulation.students[1].current_action.instance_id, "双方仍有唯一的角色动作实例")
	_check(simulation.notes.is_empty(), "发动时不伪造文字已送达")
	_check(simulation.advance(10.0) == OK, "纸条真实执行十秒")
	_close(simulation.students[0].focus, 78.4, "发起者按120上限恢复十秒且没有双重结算")
	_close(simulation.students[1].focus, 80.0 + 2.2 / 6.0, "目标按110上限恢复十秒且没有双重结算")
	_close(simulation.students[0].knowledge.chinese, knowledge_before, "纸条占用期间不同时获得学习知识")
	_check(simulation.notes.is_empty(), "持续中纸条尚未送达")
	_check(simulation.students[2].current_action.instance_id == untouched_instance, "未参与者原动作没有被互动覆盖")
	_check(simulation.advance(10.0) == OK, "纸条达到真实完成边界")
	_check(simulation.notes.size() == 1, "双参与者完成只送达一条文字")
	if simulation.notes.size() == 1:
		var note: Dictionary = simulation.notes[0]
		_check(note.interaction_id == interaction_id and note.sender_index == 0 and note.target_index == 1, "送达记录保留准确双方和互动编号")
		_check(note.text == "下课一起讨论这道题。" and is_equal_approx(note.delivered_at, 20.0), "送达文字和发生时刻来自真实完成事件")
	_check(_interaction(simulation, interaction_id).get("status") == "completed", "互动历史明确记录正常完成")
	_check(simulation.advance(0.0) == OK and simulation.notes.size() == 1, "再次处理相同时刻不会重复送达")


## 橡皮发动即占用双方，完成型资源变化不提前发放也不执行两次。
func _test_eraser_completion() -> void:
	var simulation := _new_simulation()
	_check(simulation.start_interaction(0, 1, "eraser_prank") == OK, "基础弹橡皮无需背包物品即可发动")
	_close(simulation.students[0].focus, 76.0, "橡皮发起者启动扣四点")
	_close(simulation.students[1].focus, 80.0, "橡皮发动时目标尚未扣完成型专注")
	_check(simulation.students[0].current_action.action_id == "eraser_prank" and simulation.students[1].current_action.action_id == "eraser_prank", "发动立即打断双方旧动作")
	_check(simulation.advance(29.0) == OK, "弹橡皮执行二十九秒")
	_close(simulation.students[1].focus, 80.0, "未完成不提前扣目标专注")
	_check(simulation.advance(1.0) == OK, "弹橡皮真实到达完成边界")
	_close(simulation.students[0].focus, 77.0, "发起者完成加二后自然回学习仅扣一次启动费")
	_close(simulation.students[1].focus, 73.0, "目标完成减六后自然回学习仅扣一次启动费")
	_check(simulation.students[0].current_action.action_id == "study" and simulation.students[1].current_action.action_id == "study", "完成后双方重新按当前课表选择")


## 发动前校验失败必须保留旧动作、资源、随机流和互动历史。
func _test_atomic_rejection() -> void:
	var simulation := _new_simulation()
	simulation.students[0].focus = 3.0
	var own_before: Dictionary = simulation.students[0].duplicate(true)
	var target_before: Dictionary = simulation.students[1].duplicate(true)
	var random_before: int = simulation.rng.state
	var history_before: int = simulation.interactions.size()
	var violations_before: Array = simulation.violations.duplicate(true)
	var logs_before: int = simulation.logs.size()
	_check(not simulation.can_start_interaction(0, 1, "eraser_prank"), "启动资源不足时不可执行")
	_check(simulation.start_interaction(0, 1, "eraser_prank") != OK, "资源不足明确失败")
	_check(simulation.students[0] == own_before and simulation.students[1] == target_before, "拒绝前不扣半份费用或打断任何旧动作")
	_check(simulation.rng.state == random_before and simulation.interactions.size() == history_before, "拒绝不消耗随机流或建立半成品互动")
	_check(simulation.start_interaction(0, 0, "send_note", "无效自发自收") != OK, "双人互动拒绝相同参与者")
	_check(simulation.start_interaction(0, 4, "send_note", "无效目标") != OK, "双人互动拒绝越界目标")
	_check(simulation.students[0] == own_before and simulation.students[1] == target_before, "参与者校验失败仍保留完整旧状态")
	_check(simulation.start_interaction(0, 1, "send_note", " \t\n ") == ERR_INVALID_PARAMETER, "空白纸条通过明确参数错误拒绝")
	_check(simulation.students[0] == own_before and simulation.students[1] == target_before, "空白纸条不扣费或清理旧动作")
	_check(simulation.rng.state == random_before and simulation.interactions.size() == history_before and simulation.violations == violations_before and simulation.logs.size() == logs_before, "空白纸条不消耗随机流或建立互动、违纪与成功日志")


## 课表边界取消未完成纸条，恰好完整执行二十秒则先完成再切换课程。
func _test_course_boundaries() -> void:
	for remaining in [10.0, 20.0]:
		var simulation := _new_simulation()
		var boundary: float = simulation.course_context().end_seconds
		_check(simulation.set_debug_time(1, boundary - remaining) == OK and simulation.advance(0.0) == OK, "纸条边界夹具进入下课前%s秒" % remaining)
		_check(simulation.start_interaction(0, 1, "send_note", "边界纸条%s" % remaining) == OK, "课表边界前真实发动纸条")
		var interaction_id: int = simulation.students[0].current_action.interaction_id
		_check(simulation.advance(remaining) == OK, "纸条真实推进到课表边界")
		_check(simulation.course_context().kind == "break", "互动处理后进入真实课间")
		if remaining < 20.0:
			_check(_interaction(simulation, interaction_id).status == "interrupted" and simulation.notes.is_empty(), "十秒后下课会取消未完成纸条且不送达")
		else:
			_check(_interaction(simulation, interaction_id).status == "completed" and simulation.notes.size() == 1, "结束和下课恰好重合时完整纸条只送达一次")
		_check(not simulation.students[0].current_action.has("interaction_id") and not simulation.students[1].current_action.has("interaction_id"), "切课后双方不残留旧互动动作")
		_check(simulation.get_open_violation(0).is_empty() and simulation.get_open_violation(1).is_empty(), "课间没有残留课堂可举报事件")
		_check(simulation.advance(20.0) == OK and simulation.notes.size() == (0 if remaining < 20.0 else 1), "继续推进不会让边界纸条迟到或重复送达")


## 新互动同时接管两个旧互动时，旧搭档回课表且旧结束不覆盖新动作。
func _test_chain_interruptions() -> void:
	var simulation := _new_simulation()
	_check(simulation.start_interaction(0, 1, "send_note", "第一条应被打断") == OK, "建立第一组纸条互动")
	var first_id: int = simulation.students[0].current_action.interaction_id
	_check(simulation.start_interaction(2, 3, "send_note", "第二条应被打断") == OK, "未来同学可复用同一入口建立另一组互动")
	var second_id: int = simulation.students[2].current_action.interaction_id
	_check(simulation.advance(5.0) == OK, "两组互动真实执行五秒")
	_check(simulation.start_interaction(0, 2, "eraser_prank") == OK, "新互动接管两个旧互动中的参与者")
	var newest_id: int = simulation.students[0].current_action.interaction_id
	_check(newest_id != first_id and newest_id != second_id, "新互动有独立编号")
	_check(simulation.students[2].current_action.interaction_id == newest_id, "新参与者双方均由新互动接管")
	_check(_interaction(simulation, first_id).get("status") == "interrupted" and _interaction(simulation, second_id).get("status") == "interrupted", "两个旧互动整体结束并记录打断")
	_check(_interaction(simulation, first_id).get("note_text") == "第一条应被打断" and _interaction(simulation, second_id).get("note_text") == "第二条应被打断", "打断历史保留未送达的原文字")
	_check(simulation.advance(0.0) == OK, "未加入新动作的旧搭档重新决策")
	for index in [1, 3]:
		_check(not simulation.students[index].current_action.has("interaction_id") or simulation.students[index].current_action.interaction_id != newest_id, "旧搭档%d没有被误加入新互动" % index)
		_check(simulation.students[index].current_action.action_id == "study", "旧搭档%d回归真实课表" % index)
	_check(simulation.notes.is_empty(), "被打断的纸条不显示已送达")
	_check(simulation.advance(30.0) == OK, "新橡皮动作完成")
	_check(_interaction(simulation, newest_id).get("status") == "completed", "旧结束处理未清空或覆盖新互动")
	_check(simulation.notes.is_empty(), "推进超过旧完成时刻仍不会送达被取消的纸条")


## 专注必须整体结束自己参与的旧互动，同时保留新建立的低专注学习段。
func _test_focus_breaks_pair() -> void:
	var simulation := _new_simulation()
	simulation.students[0].focus = 40.0
	_check(simulation.start_interaction(0, 1, "send_note", "专注前未送达") == OK, "低专注玩家发动纸条")
	var previous_id: int = simulation.students[0].current_action.interaction_id
	_check(simulation.advance(5.0) == OK, "专注前纸条实际执行五秒")
	var before: float = simulation.students[0].focus
	_check(simulation.focus_command() == OK, "互动中专注通过真实瞬时入口生效")
	_close(simulation.students[0].focus, before + 5.0, "专注只增加五点且不重复自然启动扣费")
	_check(simulation.students[0].current_action.action_id == "study", "仍低于阈值时本次专注也建立学习段")
	var new_instance: int = simulation.students[0].current_action.instance_id
	_check(_interaction(simulation, previous_id).get("status") == "interrupted", "专注整体结束旧双人互动")
	_check(simulation.advance(0.0) == OK, "专注后正常处理旧搭档决策")
	_check(simulation.students[0].current_action.instance_id == new_instance, "旧互动结束和自主树不会覆盖新学习段")
	_check(simulation.students[1].current_action.action_id == "study", "被专注打断的旧搭档回课表")
	_check(simulation.notes.is_empty(), "专注打断的纸条保留未送达语义")


## 举报针对连续违纪编号只结算一次，举报者的持续动作保持不变。
func _test_report_and_continuous_violation() -> void:
	var simulation := _new_simulation()
	simulation.students[1].focus = 40.0
	_check(simulation.start_action(1, "daydream") == OK, "目标真实进入课堂发呆")
	var open_violation: Dictionary = simulation.get_open_violation(1)
	_check(not open_violation.is_empty(), "课堂开小差生成可举报违纪")
	if open_violation.is_empty():
		return
	var violation_id: int = open_violation.violation_id
	_check(simulation.start_action(1, "sleep") == OK, "同一目标连续切换另一个开小差动作")
	_check(simulation.get_open_violation(1).get("violation_id") == violation_id, "连续开小差沿用同一次违纪编号")
	var own_action: Dictionary = simulation.students[0].current_action.duplicate(true)
	var before_own: float = simulation.students[0].focus
	var before_target: float = simulation.students[1].focus
	_check(simulation.report_violation(1, violation_id) == OK, "对未处理事件瞬时举报成功")
	_close(simulation.students[0].focus, before_own + 3.0, "举报立即增加举报者三点专注")
	_close(simulation.students[1].focus, before_target - 5.0, "举报目标减五且强制入段不另收启动费")
	_check(simulation.students[0].current_action == own_action, "举报不占用举报者持续动作也不重抽时长")
	_check(simulation.students[1].current_action.action_id == "study" and simulation.students[1].current_action.duration_s >= 300.0 and simulation.students[1].current_action.duration_s <= 600.0, "低专注目标进入新的五至十分钟学习段")
	_check(simulation.get_open_violation(1).is_empty(), "同一时刻不会因目标仍低专注立即生成新违纪")
	before_own = simulation.students[0].focus
	before_target = simulation.students[1].focus
	_check(simulation.report_violation(1, violation_id) != OK, "同一违纪重复举报明确返回失败")
	_close(simulation.students[0].focus, before_own, "重复举报不再次奖励举报者")
	_close(simulation.students[1].focus, before_target, "重复举报不再次惩罚目标")
	_check(simulation.start_action(1, "daydream") == OK, "后续再次开小差形成另一事件")
	open_violation = simulation.get_open_violation(1)
	_check(not open_violation.is_empty() and open_violation.violation_id != violation_id, "新的一次违纪有独立编号且未添加每日次数限制")
	if open_violation.is_empty():
		return
	violation_id = open_violation.violation_id
	_check(simulation.start_interaction(1, 2, "send_note", "举报前连续纸条") == OK, "同学互动接续真实开小差")
	_check(simulation.get_open_violation(1).get("violation_id") == violation_id, "由单人开小差转双人互动仍保留连续事件")
	var interaction_id: int = simulation.students[1].current_action.interaction_id
	own_action = simulation.students[0].current_action.duplicate(true)
	_check(simulation.report_violation(1, violation_id) == OK, "第三人可举报双人互动中的违纪目标")
	_check(_interaction(simulation, interaction_id).get("status") == "interrupted", "举报目标离开时整体结束旧互动")
	_check(simulation.students[0].current_action == own_action, "第三人举报依然不改变自己的持续动作")
	_check(simulation.advance(0.0) == OK and simulation.students[2].current_action.action_id == "study", "被举报目标的旧搭档按课表重新选择")
	_check(simulation.notes.is_empty(), "被举报打断的纸条不会送达")


## 用户确认的同组举报例外整体结束互动，举报者按课表重新选择而非保留原互动。
func _test_report_current_partner() -> void:
	for initial_focus in [40.0, 80.0]:
		var simulation := _new_simulation()
		simulation.students[0].focus = initial_focus
		simulation.students[1].focus = 40.0
		_check(simulation.start_interaction(0, 1, "send_note", "同组举报后不能送达") == OK, "同组举报夹具建立真实纸条")
		var interaction_id: int = simulation.students[0].current_action.interaction_id
		_check(simulation.advance(5.0) == OK, "同组举报前纸条实际执行五秒")
		var violation: Dictionary = simulation.get_open_violation(1)
		_check(not violation.is_empty(), "当前搭档拥有可举报的真实违纪")
		if violation.is_empty():
			continue
		var reporter_before: float = simulation.students[0].focus
		var target_before: float = simulation.students[1].focus
		_check(simulation.report_violation(1, violation.violation_id) == OK, "用户已允许举报当前互动搭档")
		_check(simulation.advance(0.0) == OK, "同组举报后按统一执行器处理双方新活动")
		_check(_interaction(simulation, interaction_id).get("status") == "interrupted", "同组举报整体结束双方旧互动")
		_check(simulation.students[1].current_action.action_id == "study", "被举报搭档强制进入当前知识课学习")
		_close(simulation.students[1].focus, target_before - 5.0, "同组被举报者只减五且不另收自然入段费")
		if initial_focus < 50.0:
			_check(simulation.students[0].current_action.action_id == "daydream", "低专注举报者按课表正常选择开小差")
			_close(simulation.students[0].focus, reporter_before + 3.0, "低专注举报者获得三点且基础发呆不收费")
		else:
			_check(simulation.students[0].current_action.action_id == "study", "高专注举报者按课表正常回学习")
			_close(simulation.students[0].focus, reporter_before + 3.0 - 1.0, "举报者正常回学习会支付一次自然入段费")
		_check(simulation.notes.is_empty(), "同组举报打断后未完成纸条不会送达")
		_check(simulation.get_open_violation(1).is_empty(), "被举报搭档在同一时刻不会重新生成违纪")


## 举报需要双方处于真实上课教室；离开教室或课间传纸条均不能制造处罚。
func _test_report_outside_classroom() -> void:
	var simulation := _new_simulation()
	_check(simulation.start_action(1, "daydream") == OK, "非教室举报夹具先建立真实课堂违纪")
	var violation: Dictionary = simulation.get_open_violation(1)
	_check(not violation.is_empty(), "非教室举报夹具保留准确事件身份")
	if violation.is_empty():
		return
	_check(simulation.start_action(0, "dorm_rest") == OK and simulation.student_location(0) == "dorm", "举报者真实离开教室进入宿舍动作")
	var before: Array = simulation.students.duplicate(true)
	_check(simulation.report_violation(1, violation.violation_id) != OK, "不在教室的举报者不能处罚仍在课堂的同学")
	_check(simulation.students == before and simulation.get_open_violation(1).violation_id == violation.violation_id, "非教室举报拒绝不改变双方动作、资源或事件身份")
	var boundary: float = simulation.course_context().end_seconds
	_check(simulation.set_debug_time(1, boundary) == OK and simulation.advance(0.0) == OK, "非教室举报夹具进入真实课间")
	_check(simulation.start_interaction(0, 1, "send_note", "课间不能举报这张纸条") == OK, "课间仍可真实传递纸条")
	_check(simulation.get_open_violation(1).is_empty(), "课间纸条不生成可举报的课堂违纪")
	before = simulation.students.duplicate(true)
	_check(simulation.report_violation(1, violation.violation_id) != OK and simulation.students == before, "课间旧举报编号不能处罚当前纸条或改变真实资源")


## 中途存档保留双方关联、抽样时长与进度，读档不重新收费或重抽。
func _test_pair_save_round_trip() -> void:
	var simulation := _new_simulation()
	_check(simulation.start_interaction(0, 1, "send_note", "读档后只送达一次") == OK, "建立存档中的真实纸条")
	_check(simulation.advance(7.0) == OK, "存档前实际执行七秒")
	var action_before: Dictionary = simulation.students[0].current_action.duplicate(true)
	var own_before: float = simulation.students[0].focus
	var random_before: int = simulation.rng.state
	var path: String = "user://interaction_mid_note.json"
	_check(simulation.save_file(path) == OK, "保存真实进行中的双人互动")
	var restored := _new_simulation()
	_check(restored.load_file(path, false) == OK, "恢复真实双人互动存档：%s" % restored.error_message)
	var restored_action: Dictionary = restored.students[0].current_action
	# JSON将整数解析成浮点数，编号按整数语义比较，时间和资源按真实数值比较。
	_check(int(restored_action.instance_id) == int(action_before.instance_id) and int(restored_action.interaction_id) == int(action_before.interaction_id), "读档保留角色动作及共同互动的确切编号")
	_check(restored_action.action_id == action_before.action_id and restored_action.subject_id == action_before.subject_id and restored_action.natural_entry == action_before.natural_entry, "读档保留动作类型、课程和入段来源")
	for key in ["started_at", "ends_at", "duration_s", "last_settled_at", "knowledge_gain"]:
		_close(restored_action[key], action_before[key], "读档保留动作字段%s" % key)
	_check(restored_action.resource_changes.size() == action_before.resource_changes.size() and restored_action.resource_changes.has_all(action_before.resource_changes.keys()), "读档保留已经结算的资源种类")
	for resource in action_before.resource_changes:
		var expected: Dictionary = action_before.resource_changes[resource]
		var actual: Dictionary = restored_action.resource_changes[resource]
		_check(actual.size() == expected.size() and actual.has_all(expected.keys()), "读档保留%s资源的结算记录字段" % resource)
		for key in expected:
			_close(actual[key], expected[key], "读档保留%s的%s数值" % [resource, key])
	_close(restored.elapsed_s, simulation.elapsed_s, "读档不补充进程退出期间的已推进秒数")
	_close(restored.clock_seconds, simulation.clock_seconds, "显式开发时钟读档保持保存时刻")
	_close(restored.students[0].focus, own_before, "读档不重复扣纸条启动费")
	_check(restored.rng.state == random_before, "双人读档精确恢复随机状态")
	_check(restored.notes.is_empty(), "读档不提前送达未完成纸条")
	_check(restored.advance(13.0) == OK, "读档仅推进真实剩余十三秒")
	_check(restored.notes.size() == 1 and restored.notes[0].text == "读档后只送达一次", "恢复后完成只送达一次原文字")
	_check(restored.save_file(path) == OK, "完成后再次保存聊天记录")
	var completed := _new_simulation()
	_check(completed.load_file(path, false) == OK, "恢复已完成互动及聊天记录：%s" % completed.error_message)
	_check(completed.advance(0.0) == OK and completed.notes.size() == 1, "已完成纸条跨保存恢复不重复送达")


## JSON恢复后仍可整体接管旧互动，零秒重绘不会改号或制造额外违纪。
func _test_restored_pair_control() -> void:
	var source := _new_simulation()
	_check(source.start_interaction(0, 1, "send_note", "恢复后被真实控制打断") == OK and source.advance(7.0) == OK, "恢复控制夹具建立执行七秒的纸条")
	_check(source.save_file("user://restored_pair_control.json") == OK, "恢复控制夹具保存真实在途互动")
	for control in ["new_pair", "focus"]:
		var restored := _new_simulation()
		_check(restored.load_file("user://restored_pair_control.json", false) == OK, "恢复控制夹具加载原互动：%s" % restored.error_message)
		var interaction_id: int = int(restored.students[0].current_action.interaction_id)
		var violation: Dictionary = restored.get_open_violation(0)
		var count_before: int = restored.violations.size()
		_check(restored.advance(0.0) == OK and restored.violations.size() == count_before, "恢复后的零秒推进不重复建立违纪")
		_check(restored.get_open_violation(0).violation_id == violation.violation_id, "恢复后的零秒推进保留原事件编号")
		if control == "new_pair":
			_check(restored.start_interaction(0, 2, "eraser_prank") == OK, "恢复后可以用新互动整体接管旧纸条")
			_check(restored.students[0].current_action.action_id == "eraser_prank" and restored.students[2].current_action.action_id == "eraser_prank", "恢复后的新互动绑定正确双方")
			_check(restored.get_open_violation(0).violation_id == violation.violation_id, "恢复后连续换互动仍沿用原违纪身份")
		else:
			_check(restored.focus_command(0) == OK, "恢复后专注可以整体结束原互动")
			_check(restored.students[0].current_action.action_id == "study", "恢复后专注保留新学习动作")
		_check(_interaction(restored, interaction_id).status == "interrupted" and restored.students[1].current_action.action_id == "study", "恢复后的原搭档正常回学习且旧互动明确中断")
		_check(restored.advance(13.0) == OK and restored.notes.is_empty(), "恢复后被控制打断的纸条不在旧完成时刻送达")


## 已处理的违纪身份需要持久化，重启后重复请求仍不可重复结算。
func _test_report_save_round_trip() -> void:
	var simulation := _new_simulation()
	simulation.students[1].focus = 40.0
	_check(simulation.start_action(1, "daydream") == OK, "建立举报存档夹具")
	var violation: Dictionary = simulation.get_open_violation(1)
	_check(not violation.is_empty(), "举报存档夹具存在真实事件")
	if violation.is_empty():
		return
	var id: int = violation.violation_id
	_check(simulation.report_violation(1, id) == OK, "存档前只处理一次举报")
	_check(simulation.save_file("user://interaction_reported.json") == OK, "保存已处理的违纪事件")
	var restored := _new_simulation()
	_check(restored.load_file("user://interaction_reported.json", false) == OK, "恢复已处理违纪：%s" % restored.error_message)
	var own_before: float = restored.students[0].focus
	var target_before: float = restored.students[1].focus
	_check(restored.report_violation(1, id) != OK, "恢复后重复举报仍明确拒绝")
	_close(restored.students[0].focus, own_before, "恢复后重复举报不增加奖励")
	_close(restored.students[1].focus, target_before, "恢复后重复举报不增加惩罚")


## 真实系统日期跨天载入只对齐课表并中断旧互动，不结算退出期间的资源和知识。
func _test_no_offline_settlement() -> void:
	var source := _new_simulation()
	_check(source.advance(60.0) == OK, "离线夹具先真实获得一段学习结果")
	_check(source.start_interaction(0, 1, "send_note", "退出期间不能自动送达") == OK and source.advance(7.0) == OK, "离线夹具保存尚未完成的真实纸条")
	var snapshot: Dictionary = _snapshot(source, "user://offline_source.json")
	var now: Dictionary = Time.get_datetime_dict_from_system()
	var today: String = "%04d-%02d-%02d" % [now.year, now.month, now.day]
	var yesterday: Dictionary = Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_datetime_string(today + "T00:00:00")) - 86400)
	snapshot.created_date = "%04d-%02d-%02d" % [yesterday.year, yesterday.month, yesterday.day]
	_write_json("user://offline_yesterday.json", snapshot)
	var restored := _new_simulation()
	_check(restored.load_file("user://offline_yesterday.json", true) == OK, "真实系统时钟载入前一天保存的互动：%s" % restored.error_message)
	_check(restored.day >= 2, "读档跟随当前电脑日期推进局内日期")
	_close(restored.elapsed_s, source.elapsed_s, "跨天读档不增加已经模拟的在线秒数")
	for index in source.students.size():
		for resource in ["focus", "stamina"]:
			_close(restored.students[index][resource], source.students[index][resource], "跨天读档不改变角色%d的%s资源" % [index, resource])
		for subject in source.students[index].knowledge:
			_close(restored.students[index].knowledge[subject], source.students[index].knowledge[subject], "跨天读档不增加角色%d的%s知识" % [index, subject])
		_check(restored.students[index].current_action.is_empty(), "跨天读档只结束角色%d旧动作，不制造新动作费用或收益" % index)
	_check(restored.interactions[0].status == "interrupted" and restored.notes.is_empty(), "跨天退出打断旧纸条且不能补送达")
	_check(restored.get_open_violation(0).is_empty() and restored.get_open_violation(1).is_empty(), "跨天读档关闭旧课堂违纪")


## 构造真实旧版字段集合，显式兼容旧局且保留其资源和在途动作。
func _test_legacy_save_migration() -> void:
	var simulation := _new_simulation()
	_check(simulation.advance(12.0) == OK, "旧版迁移夹具先执行真实学习")
	var snapshot: Dictionary = _snapshot(simulation, "user://legacy_source.json")
	var legacy: Dictionary = {}
	for key in ["save_version", "config_fingerprint", "config_version", "created_date", "day", "clock_seconds", "elapsed_s", "context_key", "students", "logs", "rng_seed", "rng_state", "next_action_number"]:
		legacy[key] = snapshot[key]
	legacy.save_version = 1
	legacy.logs = legacy.logs.filter(func(entry: Dictionary): return entry.type != "daily_items")
	for student in legacy.students:
		# 真正v1不含后续加入的每日领取权威字段，不能仅改版本号冒充旧格式。
		student.erase("daily_item_claim_days")
		student.inventory = {}
		var old_action: Dictionary = {}
		for key in ["instance_id", "action_id", "started_at", "ends_at", "duration_s", "last_settled_at", "subject_id", "natural_entry", "resource_changes", "knowledge_gain"]:
			old_action[key] = student.current_action[key]
		student.current_action = old_action
	_write_json("user://legacy_v1.json", legacy)
	var restored := _new_simulation()
	_check(restored.load_file("user://legacy_v1.json", false) == OK, "旧v1单人动作存档通过明确迁移恢复：%s" % restored.error_message)
	_close(restored.students[0].focus, simulation.students[0].focus, "旧局迁移保留已发生资源而非重开默认局")
	_check(restored.students[0].current_action.instance_id == simulation.students[0].current_action.instance_id and is_equal_approx(restored.students[0].current_action.ends_at, simulation.students[0].current_action.ends_at), "旧局迁移保留动作身份与抽样时长")
	_check(restored.interactions.is_empty() and restored.notes.is_empty(), "旧局迁移不会制造未发生互动或聊天")
	_check(restored.rng.state == simulation.rng.state, "旧局迁移保留精确随机流")


## 损坏关联必须在入口拒绝，不能让半个双人动作或未送达纸条进入结算。
func _test_corrupt_pair_rejection() -> void:
	var source := _new_simulation()
	_check(source.start_interaction(0, 1, "send_note", "损坏夹具原文字") == OK, "建立关联校验夹具")
	_check(source.advance(3.0) == OK, "关联夹具执行三秒")
	var original: Dictionary = _snapshot(source, "user://pair_corrupt_source.json")
	var cases: Array[Dictionary] = []
	var missing_registry: Dictionary = original.duplicate(true)
	missing_registry.interactions = []
	cases.append(missing_registry)
	var orphan: Dictionary = original.duplicate(true)
	orphan.students[0].current_action.interaction_id = 999999
	cases.append(orphan)
	var missing_partner: Dictionary = original.duplicate(true)
	missing_partner.students[1].current_action = {}
	cases.append(missing_partner)
	var duplicated_instance: Dictionary = original.duplicate(true)
	duplicated_instance.students[1].current_action.instance_id = duplicated_instance.students[0].current_action.instance_id
	cases.append(duplicated_instance)
	var invalid_participant: Dictionary = original.duplicate(true)
	invalid_participant.interactions[0].target_index = 4
	cases.append(invalid_participant)
	var mismatched_time: Dictionary = original.duplicate(true)
	mismatched_time.students[1].current_action.ends_at += 1.0
	mismatched_time.students[1].current_action.duration_s += 1.0
	cases.append(mismatched_time)
	var third_participant: Dictionary = original.duplicate(true)
	var third_instance: int = int(third_participant.students[2].current_action.instance_id)
	third_participant.students[2].current_action = third_participant.students[0].current_action.duplicate(true)
	third_participant.students[2].current_action.instance_id = third_instance
	cases.append(third_participant)
	var missing_violation: Dictionary = original.duplicate(true)
	missing_violation.violations = []
	cases.append(missing_violation)
	var wrong_violation_action: Dictionary = original.duplicate(true)
	wrong_violation_action.violations[0].action_ids[0] = "eraser_prank"
	cases.append(wrong_violation_action)
	var restored := _new_simulation()
	var before: Dictionary = restored.students[0].duplicate(true)
	for index in cases.size():
		_write_json("user://pair_corrupt_case.json", cases[index])
		_check(restored.load_file("user://pair_corrupt_case.json", false) != OK, "损坏双人关联夹具%d必须明确拒绝" % index)
		_check(restored.students[0] == before and restored.interactions.is_empty(), "关联校验失败不得覆盖现存有效局%d" % index)


## 调表立即改变双方持续费率，当前段不重抽、不重扣，新段才使用新时长。
func _test_config_reload() -> void:
	var simulation := _new_simulation()
	_check(simulation.start_interaction(0, 1, "send_note", "调表中的纸条") == OK, "建立调表中的真实互动")
	_check(simulation.advance(5.0) == OK, "调表前执行五秒")
	var original_end: float = simulation.students[0].current_action.ends_at
	var own_before: float = simulation.students[0].focus
	var target_before: float = simulation.students[1].focus
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for action in source.tables.actions:
		if action.id == "send_note":
			action.duration_min_s = 40.0
			action.duration_max_s = 40.0
	for effect in source.tables.effects:
		if effect.id == "send_note_tick_1":
			effect.value = 0.06
	_write_json("user://interaction_new_config.json", source)
	var changed := CONFIG.new()
	_check(changed.load_file("user://interaction_new_config.json") == OK, "修改后配置仍通过真实入口校验")
	_check(simulation.apply_config(changed) == OK, "互动中接管新配置")
	_close(simulation.students[0].focus, own_before, "调表不重复收发起者启动费")
	_close(simulation.students[1].focus, target_before, "调表不重新结算目标过去收益")
	_close(simulation.students[0].current_action.ends_at, original_end, "当前纸条保留原二十秒结束时间")
	_check(simulation.advance(5.0) == OK, "调表后继续执行五秒")
	_close(simulation.students[0].focus, own_before + 0.5, "发起者后续按新费率恢复")
	_close(simulation.students[1].focus, target_before + 0.5, "目标后续按新费率恢复且不重复")
	_check(simulation.start_interaction(0, 2, "send_note", "新时长纸条") == OK, "调表后的新互动可以正常发动")
	_close(simulation.students[0].current_action.duration_s, 40.0, "新互动才使用新四十秒时长")


## 必要业务事件及强制回课堂顺序必须在配置入口拒绝，不能等执行后写出不可读存档。
func _test_required_config_events() -> void:
	var simulation := _new_simulation()
	var original_config: RefCounted = simulation.config
	var before: Array = simulation.students.duplicate(true)
	var random_before: int = simulation.rng.state
	var logs_before: int = simulation.logs.size()
	for scenario in ["conditional_note", "conditional_close", "conditional_route", "route_before_close", "resource_after_route"]:
		var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
		for effect in source.tables.effects:
			if scenario == "conditional_note" and effect.action_id == "send_note" and effect.type == "event":
				effect.condition = "course_active"
			elif scenario == "conditional_close" and effect.action_id == "report" and effect.type == "event":
				effect.condition = "course_active"
			elif scenario == "conditional_route" and effect.action_id == "report" and effect.type == "start_action":
				effect.condition = "course_active"
			elif scenario == "route_before_close" and effect.action_id == "report":
				if effect.type == "event":
					effect.sequence = 4
				elif effect.type == "start_action":
					effect.sequence = 3
			elif scenario == "resource_after_route" and effect.id == "report_instant_1":
				effect.sequence = 5
		_write_json("user://required_event_config.json", source)
		var changed := CONFIG.new()
		_check(changed.load_file("user://required_event_config.json") == OK, "业务契约夹具%s仍是合法通用配表" % scenario)
		var probe := SIMULATION.new()
		_check(probe.setup(changed, 123) != OK, "新局入口拒绝必要事件或执行顺序冲突：%s" % scenario)
		_check(simulation.apply_config(changed) != OK, "热更新入口拒绝必要事件或执行顺序冲突：%s" % scenario)
		_check(simulation.config == original_config and simulation.students == before and simulation.rng.state == random_before and simulation.logs.size() == logs_before, "拒绝配置%s保留旧配置和完整真实状态" % scenario)


## 历史违纪保留发生时的身份，调整当前违纪分类后保存与旧档恢复仍须可用。
func _test_violation_config_reload() -> void:
	var simulation := _new_simulation()
	_check(simulation.start_action(1, "daydream") == OK, "违纪分类调表夹具产生真实课堂事件")
	var violation: Dictionary = simulation.get_open_violation(1)
	_check(not violation.is_empty(), "违纪分类调表夹具保留原事件身份")
	if violation.is_empty():
		return
	_check(simulation.save_file("user://before_violation_config_change.json") == OK, "分类调表前保存原来的开放事件")
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for action in source.tables.actions:
		if action.id == "daydream":
			action.violation = "none"
	_write_json("user://changed_violation_classification.json", source)
	var changed := CONFIG.new()
	_check(changed.load_file("user://changed_violation_classification.json") == OK, "当前动作违纪分类调整通过通用配置校验")
	_check(simulation.apply_config(changed) == OK, "真实模拟器接管新的违纪分类")
	_check(simulation.get_open_violation(1).is_empty() and simulation.violations[0].violation_id == violation.violation_id and simulation.violations[0].status == "closed", "分类调整关闭当前事件并保留历史身份")
	_check(simulation.save_file("user://after_violation_config_change.json") == OK, "分类调整后的历史事件仍可正常保存")
	for path in ["user://before_violation_config_change.json", "user://after_violation_config_change.json"]:
		var restored := _new_simulation()
		_check(restored.apply_config(changed) == OK, "历史分类恢复夹具采用新配置")
		_check(restored.load_file(path, false) == OK, "新配置恢复分类变化前后保存的真实局：%s" % restored.error_message)
		_check(restored.get_open_violation(1).is_empty() and restored.violations.size() == 1 and restored.violations[0].violation_id == violation.violation_id and restored.violations[0].status == "closed", "新配置恢复保留原事件为已关闭，不遗失或伪造当前可举报状态")


## 从历史中查找确切互动编号，不用当前角色动作冒充过去完成状态。
func _interaction(simulation: ClassroomSimulation, id: int) -> Dictionary:
	for interaction in simulation.interactions:
		if interaction.interaction_id == id:
			return interaction
	return {}


## 通过真实保存入口获取夹具基础，损坏用例只在隔离副本修改。
func _snapshot(simulation: ClassroomSimulation, path: String) -> Dictionary:
	_check(simulation.save_file(path) == OK, "生成真实互动存档夹具")
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(data is Dictionary, "真实互动存档夹具是完整JSON")
	return data if data is Dictionary else {}


## 仅在隔离测试目录落盘配置与损坏存档，写入失败会记录真实失败。
func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "写入隔离测试夹具：%s" % path)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()


## 浮点数按真实结算结果比较，容差仅处理运算舍入。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s，实际%.9f，预期%.9f" % [message, actual, expected])


## 记录实际断言，由最终非零退出码暴露所有失败。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 仅所有真实规则断言通过才输出通过标记。
func _finish() -> void:
	if failures.is_empty():
		print("INTERACTIONS_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("INTERACTIONS_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
