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
	var distracted: bool = float(state["focus"]) < float(simulation.config.globals["distraction_focus_threshold"])
	var matches := false
	match decision_kind:
		"scheduled":
			matches = not knowledge_course
		"sleep":
			matches = knowledge_course and tired
		"distraction":
			matches = knowledge_course and not tired and distracted
		"study":
			matches = knowledge_course and not tired and not distracted
	return SUCCESS if matches else FAILURE
