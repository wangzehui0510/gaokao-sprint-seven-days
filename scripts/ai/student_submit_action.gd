extends ActionLeaf


# 所有选择最终只提交一次；竞争互动走双人入口，个人动作走统一执行入口。
func tick(actor: Node, blackboard: Blackboard) -> int:
	var student_actor := actor as StudentBehaviorActor
	var action_id: String = blackboard.get_value("requested_action_id")
	var subject_id: String = blackboard.get_value("requested_subject_id")
	var result: Error
	if blackboard.get_value("decision_kind") == "social":
		result = student_actor.simulation.start_interaction(
			student_actor.student_index,
			int(blackboard.get_value("social_target_index")),
			action_id, "", subject_id,
		)
	else:
		result = student_actor.simulation.start_action(student_actor.student_index, action_id, true, -1, "自主选择", subject_id)
	return SUCCESS if result == OK else FAILURE
