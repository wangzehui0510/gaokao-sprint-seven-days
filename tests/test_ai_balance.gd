extends SceneTree
## 使用正式系数、多种真实八点加法及固定种子观察七天结果；不把小样本视为平衡定稿。

const SUBJECTS: Array[String] = ["chinese", "math", "english", "physical"]
const SEEDS: Array[int] = [261109, 817233, 940137]
const BUILDS: Dictionary = {
	"均衡": {"attention": 2, "discipline": 2, "health": 2, "intelligence": 2},
	"专注": {"attention": 8},
	"自律": {"discipline": 8},
	"健康": {"health": 8},
	"智力": {"intelligence": 8},
}
# 输出由父进程按普通日志保存，统计只读真实运行记录，不修改成绩或权威数值。
var samples: Array[Dictionary] = []
var checks: int = 0
var failures: Array[String] = []


## 场景树就绪后创建真实四人行为树。
func _initialize() -> void:
	call_deferred("_run")


## 每条路线均完整推进七天，显式输出真实分数、动作和互动覆盖。
func _run() -> void:
	for build_name: String in BUILDS:
		for seed_value: int in SEEDS:
			if not _sample(build_name, BUILDS[build_name], seed_value):
				_finish()
				return
	_report()
	_finish()


## 属性必须消费本人真实初始八点，其他三名角色保留正式预设。
func _sample(build_name: String, build: Dictionary, seed_value: int) -> bool:
	var config := GameConfig.new()
	if not _check(config.load_file() == OK, "正式配置可读：" + config.error_message):
		return false
	var simulation := ClassroomSimulation.new()
	if not _check(simulation.setup(config, seed_value) == OK, "建立真实七天数值观察局：" + simulation.error_message):
		return false
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	simulation.decision_handler = controller.decide
	for attribute_id: String in build:
		if not _check(simulation.allocate_attribute(attribute_id, int(build[attribute_id])) == OK, "真实分配八点路线：" + build_name):
			controller.free()
			return false
	_check(simulation.students[0].unspent_points == 0, "每个观察路线恰好花完八点初始属性")
	if not _check(simulation.set_debug_time(1, 0.0) == OK, "定位七天起点") or not _check(simulation.advance(6.0 * 86400.0 + 60000.0) == OK, "真实执行完整七天：" + simulation.error_message):
		controller.free()
		return false
	var final: Dictionary = simulation.get_final_board()
	if not _check(simulation.is_round_finished() and final.status == "published" and final.rows.size() == 4, "连续运行真实生成完整四人终榜"):
		controller.free()
		return false
	var player_row: Dictionary = {}
	for row: Dictionary in final.rows:
		if row.student_id == "student_0":
			player_row = row
	if not _check(not player_row.is_empty(), "真实最终榜包含本人"):
		controller.free()
		return false
	var knowledge: Dictionary = simulation.students[0].knowledge.duplicate(true)
	var score_by_subject: Dictionary = {}
	for subject: String in SUBJECTS:
		var board: Dictionary = simulation.get_exam_board(subject)
		if not _check(board.status == "published", "完整路线存在真实单科快照：" + subject):
			controller.free()
			return false
		for row: Dictionary in board.rows:
			if row.student_id == "student_0":
				score_by_subject[subject] = row.score
	for index in 4:
		var student: Dictionary = simulation.students[index]
		_check(student.current_action.is_empty(), "终局每名角色均停止真实动作")
		_check(is_finite(student.focus) and is_finite(student.stamina) and student.focus >= 0.0 and student.stamina >= 0.0, "七天资源始终保留有效实际结果")
		for subject: String in SUBJECTS:
			_check(is_finite(student.knowledge[subject]) and student.knowledge[subject] > 0.0, "每名角色四科均获得真实正知识")
	var activity_counts: Dictionary = {}
	for entry: Dictionary in simulation.logs:
		if entry.type == "start" and int(entry.student_index) == 0:
			var action_id: String = entry.details.action_id
			activity_counts[action_id] = int(activity_counts.get(action_id, 0)) + 1
	var social_counts: Dictionary = {}
	for interaction: Dictionary in simulation.interactions:
		var action_id: String = interaction.action_id
		social_counts[action_id] = int(social_counts.get(action_id, 0)) + 1
	var sample: Dictionary = {
		"build": build_name, "seed": seed_value, "score": player_row.score, "rank": player_row.rank,
		"subjects": score_by_subject, "knowledge": knowledge, "actions": activity_counts,
		"social": social_counts, "interaction_count": simulation.interactions.size(),
	}
	samples.append(sample)
	print("AI_BALANCE_SAMPLE " + JSON.stringify(sample, "", true, true))
	simulation.decision_handler = Callable()
	controller.free()
	return true


## 汇总只说明本次固定样本，不擅自给出不存在单一最优点法的全局证明。
func _report() -> void:
	var summaries: Array[Dictionary] = []
	for build_name: String in BUILDS:
		var total: float = 0.0
		var minimum: float = INF
		var maximum: float = -INF
		for sample: Dictionary in samples:
			if sample.build == build_name:
				total += float(sample.score)
				minimum = minf(minimum, float(sample.score))
				maximum = maxf(maximum, float(sample.score))
		summaries.append({"build": build_name, "mean": total / SEEDS.size(), "min": minimum, "max": maximum})
	_check(samples.size() == BUILDS.size() * SEEDS.size(), "五条真实加点路线各完成三个固定种子七天")
	print("AI_BALANCE_SUMMARY " + JSON.stringify(summaries, "", true, true))


## 明确记录失败，样本必须完整才允许最终通过。
func _check(condition: bool, label: String) -> bool:
	checks += 1
	if not condition:
		failures.append(label)
	return condition


## 观察组通过只代表真实运行有效，数值平衡结论由完整样本另行判断。
func _finish() -> void:
	if failures.is_empty():
		print("AI_BALANCE_TEST_PASS checks=%d samples=%d" % [checks, samples.size()])
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("AI_BALANCE_TEST_FAIL checks=%d failures=%d samples=%d" % [checks, failures.size(), samples.size()])
		quit(1)
