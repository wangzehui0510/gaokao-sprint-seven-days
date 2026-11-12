extends ActionLeaf


# 所有选择最终只提交一次；有目标时走双人入口（竞争互动与宿舍结伴），个人动作走统一执行入口。
func tick(actor: Node, blackboard: Blackboard) -> int:
	var student_actor := actor as StudentBehaviorActor
	var action_id: String = blackboard.get_value("requested_action_id")
	var subject_id: String = blackboard.get_value("requested_subject_id")
	var target_index: int = int(blackboard.get_value("social_target_index"))
	var result: Error
	if target_index >= 0:
		result = student_actor.simulation.start_interaction(
			student_actor.student_index,
			target_index,
			action_id, "", subject_id,
			"自主干扰" if blackboard.get_value("decision_kind") == "social" else "自主结伴",
		)
	else:
		result = student_actor.simulation.start_action(student_actor.student_index, action_id, true, -1, "自主选择", subject_id)
	return SUCCESS if result == OK else FAILURE
