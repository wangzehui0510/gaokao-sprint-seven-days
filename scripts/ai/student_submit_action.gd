extends ActionLeaf


# 所有选择最终只提交一次；失败向树根传播，不再尝试另一动作伪装成功。
func tick(actor: Node, blackboard: Blackboard) -> int:
	var student_actor := actor as StudentBehaviorActor
	var action_id: String = blackboard.get_value("requested_action_id")
	var result: Error = student_actor.simulation.start_action(student_actor.student_index, action_id, true)
	return SUCCESS if result == OK else FAILURE
