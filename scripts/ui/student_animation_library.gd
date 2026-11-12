class_name StudentAnimationLibrary
extends RefCounted
## 学生动作库只管理验收帧和播放选择，不持有业务时钟、收益或互动结果。

const MANIFEST_PATH = "res://assets/pixel/student01/animations/manifest.json"
# 每个片段缓存原生画布、锚点、逐帧秒数和纹理，完整帧已经包含手部。
var clips: Dictionary = {}


## 一次载入正式索引；素材或索引损坏明确报错，不能悄悄回到旧两帧人物。
func load_library() -> Error:
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_error("学生动画索引无法读取：" + MANIFEST_PATH)
		return FileAccess.get_open_error()
	var parser := JSON.new()
	var result: Error = parser.parse(file.get_as_text())
	if result != OK:
		push_error("学生动画索引解析失败：" + parser.get_error_message())
		return result
	clips.clear()
	for row: Dictionary in parser.data.clips:
		var textures: Array[Texture2D] = []
		var durations := PackedFloat64Array()
		for index in row.frame_paths.size():
			var path: String = "res://assets/pixel/student01/animations/" + String(row.frame_paths[index])
			var texture: Texture2D = load(path)
			if texture == null:
				push_error("学生动画帧载入失败：" + path)
				return ERR_FILE_CANT_READ
			textures.append(texture)
			var milliseconds: float = float(row.duration_ms[index]) if row.duration_ms is Array else float(row.duration_ms)
			durations.append(milliseconds / 1000.0)
		clips[String(row.id)] = {
			"textures": textures, "durations": durations, "loop": bool(row.loop),
			"canvas": Vector2(row.canvas[0], row.canvas[1]),
			"anchor": Vector2(row.anchor[0], row.anchor[1]),
		}
	return OK


## 逐帧累加真实制作时长，循环取余，单次手势在自身片段内停末帧。
func sample(clip_id: String, age_seconds: float) -> int:
	var clip: Dictionary = clips[clip_id]
	var age: float = maxf(age_seconds, 0.0)
	if clip.loop:
		age = fposmod(age, duration_seconds(clip_id))
	var durations: PackedFloat64Array = clip.durations
	for index in durations.size():
		if age < durations[index] - 0.000000001:
			return index
		age -= durations[index]
	return durations.size() - 1


## 单次片段播完后，调用者可恢复当前真实动作的主循环。
func duration_seconds(clip_id: String) -> float:
	var total: float = 0.0
	for value: float in clips[clip_id].durations:
		total += value
	return total


## 业务动作保持各自ID；此处仅复用同族身体，目标角色不会跟随发起者一起吃东西。
func sequence_for(action_id: String, location: String, target: bool = false, facing: String = "east", physical: bool = false) -> Dictionary:
	var idle: String = "A03_relax_north" if location == "classroom" else "A03_idle_south"
	var main: String = idle
	var intro: String = ""
	match action_id:
		"study", "sprint_study", "self_test":
			main = "A08_stretch_south" if physical else "A01_write_north"
		"notes", "exam", "art_class", "dorm_practice", "solve_together":
			main = "A01_write_north"
			if action_id == "solve_together" and not target:
				intro = "B02_point_north"
		"preview", "dorm_study", "read_comic", "read_comic_item", "study_together":
			main = "A02_read_north"
			if action_id == "study_together" and not target:
				intro = "B02_point_north"
		"daydream": main = "A03_daydream_north"
		"standing_study", "exercise_slack": main = "A03_idle_south"
		"sleep": main = "A04_sleep_desk_north"
		"dorm_rest", "linger_dorm_rest": main = "A05_sleep_bed"
		"rest", "lunch_rest":
			if location == "dorm": main = "A05_sleep_bed"
		"snack_self": main = "A06_snack_south"
		"eat_meal", "invite_canteen": main = "A06_meal_north"
		"eat_candy_item": main = "A06_candy_south"
		"dorm_game", "roommate_game": main = "A07_computer_" + facing
		"physical_study", "morning_exercise", "dorm_workout": main = "A08_stretch_south"
		"playground_play", "invite_playground": main = "A08_step_east"
		"chores": main = "A09_sweep_south"
		"dorm_wash": main = "A10_wash_face_east"
		"eye_exercise": main = "A11_eye_exercise_north"
		"arm_wrestle": main = "A12_wrestle_" + facing
		"pillow_fight": main = "A13_pillow_" + facing
		"remind_self", "focus_command": intro = "B04_react_south"
		"wake_self": intro = "B04_wake_north"
		"send_note":
			if not target: intro = "B03_throw_paper_north"
		"eraser_prank", "use_eraser":
			if not target: intro = "B03_flick_eraser_north"
		"answer_challenge": intro = "B02_raise_north"
		"borrow_notes", "give_comic_item", "swap_book", "swap_book_boost":
			main = "A02_read_north"
			# 借笔记由目标递出；这只是手势，道具接力仍未补齐，不能生成物品转移。
			var giver: bool = target if action_id == "borrow_notes" else not target
			intro = "B01_give_north" if giver else ("B01_receive_left_north" if facing == "west" else "B01_receive_right_north")
		"feed_snack", "give_candy_item":
			main = ("A06_snack_south" if action_id == "feed_snack" else "A06_candy_south") if target else idle
			intro = "B01_receive_left_north" if target else "B02_point_north"
		"remind_friend", "encourage", "prank_together", "take_comic", "report":
			if not target or action_id == "encourage": intro = "B02_point_north"
		"", "break_rest", "music_class", "linger_break", "recall_classroom", "bathroom": pass
		_:
			assert(false, "未配置学生动画的动作：" + action_id)
	if action_id in ["invite_canteen", "invite_playground", "roommate_game"] and not target:
		intro = "B02_point_north"
	return {"main": main, "intro": intro}


## 北向坐姿才需要单独桌面；电脑、床和洗手台已经包含家具，不能重复叠加。
func needs_desk(clip_id: String) -> bool:
	return clip_id.ends_with("_north") and not clip_id.begins_with("B04_react")
