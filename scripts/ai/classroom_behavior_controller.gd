class_name ClassroomBehaviorController
extends Node

const ACTOR_SCRIPT = preload("res://scripts/ai/student_behavior_actor.gd")
const RUNNING_SCRIPT = preload("res://scripts/ai/student_running_action.gd")
const CONDITION_SCRIPT = preload("res://scripts/ai/student_decision_condition.gd")
const SELECT_SCRIPT = preload("res://scripts/ai/student_select_action.gd")
const SUBMIT_SCRIPT = preload("res://scripts/ai/student_submit_action.gd")

# 全班共享执行器；每棵树各有独立Actor、Blackboard和节点运行游标。
var simulation: ClassroomSimulation
var trees: Array[BeehaveTree] = []


# 从同一个蓝图工厂实例化全班的树，玩家角色不使用另一套自主逻辑。
func setup(value: ClassroomSimulation) -> void:
	simulation = value
	for index in simulation.students.size():
		var actor := ACTOR_SCRIPT.new() as StudentBehaviorActor
		actor.name = "StudentBehavior_%d" % index
		actor.setup(simulation, index)
		add_child(actor)
		var tree := _create_shared_tree(actor)
		actor.add_child(tree)
		tree.enabled = true
		tree.blackboard.set_value("student_index", index)
		trees.append(tree)


# 由统一时序执行器在动作或课表边界回调，不依靠帧数重复开始动作。
func decide(student_index: int) -> void:
	var result: int = trees[student_index].tick()
	if result == BeehaveTree.FAILURE:
		# 空候选和执行失败明确暴露，不静默改成学习、休息或默认成功。
		if simulation.error_message.is_empty():
			simulation.error_message = "角色%d的自主行为没有可执行动作，请检查课表、阶段范围与自主动作配表。" % (student_index + 1)
		push_error(simulation.error_message)


# 全班启动和验收都复用单角色入口，运行中的动作只会返回RUNNING。
func tick_all() -> void:
	for index in trees.size():
		decide(index)


# 树只选择和提交动作；执行器独立负责时长、资源积分、完成与打断。
func _create_shared_tree(actor: StudentBehaviorActor) -> BeehaveTree:
	var tree := BeehaveTree.new()
	tree.name = "SharedStudentBehavior"
	tree.process_thread = BeehaveTree.ProcessThread.MANUAL
	tree.actor = actor
	var root := SelectorComposite.new()
	root.name = "ContinueOrDecide"
	tree.add_child(root)
	var running := RUNNING_SCRIPT.new()
	running.name = "ContinueCurrentAction"
	root.add_child(running)
	var decision := SequenceComposite.new()
	decision.name = "SelectThenSubmit"
	root.add_child(decision)
	var priorities := SelectorComposite.new()
	priorities.name = "ScheduleAndResources"
	decision.add_child(priorities)
	for kind in ["dorm", "scheduled", "sleep", "social", "distraction", "study"]:
		var branch := SequenceComposite.new()
		branch.name = String(kind).capitalize()
		priorities.add_child(branch)
		var condition := CONDITION_SCRIPT.new()
		condition.name = "IsApplicable"
		condition.decision_kind = kind
		branch.add_child(condition)
		var select := SELECT_SCRIPT.new()
		select.name = "SelectConfiguredAction"
		select.decision_kind = kind
		branch.add_child(select)
	var submit := SUBMIT_SCRIPT.new()
	submit.name = "SubmitToActionExecutor"
	decision.add_child(submit)
	return tree
