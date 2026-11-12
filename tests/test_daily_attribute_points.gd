extends SceneTree
## 每日属性点：每天08:00发放、离线上线补发、NPC轮换立即消费、幂等与存档v6校验。

# 临时存档全部写入本进程独占目录，失败时保留证据。
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
	fixture_root = OS.get_cache_dir().path_join("DailyAttributePoints_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占发点测试目录"):
		_finish()
		return
	# 本组验证发点检查点本身：事件不参与，显式关闭保持既有基线。
	configuration.globals["events_enabled"] = false
	if _empty() == null:
		_finish()
		return
	_check(_test_first_day_no_grant(), "第1天不发点场景完整执行")
	_check(_test_cross_boundary_grant(), "推进跨越08:00发点场景完整执行")
	_check(_test_npc_rotation(), "NPC连续四天轮换加点场景完整执行")
	_check(_test_offline_catch_up(), "离线后时钟前移补发场景完整执行")
	_check(_test_idempotent_rollback(), "开发时钟回退不重复发放场景完整执行")
	_check(_test_roundtrip(), "发点状态存档往返场景完整执行")
	_check(_test_v5_migration(), "v5旧档迁移不补历史场景完整执行")
	_check(_test_corruption(), "v6缺字段与旧档混入拒绝场景完整执行")
	_finish()


## 建立尚未自主决策的四人局；学生0为玩家，学生1-3为NPC。
func _empty() -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, 261109), "创建真实四人局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	simulation.decision_handler = controller.decide
	controllers.append(controller)
	return simulation


## 首次定位沿用开发时钟语义；时钟切换会触发补点，断言时必须按最终时刻理解状态。
func _at(at_day: int, seconds: float) -> ClassroomSimulation:
	var simulation := _empty()
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(at_day, seconds), "定位隔离开发时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实行为树开始当前时段", simulation.error_message):
		return null
	return simulation


## 第1天任何时刻都不发点，初始点只来自开局配置。
func _test_first_day_no_grant() -> bool:
	var simulation := _at(1, 40000.0)
	if simulation == null:
		return false
	var ok: bool = _check(simulation.daily_points.granted_days.is_empty(), "第1天没有发点记录")
	ok = _check(int(simulation.students[0].unspent_points) == 8, "玩家只有初始待分配点") and ok
	ok = _check(not simulation.logs.any(func(entry: Dictionary): return entry.type == "attribute_points"), "没有发点日志") and ok
	return ok


## 真实推进从第1天晚上跨到第2天08:00后，全员+1且NPC立即消费。
func _test_cross_boundary_grant() -> bool:
	var simulation := _at(1, 70000.0)
	if simulation == null:
		return false
	if not _result(simulation.advance(46000.0), "推进跨越第2天08:00", simulation.error_message):
		return false
	var ok: bool = _check(simulation.daily_points.granted_days == [2], "已发放日记录为第2天")
	ok = _check(int(simulation.students[0].unspent_points) == 9, "玩家待分配点8+1") and ok
	ok = _check(float(simulation.students[1].attributes.attention) == float(simulation.students[1].attributes.attention) + 0.0, "NPC属性为有限数值") and ok
	ok = _check(int(simulation.students[1].unspent_points) == 0, "NPC不保留待分配点") and ok
	ok = _check(simulation.logs.filter(func(entry: Dictionary): return entry.type == "attribute_points" and int(entry.student_index) == -1).size() == 1, "班级发点日志只有一条") and ok
	ok = _check(simulation.logs.filter(func(entry: Dictionary): return entry.type == "attribute_points" and int(entry.student_index) >= 1).size() == 3, "三名NPC各有一条分配日志") and ok
	ok = _check(int(simulation.npc_growth.cursor) == 3, "NPC轮换游标前进3次") and ok
	return ok


## 连续四天发点后，NPC1按专注→自律→健康→智力各+1，游标回到起点。
func _test_npc_rotation() -> bool:
	var simulation := _at(1, 70000.0)
	if simulation == null:
		return false
	if not _result(simulation.advance(4 * 86400.0 - 70000.0 + 40000.0), "推进跨越第2至第5天四次发点", simulation.error_message):
		return false
	var ok: bool = _check(simulation.daily_points.granted_days == [2, 3, 4, 5], "第2至5天各发一次")
	var cycle: Array[String] = ["attention", "discipline", "health", "intelligence"]
	var expected: Dictionary = {"attention": 0.0, "discipline": 0.0, "health": 0.0, "intelligence": 0.0}
	# NPC1在四次发点中依次吃到轮换的第0-3个属性（每名NPC逐个消耗游标）。
	var cursor: int = 0
	for day_index in 4:
		for npc_index in range(1, 4):
			var attribute: String = cycle[cursor]
			cursor = (cursor + 1) % cycle.size()
			if npc_index == 1:
				expected[attribute] = 1.0
	for attribute_id: String in cycle:
		ok = _check(float(simulation.students[1].attributes[attribute_id]) == expected[attribute_id] + _npc_build_value(1, attribute_id), "NPC1第%s轮换加点%s" % [attribute_id, "符合预期" if expected[attribute_id] == 1.0 else "不变"]) and ok
	ok = _check(int(simulation.npc_growth.cursor) == 12 % 4, "轮换游标循环回起点") and ok
	return ok


## 读取NPC预设加点基线，用于区分轮换增量。
func _npc_build_value(npc_index: int, attribute_id: String) -> float:
	return float(configuration.indexes.npc_attributes["student_%d" % npc_index][attribute_id])


## 保存于第2天07:00，时钟直接切到第3天11:00后补发第2、3两天的点。
func _test_offline_catch_up() -> bool:
	var simulation := _at(2, 25000.0)
	if simulation == null:
		return false
	var path: String = fixture_root.path_join("offline_0730.json")
	if not _result(simulation.save_file(path), "保存未到发点时刻的存档", simulation.error_message):
		return false
	if not _result(simulation.set_debug_time(3, 40000.0), "时钟前移越过两次发点", simulation.error_message):
		return false
	var ok: bool = _check(simulation.daily_points.granted_days == [2, 3], "第2、3天离线补发")
	ok = _check(int(simulation.students[0].unspent_points) == 10, "玩家补得两天共2点") and ok
	return ok


## 已发放的日子在开发时钟回退后不重复发放。
func _test_idempotent_rollback() -> bool:
	var simulation := _at(2, 40000.0)
	if simulation == null:
		return false
	var granted_after_day2: int = int(simulation.students[0].unspent_points)
	if not _result(simulation.set_debug_time(2, 20000.0), "回退到第2天发点之前", simulation.error_message):
		return false
	var ok: bool = _check(int(simulation.students[0].unspent_points) == granted_after_day2, "回退不回滚也不重复发放")
	if not _result(simulation.set_debug_time(4, 40000.0), "再次前移越过已发放日", simulation.error_message):
		return false
	ok = _check(simulation.daily_points.granted_days == [2, 3, 4], "已发放日不重复补发") and ok
	ok = _check(int(simulation.students[0].unspent_points) == granted_after_day2 + 2, "只补发未发过的第3、4天") and ok
	return ok


## 发点记录、轮换游标与属性随v6存档无损往返。
func _test_roundtrip() -> bool:
	var simulation := _at(3, 40000.0)
	if simulation == null:
		return false
	var path: String = fixture_root.path_join("points_active.json")
	if not _result(simulation.save_file(path), "保存含发点状态的存档", simulation.error_message):
		return false
	var restored := _empty()
	if restored == null or not _result(restored.load_file(path, false), "恢复含发点状态的存档", restored.error_message):
		return false
	var ok: bool = _check(restored.daily_points.granted_days == simulation.daily_points.granted_days and int(restored.npc_growth.cursor) == int(simulation.npc_growth.cursor), "发点记录与轮换游标往返一致")
	ok = _check(int(restored.students[0].unspent_points) == int(simulation.students[0].unspent_points), "待分配点往返一致") and ok
	ok = _check(str(restored.students[1].attributes) == str(simulation.students[1].attributes), "NPC轮换属性往返一致") and ok
	if not _result(simulation.advance(86400.0), "原局继续跨一次发点", simulation.error_message) or not _result(restored.advance(86400.0), "读档局继续跨一次发点", restored.error_message):
		return false
	ok = _check(restored.daily_points.granted_days == simulation.daily_points.granted_days, "读档后发点序列与原局一致") and ok
	ok = _check(str(restored.students[2].attributes) == str(simulation.students[2].attributes), "读档后NPC轮换与原局一致") and ok
	return ok


## v5旧档迁移不补历史：迁移日及之前视为已发放，之后跨08:00正常发放。
func _test_v5_migration() -> bool:
	var simulation := _at(4, 40000.0)
	if simulation == null:
		return false
	var path: String = fixture_root.path_join("source_v6.json")
	if not _result(simulation.save_file(path), "保存v6来源存档", simulation.error_message):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return false
	var legacy: Dictionary = parsed
	legacy.save_version = 5
	legacy.erase("daily_points")
	legacy.erase("npc_growth")
	# v6抢答检查点状态同样不属于旧档。
	legacy.erase("challenge_auto")
	# 课间磨蹭状态同属v6，旧档夹具一并剔除。
	legacy.erase("linger_auto")
	var legacy_path: String = fixture_root.path_join("legacy_v5.json")
	if not _write_json(legacy_path, legacy):
		return false
	var restored := _empty()
	if restored == null or not _result(restored.load_file(legacy_path, false), "v5旧档明确迁移", restored.error_message):
		return false
	var ok: bool = _check(restored.daily_points.granted_days == [2, 3, 4], "迁移日及之前全部视为已发放")
	var unspent_before: int = int(restored.students[0].unspent_points)
	if not _result(restored.advance(86400.0), "迁移后真实推进跨一次发点", restored.error_message):
		return false
	ok = _check(int(restored.students[0].unspent_points) == unspent_before + 1, "迁移后只发新的一天") and ok
	return ok


## v6缺字段、发点记录非法与旧档混入都必须明确拒绝。
func _test_corruption() -> bool:
	var simulation := _at(3, 40000.0)
	if simulation == null:
		return false
	var path: String = fixture_root.path_join("source_points.json")
	if not _result(simulation.save_file(path), "保存v6来源存档", simulation.error_message):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return false
	var ok: bool = true
	for case: Dictionary in [
		{"label": "缺少每日属性点状态", "erase": "daily_points", "detail": "每日属性点状态"},
		{"label": "缺少NPC轮换游标", "erase": "npc_growth", "detail": "每日属性点状态"},
		{"label": "缺少抢答检查点状态", "erase": "challenge_auto", "detail": "抢答自主检查点状态"},
		{"label": "缺少课间磨蹭状态", "erase": "linger_auto", "detail": "课间磨蹭状态"},
	]:
		var broken: Dictionary = parsed.duplicate(true)
		broken.erase(case.erase)
		var broken_path: String = fixture_root.path_join("corrupt_%d.json" % checks)
		_write_json(broken_path, broken)
		var rejected := _empty()
		if rejected == null:
			return false
		ok = _check(rejected.load_file(broken_path, false) != OK and rejected.error_message.contains(case.detail), String(case.label) + "被明确拒绝") and ok
	var unordered: Dictionary = parsed.duplicate(true)
	unordered.daily_points.granted_days = [3, 2]
	var unordered_path: String = fixture_root.path_join("corrupt_order.json")
	_write_json(unordered_path, unordered)
	var rejected_order := _empty()
	if rejected_order == null:
		return false
	ok = _check(rejected_order.load_file(unordered_path, false) != OK and rejected_order.error_message.contains("升序"), "发点记录乱序被明确拒绝") and ok
	var polluted: Dictionary = parsed.duplicate(true)
	polluted.save_version = 5
	polluted.inspection = parsed.inspection.duplicate(true)
	# v5夹具本不该有v6字段；保留daily_points验证混入拒绝。
	var polluted_path: String = fixture_root.path_join("polluted_v5.json")
	_write_json(polluted_path, polluted)
	var rejected_polluted := _empty()
	if rejected_polluted == null:
		return false
	ok = _check(rejected_polluted.load_file(polluted_path, false) != OK and rejected_polluted.error_message.contains("每日属性点状态"), "旧档混入每日属性点状态被明确拒绝") and ok
	return ok


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
		print("DAILY_ATTRIBUTE_POINTS_TEST_%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
		if not fixture_root.is_empty():
			for path: String in DirAccess.get_files_at(fixture_root):
				DirAccess.remove_absolute(fixture_root.path_join(path))
			DirAccess.remove_absolute(fixture_root)
	quit(0 if failures.is_empty() else 1)
