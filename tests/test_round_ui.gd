extends SceneTree
## 在独立工程内验证真实七天榜单、考试公布与结束局界面，不以预填成绩代替业务结果。

# 所有临时文件均属于隔离应用，检查只统计真实断言。
var checks: int = 0
var failures: Array[String] = []


## 等待场景树建立后再创建隔离测试环境。
func _initialize() -> void:
	call_deferred("_run")


## 子进程验证专用用户目录，避免UI生命周期触及正式存档。
func _run() -> void:
	if "--isolated-round-ui" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with("ClassroomRoundUiTest_") or marker not in OS.get_user_data_dir():
		push_error("七天榜单界面测试用户目录未隔离，拒绝运行。")
		quit(1)
		return
	create_timer(120.0).timeout.connect(func():
		_check(false, "七天榜单界面验收超时，可能存在未处理脚本错误")
		_finish()
	)
	await _test_interface()
	_finish()


## 复制生产源码并使用独立应用名称，实际配置与执行器均保持原样。
func _launch_isolated_project() -> void:
	var marker: String = "ClassroomRoundUiTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	for folder: String in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		var result: Error = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制榜单隔离工程失败：%s，错误码%s。" % [folder, result])
			quit(1)
			return
	var project := ConfigFile.new()
	if project.load("res://project.godot") != OK:
		push_error("无法读取榜单测试所需真实工程设置。")
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	if project.save(isolated_root.path_join("project.godot")) != OK:
		push_error("无法保存榜单隔离工程设置。")
		quit(1)
		return
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--editor", "--import"], output, true)
	if exit_code != 0:
		for line in output:
			print(line)
		quit(exit_code)
		return
	output.clear()
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", "res://tests/test_round_ui.gd", "--", "--isolated-round-ui"], output, true)
	for line in output:
		print(line)
	print("ROUND_UI_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 逐项复制并返回真实文件错误，不遗漏源码后继续测试。
func _copy_directory(source: String, destination: String) -> Error:
	var directory := DirAccess.open(source)
	if directory == null:
		return ERR_CANT_OPEN
	var result: Error = DirAccess.make_dir_recursive_absolute(destination)
	if result != OK:
		return result
	for folder in directory.get_directories():
		result = _copy_directory(source.path_join(folder), destination.path_join(folder))
		if result != OK:
			return result
	for filename in directory.get_files():
		result = DirAccess.copy_absolute(source.path_join(filename), destination.path_join(filename))
		if result != OK:
			return result
	return OK


## 真实界面仅省略无头环境不支持的原生初始化，榜单必须经正常时间推进产生。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	for method: String in ["_show_round_boards", "_refresh_round_interface", "_reset_round_interface"]:
		if not ui.has_method(method):
			_check(false, "生产界面缺少阶段5入口：" + method)
			ui.free()
			return
	ui._build_theme()
	ui._build_interface()
	var configuration := GameConfig.new()
	if not _result(configuration.load_file(), "读取真实配表", configuration.error_message):
		ui.free()
		return
	ui.configuration = configuration
	if not _reset_session(ui):
		ui.free()
		return
	_check(ui.inspector_tabs.get_tab_count() == 6, "榜单只追加第六页")
	for index in 6:
		_check(ui.inspector_tabs.get_tab_title(index) == ["人物", "课表", "记录", "互动", "背包", "榜单"][index], "第%d页名称和索引稳定" % index)
	_test_pending_and_read_only(ui)
	if not _test_daily_publication(ui):
		ui.free()
		return
	await _test_layout_and_scroll(ui)
	if not await _test_exam_publication(ui):
		ui.free()
		return
	await _test_finished_interface(ui)
	if not _test_offline_frozen_interface(ui) or not _test_legacy_interface(ui):
		ui.free()
		return
	_test_restart_filters(ui)
	if not _test_hot_reload_display(ui):
		ui.free()
		return
	_check(not FileAccess.file_exists("user://classroom_save.json") and not FileAccess.file_exists("user://classroom_debug_save.json"), "只读榜单与测试重建不写入正式或开发局文件")
	print("ROUND_UI_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 首次推进前明确第1天早课，避免宿主当前时刻提前影响测试起点。
func _reset_session(ui: Control) -> bool:
	if is_instance_valid(ui.behavior):
		ui.remove_child(ui.behavior)
		ui.behavior.queue_free()
	ui.simulation = ClassroomSimulation.new()
	if not _result(ui.simulation.setup(ui.configuration, 711026), "建立真实七天局", ui.simulation.error_message):
		return false
	if not _result(ui.simulation.set_debug_time(1, 28800.0), "定位第1天08:00", ui.simulation.error_message):
		return false
	ui._attach_behavior()
	return _result(OK if not ui.fatal_error and ui.simulation != null else ERR_INVALID_DATA, "真实界面绑定四棵行为树")


## 筛选仅查看记录，不能移动草稿、修改角色或提前产生榜单与成绩。
func _test_pending_and_read_only(ui: Control) -> void:
	ui._set_interaction_target(2)
	ui.note_input.text = "查看榜单后仍发给小陈"
	ui._on_note_text_changed(ui.note_input.text)
	var drafts: Dictionary = ui.note_drafts.duplicate(true)
	var before: Dictionary = _authoritative_snapshot(ui)
	ui._on_menu(4)
	_check(ui.inspector_panel.visible and ui.inspector_tabs.current_tab == 5, "设置菜单打开第六页榜单")
	_check(ui.round_board_text.text.contains("尚未发布"), "未到16:40明确显示知识榜尚未发布")
	for view_type in 3:
		ui.round_type_picker.select(view_type)
		ui._on_round_type_selected(view_type)
		for subject_index in 4:
			ui.round_subject_picker.select(subject_index)
			ui._on_round_subject_selected(subject_index)
			if view_type == 0:
				ui.round_day_picker.select(2)
				ui._on_round_day_selected(2)
	_check(_authoritative_snapshot(ui) == before, "遍历榜单与未来日期不改资源、知识、库存、动作、随机流或业务记录")
	_check(ui.interaction_target_index == 2 and ui.note_input.text == "查看榜单后仍发给小陈" and ui.note_drafts == drafts, "榜单查看保持原收件人与各自草稿")
	_check(ui.round_board_text.text.contains("总榜尚未发布"), "七天结束前不伪造总榜")
	ui.round_type_picker.select(0)
	ui._on_round_type_selected(0)
	ui.round_day_picker.select(0)
	ui._on_round_day_selected(0)
	ui.round_subject_picker.select(0)
	ui._on_round_subject_selected(0)


## 当日榜由完整真实课程推进产生，显示数值直接核对核心记录。
func _test_daily_publication(ui: Control) -> bool:
	if not _result(ui.simulation.advance(60000.0 - ui.simulation.clock_seconds), "真实推进至第1天16:40", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	ui._show_round_boards()
	var board: Dictionary = ui.simulation.get_daily_board(1, "chinese")
	_check(board.status == "published" and board.rows.size() == 4, "真实第1天产生四人语文知识榜")
	_check(board.knowledge_scope == "school" and ui.round_board_text.text.contains("语文在校知识榜") and ui.round_board_text.text.contains("在线实际状态"), "日榜显示真实科目、在校统计口径与在线来源")
	_check(ui.round_board_text.text.contains("统计") and ui.round_board_text.text.contains("16:40:00"), "日榜显示实际统计起止")
	var positive_knowledge: bool = false
	for row: Dictionary in board.rows:
		_check(ui.round_board_text.text.contains(String(row.name)) and ui.round_board_text.text.contains(ui._interaction_number(float(row.knowledge))), "日榜显示真实成员和新增知识：%s" % row.name)
		if float(row.knowledge) > 0.0:
			positive_knowledge = true
	_check(positive_knowledge, "榜单非预填零分，至少一人有真实学习知识")
	var before: Dictionary = _authoritative_snapshot(ui)
	for repeat_index in 3:
		ui._refresh_round_interface()
		ui._show_round_boards()
	_check(_authoritative_snapshot(ui) == before, "反复刷新已发布知识榜不重复结算")
	return true


## 固定两种窗口尺寸，长考试来源在榜单文本区域滚动而不撑大窗口。
func _test_layout_and_scroll(ui: Control) -> void:
	for scale in [1, 2]:
		ui._set_window_scale(scale)
		ui._show_round_boards()
		await process_frame
		await process_frame
		var expected := Vector2i(684, 320) if scale == 1 else Vector2i(1068, 576)
		_check(Vector2i(ui.size) == expected and ui._get_layout_size() == expected, "%d倍榜单保持既定窗口尺寸" % scale)
		_check(ui.round_board_text.scroll_active and not ui.round_board_text.fit_content, "%d倍榜单使用固定可滚动区域" % scale)
		var bounds := Rect2(ui.global_position, ui.size).grow(1.0)
		_check_control_bounds(ui, bounds, "%d倍知识榜" % scale)
		ui.round_day_picker.select(0)
		ui._on_round_day_selected(0)
		ui._refresh_interface()
		_check(ui.round_view_day == 1 and ui.round_day_picker.get_selected_id() == 1, "后台刷新不重置用户选定历史日期")


## 七天真实培养后到开考边界取值，课程结束前不得把快照结果显示为已公布成绩。
func _test_exam_publication(ui: Control) -> bool:
	var target: float = 6.0 * 86400.0 + 14.0 * 3600.0 - 1.0
	var current: float = (ui.simulation.day - 1.0) * 86400.0 + ui.simulation.clock_seconds
	if not _result(ui.simulation.advance(target - current), "真实推进至第7天语文开考前1秒", ui.simulation.error_message):
		return false
	ui.round_type_picker.select(1)
	ui._on_round_type_selected(1)
	ui.round_subject_picker.select(0)
	ui._on_round_subject_selected(0)
	_check(ui.round_board_text.text.contains("尚未开考"), "开考前不展示预测分")
	# 只调整创建日期来模拟退出至第8天，保存内容仍由真实七天执行器和生产保存器产生。
	var original_date: String = ui.simulation.created_date
	var midnight: int = int(Time.get_unix_time_from_datetime_string(original_date + "T00:00:00"))
	ui.simulation.created_date = Time.get_date_string_from_unix_time(midnight - 7 * 86400)
	var freeze_result: Error = ui.simulation.save_file("user://round_ui_offline_source.json")
	ui.simulation.created_date = original_date
	if not _result(freeze_result, "保存开考前真实冻结状态至隔离文件", ui.simulation.error_message):
		return false
	if not _result(ui.simulation.advance(1.0), "真实跨过语文开考边界", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	var snapshot_board: Dictionary = ui.simulation.get_exam_board("chinese")
	_check(snapshot_board.status == "snapshot", "第7天14:00只保存语文开考快照")
	_check(ui.round_board_text.text.contains("开考快照已保存") and not ui.round_board_text.text.contains("第1名"), "快照未发布时不提前展示排名与成绩")
	if not _result(ui.simulation.advance(2700.0), "真实完成45分钟语文考试", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	var board: Dictionary = ui.simulation.get_exam_board("chinese")
	_check(board.status == "published" and board.rows.size() == 4, "考试课程结束后才公布四人真实成绩")
	_check(ui.round_board_text.text.contains("快照知识") and ui.round_board_text.text.contains("有效智力") and ui.round_board_text.text.contains("曲线") and ui.round_board_text.text.contains("智力系数"), "考试解释展示保存K、I、曲线与系数")
	for row: Dictionary in board.rows:
		_check(ui.round_board_text.text.contains(ui._round_score_text(float(row.score), int(row.score_decimal_places)) + "分"), "成绩文字采用公布时保存的小数位：%s" % row.name)
	if not _result(ui.simulation.save_file("user://round_ui_legacy_source.json"), "保存真实七天局用于旧格式迁移验证", ui.simulation.error_message):
		return false
	for scale in [1, 2]:
		ui._set_window_scale(scale)
		ui._show_round_boards()
		await process_frame
		await process_frame
		_check_control_bounds(ui, Rect2(ui.global_position, ui.size).grow(1.0), "%d倍考试成绩" % scale)
		if scale == 1:
			var scrollbar: VScrollBar = ui.round_board_text.get_v_scroll_bar()
			_check(scrollbar.max_value > scrollbar.page, "真实四人成绩和快照解释在1倍窗口产生滚动")
			scrollbar.value = 25.0
			var previous_scroll: float = scrollbar.value
			ui._refresh_round_interface()
			_check(is_equal_approx(scrollbar.value, previous_scroll), "后台刷新不打断考试来源阅读位置")
	return true


## 完整结束局只允许查阅，结束不强制弹窗或重开，也不会发送未提交草稿。
func _test_finished_interface(ui: Control) -> void:
	if not _result(ui.simulation.advance(60000.0 - ui.simulation.clock_seconds), "真实推进至第7天最终榜边界", ui.simulation.error_message):
		return
	ui._refresh_interface()
	_check(ui.simulation.is_round_finished(), "第7天16:40核心进入已结束状态")
	_check(ui.focus_button.disabled and ui.rest_button.disabled and ui.sleep_button.disabled, "结束局禁用全部底部新指令")
	_check(ui.selected_action.text.contains("本局已结束") and ui.course_label.text == "本局已结束", "人物动作与顶栏均显示本局已结束")
	ui._show_student_context(1, Vector2(100, 100))
	_check(not ui.context_overlay.visible and ui.context_target_index == -1, "结束局右键不打开新互动菜单")
	ui._show_interactions()
	_check(not ui.note_input.editable and ui.send_note_button.disabled and ui.eraser_button.disabled and ui.report_button.disabled, "结束局会话可查阅但不接受新互动")
	_check(ui.interaction_target_index == 2 and ui.note_input.text == "查看榜单后仍发给小陈", "局末保留原收件人与未发草稿")
	ui.round_type_picker.select(2)
	ui._on_round_type_selected(2)
	ui._show_round_boards()
	var final_board: Dictionary = ui.simulation.get_final_board()
	_check(final_board.status == "published" and final_board.rows.size() == 4, "真实三科考试与体育快照构成完整四人最终榜")
	_check(ui.round_board_text.text.contains("七天最终榜") and ui.round_board_text.text.contains("本局已结束"), "最终榜显示结束局说明")
	for row: Dictionary in final_board.rows:
		_check(ui.round_board_text.text.contains(String(row.name)) and ui.round_board_text.text.contains(ui._interaction_number(float(row.score))), "最终榜显示真实总分：%s" % row.name)
	var before: Dictionary = _authoritative_snapshot(ui)
	ui._show_inventory()
	ui._show_records()
	ui._show_round_boards()
	ui._refresh_interface()
	_check(_authoritative_snapshot(ui) == before, "结束局查阅背包、记录和榜单仍只读")
	for scale in [1, 2]:
		ui._set_window_scale(scale)
		await process_frame
		await process_frame
		_check_control_bounds(ui, Rect2(ui.global_position, ui.size).grow(1.0), "%d倍最终榜" % scale)


## 生产读档跨过考试边界，UI必须说明冻结来源而不能标成真实离线学习。
func _test_offline_frozen_interface(ui: Control) -> bool:
	var restored := ClassroomSimulation.new()
	if not _result(restored.setup(ui.configuration, 711027), "建立离线恢复目标实例", restored.error_message):
		return false
	if not _result(restored.load_file("user://round_ui_offline_source.json", true), "生产读档对齐至退出后的第8天", restored.error_message):
		return false
	_bind_restored_session(ui, restored)
	if ui.fatal_error:
		_check(false, "冻结状态局恢复后UI绑定失败")
		return false
	ui.round_type_picker.select(1)
	ui._on_round_type_selected(1)
	ui.round_subject_picker.select(0)
	ui._on_round_subject_selected(0)
	var board: Dictionary = restored.get_exam_board("chinese")
	_check(board.status == "published" and board.source == "offline_frozen", "关闭跨开考时点使用真实保存的冻结输入")
	_check(ui.round_board_text.text.contains("离线冻结状态结算") and ui.round_board_text.text.contains(String(board.reason)), "UI显示离线冻结来源与核心解释")
	_check(ui.round_board_text.text.contains("快照知识") and ui.round_board_text.text.contains("智力系数"), "离线冻结成绩同样展示保存的知识、智力和参数")
	ui.round_type_picker.select(0)
	ui._on_round_type_selected(0)
	ui.round_day_picker.select(6)
	ui._on_round_day_selected(6)
	var daily: Dictionary = restored.get_daily_board(7, "chinese")
	_check(daily.status == "published" and daily.source == "offline_frozen", "退出跨当日出榜边界仍保留真实新增知识")
	_check(ui.round_board_text.text.contains("离线冻结状态结算"), "知识榜不隐去离线冻结来源")
	return true


## 从生产存档显式剔除旧版不存在的账本，缺历史不能被当前状态补造。
func _test_legacy_interface(ui: Control) -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://round_ui_legacy_source.json"))
	if not parsed is Dictionary:
		_check(false, "真实旧格式来源存档无法解析")
		return false
	var legacy: Dictionary = parsed
	legacy.save_version = 3
	legacy.erase("round_progression")
	legacy.logs = legacy.logs.filter(func(entry: Dictionary):
		return entry.type not in ["daily_board", "exam_snapshot", "exam_published", "round_finished"]
	)
	var file := FileAccess.open("user://round_ui_legacy_v3.json", FileAccess.WRITE)
	if file == null:
		_check(false, "无法写入隔离旧v3结构夹具")
		return false
	file.store_string(JSON.stringify(legacy))
	file.close()
	var restored := ClassroomSimulation.new()
	if not _result(restored.setup(ui.configuration, 711028), "建立旧档迁移目标实例", restored.error_message):
		return false
	if not _result(restored.load_file("user://round_ui_legacy_v3.json", false), "真实v3缺历史账本显式迁移", restored.error_message):
		return false
	_bind_restored_session(ui, restored)
	if ui.fatal_error:
		_check(false, "旧档迁移后UI绑定失败")
		return false
	ui.round_type_picker.select(1)
	ui._on_round_type_selected(1)
	var exam: Dictionary = restored.get_exam_board("chinese")
	_check(exam.status == "unrecorded" and ui.round_board_text.text.contains("未记录"), "旧档错过开考且无快照时显示未记录")
	_check(ui.round_board_text.text.contains(String(exam.reason)) and not ui.round_board_text.text.contains("第1名"), "缺失快照显示真实原因，不猜分或排名")
	if not _result(restored.advance(60000.0 - restored.clock_seconds), "迁移后只推进真实剩余课程至结算", restored.error_message):
		return false
	ui._refresh_interface()
	ui.round_type_picker.select(0)
	ui._on_round_type_selected(0)
	ui.round_day_picker.select(6)
	ui._on_round_day_selected(6)
	var daily: Dictionary = restored.get_daily_board(7, "chinese")
	_check(daily.status == "published" and daily.source == "partial" and daily.start_seconds == 53100.0, "迁移当天从真实接入的14:45开始统计")
	_check(ui.round_board_text.text.contains("14:45:00") and ui.round_board_text.text.contains("迁移日从接入时开始统计"), "UI明确显示迁移统计起点")
	ui.round_type_picker.select(2)
	ui._on_round_type_selected(2)
	var final_board: Dictionary = restored.get_final_board()
	_check(final_board.status == "incomplete" and ui.round_board_text.text.contains("缺少科目"), "缺开考快照时最终榜显示不完整与缺科")
	_check(not ui.round_board_text.text.contains("第1名") and ui.round_board_text.text.contains("不生成完整总分"), "缺科不以零分伪造完整总榜")
	return true


## 读取成功后才替换界面唯一模拟器，行为树仍使用生产绑定流程。
func _bind_restored_session(ui: Control, restored: ClassroomSimulation) -> void:
	if is_instance_valid(ui.behavior):
		ui.remove_child(ui.behavior)
		ui.behavior.queue_free()
	ui.simulation = restored
	ui._attach_behavior()


## 新局不沿用上一局最终榜筛选、旧成绩或纸条草稿。
func _test_restart_filters(ui: Control) -> void:
	if not _reset_session(ui):
		return
	ui._show_round_boards()
	_check(ui.round_view_type == 0 and ui.round_view_day == 1 and ui.round_view_subject == "chinese", "换局重置榜单类型、日期与科目缓存")
	_check(ui.round_type_picker.selected == 0 and ui.round_day_picker.get_selected_id() == 1, "换局筛选控件与缓存保持一致")
	_check(ui.round_board_text.text.contains("尚未发布") and not ui.round_board_text.text.contains("七天最终榜"), "换局清除上局成绩文字")
	_check(ui.note_drafts.is_empty() and ui.note_input.text.is_empty(), "换局沿用草稿清空规则")
	_check(not ui.focus_button.disabled and not ui.rest_button.disabled, "新局恢复合法主动指令入口")


## 真实热改出榜边界与后续考试精度，UI须读取账本时刻和每科保存的小数位。
func _test_hot_reload_display(ui: Control) -> bool:
	var restored := ClassroomSimulation.new()
	if not _result(restored.setup(ui.configuration, 711029), "建立热改显示目标实例", restored.error_message):
		return false
	if not _result(restored.load_file("user://round_ui_legacy_source.json", false), "读取语文已公布、后两科未开考的真实局", restored.error_message):
		return false
	var modified: GameConfig = _hot_reload_configuration(2, 59700.0, "user://round_ui_two_decimals.json")
	if modified == null or not _result(restored.apply_config(modified), "真实热改后续考试为两位小数并提前当日出榜", restored.error_message):
		return false
	ui.configuration = modified
	_bind_restored_session(ui, restored)
	if ui.fatal_error:
		_check(false, "热改局绑定UI失败")
		return false
	ui._show_round_boards()
	var daily: Dictionary = restored.get_daily_board(7, "chinese")
	var summary: Dictionary = restored.get_round_summary()
	_check(daily.status == "pending" and daily.end_seconds == 59700.0, "真实课表热改后的日榜边界为16:35")
	_check(ui.round_board_text.text.contains("当日16:35:00") and not ui.round_board_text.text.contains("16:40"), "待发布日榜显示账本边界，未硬写16:40")
	ui.round_type_picker.select(2)
	ui._on_round_type_selected(2)
	_check(summary.final_day == 7 and summary.final_seconds == 59700.0, "总榜查询提供真实局末边界")
	_check(ui.round_board_text.text.contains("第7天16:35:00") and not ui.round_board_text.text.contains("16:40"), "待发布总榜跟随真实热改边界")
	if not _result(restored.advance(59700.0 - restored.clock_seconds), "热改后实际完成数学英语考试并抵达16:35", restored.error_message):
		return false
	ui._refresh_interface()
	var final_board: Dictionary = restored.get_final_board()
	_check(final_board.status == "published" and restored.is_round_finished(), "真实热改边界发布最终榜并结束局")
	_check(restored.get_exam_board("chinese").rows[0].score_decimal_places == 1 and restored.get_exam_board("physical").rows[0].score_decimal_places == 1, "先前语文体育快照仍保存一位小数")
	_check(restored.get_exam_board("math").rows[0].score_decimal_places == 2 and restored.get_exam_board("english").rows[0].score_decimal_places == 2, "热改后数学英语快照保存两位小数")
	for row: Dictionary in final_board.rows:
		_check(row.score_decimal_places == 2, "总榜使用两位共同刻度：%s" % row.name)
		_check(ui.round_board_text.text.contains("总分 " + ui._round_score_text(float(row.score), int(row.score_decimal_places))), "总榜总分保留保存的两位精度：%s" % row.name)
		for subject_id: String in ["chinese", "math", "english", "physical"]:
			var exam: Dictionary = restored.get_exam_board(subject_id)
			for subject_row: Dictionary in exam.rows:
				if subject_row.student_id == row.student_id:
					var expected: String = "%s %s" % [ui.configuration.subjects[subject_id].name, ui._round_score_text(float(subject_row.score), int(subject_row.score_decimal_places))]
					_check(ui.round_board_text.text.contains(expected), "总榜%s按%s各自历史小数位显示" % [row.name, subject_id])
	var displayed: String = ui.round_board_text.text
	var zero_decimals: GameConfig = _hot_reload_configuration(0, 59700.0, "user://round_ui_zero_decimals.json")
	if zero_decimals == null or not _result(restored.apply_config(zero_decimals), "结算后真实热改当前精度为零位", restored.error_message):
		return false
	ui.configuration = zero_decimals
	ui._refresh_interface()
	_check(ui.round_board_text.text == displayed, "当前配置改为零位不会覆盖总榜及各科保存的历史显示精度")
	return true


## 配置副本通过完整生产加载入口，数值热改只写隔离文件，不改正式JSON或Excel。
func _hot_reload_configuration(decimal_places: int, final_seconds: float, path: String) -> GameConfig:
	var source: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	if not source is Dictionary:
		_check(false, "真实配置无法解析为热改测试来源")
		return null
	for row: Dictionary in source.tables.globals:
		if row.key == "score_decimal_places":
			row.value = decimal_places
	for row: Dictionary in source.tables.periods:
		if row.id == "lesson_7":
			row.end_time = final_seconds / 86400.0
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check(false, "无法写入隔离热改配置")
		return null
	file.store_string(JSON.stringify(source))
	file.close()
	var loaded := GameConfig.new()
	if not _result(loaded.load_file(path), "热改副本通过真实配置字段与课表校验", loaded.error_message):
		return null
	return loaded


## 深拷贝权威状态与查询结果，防止只读展示暗中改写榜单或消耗随机流。
func _authoritative_snapshot(ui: Control) -> Dictionary:
	var simulation: ClassroomSimulation = ui.simulation
	var daily_boards: Array[Dictionary] = []
	for board_day in range(1, int(simulation.get_round_summary().session_days) + 1):
		for subject_id: String in ["chinese", "math", "english", "physical"]:
			daily_boards.append(simulation.get_daily_board(board_day, subject_id).duplicate(true))
	var exam_boards: Array[Dictionary] = []
	for subject_id: String in ["chinese", "math", "english", "physical"]:
		exam_boards.append(simulation.get_exam_board(subject_id).duplicate(true))
	return {
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true), "day": simulation.day,
		"clock_seconds": simulation.clock_seconds, "elapsed_s": simulation.elapsed_s,
		"rng_seed": str(simulation.rng.seed), "rng_state": str(simulation.rng.state),
		"daily_boards": daily_boards, "exam_boards": exam_boards,
		"final_board": simulation.get_final_board().duplicate(true), "summary": simulation.get_round_summary().duplicate(true),
	}


## 只检查当前可见控件，滚动文字内容不作为窗口外溢。
func _check_control_bounds(node: Node, bounds: Rect2, context: String) -> void:
	if node is Control and node.is_visible_in_tree() and node.size.x > 0.0 and node.size.y > 0.0:
		_check(bounds.encloses(node.get_global_rect()), "%s控件保持在桌面边界：%s %s" % [context, node.name, node.get_global_rect()])
	for child in node.get_children():
		if not child is Window:
			_check_control_bounds(child, bounds, context)


## 失败保留原始执行原因，不能仅检查后续文字而跳过真实业务失败。
func _result(result: Error, message: String, detail: String = "") -> bool:
	_check(result == OK, "%s：%s" % [message, detail])
	return result == OK


## 记录独立断言，最终统一返回非零错误码。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 汇总真实七天榜单和UI证据，不把无头布局当作原生桌面验收。
func _finish() -> void:
	if failures.is_empty():
		print("ROUND_UI_TEST_PASS checks=%d real_round_boards_tested native_tray_not_tested" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("ROUND_UI_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
