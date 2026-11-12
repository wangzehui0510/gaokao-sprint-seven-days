extends SceneTree
## 教师在场与教导主任抽查：文化课任课老师必须在教室，抽查抓到不在教室的学生扣当日纪律分。

# 临时存档与日志全部写入本进程独占目录，失败时保留证据。
var fixture_root: String = ""
var configuration: GameConfig
var controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等待场景树就绪后开始真实规则验证。
func _initialize() -> void:
	call_deferred("_run")


## 逐场景真实执行并检查返回值，脚本异常不能绕过结束标记。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置加载", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomTeacherInspection_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占抽查测试目录"):
		_finish()
		return
	# 本组验证抽查自身规则：事件为独立内容，显式关闭保持既有基线。
	configuration.globals["events_enabled"] = false
	# 阶段范围在模拟器setup内装载，先建一局真实模拟器确认正式参数可用。
	if _empty() == null:
		_finish()
		return
	_check(_test_teacher_presence(), "教师在场规则完整执行")
	_check(_test_inspection_deduction(), "抽查抓到离座学生扣分场景完整执行")
	_check(_test_inspection_without_violation(), "全员在教室不扣分场景完整执行")
	_check(_test_physical_lesson_exempt(), "体育课不抽查离座场景完整执行")
	_check(_test_roundtrip(), "抽查状态与纪律分往返场景完整执行")
	_check(_test_legacy_and_corruption(), "旧档迁移与缺失抽查状态拒绝场景完整执行")
	_finish()


## 建立尚未自主决策的四人局；forced为真时在setup后显式覆盖抽查间隔、概率与冷却。
## setup每次都会重新解析phase_scope.json，因此抽查参数必须在建立模拟器之后覆盖。
func _empty(forced: bool = false) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, 261109), "创建真实四人局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	simulation.decision_handler = controller.decide
	controllers.append(controller)
	if forced:
		configuration.phase_scope.inspection.check_interval_seconds = 60.0
		configuration.phase_scope.inspection.chance = 1.0
		configuration.phase_scope.inspection.cooldown_seconds = 0.0
		simulation.inspection.next_check_elapsed = 60.0
	return simulation


## 首次定位沿用开发时钟语义，知识、资源和结果均由真实推进产生。
func _at(at_day: int, seconds: float, forced: bool = false) -> ClassroomSimulation:
	var simulation := _empty(forced)
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(at_day, seconds), "定位隔离开发时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实行为树开始当前时段", simulation.error_message):
		return null
	return simulation


## 在第一天真实课表中找出指定科目的上课时刻与上下文。
func _find_lesson(want_subject: String) -> Dictionary:
	for period: Dictionary in configuration.periods:
		var start_seconds: float = float(period.start_time) * 86400.0 + 1.0
		var simulation := _at(1, start_seconds)
		if simulation == null:
			return {}
		var context: Dictionary = simulation.course_context()
		if context.kind == "lesson" and context.subject_id == want_subject:
			return {"seconds": start_seconds, "subject": String(context.subject_id)}
	return {}


## 第一天第一个文化课时刻（语数英之一）。
func _find_cultural_lesson() -> Dictionary:
	for subject in ["chinese", "math", "english"]:
		var found: Dictionary = _find_lesson(subject)
		if not found.is_empty():
			return found
	return {}


## 文化课期间老师必须在场且科目一致；课间、体育课及其他科目不得凭空出现老师。
func _test_teacher_presence() -> bool:
	var any_cultural: bool = false
	var any_other: bool = false
	for period: Dictionary in configuration.periods:
		var start_seconds: float = float(period.start_time) * 86400.0 + 1.0
		var simulation := _empty()
		if simulation == null:
			return false
		if not _result(simulation.set_debug_time(1, start_seconds), "定位教师在场检查时段", simulation.error_message):
			return false
		var context: Dictionary = simulation.course_context()
		var teacher: Dictionary = simulation.teacher_on_duty()
		if context.kind == "lesson" and context.subject_id in ["chinese", "math", "english"]:
			any_cultural = true
			if not _check(not teacher.is_empty() and teacher.subject_id == context.subject_id, "文化课任课老师在教室：" + String(period.name)):
				return false
			if not _check(String(teacher.name) == String(configuration.subjects[context.subject_id].name) + "老师", "任课老师与科目对应：" + String(period.name)):
				return false
		else:
			any_other = true
			if not _check(teacher.is_empty(), "非文化课不凭空出现任课老师：" + String(period.name)):
				return false
	return _check(any_cultural and any_other, "课表同时覆盖文化课与非文化课时段")


## 文化课期间两人真实离座，主任抽查必须各扣一次当日纪律分并留下记录。
func _test_inspection_deduction() -> bool:
	var lesson: Dictionary = _find_cultural_lesson()
	if not _check(not lesson.is_empty(), "第一天存在可抽查的文化课"):
		return false
	var simulation := _at(1, float(lesson.seconds), true)
	if simulation == null:
		return false
	if not _result(simulation.start_interaction(0, 1, "invite_playground", ""), "两人真实溜去操场", simulation.error_message):
		return false
	if not _check(simulation.student_location(0) == "playground" and simulation.student_location(2) == "classroom", "离座判定读取真实地点"):
		return false
	if not _result(simulation.advance(61.0), "推进到第一次抽查检查点", simulation.error_message):
		return false
	var ok: bool = _check(simulation.inspection.last.found.size() == 2, "抽查记录到两名离座学生")
	ok = _check(int(simulation.students[0].daily_discipline) == 90 and int(simulation.students[1].daily_discipline) == 90, "两名离座学生各扣10分") and ok
	ok = _check(int(simulation.students[2].daily_discipline) == 100 and int(simulation.students[3].daily_discipline) == 100, "在教室学生不被扣分") and ok
	ok = _check(int(simulation.inspection.last.deduction) == 10, "抽查记录真实扣分额度") and ok
	ok = _check(simulation.logs.filter(func(entry: Dictionary): return entry.type == "inspection").size() == 2, "每名被抓学生各留一条抽查记录") and ok
	ok = _check(simulation.dean_is_visible() and simulation.dean_visibility_ratio() > 0.0, "主任抽查后在教室短暂可见") and ok
	return ok


## 全员在教室时抽查到访但不扣分，只留一条班级级到访记录。
func _test_inspection_without_violation() -> bool:
	var lesson: Dictionary = _find_cultural_lesson()
	if not _check(not lesson.is_empty(), "存在可抽查的文化课"):
		return false
	var simulation := _at(1, float(lesson.seconds), true)
	if simulation == null:
		return false
	if not _result(simulation.advance(61.0), "推进到第一次抽查检查点", simulation.error_message):
		return false
	var ok: bool = _check(simulation.inspection.last.found.is_empty(), "全员在教室时没有离座记录")
	ok = _check(simulation.students.all(func(student: Dictionary): return int(student.daily_discipline) == 100), "全员在教室不扣纪律分") and ok
	var class_logs: Array = simulation.logs.filter(func(entry: Dictionary): return entry.type == "inspection")
	ok = _check(class_logs.size() == 1 and int(class_logs[0].student_index) == -1, "到访记录归属班级且只有一条") and ok
	return ok


## 体育课全员在操场属于课程安排，不触发抽查也不扣分。
func _test_physical_lesson_exempt() -> bool:
	var lesson: Dictionary = _find_lesson("physical")
	if not _check(not lesson.is_empty(), "第一天存在体育课"):
		return false
	var simulation := _at(1, float(lesson.seconds), true)
	if simulation == null:
		return false
	if not _check(simulation.student_location(0) == "playground" and simulation.student_location(3) == "playground", "体育课全员操场"):
		return false
	var ok: bool = _result(simulation.advance(61.0), "体育课推进跨越抽查检查点", simulation.error_message)
	ok = _check(simulation.inspection.last.is_empty(), "体育课不执行抽查") and ok
	ok = _check(simulation.students.all(func(student: Dictionary): return int(student.daily_discipline) == 100), "体育课不扣纪律分") and ok
	ok = _check(simulation.teacher_on_duty().is_empty(), "体育课没有对应任课老师立绘") and ok
	return ok


## 抽查状态、独立随机流与纪律分必须随存档无损往返并继续同一检查点序列。
func _test_roundtrip() -> bool:
	var lesson: Dictionary = _find_cultural_lesson()
	if not _check(not lesson.is_empty(), "存在可抽查的文化课"):
		return false
	var simulation := _at(1, float(lesson.seconds), true)
	if simulation == null:
		return false
	if not _result(simulation.start_interaction(0, 1, "invite_playground", ""), "两人真实溜去操场", simulation.error_message):
		return false
	if not _result(simulation.advance(61.0), "推进到第一次抽查", simulation.error_message):
		return false
	var path: String = fixture_root.path_join("inspection_active.json")
	if not _result(simulation.save_file(path), "保存含抽查状态的存档", simulation.error_message):
		return false
	var restored := _empty(true)
	if restored == null or not _result(restored.load_file(path, false), "恢复含抽查状态的存档", restored.error_message):
		return false
	var ok: bool = _check(restored.students[0].daily_discipline == simulation.students[0].daily_discipline and restored.students[2].daily_discipline == simulation.students[2].daily_discipline, "纪律分往返原样保留")
	ok = _check(int(restored.inspection.next_check_elapsed) == int(simulation.inspection.next_check_elapsed) and str(restored.inspection.rng_state) == str(simulation.inspection.rng_state), "抽查检查点与独立随机流往返一致") and ok
	ok = _check(restored.inspection.last.found.size() == 2, "最近抽查结果往返保留") and ok
	if not _result(simulation.advance(120.0), "原存档继续推进两个检查点", simulation.error_message) or not _result(restored.advance(120.0), "读档继续推进两个检查点", restored.error_message):
		return false
	ok = _check(restored.students[0].daily_discipline == simulation.students[0].daily_discipline and restored.students[2].daily_discipline == simulation.students[2].daily_discipline, "读档后抽查扣分与原局完全一致") and ok
	ok = _check(restored.inspection.last.found.size() == simulation.inspection.last.found.size() and str(restored.inspection.rng_state) == str(simulation.inspection.rng_state), "读档后继续沿同一抽查随机流") and ok
	return ok


## v4旧档显式迁移为当日基准纪律分；v5缺少抽查状态必须明确拒绝。
func _test_legacy_and_corruption() -> bool:
	var lesson: Dictionary = _find_cultural_lesson()
	if not _check(not lesson.is_empty(), "存在可抽查的文化课"):
		return false
	var simulation := _at(1, float(lesson.seconds), true)
	if simulation == null:
		return false
	if not _result(simulation.advance(61.0), "推进以生成真实抽查状态", simulation.error_message):
		return false
	var parsed: Variant = JSON.parse_string(JSON.stringify(_snapshot(simulation), "", true, true))
	if not parsed is Dictionary:
		return false
	var legacy: Dictionary = parsed.duplicate(true)
	legacy.save_version = 4
	legacy.erase("inspection")
	# v4不含v5抽查与v6每日属性点状态，降级夹具显式剔除。
	legacy.erase("daily_points")
	legacy.erase("npc_growth")
	# v6抢答检查点状态同样不属于旧档。
	legacy.erase("challenge_auto")
	# 课间磨蹭状态同属v6，旧档夹具一并剔除。
	legacy.erase("linger_auto")
	for student: Dictionary in legacy.students:
		student.erase("daily_discipline")
		student.erase("daily_discipline_day")
	var legacy_path: String = fixture_root.path_join("legacy_v4.json")
	if not _write_json(legacy_path, legacy):
		return false
	var restored := _empty(true)
	if restored == null or not _result(restored.load_file(legacy_path, false), "v4旧档明确迁移", restored.error_message):
		return false
	var ok: bool = _check(restored.students.all(func(student: Dictionary): return int(student.daily_discipline) == 100), "v4旧档迁移为当日基准纪律分")
	if not _result(restored.advance(0.0), "迁移后真实推进", restored.error_message):
		return false
	var corrupt: Dictionary = parsed.duplicate(true)
	corrupt.erase("inspection")
	var corrupt_path: String = fixture_root.path_join("corrupt_v5.json")
	_write_json(corrupt_path, corrupt)
	var rejected := _empty()
	if rejected == null:
		return false
	ok = _check(_expect_corrupt_rejected(rejected, corrupt_path), "v5缺少抽查状态被明确拒绝") and ok
	return ok


## 校验v5缺抽查状态的存档被拒绝，并把读取结果写入调试文件供失败排查。
func _expect_corrupt_rejected(rejected: ClassroomSimulation, corrupt_path: String) -> bool:
	var load_result: Error = rejected.load_file(corrupt_path, false)
	var file := FileAccess.open(fixture_root.path_join("corrupt_debug.txt"), FileAccess.WRITE)
	if file != null:
		file.store_string("result=%d msg=%s" % [load_result, rejected.error_message])
		file.close()
	return load_result != OK and rejected.error_message.contains("抽查状态")


## 读取权威保存快照，用于构造旧版与损坏夹具。
func _snapshot(simulation: ClassroomSimulation) -> Dictionary:
	var path: String = fixture_root.path_join("source_%d.json" % Time.get_ticks_usec())
	if simulation.save_file(path) != OK:
		return {}
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## 写入JSON夹具并保留失败原因。
func _write_json(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t", true, true))
	file.close()
	return true


## 统一结果检查，累计失败原因。
func _result(value: Error, label: String, detail: String = "") -> bool:
	return _check(value == OK, label, detail)


## 记录一次断言；失败时输出明确原因。
func _check(condition: bool, label: String, detail: String = "") -> bool:
	checks += 1
	if condition:
		return true
	failures.append(label + ("" if detail.is_empty() else "：" + detail))
	push_error(label + ("" if detail.is_empty() else "：" + detail))
	return false


## 输出完整结束标记；失败数直接决定退出码。
func _finish() -> void:
	if fixture_root.is_empty() or failures.is_empty():
		print("TEACHER_INSPECTION_TEST_%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
		if not fixture_root.is_empty():
			for path: String in DirAccess.get_files_at(fixture_root):
				DirAccess.remove_absolute(fixture_root.path_join(path))
			DirAccess.remove_absolute(fixture_root)
	quit(0 if failures.is_empty() else 1)
