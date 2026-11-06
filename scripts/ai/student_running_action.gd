extends ActionLeaf


# 进行中的真实动作继续运行；主动指令建立的新动作也由这一分支接管。
func tick(actor: Node, _blackboard: Blackboard) -> int:
	var student_actor := actor as StudentBehaviorActor
	var action: Dictionary = student_actor.student_state()["current_action"]
	if not action.is_empty() and float(action["ends_at"]) > student_actor.simulation.elapsed_s:
		return RUNNING
	return FAILURE
