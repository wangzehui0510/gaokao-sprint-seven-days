extends ActionLeaf

# 共享蓝图指定本叶子的选择方式；实际时长和费用仍由执行器按配表处理。
var decision_kind: String


# 仅选出动作ID写入本角色黑板，尚不扣费或改变当前动作。
func tick(actor: Node, blackboard: Blackboard) -> int:
	var student_actor := actor as StudentBehaviorActor
	var simulation := student_actor.simulation
	var context: Dictionary = simulation.course_context()
	var action_id: String
	match decision_kind:
		"sleep":
			action_id = "sleep"
		"distraction":
			var candidates: Array[Dictionary] = simulation.get_auto_candidates(student_actor.student_index)
			if candidates.is_empty():
				return FAILURE
			# 使用执行器保存的同一随机流，读档不会为树额外重抽动作或时长。
			var total_weight := 0.0
			for candidate in candidates:
				total_weight += float(candidate["weight"])
			if total_weight <= 0.0:
				return FAILURE
			# 将原生32位随机整数映射到左闭右开区间，避免端点恰等于总权重而漏选。
			var choice: float = float(simulation.rng.randi()) / 4294967296.0 * total_weight
			var cursor := 0.0
			for candidate in candidates:
				cursor += float(candidate["weight"])
				if choice < cursor:
					action_id = String(candidate["action_id"])
					break
		"scheduled", "study":
			action_id = String(context["default_action_id"])
	blackboard.set_value("requested_action_id", action_id)
	blackboard.set_value("decision_kind", decision_kind)
	return SUCCESS
