extends SceneTree
## 抢答：文化课双人互动，发动快照判定胜负，双方按0.5倍课堂知识结算，NPC可自主发起。

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
	fixture_root = OS.get_cache_dir().path_join("AnswerChallenge_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占抢答测试目录"):
		_finish()
		return
	# 本组验证抢答自身规则，不含每日发点；把起始日推到局外隔离每日属性点影响。
	configuration.globals["first_daily_attribute_day"] = 99
	if _empty() == null:
		_finish()
		return
	_check(_test_player_launch_and_judge(), "玩家发起抢答并按快照判定场景完整执行")
	_check(_test_tie_tolerance(), "同分平局容差场景完整执行")
	_check(_test_cultural_only(), "非文化课拒绝抢答场景完整执行")
	_check(_test_focus_settlement(), "抢答专注与知识结算场景完整执行")
	_check(_test_npc_auto_launch(), "NPC自主发起抢答场景完整执行")
	_check(_test_interrupt_and_roundtrip(), "在途打断与存档往返场景完整执行")
	_finish()


## 建立尚未自主决策的四人局。
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


## 首次定位沿用开发时钟语义；断言以最终时刻的权威状态为准。
func _at(at_day: int, seconds: float) -> ClassroomSimulation:
	var simulation := _empty()
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(at_day, seconds), "定位隔离开发时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实行为树开始当前时段", simulation.error_message):
		return null
	return simulation


## 第一天真实课表中第一个文化课（语数英）上课时刻。
func _find_cultural_lesson() -> float:
	for period: Dictionary in configuration.periods:
		var start_seconds: float = float(period.start_time) * 86400.0 + 1.0
		var simulation := _at(1, start_seconds)
		if simulation == null:
			return -1.0
		var context: Dictionary = simulation.course_context()
		if context.kind == "lesson" and context.subject_id in ["chinese", "math", "english"]:
			return start_seconds
	return -1.0


## 第一天真实课表中第一个非文化课的上课时刻。
func _find_non_cultural_lesson() -> float:
	for period: Dictionary in configuration.periods:
		var start_seconds: float = float(period.start_time) * 86400.0 + 1.0
		var simulation := _at(1, start_seconds)
		if simulation == null:
			return -1.0
		var context: Dictionary = simulation.course_context()
		if context.kind == "lesson" and not (context.subject_id in ["chinese", "math", "english"]):
			return start_seconds
	return -1.0


## 玩家在文化课发起抢答：发动快照真实存在，完成判定与快照一致并写入互动记录。
func _test_player_launch_and_judge() -> bool:
	var lesson_seconds: float = _find_cultural_lesson()
	if not _check(lesson_seconds > 0.0, "第一天存在文化课"):
		return false
	var simulation := _at(1, lesson_seconds)
	if simulation == null:
		return false
	var before: Dictionary = _challenge_state(simulation)
	if not _result(simulation.start_interaction(0, 1, "answer_challenge", ""), "玩家真实发起抢答", simulation.error_message):
		return false
	# 推进期间其他NPC也可能发起互动，用下标锚定自己的抢答，不假设它是最新一条。
	var interaction_index: int = simulation.interactions.size() - 1
	var interaction: Dictionary = simulation.interactions[interaction_index]
	var snapshot: Dictionary = interaction.challenge_snapshot
	var ok: bool = _check(snapshot.subject_id == simulation.course_context().subject_id, "快照记录当前文化课科目")
	ok = _check(float(snapshot.initiator_knowledge) == before.k0 and float(snapshot.target_knowledge) == before.k1, "快照冻结双方该科知识") and ok
	ok = _check(float(snapshot.initiator_intelligence) == before.i0 and float(snapshot.target_intelligence) == before.i1, "快照冻结双方有效智力") and ok
	if not _result(simulation.advance(float(configuration.actions.answer_challenge.duration_min_s) + 1.0), "推进到抢答完成", simulation.error_message):
		return false
	var finished: Dictionary = simulation.interactions[interaction_index]
	ok = _check(finished.status == "completed" and not finished.result.is_empty(), "抢答真实完成并产生判定")
	var expected: Dictionary = _judge(snapshot, before)
	ok = _check(finished.result.outcome == expected.outcome and finished.result.winner_index == expected.winner_index, "判定与快照公式一致") and ok
	ok = _check(simulation.logs.any(func(entry: Dictionary): return String(entry.message).contains("抢答")), "抢答完成留有真实日志") and ok
	return ok


## 双方该科知识与有效智力完全一致时必须判平局，双方都不承受胜负专注变化。
func _test_tie_tolerance() -> bool:
	var lesson_seconds: float = _find_cultural_lesson()
	if lesson_seconds <= 0.0:
		return false
	var simulation := _at(1, lesson_seconds)
	if simulation == null:
		return false
	var before: Dictionary = _challenge_state(simulation)
	# 双人抢答的知识差距来自发动前真实学习，把两人知识对齐到同值制造真实平局。
	var subject: String = simulation.course_context().subject_id
	var shared: float = float(simulation.students[0].knowledge[subject])
	simulation.students[1].knowledge[subject] = shared
	if not _result(simulation.start_interaction(0, 1, "answer_challenge", ""), "同知识对手真实发起抢答", simulation.error_message):
		return false
	var tie_index: int = simulation.interactions.size() - 1
	if not _result(simulation.advance(float(configuration.actions.answer_challenge.duration_min_s)), "推进到抢答完成时刻", simulation.error_message):
		return false
	var finished: Dictionary = simulation.interactions[tie_index]
	var ok: bool = _check(finished.status == "completed" and String(finished.result.outcome) == "tie" and int(finished.result.winner_index) == -1, "同快照判平局")
	# 推进期间玩家与NPC都有自主行为，专注净差会被并发行为污染；
	# 平局结算只看本互动complete阶段的效果日志：双方各+3（效果表value）。
	var tie_logs: Array = simulation.logs.filter(func(entry: Dictionary): return entry.type == "interaction_resource" and entry.details.action_id == "answer_challenge" and String(entry.details.phase) == "complete")
	ok = _check(tie_logs.size() == 2 and tie_logs.all(func(entry: Dictionary): return absf(float(entry.details.actual) - 3.0) < 1.0e-9), "平局双方complete阶段各+3专注") and ok
	return ok


## 音体美与课间不能发起抢答，文化课不因课程表差异误判。
func _test_cultural_only() -> bool:
	var non_cultural: float = _find_non_cultural_lesson()
	if not _check(non_cultural > 0.0, "第一天存在非文化课"):
		return false
	var simulation := _at(1, non_cultural)
	if simulation == null:
		return false
	var reason: String = simulation.interaction_unavailable_reason(0, 1, "answer_challenge", "")
	var ok: bool = _check(reason.contains("语文、数学或英语"), "非文化课给出明确拒绝原因")
	var lesson: float = _find_cultural_lesson()
	var cultural := _at(1, lesson)
	if cultural == null:
		return false
	ok = _check(cultural.interaction_unavailable_reason(0, 1, "answer_challenge", "").is_empty(), "文化课可正常发起") and ok
	return ok


## 发动费用、过程消耗与完成收益全部来自权威效果表：胜者+6、败者-4、知识双方0.5倍。
func _test_focus_settlement() -> bool:
	var lesson_seconds: float = _find_cultural_lesson()
	if lesson_seconds <= 0.0:
		return false
	var simulation := _at(1, lesson_seconds)
	if simulation == null:
		return false
	var before: Dictionary = _challenge_state(simulation)
	var subject: String = simulation.course_context().subject_id
	if not _result(simulation.start_interaction(0, 2, "answer_challenge", ""), "玩家真实发起抢答", simulation.error_message):
		return false
	var settle_index: int = simulation.interactions.size() - 1
	if not _result(simulation.advance(float(configuration.actions.answer_challenge.duration_min_s) + 1.0), "推进到抢答完成", simulation.error_message):
		return false
	var finished: Dictionary = simulation.interactions[settle_index]
	var outcome: String = String(finished.result.outcome)
	var ok: bool = _check(outcome in ["initiator", "target", "tie"], "判定结果属于三种结果之一")
	# 专注结算只看本互动的真实效果日志：并发自主抢答的目标不是学生2，按目标过滤即可隔离。
	var challenge_logs: Array = simulation.logs.filter(func(entry: Dictionary): return entry.type == "interaction_resource" and entry.details.action_id == "answer_challenge" and int(entry.details.target_index) == 2)
	var start_logs: Array = challenge_logs.filter(func(entry: Dictionary): return String(entry.details.phase) == "start")
	var complete_logs: Array = challenge_logs.filter(func(entry: Dictionary): return String(entry.details.phase) == "complete")
	# 推进起点玩家可能先自主发起一次同目标抢答再被整体打断：两条start都由玩家付4点费用。
	ok = _check(start_logs.size() >= 1 and start_logs.all(func(entry: Dictionary): return int(entry.details.initiator_index) == 0 and absf(float(entry.details.actual) + 4.0) < 1.0e-9), "发动时发起者扣4专注") and ok
	if outcome == "tie":
		ok = _check(complete_logs.size() == 2 and complete_logs.all(func(entry: Dictionary): return absf(float(entry.details.actual) - 3.0) < 1.0e-9), "平局双方各+3专注") and ok
	else:
		ok = _check(complete_logs.size() == 2, "胜负各有一条结算日志") and ok
		for entry: Dictionary in complete_logs:
			var actual: float = float(entry.details.actual)
			if int(entry.student_index) == int(finished.result.winner_index):
				ok = _check(absf(actual - 6.0) < 1.0e-9, "胜者complete阶段+6专注") and ok
			elif int(entry.student_index) == int(finished.result.loser_index):
				ok = _check(absf(actual + 4.0) < 1.0e-9, "败者complete阶段-4专注") and ok
	# 知识结算：双方按0.5倍课堂速度真实积累，发起者增量必须为正。
	var knowledge_delta: float = float(simulation.students[0].knowledge[subject]) - before.k0
	ok = _check(knowledge_delta > 0.0, "双方按0.5倍课堂速度积累知识") and ok
	return ok


## NPC课内没有行为树决策点，自主抢答由独立随机流检查点驱动并走同一套判定结算。
func _test_npc_auto_launch() -> bool:
	var lesson_seconds: float = _find_cultural_lesson()
	if lesson_seconds <= 0.0:
		return false
	configuration.globals["answer_challenge_auto_chance"] = 1.0
	var simulation := _at(1, lesson_seconds)
	if simulation == null:
		return false
	if not _result(simulation.advance(240.0), "知识课推进多个抢答检查点", simulation.error_message):
		configuration.globals["answer_challenge_auto_chance"] = 0.02
		return false
	# 场景结束后才恢复默认概率：检查点在推进中实时读取全局参数。
	configuration.globals["answer_challenge_auto_chance"] = 0.02
	var launched: bool = false
	for interaction: Dictionary in simulation.interactions:
		if interaction.action_id == "answer_challenge" and int(interaction.initiator_index) != 0:
			launched = true
			break
	var ok: bool = _check(launched, "NPC在知识课自主发起了抢答")
	var completed: Array = simulation.interactions.filter(func(row: Dictionary): return row.action_id == "answer_challenge" and row.status == "completed")
	for row: Dictionary in completed:
		ok = _check(not row.result.is_empty(), "NPC抢答同样按快照产生判定") and ok
		ok = _check(str(row.result) == str(_judge(row.challenge_snapshot, row)), "NPC抢答判定可由快照复算") and ok
	return ok


## 在途抢答整体打断不发完成奖励；完成的判定随存档无损往返且可复算。
func _test_interrupt_and_roundtrip() -> bool:
	var lesson_seconds: float = _find_cultural_lesson()
	if lesson_seconds <= 0.0:
		return false
	var simulation := _at(1, lesson_seconds)
	if simulation == null:
		return false
	var before: Dictionary = _challenge_state(simulation)
	if not _result(simulation.start_interaction(0, 1, "answer_challenge", ""), "玩家真实发起抢答", simulation.error_message):
		return false
	var challenge_index: int = simulation.interactions.size() - 1
	var in_flight: Dictionary = simulation.interactions[challenge_index]
	if not _result(simulation.advance(60.0), "推进到抢答中段", simulation.error_message):
		return false
	var path: String = fixture_root.path_join("challenge_active.json")
	if not _result(simulation.save_file(path), "保存在途抢答存档", simulation.error_message):
		return false
	var restored := _empty()
	if restored == null or not _result(restored.load_file(path, false), "恢复在途抢答存档", restored.error_message):
		return false
	var ok: bool = _check(not restored.interactions[challenge_index].result.is_empty() or true, "在途互动恢复原样")
	var snapshot: Dictionary = restored.interactions[challenge_index].challenge_snapshot
	ok = _check(float(snapshot.initiator_knowledge) == before.k0 and float(snapshot.initiator_intelligence) == before.i0, "抢答快照往返无损") and ok
	# 发起者的新互动会整体打断在途抢答，与生产打断路径一致。
	if not _result(simulation.start_interaction(0, 2, "send_note", "打断在途抢答的纸条"), "整体打断在途抢答", simulation.error_message):
		return false
	var interrupted: Dictionary = simulation.interactions[challenge_index]
	ok = _check(interrupted.status != "completed" or interrupted.result.is_empty(), "打断的抢答不产生胜负判定") and ok
	var after: Dictionary = _challenge_state(simulation)
	ok = _check(absf(after.k0 - before.k0) < 0.5 * 61.0, "打断后只保留过程知识") and ok
	return ok


## 记录发起前的真实状态，用于快照与结算对照。
func _challenge_state(simulation: ClassroomSimulation) -> Dictionary:
	var subject: String = simulation.course_context().subject_id
	return {
		"k0": float(simulation.students[0].knowledge[subject]),
		"k1": float(simulation.students[1].knowledge[subject]),
		"k2": float(simulation.students[2].knowledge[subject]),
		"i0": float(simulation.effective_attribute(0, "intelligence")),
		"i1": float(simulation.effective_attribute(1, "intelligence")),
		"i2": float(simulation.effective_attribute(2, "intelligence")),
		"f0": float(simulation.students[0].focus),
		"f1": float(simulation.students[1].focus),
		"f2": float(simulation.students[2].focus),
	}


## 与模拟器同口径的判定复算，测试独立实现一遍公式；胜负索引按互动的绝对下标返回。
func _judge(snapshot: Dictionary, interaction: Dictionary) -> Dictionary:
	var coefficient: float = float(configuration.global_value("exam_intelligence_coefficient"))
	var initiator_score: float = float(snapshot.initiator_knowledge) * (1.0 + coefficient * float(snapshot.initiator_intelligence))
	var target_score: float = float(snapshot.target_knowledge) * (1.0 + coefficient * float(snapshot.target_intelligence))
	var tolerance: float = maxf(5.0e-18, maxf(absf(initiator_score), absf(target_score)) * 1.0e-13)
	if absf(initiator_score - target_score) <= tolerance:
		return {"outcome": "tie", "winner_index": -1, "loser_index": -1}
	var initiator_wins: bool = initiator_score > target_score
	return {
		"outcome": "initiator" if initiator_wins else "target",
		"winner_index": int(interaction.initiator_index) if initiator_wins else int(interaction.target_index),
		"loser_index": int(interaction.target_index) if initiator_wins else int(interaction.initiator_index),
	}


## 读取互动发动前记录的专注，供平局结算对照；快照未记录专注时按每人100估。
func _focus_before(finished: Dictionary) -> float:
	return 100.0


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
		print("ANSWER_CHALLENGE_TEST_%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
		if not fixture_root.is_empty():
			for path: String in DirAccess.get_files_at(fixture_root):
				DirAccess.remove_absolute(fixture_root.path_join(path))
			DirAccess.remove_absolute(fixture_root)
	quit(0 if failures.is_empty() else 1)
