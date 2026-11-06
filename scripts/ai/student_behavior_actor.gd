class_name StudentBehaviorActor
extends Node

# 四个树实例引用同一个执行器，但索引始终指向各自的权威角色状态。
var simulation: ClassroomSimulation
var student_index: int


# 只绑定角色身份，不缓存资源、背包或动作进度。
func setup(value: ClassroomSimulation, index: int) -> void:
	simulation = value
	student_index = index


# 每次从执行器读取角色数据，避免黑板成为第二份资源来源。
func student_state() -> Dictionary:
	return simulation.students[student_index]
