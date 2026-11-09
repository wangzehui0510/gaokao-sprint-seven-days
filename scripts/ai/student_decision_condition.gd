extends ConditionLeaf

# 同一条件节点脚本由共享蓝图指定分支语义，不保存任何角色资源。
var decision_kind: String


# 只在没有有效动作的决策点检查课表和阈值，学习中不按低专注强制重选。
func tick(actor: Node, _blackboard: Blackboard) -> int:
	var student_actor := actor as StudentBehaviorActor
	var simulation := student_actor.simulation
	var context: Dictionary = simulation.course_context()
	var state: Dictionary = student_actor.student_state()
	var knowledge_course: bool = context["subject_kind"] == "knowledge"
	var tired: bool = float(state["stamina"]) < float(simulation.config.globals["sleep_stamina_threshold"])
	# 开小差阈值按自律性个性化：自律越高阈值越低，更晚走神。
	var distracted: bool = float(state["focus"]) < simulation.distraction_threshold(student_actor.student_index)
	var matches := false
	match decision_kind:
		"dorm":
			matches = simulation.is_dorm_free_time(student_actor.student_index)
		"scheduled":
			# 宿舍选择失败应明确暴露，不能落到课表分支假装成功选择默认休息。
			matches = not knowledge_course and not simulation.is_dorm_free_time(student_actor.student_index)
		"sleep":
			matches = knowledge_course and tired
		"social":
			# 竞争互动只在知识课、非疲劳且已分心时发起：专注的学生学习，只有无聊/分心者才去干扰对手，避免开局全员逃课。
			matches = knowledge_course and not tired and distracted
		"distraction":
			matches = knowledge_course and not tired and distracted
		"study":
			matches = knowledge_course and not tired and not distracted
	return SUCCESS if matches else FAILURE
