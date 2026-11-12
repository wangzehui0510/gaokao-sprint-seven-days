extends SceneTree
## 动画回归只创建独立真实模拟器、行为树和生产视图，不启动主场景、不访问任何玩家存档。

const LIBRARY_PATH: String = "res://scripts/ui/student_animation_library.gd"
const MANIFEST_PATH: String = "res://assets/pixel/student01/animation_batches/2026-11-11/curated_manifest.json"

# 素材数量是本批交付契约；帧时长和原生尺寸仍从真实清单独立读取。
const EXPECTED_CLIPS: int = 32
const EXPECTED_FRAMES: int = 178

var checks: int = 0
var failures: Array[String] = []
# 每组必须执行到末尾；运行时异常中断某组时也不能只凭其余断言打印通过。
var completed_groups: int = 0
# 延迟加载接口便于在依赖编译失败时输出明确失败，避免测试自身被预加载错误截断。
var library: Variant
# 登记每个真实夹具，失败分支也统一释放视图与行为树。
var fixtures: Array[Dictionary] = []


## 场景树就绪后读取生产素材库，避免初始化阶段尚未建立根节点。
func _initialize() -> void:
	call_deferred("_run")


## 依赖编译或载入失败必须明确退出，不能跳过用例后打印通过。
func _run() -> void:
	for dependency: String in [LIBRARY_PATH, "res://scripts/ui/classroom_view.gd", "res://scripts/core/classroom_simulation.gd", "res://scripts/ai/classroom_behavior_controller.gd"]:
		var dependency_script: Script = load(dependency)
		if dependency_script == null or not dependency_script.can_instantiate():
			_check(false, "动画验收依赖无法实例化：" + dependency)
			_finish()
			return
	library = load(LIBRARY_PATH).new()
	if not _result(library.load_library(), "载入真实学生动画库"):
		_finish()
		return
	_test_real_library_and_sampling()
	_test_semantic_routes()
	_test_real_personal_actions()
	_test_instance_and_intro_lifecycle()
	_test_hidden_intro_expiry()
	_test_physical_course_and_camera()
	_test_dorm_stations()
	_test_pair_stations_and_results()
	_test_together_labels_and_hit_targets()
	_test_visual_time_cannot_deliver()
	_test_real_impact_reaction()
	_check(completed_groups == 11, "十一组动画回归均执行到末尾")
	_finish()


## 核对全部真实纹理、原生画布、锚点和边界采样，防止只加载首帧或仍按两帧播放。
func _test_real_library_and_sampling() -> void:
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not _check(manifest is Dictionary and manifest.has("clips"), "正式动画清单可读取"):
		return
	_check(manifest.clips.size() == EXPECTED_CLIPS and library.clips.size() == EXPECTED_CLIPS, "本批清单与库均为32组")
	var loaded_count: int = 0
	for row: Dictionary in manifest.clips:
		var clip_id: String = String(row.id)
		if not _check(library.clips.has(clip_id), "素材库包含真实片段：" + clip_id):
			continue
		var clip: Dictionary = library.clips[clip_id]
		var frame_count: int = row.frame_paths.size()
		var expected_durations := PackedFloat64Array()
		var total_seconds: float = 0.0
		for frame_index in frame_count:
			# 循环采用统一时长，短手势保留蓄力、接触与回收各自的制作节奏。
			var milliseconds: float = float(row.duration_ms[frame_index]) if row.duration_ms is Array else float(row.duration_ms)
			expected_durations.append(milliseconds / 1000.0)
			total_seconds += milliseconds / 1000.0
		var first_seconds: float = expected_durations[0]
		_check(clip.textures.size() == frame_count and clip.durations.size() == frame_count, "纹理与时长完整加载：" + clip_id)
		_check(clip.canvas == Vector2(row.canvas[0], row.canvas[1]) and clip.anchor == Vector2(row.anchor[0], row.anchor[1]), "保留原生画布和脚锚点：" + clip_id)
		_check(bool(clip.loop) == bool(row.loop), "保留清单循环语义：" + clip_id)
		_check(is_equal_approx(library.duration_seconds(clip_id), total_seconds), "总时长等于全部源帧时长：" + clip_id)
		for frame_index in clip.textures.size():
			var texture: Texture2D = clip.textures[frame_index]
			_check(texture != null and texture.get_size() == clip.canvas, "实际纹理尺寸与画布一致：%s/%02d" % [clip_id, frame_index])
			loaded_count += 1
		for frame_index in expected_durations.size():
			_check(is_equal_approx(float(clip.durations[frame_index]), expected_durations[frame_index]), "逐帧时长来自真实清单：%s/%02d" % [clip_id, frame_index])
		_check(library.sample(clip_id, 0.0) == 0, "新片段从首帧开始：" + clip_id)
		_check(library.sample(clip_id, first_seconds - 0.000001) == 0, "跨时长前不抢跑下一帧：" + clip_id)
		_check(library.sample(clip_id, first_seconds + 0.000001) == 1, "跨时长后进入第二帧：" + clip_id)
		_check(library.sample(clip_id, total_seconds - 0.000001) == frame_count - 1, "最后一帧完整播放：" + clip_id)
		if bool(row.loop):
			_check(library.sample(clip_id, total_seconds + first_seconds * 0.5) == 0, "循环越界后回到首帧：" + clip_id)
			_check(library.sample(clip_id, total_seconds * 3.0 + first_seconds + expected_durations[1] * 0.5) == 1, "大跨度仍按真实循环时长取帧：" + clip_id)
		else:
			_check(library.sample(clip_id, total_seconds + 100.0) == frame_count - 1, "一次性短动作结束后停末帧：" + clip_id)
	_check(loaded_count == EXPECTED_FRAMES, "32组全部178张真实纹理均已加载")
	completed_groups += 1


## 使用已确认的动作族语义约束路由，不把所有行为退回旧学习或静态站姿。
func _test_semantic_routes() -> void:
	var cases: Array[Dictionary] = [
		{"action": "study", "location": "classroom", "main": "A01_write_north"},
		{"action": "preview", "location": "classroom", "main": "A02_read_north"},
		{"action": "daydream", "location": "classroom", "main": "A03_daydream_north"},
		{"action": "sleep", "location": "classroom", "main": "A04_sleep_desk_north"},
		{"action": "dorm_rest", "location": "dorm", "main": "A05_sleep_bed"},
		{"action": "eat_meal", "location": "canteen", "main": "A06_meal_north"},
		{"action": "chores", "location": "classroom", "main": "A09_sweep_south"},
		{"action": "dorm_wash", "location": "dorm", "main": "A10_wash_face_east"},
		{"action": "eye_exercise", "location": "classroom", "main": "A11_eye_exercise_north"},
	]
	for scenario: Dictionary in cases:
		var sequence: Dictionary = library.sequence_for(scenario.action, scenario.location)
		_check(String(sequence.main) == String(scenario.main), "共用动作映射符合语义：" + String(scenario.action))
	for action_id: String in ["study", "sprint_study", "self_test", "physical_study", "morning_exercise", "dorm_workout", "playground_play"]:
		var physical_sequence: Dictionary = library.sequence_for(action_id, "playground", false, "east", true)
		_check(String(physical_sequence.main) in ["A08_stretch_south", "A08_step_east"], "实际体育或运动行为选择运动族：" + action_id)
	var west: Dictionary = library.sequence_for("dorm_game", "dorm", false, "west")
	var east: Dictionary = library.sequence_for("dorm_game", "dorm", false, "east")
	_check(String(west.main) == "A07_computer_west" and String(east.main) == "A07_computer_east", "电脑操作按工位方向区分两版")
	var wake: Dictionary = library.sequence_for("wake_self", "classroom")
	_check(String(wake.intro) == "B04_wake_north" and String(wake.main) != String(wake.intro), "叫醒只使用一次醒来引入段")
	var flick: Dictionary = library.sequence_for("eraser_prank", "classroom")
	_check(String(flick.intro) == "B03_flick_eraser_north", "普通弹橡皮使用桌边弹指引入段")
	completed_groups += 1


## 由真实个人入口产生当前动作，再检查视图实际使用的片段。
func _test_real_personal_actions() -> void:
	var fixture: Dictionary = _fixture(30000.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	var cases: Array[Dictionary] = [
		{"action": "study", "clip": "A01_write_north"},
		{"action": "preview", "clip": "A02_read_north"},
		{"action": "daydream", "clip": "A03_daydream_north"},
		{"action": "sleep", "clip": "A04_sleep_desk_north"},
		{"action": "chores", "clip": "A09_sweep_south"},
		{"action": "eye_exercise", "clip": "A11_eye_exercise_north"},
	]
	for scenario: Dictionary in cases:
		if not _result(simulation.start_action(0, scenario.action, false), "真实发起个人动作：" + String(scenario.action), simulation.error_message):
			return
		room.refresh_state()
		_check(String(simulation.students[0].current_action.action_id) == String(scenario.action), "权威当前动作来自实际执行器：" + String(scenario.action))
		_check(String(room.visual_students[0].main) == String(scenario.clip), "真实动作选中专用主片段：" + String(scenario.action))
		if String(scenario.action) == "chores":
			# 前一项真实趴睡退出后先醒来，这是有效过渡，不应误判为扫地路由失败。
			_check(String(room.rendered_clips[0]) == "B04_wake_north", "趴睡转扫地先播放背向醒来")
			room._process(library.duration_seconds("B04_wake_north") + 0.01)
		_check(String(room.rendered_clips[0]) == String(scenario.clip) and room.rendered_frames[0] == 0, "真实动作切换到专用片段首帧：" + String(scenario.action))
	completed_groups += 1


## 同名动作的新实例重置，普通刷新和镜头切换保留当前播放位置。
func _test_instance_and_intro_lifecycle() -> void:
	var fixture: Dictionary = _fixture(30000.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	if not _result(simulation.start_action(0, "study", false), "真实建立写字实例", simulation.error_message):
		return
	room.refresh_state()
	var first_instance: int = simulation.students[0].current_action.instance_id
	room._process(0.19)
	var advanced_frame: int = room.rendered_frames[0]
	_check(advanced_frame == 1, "写字跨180毫秒后进入第二帧")
	for _refresh_index in 3:
		room.refresh_state()
	_check(room.rendered_frames[0] == advanced_frame and simulation.students[0].current_action.instance_id == first_instance, "重复刷新不重建同一实例动画")
	var authority_before: Dictionary = _snapshot(simulation)
	room.set_view_location("dorm")
	room.set_view_location("classroom")
	_check(String(room.rendered_clips[0]) == "A01_write_north" and room.rendered_frames[0] == advanced_frame, "移开再返回镜头不重播写字首帧")
	_check(_snapshot(simulation) == authority_before, "镜头切换不改业务状态或随机流")
	if not _result(simulation.start_action(0, "study", false), "真实再次发起同名写字动作", simulation.error_message):
		return
	room.refresh_state()
	_check(simulation.students[0].current_action.instance_id != first_instance and room.rendered_frames[0] == 0, "同名新instance_id重新从首帧播放")
	if not _result(simulation.start_action(0, "wake_self", false), "真实发起叫醒自己", simulation.error_message):
		return
	room.refresh_state()
	_check(String(room.rendered_clips[0]) == "B04_wake_north", "叫醒实例开始播放背向醒来")
	room._process(library.duration_seconds("B04_wake_north") + 0.01)
	var main_clip: String = String(library.sequence_for("wake_self", "classroom").main)
	_check(String(room.rendered_clips[0]) == main_clip, "醒来短段播完后回共用主循环")
	room.refresh_state()
	room.refresh_state()
	_check(String(room.rendered_clips[0]) == main_clip, "短段结束后刷新不重复醒来")
	completed_groups += 1


## 隐藏期间不推进视觉时钟，恢复按权威已过去时间跳过过期短手势。
func _test_hidden_intro_expiry() -> void:
	var fixture: Dictionary = _fixture(30000.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	if not _result(simulation.start_action(0, "wake_self", false), "建立隐藏恢复的叫醒实例", simulation.error_message):
		return
	room.refresh_state()
	room.set_animation_enabled(false)
	var before_visual_time: float = room.animation_seconds
	if not _result(simulation.advance(library.duration_seconds("B04_wake_north") + 1.0), "隐藏期间真实时间超过醒来短段", simulation.error_message):
		return
	room._process(100.0)
	_check(not room.is_processing() and room.animation_seconds == before_visual_time, "隐藏时停止视觉时钟与回调")
	room.set_animation_enabled(true)
	room.set_process(false)
	_check(String(room.rendered_clips[0]) == String(library.sequence_for("wake_self", "classroom").main), "恢复当前实例时不补播旧醒来手势")
	completed_groups += 1


## 实际体育课程中的学习选择运动；视图尺寸和镜头变化只影响呈现。
func _test_physical_course_and_camera() -> void:
	var fixture: Dictionary = _fixture(50400.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	if not _check(String(simulation.course_context().subject_id) == "physical", "定位到真实体育课程"):
		return
	for action_id: String in ["study", "sprint_study", "self_test"]:
		if not _result(simulation.start_action(0, action_id, false), "体育课真实启动：" + action_id, simulation.error_message):
			return
		room.set_view_location("auto")
		room.refresh_state()
		_check(String(room.rendered_clips[0]) in ["A08_stretch_south", "A08_step_east"], "体育课学习不再画写字：" + action_id)
	var authority_before: Dictionary = _snapshot(simulation)
	for location: String in ClassroomView.LOCATION_NAMES:
		room.set_view_location(location)
		for scale_value in [1, 2]:
			room.size = Vector2(384, 256) * scale_value
			room._update_geometry()
			_check(room.pixel_scale == scale_value and room.room_origin == Vector2.ZERO, "动画接入保持四场景1倍/2倍整数几何")
		room._process(0.73)
	_check(_snapshot(simulation) == authority_before, "运动动画和四镜头不修改时间、资源、动作、随机流或榜单")
	completed_groups += 1


## 宿舍单人使用真实电脑、洗脸和卧床动作，不把家具整张缩到旧32像素画布。
func _test_dorm_stations() -> void:
	var fixture: Dictionary = _fixture(61200.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	room.set_view_location("dorm")
	for scenario: Dictionary in [
		{"action": "dorm_game", "clips": ["A07_computer_west", "A07_computer_east"]},
		{"action": "dorm_wash", "clips": ["A10_wash_face_east"]},
		{"action": "dorm_rest", "clips": ["A05_sleep_bed"]},
	]:
		if not _result(simulation.start_action(0, scenario.action, false), "真实启动宿舍动作：" + String(scenario.action), simulation.error_message):
			return
		room.refresh_state()
		_check(String(room.rendered_clips[0]) in scenario.clips, "宿舍当前实例显示专用片段：" + String(scenario.action))
		var authority_before: Dictionary = _snapshot(simulation)
		room._process(0.71)
		_check(_snapshot(simulation) == authority_before, "宿舍素材与家具播放不改业务：" + String(scenario.action))
	completed_groups += 1


## 双人站位使用实测脚距；完成反应必须读取真实结算结果。
func _test_pair_stations_and_results() -> void:
	var arm_fixture: Dictionary = _fixture(30000.0)
	if arm_fixture.is_empty():
		return
	var simulation: ClassroomSimulation = arm_fixture.simulation
	var room: Variant = arm_fixture.room
	if not _result(simulation.start_interaction(0, 1, "arm_wrestle"), "真实发起掰手腕", simulation.error_message):
		return
	var interaction: Dictionary = simulation.interactions.back()
	room.refresh_state()
	_check(String(room.rendered_clips[0]) in ["A12_wrestle_west", "A12_wrestle_east"] and String(room.rendered_clips[1]) in ["A12_wrestle_west", "A12_wrestle_east"] and room.rendered_clips[0] != room.rendered_clips[1], "掰手腕双方使用相向僵持素材")
	_check(is_equal_approx(room._together_foot(0).distance_to(room._together_foot(1)), 8.0), "真实掰手腕脚点距为8像素")
	if not _result(simulation.advance(float(interaction.ends_at) - simulation.elapsed_s), "真实完成掰手腕结算", simulation.error_message):
		return
	room.refresh_state()
	_check(interaction.status == "completed" and not interaction.result.is_empty(), "掰手腕结果来自真实执行器")
	if String(interaction.result.outcome) != "tie":
		_check(String(room.rendered_clips[int(interaction.result.winner_index)]) == "B04_happy_south", "真实胜者播放振作反应")
		_check(String(room.rendered_clips[int(interaction.result.loser_index)]) == "B04_sad_south", "真实负者播放失落反应")
	else:
		_check(String(room.rendered_clips[0]).begins_with("B04_") and String(room.rendered_clips[1]).begins_with("B04_"), "真实平局双方只有短结果反应")
	var pillow_fixture: Dictionary = _fixture(61200.0, false)
	if pillow_fixture.is_empty():
		return
	var pillow_simulation: ClassroomSimulation = pillow_fixture.simulation
	var pillow_room: Variant = pillow_fixture.room
	if not _result(pillow_simulation.start_interaction(0, 1, "pillow_fight"), "真实发起枕头大战", pillow_simulation.error_message):
		return
	pillow_room.set_view_location("dorm")
	pillow_room.refresh_state()
	_check(String(pillow_room.rendered_clips[0]) in ["A13_pillow_east", "A13_pillow_west"] and String(pillow_room.rendered_clips[1]) in ["A13_pillow_east", "A13_pillow_west"] and pillow_room.rendered_clips[0] != pillow_room.rendered_clips[1], "枕头双方使用相向挥枕素材")
	_check(is_equal_approx(pillow_room._together_foot(0).distance_to(pillow_room._together_foot(1)), 32.0), "枕头采用已复核的32像素脚点距")
	var pillow_before: Dictionary = _snapshot(pillow_simulation)
	pillow_room._process(20.0)
	_check(_snapshot(pillow_simulation) == pillow_before, "挥枕画面循环不虚构逐击结算")
	var computer_fixture: Dictionary = _fixture(61200.0, false)
	if computer_fixture.is_empty():
		return
	var computer_simulation: ClassroomSimulation = computer_fixture.simulation
	var computer_room: Variant = computer_fixture.room
	# setup后尚未advance，目标真实空闲；不清空当前动作伪造结伴前置。
	_check(computer_simulation.students[1].current_action.is_empty(), "结伴目标由真实新局保持空闲")
	if not _result(computer_simulation.start_interaction(0, 1, "roommate_game"), "真实发起双方电脑开黑", computer_simulation.error_message):
		return
	computer_room.set_view_location("dorm")
	computer_room.refresh_state()
	_check(String(computer_room.rendered_clips[0]) == "B02_point_north", "开黑发起者先播放一次邀请示意")
	computer_room._process(library.duration_seconds("B02_point_north") + 0.01)
	_check(String(computer_room.rendered_clips[0]) in ["A07_computer_west", "A07_computer_east"] and String(computer_room.rendered_clips[1]) in ["A07_computer_west", "A07_computer_east"] and computer_room.rendered_clips[0] != computer_room.rendered_clips[1], "开黑双方使用方向相反的电脑工位")
	_check(is_equal_approx(computer_room._together_foot(0).distance_to(computer_room._together_foot(1)), 64.0), "双电脑脚点距64像素避免两张电脑重合")
	completed_groups += 1


## 普通操场合作必须分开双方姓名，点击区域随真实结伴脚点移动。
func _test_together_labels_and_hit_targets() -> void:
	var fixture: Dictionary = _fixture(30000.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	if not _result(simulation.start_interaction(0, 1, "invite_playground"), "真实发起普通操场合作邀请", simulation.error_message):
		return
	var interaction: Dictionary = simulation.interactions.back()
	room.set_view_location("playground")
	room.refresh_state()
	_check(interaction.status == "active" and interaction.action_id == "invite_playground", "普通合作检查使用真实在途邀请")
	_check(simulation.student_location(0) == "playground" and simulation.student_location(1) == "playground", "真实邀请已将双方带到操场")
	_check(room.visual_students[0].visible and room.visual_students[1].visible and not room.visual_students[2].visible and not room.visual_students[3].visible, "操场只显示真实到场的合作双方")
	_check(is_equal_approx(room._render_foot(0).distance_to(room._render_foot(1)), 28.0), "普通操场合作保留28像素近距站位")
	var authority_before: Dictionary = _snapshot(simulation)
	# 同时核对原生、双倍与带居中偏移的窗口，防止标签与人物使用不同坐标系。
	for viewport_size: Vector2 in [Vector2(384, 256), Vector2(768, 512), Vector2(800, 560)]:
		room.size = viewport_size
		room._update_geometry()
		var left_label: Rect2 = room._student_label_rect(0)
		var right_label: Rect2 = room._student_label_rect(1)
		_check(not left_label.intersects(right_label), "普通合作双方姓名框不相交：%s" % viewport_size)
		for index in [0, 1]:
			var label: Rect2 = left_label if index == 0 else right_label
			var foot: Vector2 = room._render_foot(index)
			var old_anchor: Vector2 = room._student_anchor(index)
			_check(foot != old_anchor, "真实结伴脚点已离开原独立站位：%s/%d" % [viewport_size, index])
			_check(room._student_at(label.get_center()) == index, "点击分开后的姓名框命中对应角色：%s/%d" % [viewport_size, index])
			_check(room._student_at(room.room_origin + foot * room.pixel_scale) == index, "点击命中跟随当前结伴脚点：%s/%d" % [viewport_size, index])
			_check(room._student_at(room.room_origin + old_anchor * room.pixel_scale) == -1, "旧独立站位不再保留角色命中：%s/%d" % [viewport_size, index])
	_check(_snapshot(simulation) == authority_before, "姓名框和命中查询不改变合作、时间、资源或随机流")
	completed_groups += 1


## 纸条飞行和正文送达继续服从权威执行器，独立画面时钟不能提前完成。
func _test_visual_time_cannot_deliver() -> void:
	var fixture: Dictionary = _fixture(28800.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	if not _result(simulation.start_interaction(0, 1, "send_note", "动画不能伪造的真实纸条"), "通过生产入口发送纸条", simulation.error_message):
		return
	var interaction: Dictionary = simulation.interactions.back()
	room.refresh_state()
	_check(String(room.rendered_clips[0]) == "B03_throw_paper_north", "纸条发起实例播放抛出短动作")
	var authority_before: Dictionary = _snapshot(simulation)
	room._process(1000.0)
	room.refresh_state()
	_check(_snapshot(simulation) == authority_before and interaction.status == "active", "大量动画时间不推进业务或伪造完成")
	_check(simulation.notes.is_empty() and room.visual_interactions.size() == 1 and not room.visual_interactions[0].delivered, "抛出短动作结束不等于正文送达")
	if not _result(simulation.advance(5.0), "真实执行纸条五秒", simulation.error_message):
		return
	room.refresh_state()
	_check(is_equal_approx(float(room.visual_interactions[0].progress), 0.25) and not room.visual_interactions[0].delivered, "短手势之后的飞行仍读取真实四分之一进度")
	if not _result(simulation.advance(float(interaction.ends_at) - simulation.elapsed_s), "实际执行纸条到完成边界", simulation.error_message):
		return
	room.refresh_state()
	_check(interaction.status == "completed" and simulation.notes.size() == 1 and room.visual_interactions[0].delivered, "真实结束记录之后才有送达正文")
	completed_groups += 1


## 橡皮的目标反应只由真实命中触发，播放弹指不能制造受击或额外收益。
func _test_real_impact_reaction() -> void:
	var fixture: Dictionary = _fixture(28800.0)
	if fixture.is_empty():
		return
	var simulation: ClassroomSimulation = fixture.simulation
	var room: Variant = fixture.room
	if not _result(simulation.start_interaction(0, 3, "eraser_prank"), "真实发起橡皮捣乱", simulation.error_message):
		return
	var interaction: Dictionary = simulation.interactions.back()
	room.refresh_state()
	_check(String(room.rendered_clips[0]) == "B03_flick_eraser_north", "发起者播放真实弹指素材")
	room._process(100.0)
	_check(room.visual_impacts.is_empty() and String(room.rendered_clips[3]) != "B04_react_south", "单纯播放弹指不让目标提前受击")
	if not _result(simulation.advance(float(interaction.ends_at) - simulation.elapsed_s), "真实执行橡皮至命中", simulation.error_message):
		return
	room.refresh_state()
	_check(interaction.status == "completed" and room.visual_impacts.size() == 1 and room.visual_impacts[0].target_index == 3, "命中关联真实目标和完成记录")
	_check(String(room.rendered_clips[3]) == "B04_react_south", "真实受击目标播放短反应")
	_check(String(room.rendered_clips[0]) != "B04_react_south" and String(room.rendered_clips[1]) != "B04_react_south", "发起者和旁观者不冒充受击目标")
	room.set_animation_enabled(false)
	if not _result(simulation.advance(ClassroomView.REPORT_VISUAL_SECONDS + 0.1), "隐藏期间真实经过结果提示寿命", simulation.error_message):
		return
	room.set_animation_enabled(true)
	room.set_process(false)
	_check(room.visual_impacts.is_empty() and String(room.rendered_clips[3]) != "B04_react_south", "隐藏后恢复不补播已过期的受击反应")
	completed_groups += 1


## 夹具复制真实配置后只隔离无关随机内容，所有动作与结果均由生产入口产生。
func _fixture(seconds: float, advance_initial: bool = true) -> Dictionary:
	var configuration := GameConfig.new()
	if not _result(configuration.load_file(), "读取真实配置"):
		return {}
	configuration.globals["events_enabled"] = false
	configuration.globals["answer_challenge_auto_chance"] = 0.0
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, 517), "建立独立真实班级", simulation.error_message):
		return {}
	# 随机竞争另有专项集成；本组不让随机邀请打断正在核对的真实动画实例。
	simulation.phase_scope.social_auto_actions = []
	simulation.phase_scope.dorm_auto_actions = ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"]
	var behavior := ClassroomBehaviorController.new()
	root.add_child(behavior)
	behavior.setup(simulation)
	simulation.decision_handler = behavior.decide
	if not _result(simulation.set_debug_time(1, seconds), "定位真实课表", simulation.error_message):
		behavior.free()
		return {}
	if advance_initial and not _result(simulation.advance(0.0), "真实行为树开始当前活动", simulation.error_message):
		behavior.free()
		return {}
	var room := ClassroomView.new()
	room.size = Vector2(384, 256)
	root.add_child(room)
	room.set_process(false)
	room.bind_game(simulation)
	var fixture: Dictionary = {"simulation": simulation, "behavior": behavior, "room": room}
	fixtures.append(fixture)
	return fixture


## 对权威状态做深拷贝，检查画面既不结算也不消耗随机流。
func _snapshot(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"day": simulation.day, "clock": simulation.clock_seconds, "elapsed": simulation.elapsed_s,
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true), "next_action": simulation.next_action_number,
		"rng_seed": str(simulation.rng.seed), "rng_state": str(simulation.rng.state),
		"round": simulation.get_round_summary(), "final": simulation.get_final_board(),
	}


## 记录生产入口的真实错误码和原因，不吞掉失败或返回默认成功。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：%s %s" % [message, result, detail] if result != OK else message)


## 汇总每个可读断言，失败留在本次验收输出中。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 统一释放本次夹具，并以明确完成标记和非零失败退出码结束。
func _finish() -> void:
	for fixture: Dictionary in fixtures:
		fixture.room.free()
		fixture.behavior.free()
	if failures.is_empty():
		print("STUDENT_ANIMATIONS_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("STUDENT_ANIMATIONS_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
