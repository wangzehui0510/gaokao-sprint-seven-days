extends ActionLeaf

# 共享蓝图指定本叶子的选择方式；实际时长和费用仍由执行器按配表处理。
var decision_kind: String


# 选择动作、选科或竞争互动目标写入本角色黑板；所有抽取都走唯一执行器的随机流。
func tick(actor: Node, blackboard: Blackboard) -> int:
	var student_actor := actor as StudentBehaviorActor
	var simulation := student_actor.simulation
	var context: Dictionary = simulation.course_context()
	var action_id: String = ""
	var selected_subject: String = ""
	var social_target: int = -1
	match decision_kind:
		"dorm":
			# 宿舍选择含双人活动目标；结伴自习抽中后由本人显式选科。
			var option: Dictionary = simulation.select_dorm_option(student_actor.student_index)
			if option.is_empty():
				return FAILURE
			action_id = String(option["action_id"])
			social_target = int(option.get("target_index", -1))
			if simulation.config.actions[action_id].knowledge_mode == "selected_subject":
				selected_subject = simulation.select_cultural_subject(student_actor.student_index)
		"sleep":
			action_id = "sleep"
		"social":
			# 竞争互动：自律越低越爱发起；roll未通过或无合法目标则失败，落到后续学习/开小差分支。
			if not simulation.should_initiate_social(student_actor.student_index):
				return FAILURE
			var option: Dictionary = simulation.select_social_action(student_actor.student_index)
			if option.is_empty():
				return FAILURE
			action_id = String(option["action_id"])
			social_target = int(option["target_index"])
			selected_subject = String(option["selected_subject_id"])
		"distraction":
			action_id = simulation.select_auto_action(student_actor.student_index)
			if action_id.is_empty():
				return FAILURE
		"scheduled", "study":
			action_id = String(context["default_action_id"])
	blackboard.set_value("requested_action_id", action_id)
	blackboard.set_value("requested_subject_id", selected_subject)
	blackboard.set_value("social_target_index", social_target)
	blackboard.set_value("decision_kind", decision_kind)
	return SUCCESS
