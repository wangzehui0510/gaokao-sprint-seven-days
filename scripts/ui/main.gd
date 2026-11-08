extends Control

const SAVE_PATH = "user://classroom_save.json"
const DEBUG_SAVE_PATH = "user://classroom_debug_save.json"
const CONFIG_PATH = "res://config/game_config.json"
const INK = Color("273f36")
const MUTED = Color("73877c")
const BLUE = Color("2683a1")
const DESKTOP_SCRIPT = preload("res://scripts/desktop/desktop_window_controller.gd")
const PANEL_WIDTH: int = 292
const PANEL_GAP: int = 8
const BAR_HEIGHT: int = 32
const ROUND_SUBJECT_IDS: Array[String] = ["chinese", "math", "english", "physical"]
const ATTRIBUTE_NAMES = {"attention": "专注力", "discipline": "自律性", "health": "健康", "intelligence": "智力"}
# 本轮个人动作名单不包含课表默认活动；自主专用动作仍按配置来源排除玩家入口。
const PERSONAL_ACTION_IDS: Array[String] = [
	"snack_self", "lunch_rest", "read_comic", "bathroom", "linger_break",
	"sprint_study", "preview", "notes", "self_test", "standing_study",
	"chores", "exercise_slack", "remind_self", "wake_self", "recall_classroom",
	"read_comic_item", "eat_candy_item",
]
# 只展示本阶段规则已明确的玩家双人动作，抢答仍等待胜负公式确认。
const PAIR_ACTION_IDS: Array[String] = [
	"remind_friend", "solve_together", "invite_playground", "invite_canteen",
	"borrow_notes", "encourage", "pillow_fight", "feed_snack", "use_eraser",
	"give_comic_item", "give_candy_item", "swap_book", "swap_book_boost", "arm_wrestle",
]

# 核心状态、共享树控制器和界面分开持有，画面不能自行结算收益。
var simulation: ClassroomSimulation
var configuration: GameConfig
var behavior: ClassroomBehaviorController
var room: ClassroomView
var selected_index: int = 0
var fatal_error: bool = false
var last_ticks: int = 0
var refresh_elapsed: float = 0.0
var save_elapsed: float = 0.0
var config_poll_elapsed: float = 0.0
var config_modified_at: int = 0
var rendered_log_count: int = 0

# 窗口状态只负责呈现与系统交互，不能成为第二套游戏时钟或存档。
var desktop
var window_scale: int = 1
var classroom_stage: Control
var inspector_panel: PanelContainer
var inspector_tabs: TabContainer
var timetable_text: RichTextLabel
var header_bar: PanelContainer
var action_bar: PanelContainer
var pin_button: Button
var zoom_button: Button
var exit_in_progress: bool = false
var pending_errors: Array[String] = []
var error_presentation_active: bool = false
# 镜头选择只影响观察地点，自动模式始终跟随本人真实位置。
var scene_picker: OptionButton

# 互动收件人独立于查看对象；输入中的纸条不会因点击其他人物而改变目标。
var interaction_target_index: int = 1
var interaction_target_picker: OptionButton
var interaction_summary: Label
var interaction_cost_label: Label
var interaction_reason_label: Label
var notes_text: RichTextLabel
var note_input: LineEdit
var send_note_button: Button
var eraser_button: Button
var report_button: Button
var current_report_violation: Dictionary = {}
# 扩展互动固定打开时的同学，选动作与选科不改变纸条收件人或草稿。
var pair_action_target_index: int = -1
var pair_action_entry_button: Button
var pair_action_dialog: AcceptDialog
var pair_action_picker: OptionButton
var pair_subject_picker: OptionButton
var pair_action_text: RichTextLabel
var pair_action_reason: Label
var pair_action_button: Button
# 草稿仅属于当前界面，按收件人暂存，显式切换同学不会把旧文字发给新人。
var note_drafts: Dictionary = {}
# 聊天展示只缓存已经渲染的记录数量，换收件人或新局时从真实记录重建。
var rendered_notes_target: int = -1
var rendered_notes_count: int = -1

# 右键上下文固定目标和打开时的违纪编号，与详情选中、会话收件人分别持有。
var context_target_index: int = -1
var context_violation_id: int = -1
var context_overlay: Control
var context_panel: PanelContainer
var context_title: Label
var context_close_button: Button
var context_note_button: Button
var context_eraser_button: Button
var context_pair_button: Button
var context_report_button: Button
var context_reason_label: Label

# 高频界面保留节点引用，只更新真实状态对应的文字和进度。
var clock_label: Label
var course_label: Label
var scene_caption: Label
var selected_name: Label
var selected_action: Label
var action_progress: ProgressBar
var focus_label: Label
var focus_bar: ProgressBar
var stamina_label: Label
var stamina_bar: ProgressBar
var knowledge_label: Label
var attributes_label: Label
# 加点面板只消费本人已有点数，不维护另一份属性或每日领取记录。
var attribute_entry_button: Button
var attribute_dialog: AcceptDialog
var attribute_points_label: Label
var attribute_buttons: Dictionary = {}
var attribute_value_labels: Dictionary = {}
# 个人行动选择保留在界面；费用、物品和可用性统一交给执行器确认。
var personal_action_entry_button: Button
var personal_action_dialog: AcceptDialog
var personal_action_picker: OptionButton
var personal_action_button: Button
var personal_action_text: RichTextLabel
var personal_action_reason: Label
# 状态与背包只展示当前查看对象的真实数据，不保存第二份业务状态。
var status_effects_text: RichTextLabel
var inventory_owner_label: Label
var inventory_text: RichTextLabel
var inventory_entry_button: Button
var inventory_action_picker: OptionButton
var inventory_use_button: Button
var inventory_use_reason: Label
# 榜单筛选仅属于当前界面，读取核心已发布记录，不保存另一份成绩或统计进度。
var round_type_picker: OptionButton
var round_day_picker: OptionButton
var round_subject_picker: OptionButton
var round_board_text: RichTextLabel
var round_view_type: int = 0
var round_view_day: int = 1
var round_view_subject: String = "chinese"
var round_filter_days: int = 0
var roster_buttons: Array[Button] = []
var log_text: RichTextLabel
var footer_label: Label
var status_label: Label
var error_dialog: AcceptDialog
var restart_dialog: ConfirmationDialog
var debug_dialog: AcceptDialog
var advance_input: LineEdit
var focus_button: Button
var rest_button: Button
var sleep_button: Button


# 建立界面后再加载配置与存档，任何初始化失败都明确显示。
func _ready() -> void:
	_build_theme()
	_build_interface()
	get_tree().auto_accept_quit = false
	_initialize_desktop()
	var loaded = GameConfig.new()
	if loaded.load_file() != OK:
		_fail(loaded.error_message)
		return
	configuration = loaded
	config_modified_at = FileAccess.get_modified_time(CONFIG_PATH)
	_start_session(true)
	last_ticks = Time.get_ticks_usec()


# 用单调时钟计算真实执行时间，最小化或渲染卡顿不减少资源结算秒数。
func _process(_delta: float) -> void:
	var ticks = Time.get_ticks_usec()
	var elapsed = float(ticks - last_ticks) / 1000000.0
	last_ticks = ticks
	if simulation == null or fatal_error:
		return
	if simulation.advance(elapsed) != OK:
		_fail(simulation.error_message)
		return
	refresh_elapsed += elapsed
	save_elapsed += elapsed
	config_poll_elapsed += elapsed
	if refresh_elapsed >= 0.2:
		refresh_elapsed = 0.0
		_refresh_interface()
	if config_poll_elapsed >= 1.0:
		config_poll_elapsed = 0.0
		if FileAccess.get_modified_time(CONFIG_PATH) != config_modified_at:
			_reload_configuration()
	if save_elapsed >= 30.0:
		save_elapsed = 0.0
		_save_session(false)


# 系统关闭与界面关闭采用相同托盘入口，真正退出只响应托盘菜单请求。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_hide_to_tray()


# 右键面板接管取消与焦点切换，键盘操作不能越过遮罩进入背后的纸条输入框。
func _input(event: InputEvent) -> void:
	if context_overlay == null or not context_overlay.visible or not event is InputEventKey or not event.pressed:
		return
	if event.keycode == KEY_ESCAPE:
		_close_student_context()
		get_viewport().set_input_as_handled()
	elif event.keycode in [KEY_TAB, KEY_UP, KEY_DOWN]:
		var buttons: Array[Control] = [context_note_button]
		for button in [context_eraser_button, context_pair_button, context_report_button]:
			if not button.disabled:
				buttons.append(button)
		buttons.append(context_close_button)
		var current: int = buttons.find(get_viewport().gui_get_focus_owner())
		var backwards: bool = event.keycode == KEY_UP or (event.keycode == KEY_TAB and event.shift_pressed)
		var next: int = posmod(current + (-1 if backwards else 1), buttons.size())
		buttons[next].grab_focus()
		get_viewport().set_input_as_handled()
	elif event.keycode in [KEY_LEFT, KEY_RIGHT]:
		# 纵向菜单不做横向焦点搜索，避免方向键选中背后的输入框。
		get_viewport().set_input_as_handled()


# 整体使用适合长时间观察的浅色界面，像素场景保持最近邻采样。
func _build_theme() -> void:
	var interface_theme = Theme.new()
	var font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei"])
	interface_theme.default_font = font
	interface_theme.default_font_size = 12
	interface_theme.set_color("font_color", "Label", INK)
	interface_theme.set_color("font_color", "Button", INK)
	interface_theme.set_color("font_focus_color", "Button", INK)
	interface_theme.set_color("font_pressed_color", "Button", INK)
	interface_theme.set_color("font_hover_pressed_color", "Button", Color("155a72"))
	interface_theme.set_color("font_hover_color", "Button", Color("155a72"))
	interface_theme.set_color("font_disabled_color", "Button", Color("96a59e"))
	# Lucide素材采用白色描边，所有按钮状态统一调制为浅色工具栏可辨认的颜色。
	for control_type in ["Button", "MenuButton"]:
		interface_theme.set_color("icon_normal_color", control_type, INK)
		interface_theme.set_color("icon_focus_color", control_type, INK)
		interface_theme.set_color("icon_hover_color", control_type, Color("155a72"))
		interface_theme.set_color("icon_pressed_color", control_type, Color("155a72"))
		interface_theme.set_color("icon_hover_pressed_color", control_type, Color("155a72"))
		interface_theme.set_color("icon_disabled_color", control_type, Color("96a59e"))
	interface_theme.set_stylebox("normal", "Button", _box(Color("f5f8f6"), Color("c7d5cd")))
	interface_theme.set_stylebox("hover", "Button", _box(Color("e8f3f5"), Color("83b7c7")))
	interface_theme.set_stylebox("pressed", "Button", _box(Color("d3eaf0"), BLUE))
	interface_theme.set_stylebox("disabled", "Button", _box(Color("edf1ee"), Color("d9e1db")))
	interface_theme.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), BLUE))
	# 弹窗与主界面使用同一浅色底，避免引擎默认深色面板降低文字对比度。
	interface_theme.set_stylebox("panel", "AcceptDialog", _box(Color("edf3ef"), Color("a8bbb0")))
	interface_theme.set_stylebox("panel", "PopupMenu", _box(Color("edf3ef"), Color("a8bbb0")))
	interface_theme.set_color("font_color", "PopupMenu", INK)
	interface_theme.set_color("font_hover_color", "PopupMenu", Color("155a72"))
	interface_theme.set_stylebox("normal", "LineEdit", _box(Color("ffffff"), Color("a8bbb0")))
	interface_theme.set_stylebox("focus", "LineEdit", _box(Color(0, 0, 0, 0), BLUE))
	interface_theme.set_color("font_color", "LineEdit", INK)
	interface_theme.set_color("caret_color", "LineEdit", INK)
	theme = interface_theme
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


# 通用边框只用于控件，不把页面分区堆叠成装饰卡片。
func _box(background: Color, border: Color) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	return style


# 创建精确整数倍的教室与临时侧栏；构建控件本身不调用原生桌面服务。
func _build_interface() -> void:
	# 根界面由窗口控制器精确设置尺寸，不沿用场景的全屏锚点重新覆盖整数布局。
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	classroom_stage = Control.new()
	classroom_stage.name = "ClassroomStage"
	add_child(classroom_stage)
	_build_header(classroom_stage)
	room = ClassroomView.new()
	room.name = "Classroom"
	room.student_selected.connect(_select_student)
	room.student_context_requested.connect(_show_student_context)
	room.blackboard_selected.connect(_show_timetable)
	room.view_location_changed.connect(_on_view_location_changed)
	room.set_view_location("auto")
	classroom_stage.add_child(room)
	_build_actions(classroom_stage)
	_build_inspector()
	_build_student_context()
	_build_dialogs()
	_apply_layout()


# 顶栏把课程和时间保留为拖动区域，工具按钮只处理各自命令。
func _build_header(parent: Control) -> void:
	header_bar = PanelContainer.new()
	header_bar.name = "HeaderBar"
	header_bar.add_theme_stylebox_override("panel", _bar_style())
	parent.add_child(header_bar)
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 0)
	header_bar.add_child(header)
	var drag_area = VBoxContainer.new()
	drag_area.name = "CourseDragArea"
	drag_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drag_area.add_theme_constant_override("separation", 0)
	drag_area.gui_input.connect(_on_drag_input)
	header.add_child(drag_area)
	course_label = _label("正在读取课表", 11)
	course_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_area.add_child(course_label)
	clock_label = _label("", 11, MUTED)
	clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_area.add_child(clock_label)
	scene_picker = OptionButton.new()
	scene_picker.name = "ScenePicker"
	scene_picker.fit_to_longest_item = false
	scene_picker.custom_minimum_size = Vector2(64, BAR_HEIGHT)
	scene_picker.add_theme_font_size_override("font_size", 11)
	scene_picker.tooltip_text = "观察场景"
	header.add_child(scene_picker)
	scene_picker.add_item("跟随我")
	scene_picker.set_item_metadata(0, "auto")
	for location: String in ClassroomView.LOCATION_NAMES:
		scene_picker.add_item(ClassroomView.LOCATION_NAMES[location])
		scene_picker.set_item_metadata(scene_picker.item_count - 1, location)
	scene_picker.item_selected.connect(_on_scene_selected)
	var self_button = _icon_button("user-round", "查看我的状态")
	self_button.pressed.connect(_select_student.bind(0))
	header.add_child(self_button)
	var timetable_button = _icon_button("calendar-days", "查看当天课表，也可以点击黑板")
	timetable_button.pressed.connect(_show_timetable)
	header.add_child(timetable_button)
	var records_button = _icon_button("book-open", "查看真实班级记录")
	records_button.pressed.connect(_show_records)
	header.add_child(records_button)
	pin_button = _icon_button("pin", "切换窗口置顶")
	pin_button.toggle_mode = true
	pin_button.pressed.connect(_toggle_pinned)
	header.add_child(pin_button)
	zoom_button = _button("2x", "切换教室原始尺寸与两倍尺寸")
	zoom_button.custom_minimum_size = Vector2(28, BAR_HEIGHT)
	zoom_button.pressed.connect(_toggle_window_scale)
	header.add_child(zoom_button)
	var save_button = _icon_button("save", "保存当前正式局或开发局")
	save_button.pressed.connect(_save_session.bind(true))
	header.add_child(save_button)
	var menu = MenuButton.new()
	menu.name = "SettingsMenu"
	menu.icon = load("res://assets/ui/lucide/settings-2.svg")
	menu.expand_icon = true
	menu.add_theme_constant_override("icon_max_width", 16)
	menu.tooltip_text = "配表、重新开始与开发工具"
	menu.custom_minimum_size = Vector2(28, BAR_HEIGHT)
	header.add_child(menu)
	menu.get_popup().add_item("重新读取配表", 0)
	menu.get_popup().add_item("重新开始", 1)
	menu.get_popup().add_separator()
	menu.get_popup().add_item("开发工具", 2)
	menu.get_popup().add_item("重试桌面功能", 3)
	menu.get_popup().add_separator()
	menu.get_popup().add_item("查看榜单", 4)
	menu.get_popup().id_pressed.connect(_on_menu)
	var close_button = _icon_button("x", "收起到系统托盘，继续挂机")
	close_button.pressed.connect(_hide_to_tray)
	header.add_child(close_button)


# 底部指令始终控制本人，资源文字也始终显示本人真实数值。
func _build_actions(parent: Control) -> void:
	action_bar = PanelContainer.new()
	action_bar.name = "ActionBar"
	action_bar.add_theme_stylebox_override("panel", _bar_style())
	parent.add_child(action_bar)
	var actions = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 2)
	action_bar.add_child(actions)
	footer_label = _label("", 11, MUTED)
	footer_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(footer_label)
	focus_button = _action_button("focus", "专注", "对自己使用专注，每次点击均立即生效")
	focus_button.pressed.connect(_focus_player)
	actions.add_child(focus_button)
	rest_button = _action_button("coffee", "休息", "对自己发动免启动费用的基础休息")
	rest_button.pressed.connect(_manual_action.bind("rest"))
	actions.add_child(rest_button)
	sleep_button = _action_button("moon", "睡觉", "对自己发动趴桌睡觉")
	sleep_button.pressed.connect(_manual_action.bind("sleep"))
	actions.add_child(sleep_button)
	personal_action_entry_button = _icon_button("book-open", "选择我的行动")
	personal_action_entry_button.name = "PersonalActionEntry"
	personal_action_entry_button.pressed.connect(_show_personal_actions)
	actions.add_child(personal_action_entry_button)


# 人物、课表、记录、互动、背包和榜单共用左侧面板，不为查看对象建立额外模拟器。
func _build_inspector() -> void:
	inspector_panel = PanelContainer.new()
	inspector_panel.name = "InspectorPanel"
	var panel_style = _box(Color("edf3ef"), Color("a8bbb0"))
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	inspector_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(inspector_panel)
	var panel = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 3)
	inspector_panel.add_child(panel)
	var title_row = HBoxContainer.new()
	panel.add_child(title_row)
	var title = _label("班级详情", 14)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var interactions_entry = _button("互动", "向选中同学发纸条、弹橡皮或举报")
	interactions_entry.custom_minimum_size = Vector2(44, 24)
	interactions_entry.pressed.connect(_show_interactions)
	title_row.add_child(interactions_entry)
	inventory_entry_button = _button("背包", "查看当前人物实际持有的物品")
	inventory_entry_button.name = "InventoryEntry"
	inventory_entry_button.custom_minimum_size = Vector2(44, 24)
	inventory_entry_button.pressed.connect(_show_inventory)
	title_row.add_child(inventory_entry_button)
	var close_panel = _icon_button("chevron-left", "收起详情，保留迷你教室")
	close_panel.custom_minimum_size = Vector2(24, 24)
	close_panel.pressed.connect(_set_panel_visible.bind(false))
	title_row.add_child(close_panel)
	inspector_tabs = TabContainer.new()
	inspector_tabs.name = "InspectorTabs"
	inspector_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_tabs.add_theme_stylebox_override("panel", _box(Color("f5f8f6"), Color("c7d5cd")))
	panel.add_child(inspector_tabs)
	var details = VBoxContainer.new()
	details.name = "人物"
	details.add_theme_constant_override("separation", 2)
	inspector_tabs.add_child(details)
	var roster = HBoxContainer.new()
	roster.add_theme_constant_override("separation", 2)
	details.add_child(roster)
	for index in 4:
		var button = _button("", "查看这位同学的真实状态")
		button.custom_minimum_size.y = 22
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 11)
		button.clip_text = true
		button.pressed.connect(_select_student.bind(index))
		roster.add_child(button)
		roster_buttons.append(button)
	# 姓名与教室人数共用一行，为1倍窗口的真实状态列表保留可滚动空间。
	var selected_title_row = HBoxContainer.new()
	details.add_child(selected_title_row)
	selected_name = _label("", 14)
	selected_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selected_title_row.add_child(selected_name)
	scene_caption = _label("", 11, MUTED)
	# 关闭裁切和省略，使人数真实文字参与最小宽度，避免被姓名横向扩展压窄。
	scene_caption.clip_text = false
	scene_caption.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	selected_title_row.add_child(scene_caption)
	selected_action = _label("", 11, MUTED)
	details.add_child(selected_action)
	action_progress = _progress(Color("a9bbb0"), 3)
	details.add_child(action_progress)
	focus_label = _label("", 11)
	details.add_child(focus_label)
	focus_bar = _progress(BLUE, 5)
	details.add_child(focus_bar)
	stamina_label = _label("", 11)
	details.add_child(stamina_label)
	stamina_bar = _progress(Color("78964d"), 5)
	details.add_child(stamina_bar)
	knowledge_label = _label("", 12)
	details.add_child(knowledge_label)
	var attributes_row = HBoxContainer.new()
	attributes_row.add_theme_constant_override("separation", 2)
	details.add_child(attributes_row)
	attributes_label = _label("", 11, MUTED)
	attributes_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	attributes_row.add_child(attributes_label)
	attribute_entry_button = _button("+", "分配我的待分配属性点")
	attribute_entry_button.name = "AttributeEntry"
	attribute_entry_button.custom_minimum_size = Vector2(24, 24)
	attribute_entry_button.pressed.connect(_show_attribute_allocation)
	attributes_row.add_child(attribute_entry_button)
	# 有效属性和状态在固定剩余区域滚动，不让长说明把1倍人物页撑高。
	status_effects_text = _text_area("StatusEffects")
	status_effects_text.custom_minimum_size.y = 40
	status_effects_text.add_theme_font_size_override("normal_font_size", 11)
	details.add_child(status_effects_text)
	timetable_text = _text_area("课表")
	inspector_tabs.add_child(timetable_text)
	log_text = _text_area("记录")
	log_text.scroll_following = true
	inspector_tabs.add_child(log_text)
	_build_interaction_page()
	_build_inventory_page()
	_build_round_page()
	status_label = _label("", 11, MUTED)
	panel.add_child(status_label)
	inspector_panel.hide()


# 背包展示真实库存；本人可选择已开放的自用动作，同学背包只读。
func _build_inventory_page() -> void:
	var page = VBoxContainer.new()
	page.name = "背包"
	page.add_theme_constant_override("separation", 4)
	inspector_tabs.add_child(page)
	inventory_owner_label = _label("", 14)
	inventory_owner_label.name = "InventoryOwner"
	page.add_child(inventory_owner_label)
	inventory_text = _text_area("InventoryContents")
	page.add_child(inventory_text)
	var use_row = HBoxContainer.new()
	use_row.add_theme_constant_override("separation", 4)
	page.add_child(use_row)
	inventory_action_picker = OptionButton.new()
	inventory_action_picker.name = "InventoryAction"
	inventory_action_picker.fit_to_longest_item = false
	inventory_action_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inventory_action_picker.custom_minimum_size.y = 26
	inventory_action_picker.item_selected.connect(_on_inventory_action_selected)
	use_row.add_child(inventory_action_picker)
	inventory_use_button = _button("自用", "对自己使用选中的物品")
	inventory_use_button.name = "InventoryUse"
	inventory_use_button.custom_minimum_size = Vector2(48, 26)
	inventory_use_button.pressed.connect(_use_inventory_item)
	use_row.add_child(inventory_use_button)
	inventory_use_reason = _label("", 11, MUTED)
	inventory_use_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(inventory_use_reason)


# 榜单只提供类型、日期和科目筛选，长历史在固定左栏内滚动。
func _build_round_page() -> void:
	var page = VBoxContainer.new()
	page.name = "榜单"
	page.add_theme_constant_override("separation", 4)
	inspector_tabs.add_child(page)
	var filters = HBoxContainer.new()
	filters.add_theme_constant_override("separation", 3)
	page.add_child(filters)
	round_type_picker = OptionButton.new()
	round_type_picker.name = "RoundType"
	round_type_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for title: String in ["知识榜", "考试", "总榜"]:
		round_type_picker.add_item(title)
	round_type_picker.item_selected.connect(_on_round_type_selected)
	filters.add_child(round_type_picker)
	round_day_picker = OptionButton.new()
	round_day_picker.name = "RoundDay"
	round_day_picker.item_selected.connect(_on_round_day_selected)
	filters.add_child(round_day_picker)
	round_subject_picker = OptionButton.new()
	round_subject_picker.name = "RoundSubject"
	round_subject_picker.item_selected.connect(_on_round_subject_selected)
	filters.add_child(round_subject_picker)
	round_board_text = _text_area("RoundBoard")
	page.add_child(round_board_text)


# 互动页只提交玩家指令，聊天记录和当前搭档全部读取真实执行器。
func _build_interaction_page() -> void:
	var page = VBoxContainer.new()
	page.name = "互动"
	page.add_theme_constant_override("separation", 2)
	inspector_tabs.add_child(page)
	var target_row = HBoxContainer.new()
	target_row.add_theme_constant_override("separation", 4)
	page.add_child(target_row)
	target_row.add_child(_label("对象", 12))
	interaction_target_picker = OptionButton.new()
	interaction_target_picker.name = "InteractionTarget"
	interaction_target_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	interaction_target_picker.custom_minimum_size.y = 24
	interaction_target_picker.item_selected.connect(_on_interaction_target_selected)
	target_row.add_child(interaction_target_picker)
	interaction_summary = _label("", 11, MUTED)
	page.add_child(interaction_summary)
	interaction_cost_label = _label("", 11)
	page.add_child(interaction_cost_label)
	var actions = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	page.add_child(actions)
	eraser_button = _button("弹橡皮", "")
	eraser_button.name = "EraserButton"
	eraser_button.custom_minimum_size.y = 26
	eraser_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	eraser_button.pressed.connect(_prank_selected_student)
	actions.add_child(eraser_button)
	pair_action_entry_button = _button("更多…", "与当前同学发起其他互动")
	pair_action_entry_button.name = "PairActionEntry"
	pair_action_entry_button.custom_minimum_size.y = 26
	pair_action_entry_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pair_action_entry_button.pressed.connect(_show_selected_pair_actions)
	actions.add_child(pair_action_entry_button)
	report_button = _button("举报", "")
	report_button.name = "ReportButton"
	report_button.custom_minimum_size.y = 26
	report_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	report_button.pressed.connect(_report_selected_violation)
	actions.add_child(report_button)
	interaction_reason_label = _label("", 11, MUTED)
	page.add_child(interaction_reason_label)
	notes_text = _text_area("已送达纸条")
	notes_text.custom_minimum_size.y = 48
	notes_text.scroll_following = true
	page.add_child(notes_text)
	var compose_row = HBoxContainer.new()
	compose_row.add_theme_constant_override("separation", 4)
	page.add_child(compose_row)
	note_input = LineEdit.new()
	note_input.name = "NoteInput"
	note_input.placeholder_text = "填写纸条，完成后送达"
	note_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_input.custom_minimum_size.y = 26
	note_input.text_changed.connect(_on_note_text_changed)
	note_input.text_submitted.connect(_on_note_text_submitted)
	compose_row.add_child(note_input)
	send_note_button = _button("发送", "")
	send_note_button.name = "SendNoteButton"
	send_note_button.custom_minimum_size = Vector2(48, 26)
	send_note_button.pressed.connect(_send_note)
	compose_row.add_child(send_note_button)


# 右键面板位于窗口内部；透明遮罩消费外部点击，避免关闭时误触教室或本人指令。
func _build_student_context() -> void:
	context_overlay = Control.new()
	context_overlay.name = "StudentContextOverlay"
	context_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	context_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	context_overlay.gui_input.connect(_on_context_overlay_input)
	add_child(context_overlay)
	context_panel = PanelContainer.new()
	context_panel.name = "StudentContextPanel"
	context_panel.custom_minimum_size.x = 224
	context_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style = _box(Color("f5f8f6"), Color("83b7c7"))
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	context_panel.add_theme_stylebox_override("panel", style)
	context_overlay.add_child(context_panel)
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	context_panel.add_child(content)
	var title_row = HBoxContainer.new()
	content.add_child(title_row)
	context_title = _label("", 13)
	context_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(context_title)
	context_close_button = _icon_button("x", "关闭互动面板")
	context_close_button.custom_minimum_size = Vector2(22, 22)
	context_close_button.pressed.connect(_close_student_context)
	title_row.add_child(context_close_button)
	context_note_button = _button("发纸条…", "")
	context_note_button.custom_minimum_size.y = 26
	context_note_button.pressed.connect(_on_context_note_pressed)
	content.add_child(context_note_button)
	var pair_row = HBoxContainer.new()
	pair_row.add_theme_constant_override("separation", 4)
	content.add_child(pair_row)
	context_eraser_button = _button("弹橡皮", "")
	context_eraser_button.custom_minimum_size.y = 26
	context_eraser_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	context_eraser_button.pressed.connect(_on_context_eraser_pressed)
	pair_row.add_child(context_eraser_button)
	context_pair_button = _button("更多…", "选择其他双人互动")
	context_pair_button.name = "ContextPairAction"
	context_pair_button.custom_minimum_size.y = 26
	context_pair_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	context_pair_button.pressed.connect(_on_context_pair_pressed)
	pair_row.add_child(context_pair_button)
	context_report_button = _button("举报", "")
	context_report_button.custom_minimum_size.y = 26
	context_report_button.pressed.connect(_on_context_report_pressed)
	content.add_child(context_report_button)
	context_reason_label = _label("", 11, MUTED)
	context_reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	context_reason_label.custom_minimum_size.y = 34
	content.add_child(context_reason_label)
	content.add_child(_label("点击外部或按 Esc 关闭", 10, MUTED))
	context_overlay.hide()


# 只读取右键对象并绑定当前事件快照，不改变详情、草稿、窗口尺寸或任何角色动作。
func _show_student_context(student_index: int, local_position: Vector2) -> void:
	_close_student_context()
	if simulation == null or fatal_error or student_index <= 0 or student_index >= simulation.students.size():
		return
	if simulation.is_round_finished():
		return
	context_target_index = student_index
	var violation: Dictionary = simulation.get_open_violation(student_index)
	context_violation_id = -1 if violation.is_empty() else int(violation.violation_id)
	context_overlay.show()
	_refresh_student_context()
	context_panel.reset_size()
	var click_position: Vector2 = get_global_transform().affine_inverse() * (room.get_global_transform() * local_position)
	var desired_position: Vector2 = click_position + Vector2(8, 8)
	var menu_size: Vector2 = context_panel.size
	# 所有定位都使用根界面坐标，左侧详情展开和2倍教室不会令面板越出窗口。
	context_panel.position = Vector2(
		clampf(desired_position.x, 4.0, size.x - menu_size.x - 4.0),
		clampf(desired_position.y, 4.0, size.y - menu_size.y - 4.0)
	)
	# 菜单接管键盘焦点，回车不能越过遮罩发送背后输入框里的旧草稿。
	context_note_button.grab_focus()


# 关闭时清除快照，后续点击不能沿用已经关闭的同学或违纪事件。
func _close_student_context() -> void:
	if context_overlay != null:
		context_overlay.hide()
	context_target_index = -1
	context_violation_id = -1


# 外部点击只收起面板；再次右键教室时按原始命中规则切换目标，空地则保持关闭。
func _on_context_overlay_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	context_overlay.accept_event()
	var room_position: Vector2 = room.get_global_transform().affine_inverse() * (context_overlay.get_global_transform() * event.position)
	_close_student_context()
	if event.button_index == MOUSE_BUTTON_RIGHT and Rect2(Vector2.ZERO, room.size).has_point(room_position):
		var room_event: InputEventMouseButton = event.duplicate()
		room_event.position = room_position
		room._gui_input(room_event)


# 写字属于显式切换会话，先保存旧收件人草稿，打开后仍须点击发送才发动真实互动。
func _on_context_note_pressed() -> void:
	if context_target_index < 0 or simulation == null or fatal_error:
		return
	var recipient: int = context_target_index
	_close_student_context()
	_set_interaction_target(recipient)
	inspector_tabs.current_tab = 3
	_set_panel_visible(true)
	_refresh_interaction_interface()
	note_input.grab_focus()


# 橡皮使用右键时固定的对象，不临时改写会话收件人以复用按钮。
func _on_context_eraser_pressed() -> void:
	if context_target_index < 0:
		return
	var target: int = context_target_index
	_close_student_context()
	_prank_student(target)


# 扩展互动沿用右键固定目标，不经过纸条会话的收件人切换。
func _on_context_pair_pressed() -> void:
	if context_target_index > 0:
		_show_pair_actions(context_target_index)


# 举报提交打开时绑定的事件；过期后由核心明确拒绝，不能替换成后来的另一事件。
func _on_context_report_pressed() -> void:
	if context_target_index < 0:
		return
	var target: int = context_target_index
	var violation_id: int = context_violation_id
	_close_student_context()
	_report_student_violation(target, violation_id)


# 持续刷新可用性和已确认的举报后果，事件编号始终保持打开时的快照。
func _refresh_student_context() -> void:
	if not context_overlay.visible or simulation == null or fatal_error:
		return
	if simulation.is_round_finished():
		_close_student_context()
		return
	context_title.text = "与%s互动" % simulation.students[context_target_index].name
	context_title.tooltip_text = context_title.text
	var note_reason: String = simulation.interaction_unavailable_reason(0, context_target_index, "send_note")
	var eraser_reason: String = simulation.interaction_unavailable_reason(0, context_target_index, "eraser_prank")
	var report_reason: String = "打开时没有可举报事件，请重新右键查看"
	if context_violation_id >= 0:
		report_reason = simulation.report_unavailable_reason(context_target_index, context_violation_id)
	context_note_button.tooltip_text = "打开此同学的纸条会话，填写后发送。\n" + _interaction_tooltip("send_note", note_reason, context_target_index)
	context_eraser_button.disabled = not eraser_reason.is_empty()
	context_eraser_button.tooltip_text = _interaction_tooltip("eraser_prank", eraser_reason, context_target_index)
	context_pair_button.disabled = simulation.is_round_finished()
	context_report_button.disabled = not report_reason.is_empty()
	context_report_button.tooltip_text = _interaction_tooltip("report", report_reason, context_target_index)
	context_reason_label.text = "选择操作；悬停可查看费用与效果"
	if not report_reason.is_empty():
		context_reason_label.text = "举报：" + report_reason
	if report_reason.is_empty() and _is_player_interaction_partner(context_target_index):
		context_reason_label.text = "举报当前搭档会结束互动\n未完成纸条不送达"
	context_reason_label.tooltip_text = "\n".join([
		"纸条：" + ("可填写" if note_reason.is_empty() else note_reason),
		"橡皮：" + ("可发动" if eraser_reason.is_empty() else eraser_reason),
		"举报：" + (_report_consequence_text(context_target_index) if report_reason.is_empty() else report_reason),
	])


# 工具条不添加内容留白，确保32像素高度全部交给真实控件。
func _bar_style() -> StyleBoxFlat:
	var style = _box(Color("edf3ef"), Color("a8bbb0"))
	style.content_margin_left = 0
	style.content_margin_right = 0
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	return style


# 正式图标固定为16像素，按钮保留独立点击范围和中文鼠标提示。
func _icon_button(icon_name: String, tooltip: String) -> Button:
	var button = _button("", tooltip)
	button.icon = load("res://assets/ui/lucide/%s.svg" % icon_name)
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 16)
	button.custom_minimum_size = Vector2(28, BAR_HEIGHT)
	return button


# 本人行动同时使用图标和文字，避免只有图形时难以分辨操作。
func _action_button(icon_name: String, text_value: String, tooltip: String) -> Button:
	var button = _icon_button(icon_name, tooltip)
	button.text = text_value
	button.custom_minimum_size.x = 66
	button.add_theme_font_size_override("font_size", 12)
	return button


# 富文本容器只承载实际内容，长课表与日志在固定面板内滚动。
func _text_area(node_name: String) -> RichTextLabel:
	var text = RichTextLabel.new()
	text.name = node_name
	text.bbcode_enabled = false
	text.selection_enabled = true
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.add_theme_font_size_override("normal_font_size", 12)
	text.add_theme_color_override("default_color", INK)
	return text


# 依据唯一面板状态计算窗口内容，不让容器把像素教室拉伸为非整数倍。
func _get_layout_size() -> Vector2i:
	var width: int = 384 * window_scale
	if inspector_panel.visible:
		width += PANEL_WIDTH + PANEL_GAP
	return Vector2i(width, 256 * window_scale + BAR_HEIGHT * 2)


# 真实窗口与无头布局共用几何计算；只有已初始化的控制器才操作系统窗口。
func _apply_layout() -> void:
	_close_student_context()
	_close_player_dialogs()
	var layout = _get_layout_size()
	size = Vector2(layout)
	var panel_offset: int = PANEL_WIDTH + PANEL_GAP if inspector_panel.visible else 0
	classroom_stage.position = Vector2(panel_offset, 0)
	classroom_stage.size = Vector2(384 * window_scale, layout.y)
	header_bar.position = Vector2.ZERO
	header_bar.size = Vector2(classroom_stage.size.x, BAR_HEIGHT)
	room.position = Vector2(0, BAR_HEIGHT)
	room.custom_minimum_size = Vector2(384, 256) * window_scale
	room.size = room.custom_minimum_size
	room.queue_redraw()
	action_bar.position = Vector2(0, BAR_HEIGHT + room.size.y)
	action_bar.size = Vector2(classroom_stage.size.x, BAR_HEIGHT)
	inspector_panel.position = Vector2.ZERO
	inspector_panel.size = Vector2(PANEL_WIDTH, layout.y)
	zoom_button.text = "2x" if window_scale == 1 else "1x"
	if desktop != null and desktop.is_initialized():
		desktop.configure_layout(layout)


# 缩放只影响呈现，动作和已有学习段完全保留。
func _set_window_scale(scale: int) -> void:
	if scale not in [1, 2]:
		_show_window_error("教室仅支持1倍或2倍整数缩放。")
		return
	window_scale = scale
	_apply_layout()


# 临时面板从教室左侧展开，窗口管理器负责保持右下角位置锚点。
func _set_panel_visible(value: bool) -> void:
	inspector_panel.visible = value
	_apply_layout()


# 黑板和工具栏都读取当前游戏当天课表，不维护另一份课程模板。
func _show_timetable() -> void:
	if simulation == null or fatal_error:
		return
	_refresh_timetable()
	inspector_tabs.current_tab = 1
	_set_panel_visible(true)


# 班级记录沿用唯一执行器写入的事件，切换选项卡不触发任何结算。
func _show_records() -> void:
	inspector_tabs.current_tab = 2
	_set_panel_visible(true)


# 背包入口保留查看对象和纸条收件人，查看本身不发动自用动作。
func _show_inventory() -> void:
	if simulation == null or fatal_error:
		return
	_refresh_inventory_interface()
	inspector_tabs.current_tab = 4
	_set_panel_visible(true)


# 场景选项只切换镜头，自动跟随和固定观察都不移动人物或改变聊天收件人。
func _on_scene_selected(index: int) -> void:
	_close_student_context()
	room.set_view_location(String(scene_picker.get_item_metadata(index)))
	_refresh_interface()


# 角色真实移动使镜头变化时，旧坐标上的互动菜单必须关闭。
func _on_view_location_changed(_location: String) -> void:
	_close_student_context()


# 本人详情打开现有点数的分配面板，查看同学时保持只读。
func _show_attribute_allocation() -> void:
	if simulation == null or fatal_error or selected_index != 0:
		return
	_close_student_context()
	_refresh_attribute_interface()
	attribute_dialog.popup_centered()


# 每次点击实际消费一点；过期点击由核心明确拒绝，不赠点或重启当前动作。
func _allocate_selected_attribute(attribute_id: String) -> void:
	if simulation == null or fatal_error:
		return
	if selected_index != 0:
		_queue_error("只能分配自己的属性点")
		return
	var result: Error = simulation.allocate_attribute(attribute_id)
	if result == ERR_UNAVAILABLE:
		_queue_error(simulation.error_message)
	elif result != OK:
		_fail(simulation.error_message)
		return
	else:
		status_label.text = "%s增加1点" % ATTRIBUTE_NAMES[attribute_id]
	_refresh_interface()


# 加点控件始终读取当前本人点数和基础属性，临时状态仍由人物页分开展示。
func _refresh_attribute_interface() -> void:
	var player: Dictionary = simulation.students[0]
	var unavailable: String = ""
	if selected_index != 0:
		unavailable = "只能分配自己的属性点"
	elif simulation.is_round_finished():
		unavailable = "本局已结束，不能再分配属性点"
	elif player.unspent_points <= 0:
		unavailable = "没有待分配属性点"
	attribute_entry_button.disabled = not unavailable.is_empty()
	attribute_entry_button.tooltip_text = "分配我的待分配属性点" if unavailable.is_empty() else unavailable
	attribute_points_label.text = "剩余 %d 点" % player.unspent_points
	for attribute_id: String in ATTRIBUTE_NAMES:
		attribute_value_labels[attribute_id].text = _interaction_number(float(player.attributes[attribute_id]))
		attribute_buttons[attribute_id].disabled = not unavailable.is_empty()
		attribute_buttons[attribute_id].tooltip_text = "%s增加1点" % ATTRIBUTE_NAMES[attribute_id] if unavailable.is_empty() else unavailable


# 行动窗口只选择本人的动作，查看其他人物时也不会改变指令对象。
func _show_personal_actions() -> void:
	if simulation == null or fatal_error:
		return
	_close_student_context()
	_refresh_personal_action_interface()
	personal_action_dialog.popup_centered()


# 选择仅刷新费用和前置条件，不预扣物品或打断原动作。
func _on_personal_action_selected(_index: int) -> void:
	_refresh_personal_action_interface()


# 发动前重新经过同一权威入口；失败保留原动作和选择，成功后收起窗口。
func _start_personal_action() -> void:
	if simulation == null or fatal_error or personal_action_picker.selected < 0:
		return
	var action_id: String = personal_action_picker.get_item_metadata(personal_action_picker.selected)
	if _manual_action(action_id):
		personal_action_dialog.hide()


# 行动列表依据当前开放范围和来源；自主专用项不会被玩家按钮间接开放。
func _personal_action_ids() -> Array[String]:
	var result: Array[String] = []
	for action_id: String in PERSONAL_ACTION_IDS:
		if action_id not in simulation.phase_scope.enabled_actions:
			continue
		var definition: Dictionary = configuration.actions[action_id]
		if definition.enabled and definition.target == "self" and definition.source in ["player", "both"]:
			result.append(action_id)
	return result


# 只有消费物品的已开放个人动作进入背包自用入口，不暴露尚未实现的双人强化。
func _inventory_action_ids() -> Array[String]:
	var result: Array[String] = []
	for action_id: String in _personal_action_ids():
		for effect: Dictionary in configuration.phase_effects(action_id, "start"):
			if effect.type == "consume_item":
				result.append(action_id)
				break
	return result


# 列表结构不变时仅更新名称，后台刷新不打断展开的选项或丢失当前选择。
func _sync_action_picker(picker: OptionButton, action_ids: Array[String]) -> void:
	var previous_id: String = "" if picker.selected < 0 else String(picker.get_item_metadata(picker.selected))
	var unchanged: bool = picker.item_count == action_ids.size()
	if unchanged:
		for index: int in action_ids.size():
			if picker.get_item_metadata(index) != action_ids[index]:
				unchanged = false
				break
	if not unchanged:
		picker.clear()
		for action_id: String in action_ids:
			picker.add_item(String(configuration.actions[action_id].name))
			picker.set_item_metadata(picker.item_count - 1, action_id)
		var selected: int = action_ids.find(previous_id)
		if not action_ids.is_empty():
			picker.select(selected if selected >= 0 else 0)
	else:
		for index: int in action_ids.size():
			var title: String = configuration.actions[action_ids[index]].name
			if picker.get_item_text(index) != title:
				picker.set_item_text(index, title)


# 当前费用、状态和知识说明直接读取有效配置，界面不另算动作收益。
func _personal_action_description(action_id: String) -> String:
	var definition: Dictionary = configuration.actions[action_id]
	var lines: Array[String] = [_interaction_cost_summary(action_id), String(definition.description)]
	if float(definition.knowledge_multiplier) > 0.0:
		lines.append("知识倍率 ×%s，仅在知识课程内累计" % _interaction_number(float(definition.knowledge_multiplier)))
	for phase: String in ["start", "tick", "complete"]:
		for effect: Dictionary in configuration.phase_effects(action_id, phase):
			var detail: String = ""
			match String(effect.type):
				"resource":
					if float(effect.value) == 0.0:
						continue
					detail = _resource_effect_text(effect)
				"consume_item":
					detail = "消耗%s × %d（持有%d）" % [configuration.items[effect.item_id].name, effect.value, simulation.students[0].inventory.get(effect.item_id, 0)]
				"apply_buff":
					var buff: Dictionary = configuration.buffs[effect.buff_id]
					detail = "%s：%s" % [buff.name, buff.description]
				"start_action":
					detail = "回到当前课表对应活动"
			if not detail.is_empty():
				lines.append("%s：%s" % [{"start": "启动", "tick": "持续", "complete": "完成"}[phase], detail])
	return "\n".join(lines)


# 刷新可用性只做查询，费用不足不暂停健康的挂机局。
func _refresh_personal_action_interface() -> void:
	_sync_action_picker(personal_action_picker, _personal_action_ids())
	personal_action_entry_button.disabled = simulation.is_round_finished()
	var reason: String = "当前没有已开放的个人动作"
	if personal_action_picker.selected >= 0:
		var action_id: String = personal_action_picker.get_item_metadata(personal_action_picker.selected)
		reason = simulation.action_unavailable_reason(0, action_id)
		_update_readonly_text(personal_action_text, _personal_action_description(action_id))
	else:
		_update_readonly_text(personal_action_text, "")
	personal_action_picker.disabled = personal_action_picker.item_count == 0
	personal_action_button.disabled = not reason.is_empty()
	personal_action_reason.text = reason
	personal_action_button.tooltip_text = "开始本人选中的行动" if reason.is_empty() else reason


# 背包选项不改变库存、人物选择或纸条草稿。
func _on_inventory_action_selected(_index: int) -> void:
	_refresh_inventory_interface()


# 背包使用只允许本人库存，重复或过期点击仍由执行器原子校验。
func _use_inventory_item() -> void:
	if simulation == null or fatal_error or inventory_action_picker.selected < 0:
		return
	if selected_index != 0:
		_queue_error("只能使用自己的物品")
		return
	var action_id: String = inventory_action_picker.get_item_metadata(inventory_action_picker.selected)
	_manual_action(action_id)


# 布局、隐藏、换局和错误发生时收起旧操作面板，重新打开再查询最新条件。
func _close_player_dialogs() -> void:
	if attribute_dialog != null:
		attribute_dialog.hide()
	if personal_action_dialog != null:
		personal_action_dialog.hide()
	if pair_action_dialog != null:
		pair_action_dialog.hide()
	pair_action_target_index = -1


# 互动页的明确入口绑定当前收件人，但打开和选择操作均不改变任何业务状态。
func _show_selected_pair_actions() -> void:
	_show_pair_actions(interaction_target_index)


# 操作窗口固定目标，其他页面的查看对象与草稿保持各自原有归属。
func _show_pair_actions(target_index: int) -> void:
	if simulation == null or fatal_error or simulation.is_round_finished():
		return
	if target_index <= 0 or target_index >= simulation.students.size():
		return
	_close_student_context()
	_close_player_dialogs()
	pair_action_target_index = target_index
	_refresh_pair_action_interface()
	pair_action_dialog.popup_centered()


# 选择只刷新配表效果、选科和真实拒绝原因，不抽时长或预扣物品。
func _on_pair_action_selected(_index: int) -> void:
	_refresh_pair_action_interface()


# 科目由玩家显式选择，普通刷新不得把选定项改成另一门课程。
func _on_pair_subject_selected(_index: int) -> void:
	_refresh_pair_action_interface()


# 成功、取消及布局关闭都使旧目标失效，排队点击不能使用已经关闭的选择。
func _on_pair_dialog_hidden() -> void:
	if not pair_action_dialog.visible:
		pair_action_target_index = -1


# 仅开放已实现且允许玩家发起的双人动作，强化项不会自动改成基础动作。
func _pair_action_ids() -> Array[String]:
	var result: Array[String] = []
	for action_id: String in PAIR_ACTION_IDS:
		if action_id in simulation.phase_scope.enabled_actions:
			var definition: Dictionary = configuration.actions[action_id]
			if definition.enabled and definition.target == "pair" and definition.source in ["player", "both"]:
				result.append(action_id)
	return result


# 固定科目列表保留显式选择；当前授课科目禁选，不能用体育替代文化课。
func _refresh_pair_subjects() -> void:
	var available: Array[String] = []
	for subject: Dictionary in configuration.tables.subjects:
		if subject.kind == "knowledge" and subject.id != "physical":
			available.append(String(subject.id))
	var previous: String = "" if pair_subject_picker.selected < 0 else String(pair_subject_picker.get_item_metadata(pair_subject_picker.selected))
	pair_subject_picker.clear()
	pair_subject_picker.add_item("选择换入科目", 0)
	pair_subject_picker.set_item_metadata(0, "")
	for subject_id: String in available:
		pair_subject_picker.add_item(String(configuration.subjects[subject_id].name))
		pair_subject_picker.set_item_metadata(pair_subject_picker.item_count - 1, subject_id)
		pair_subject_picker.set_item_disabled(pair_subject_picker.item_count - 1, subject_id == simulation.course_context().subject_id)
	pair_subject_picker.select(available.find(previous) + 1 if previous in available else 0)


# 真实阶段效果包含对象、扣物、状态和完成条件，结果只由执行器产生。
func _pair_action_description(action_id: String) -> String:
	var definition: Dictionary = configuration.actions[action_id]
	var lines: Array[String] = [_interaction_cost_summary(action_id), String(definition.description)]
	if definition.knowledge_multiplier > 0.0:
		lines.append("双方知识倍率 ×%s，仅在知识课程内累计" % _interaction_number(definition.knowledge_multiplier))
	for phase: String in ["start", "tick", "complete"]:
		for effect: Dictionary in configuration.phase_effects(action_id, phase):
			var recipient: String = {"self": "我", "target": "对方", "both": "双方", "winner": "胜者", "loser": "败者"}[effect.recipient]
			var detail: String = ""
			match String(effect.type):
				"resource":
					detail = _resource_effect_text(effect)
					if effect.condition == "tie":
						detail = "平局时" + detail
				"consume_item":
					detail = "%s消耗%s × %d（我持有%d）" % [recipient, configuration.items[effect.item_id].name, effect.value, simulation.students[0].inventory.get(effect.item_id, 0)]
				"apply_buff":
					var buff: Dictionary = configuration.buffs[effect.buff_id]
					var changes: Array[String] = []
					for field: Array in [["focus_delta", "专注力"], ["discipline_delta", "自律性"], ["health_delta", "健康"], ["intelligence_delta", "智力"]]:
						var amount: float = buff[field[0]]
						if amount != 0.0:
							changes.append("%s%s%s" % [field[1], "+" if amount > 0.0 else "", _interaction_number(amount)])
					if buff.knowledge_multiplier != 1.0:
						changes.append("知识倍率 ×%s" % _interaction_number(buff.knowledge_multiplier))
					if buff.knowledge_redirect == "selected_subject":
						changes.append("知识计入所选科目")
					detail = "%s获得%s，%s\n%s" % [recipient, buff.name, "随互动结束" if buff.lifecycle == "action" else "持续" + _duration(buff.duration_s), " · ".join(changes)]
				"start_action":
					detail = recipient + "回到当前课表对应活动"
				"event":
					detail = "按发动时双方体力判定胜负，同值为平局"
			if not detail.is_empty():
				lines.append("%s：%s" % [{"start": "启动", "tick": "持续", "complete": "完成"}[phase], detail])
	return "\n".join(lines)


# 后台查询保持只读，临近边界收到的过期点击仍由权威启动入口重新验证。
func _refresh_pair_action_interface() -> void:
	pair_action_entry_button.disabled = simulation.is_round_finished()
	if pair_action_target_index <= 0:
		return
	if simulation.is_round_finished():
		pair_action_dialog.hide()
		return
	pair_action_dialog.title = "与%s互动" % simulation.students[pair_action_target_index].name
	_sync_action_picker(pair_action_picker, _pair_action_ids())
	# 只在首次或科目配置变化时重建，避免每次刷新收起用户展开的菜单。
	if pair_subject_picker.item_count == 0:
		_refresh_pair_subjects()
	else:
		for index: int in range(1, pair_subject_picker.item_count):
			var subject_id: String = pair_subject_picker.get_item_metadata(index)
			pair_subject_picker.set_item_text(index, String(configuration.subjects[subject_id].name))
			pair_subject_picker.set_item_disabled(index, subject_id == simulation.course_context().subject_id)
	var reason: String = "当前没有已开放的双人动作"
	pair_subject_picker.visible = false
	if pair_action_picker.selected >= 0:
		var action_id: String = pair_action_picker.get_item_metadata(pair_action_picker.selected)
		var needs_subject: bool = action_id in ["swap_book", "swap_book_boost"]
		pair_subject_picker.visible = needs_subject
		var subject_id: String = String(pair_subject_picker.get_item_metadata(pair_subject_picker.selected)) if needs_subject else ""
		reason = simulation.interaction_unavailable_reason(0, pair_action_target_index, action_id, subject_id)
		_update_readonly_text(pair_action_text, _pair_action_description(action_id))
	pair_action_reason.text = reason
	pair_action_button.disabled = not reason.is_empty()
	pair_action_button.tooltip_text = "与%s开始所选互动" % simulation.students[pair_action_target_index].name if reason.is_empty() else reason


# 成功后才收起操作窗口；费用或物品不足保持原动作并显示执行器的明确原因。
func _start_pair_action() -> void:
	if simulation == null or fatal_error or pair_action_target_index <= 0 or pair_action_picker.selected < 0:
		return
	var action_id: String = pair_action_picker.get_item_metadata(pair_action_picker.selected)
	var subject_id: String = String(pair_subject_picker.get_item_metadata(pair_subject_picker.selected)) if action_id in ["swap_book", "swap_book_boost"] else ""
	var result: Error = simulation.start_interaction(0, pair_action_target_index, action_id, "", subject_id)
	if result != OK:
		_show_interaction_error(result)
		return
	pair_action_dialog.hide()
	status_label.text = "已发动%s" % configuration.actions[action_id].name
	_refresh_interface()


# 只展开已保存的榜单，不改变查看人物、纸条收件人、草稿或权威游戏状态。
func _show_round_boards() -> void:
	if simulation == null or fatal_error:
		return
	_refresh_round_interface()
	inspector_tabs.current_tab = 5
	_set_panel_visible(true)


# 类型变化仅控制筛选控件和文字，未公布考试不会读取成绩行用于展示。
func _on_round_type_selected(index: int) -> void:
	round_view_type = round_type_picker.get_item_id(index)
	round_board_text.get_v_scroll_bar().value = 0.0
	_refresh_round_interface()


# 日期由筛选项明确选定，不随着后台时钟刷新跳走。
func _on_round_day_selected(index: int) -> void:
	round_view_day = round_day_picker.get_item_id(index)
	round_board_text.get_v_scroll_bar().value = 0.0
	_refresh_round_interface()


# 科目选择保持在界面层，不触发考试取值或重新计算。
func _on_round_subject_selected(index: int) -> void:
	round_view_subject = round_subject_picker.get_item_metadata(index)
	round_board_text.get_v_scroll_bar().value = 0.0
	_refresh_round_interface()


# 换局清除上局筛选与文字缓存，日数和默认日期来自本次真实局。
func _reset_round_interface() -> void:
	round_view_type = 0
	round_view_day = clampi(simulation.day, 1, int(simulation.get_round_summary().session_days))
	round_view_subject = "chinese"
	round_filter_days = 0
	round_type_picker.select(0)
	round_day_picker.clear()
	round_subject_picker.clear()
	round_board_text.clear()


# 榜单内容完全来自核心查询，缺失和未公布状态必须可见，不以零分或当前知识代填。
func _refresh_round_interface() -> void:
	if simulation == null or fatal_error:
		return
	var round_summary: Dictionary = simulation.get_round_summary()
	var session_days: int = int(round_summary.session_days)
	if round_filter_days != session_days:
		round_day_picker.clear()
		for board_day in range(1, session_days + 1):
			round_day_picker.add_item("第%d天" % board_day, board_day)
		round_day_picker.select(round_day_picker.get_item_index(round_view_day))
		round_filter_days = session_days
	if round_subject_picker.item_count == 0:
		for subject_id: String in ROUND_SUBJECT_IDS:
			round_subject_picker.add_item(String(configuration.subjects[subject_id].name))
			round_subject_picker.set_item_metadata(round_subject_picker.item_count - 1, subject_id)
		round_subject_picker.select(ROUND_SUBJECT_IDS.find(round_view_subject))
	for index in ROUND_SUBJECT_IDS.size():
		round_subject_picker.set_item_text(index, String(configuration.subjects[ROUND_SUBJECT_IDS[index]].name))
	round_day_picker.visible = round_view_type == 0
	round_subject_picker.visible = round_view_type != 2
	var lines := PackedStringArray()
	match round_view_type:
		0:
			var board: Dictionary = simulation.get_daily_board(round_view_day, round_view_subject)
			lines.append("第%d天 · %s知识榜" % [round_view_day, configuration.subjects[round_view_subject].name])
			if board.status == "published":
				lines.append("统计 %s—%s" % [_clock(board.start_seconds), _clock(board.end_seconds)])
				lines.append("来源：" + _round_source_text(String(board.source)))
				if not String(board.reason).is_empty():
					lines.append(String(board.reason))
				for row: Dictionary in board.rows:
					lines.append("\n第%d名  %s\n新增知识 %s" % [row.rank, row.name, _interaction_number(float(row.knowledge))])
			elif board.status == "pending":
				lines.append("尚未发布：当日%s统计新增知识。" % _clock(board.end_seconds))
			else:
				lines.append("未记录：" + String(board.reason))
		1:
			var board: Dictionary = simulation.get_exam_board(round_view_subject)
			lines.append("%s · 考试成绩" % configuration.subjects[round_view_subject].name)
			if board.status == "published":
				lines.append("第%d天开考 %s · 发布 %s" % [board.day, _clock(board.start_seconds), _clock(board.end_seconds)])
				lines.append("来源：" + _round_source_text(String(board.source)))
				if not String(board.reason).is_empty():
					lines.append(String(board.reason))
				for row: Dictionary in board.rows:
					lines.append("\n第%d名  %s  %s分" % [row.rank, row.name, _round_score_text(float(row.score), int(row.score_decimal_places))])
					lines.append("快照知识 %s · 有效智力 %s" % [_interaction_number(float(row.knowledge)), _interaction_number(float(row.effective_intelligence))])
					lines.append("满分 %s · 曲线 %s\n智力系数 %s · 保留%d位小数" % [_interaction_number(float(row.max_score)), _interaction_number(float(row.score_scale)), _interaction_number(float(row.exam_intelligence_coefficient)), row.score_decimal_places])
				lines.append("\n成绩使用开考时保存的知识、智力和计分参数，后续调表不重算历史。")
			elif board.status == "snapshot":
				lines.append("开考快照已保存，课程结束后公布成绩。")
				lines.append("来源：" + _round_source_text(String(board.source)))
			elif board.status == "pending":
				lines.append("尚未开考：第%d天 %s。" % [board.day, _clock(board.start_seconds)])
			else:
				lines.append("未记录：" + String(board.reason))
		2:
			var board: Dictionary = simulation.get_final_board()
			lines.append("七天最终榜")
			if board.status == "published":
				# 总榜可能合并不同历史精度的科目，逐科只读当时已公布的记录。
				var published_subjects: Dictionary = {}
				for subject_id: String in ROUND_SUBJECT_IDS:
					var published_rows: Dictionary = {}
					for subject_row: Dictionary in simulation.get_exam_board(subject_id).rows:
						published_rows[subject_row.student_id] = subject_row
					published_subjects[subject_id] = published_rows
				for row: Dictionary in board.rows:
					lines.append("\n第%d名  %s\n总分 %s" % [row.rank, row.name, _round_score_text(float(row.score), int(row.score_decimal_places))])
					var subject_scores := PackedStringArray()
					for subject_id: String in ROUND_SUBJECT_IDS:
						var saved_subject: Dictionary = published_subjects[subject_id][row.student_id]
						subject_scores.append("%s %s" % [configuration.subjects[subject_id].name, _round_score_text(float(saved_subject.score), int(saved_subject.score_decimal_places))])
					lines.append(" · ".join(subject_scores))
				lines.append("\n各科先按快照参数取整，再相加；同分并列。")
			elif board.status == "incomplete":
				lines.append("最终成绩未完整记录：" + String(board.reason))
				var missing := PackedStringArray()
				for subject_id: String in board.missing_subjects:
					missing.append(String(configuration.subjects[subject_id].name))
				lines.append("缺少科目：" + "、".join(missing))
				lines.append("缺失科目不猜分，不生成完整总分。")
			else:
				lines.append("总榜尚未发布，第%d天%s结算。" % [round_summary.final_day, _clock(round_summary.final_seconds)])
	if simulation.is_round_finished():
		lines.append("\n本局已结束，可查阅、保存或在设置中手动重新开始。")
	_update_readonly_text(round_board_text, "\n".join(lines))


# 将核心来源标识译为可读说明；未知来源原样呈现，不能伪装成在线记录。
func _round_source_text(source: String) -> String:
	match source:
		"online":
			return "在线实际状态"
		"offline_frozen":
			return "离线冻结状态结算"
		"partial":
			return "迁移日从接入时开始统计"
	return source


# 显示保存的成绩精度，不用当前配置覆盖历史的小数位。
func _round_score_text(value: float, decimal_places: int) -> String:
	return ("%." + str(decimal_places) + "f") % value


# 没有草稿时沿用正在查看的同学；已有草稿始终保留明确选择的收件人。
func _show_interactions() -> void:
	if simulation == null or fatal_error:
		return
	if note_input.text.is_empty() and selected_index > 0:
		_set_interaction_target(selected_index)
	inspector_tabs.current_tab = 3
	_set_panel_visible(true)
	_refresh_interaction_interface()


# 下拉列表和右键纸条入口显式切换收件人，查看其他人物不转移正在写的纸条。
func _on_interaction_target_selected(item_index: int) -> void:
	_set_interaction_target(interaction_target_picker.get_item_id(item_index))
	_refresh_interaction_interface()


# 每位同学分别暂存草稿；恢复只用于输入框，不参与存档或权威业务状态。
func _set_interaction_target(target_index: int) -> void:
	note_drafts[interaction_target_index] = note_input.text
	interaction_target_index = target_index
	interaction_target_picker.select(target_index - 1)
	note_input.text = String(note_drafts.get(target_index, ""))


# 输入仅更新发送条件，不提前建立互动或把草稿显示为已送达。
func _on_note_text_changed(_text_value: String) -> void:
	note_drafts[interaction_target_index] = note_input.text
	if simulation != null and not fatal_error:
		_refresh_interaction_interface()


# 回车和发送按钮走同一条真实指令入口。
func _on_note_text_submitted(_text_value: String) -> void:
	_send_note()


# 提交时固定玩家和当前收件人，只有真实发动成功后才清空草稿。
func _send_note() -> void:
	if simulation == null or fatal_error:
		return
	if simulation.is_round_finished():
		_refresh_interface()
		return
	var recipient: int = interaction_target_index
	var result: Error = simulation.start_interaction(0, recipient, "send_note", note_input.text)
	if result != OK:
		_show_interaction_error(result)
		return
	note_input.clear()
	note_drafts.erase(recipient)
	status_label.text = "已发动纸条，完成后送达"
	_refresh_interface()


# 基础橡皮直接调用无道具变体，不读取背包或自动改成增强型动作。
func _prank_selected_student() -> void:
	_prank_student(interaction_target_index)


# 两种界面入口显式传入各自绑定的目标，共用同一个真实执行器。
func _prank_student(target_index: int) -> void:
	if simulation == null or fatal_error:
		return
	if simulation.is_round_finished():
		_refresh_interface()
		return
	var result: Error = simulation.start_interaction(0, target_index, "eraser_prank")
	if result != OK:
		_show_interaction_error(result)
		return
	status_label.text = "已发动弹橡皮"
	_refresh_interface()


# 举报提交界面当前显示的真实事件编号，由核心保证同一事件只结算一次。
func _report_selected_violation() -> void:
	_report_student_violation(interaction_target_index, -1 if current_report_violation.is_empty() else int(current_report_violation.violation_id))


# 事件编号由入口固定，任何普通拒绝仍保留原动作和资源并向用户显示真实原因。
func _report_student_violation(target_index: int, violation_id: int) -> void:
	if simulation == null or fatal_error:
		return
	if simulation.is_round_finished():
		_refresh_interface()
		return
	if violation_id < 0:
		_queue_error("该同学当前没有可举报的违纪事件。")
		return
	var result: Error = simulation.report_violation(target_index, violation_id)
	if result != OK:
		_show_interaction_error(result)
		return
	status_label.text = "举报已结算"
	_refresh_interface()


# 正常指令拒绝可见但不停止游戏，配置或状态不变量失败仍保留致命错误现场。
func _show_interaction_error(result: Error) -> void:
	if result in [ERR_UNAVAILABLE, ERR_INVALID_PARAMETER, ERR_ALREADY_EXISTS]:
		status_label.text = "互动未执行"
		_queue_error(simulation.error_message)
		_refresh_interface()
	else:
		_fail(simulation.error_message)


# 费用、时长和禁用原因均读取执行器及当前配表，不另存一套业务数值。
func _refresh_interaction_interface() -> void:
	if simulation == null or fatal_error:
		return
	var target_name: String = String(simulation.students[interaction_target_index].name)
	interaction_summary.text = "我：%s\n%s：%s" % [_student_activity_summary(0), target_name, _student_activity_summary(interaction_target_index)]
	interaction_summary.tooltip_text = interaction_summary.text
	interaction_cost_label.text = "%s\n%s" % [_interaction_cost_summary("send_note"), _interaction_cost_summary("eraser_prank")]
	interaction_cost_label.tooltip_text = interaction_cost_label.text
	var note_reason: String = simulation.interaction_unavailable_reason(0, interaction_target_index, "send_note")
	if note_reason.is_empty() and note_input.text.strip_edges().is_empty():
		note_reason = "请输入纸条内容"
	var eraser_reason: String = simulation.interaction_unavailable_reason(0, interaction_target_index, "eraser_prank")
	current_report_violation = simulation.get_open_violation(interaction_target_index)
	var report_reason: String = "当前没有可举报的违纪事件"
	if not current_report_violation.is_empty():
		report_reason = simulation.report_unavailable_reason(interaction_target_index, current_report_violation.violation_id)
	send_note_button.disabled = not note_reason.is_empty()
	eraser_button.disabled = not eraser_reason.is_empty()
	report_button.disabled = not report_reason.is_empty()
	note_input.editable = not simulation.is_round_finished()
	send_note_button.tooltip_text = _interaction_tooltip("send_note", note_reason)
	eraser_button.tooltip_text = _interaction_tooltip("eraser_prank", eraser_reason)
	report_button.tooltip_text = _interaction_tooltip("report", report_reason)
	var reasons: Array[String] = []
	if not note_reason.is_empty():
		reasons.append("纸条：" + note_reason)
	if not eraser_reason.is_empty():
		reasons.append("橡皮：" + eraser_reason)
	if not report_reason.is_empty():
		reasons.append("举报：" + report_reason)
	interaction_reason_label.text = "可用操作见上方按钮" if reasons.is_empty() else reasons[0]
	interaction_reason_label.tooltip_text = "\n".join(reasons)
	if report_reason.is_empty() and _is_player_interaction_partner():
		interaction_reason_label.text = "举报当前搭档会结束互动"
		interaction_reason_label.tooltip_text = _report_consequence_text()
	_refresh_notes()


# 当前搭档只从有效的共同互动中查找；普通动作名称仍采用配置权威源。
func _student_activity_summary(student_index: int) -> String:
	for interaction in simulation.interactions:
		if String(interaction.status) != "active":
			continue
		var partner_index: int = -1
		var direction: String = ""
		if int(interaction.initiator_index) == student_index:
			partner_index = int(interaction.target_index)
			direction = "→"
		elif int(interaction.target_index) == student_index:
			partner_index = int(interaction.initiator_index)
			direction = "←"
		if partner_index >= 0:
			return "%s %s %s" % [configuration.actions[String(interaction.action_id)].name, direction, simulation.students[partner_index].name]
	return _action_name(simulation.students[student_index])


# 收发记录仅展示完成事件产生的notes，重绘不会让在途或中断纸条提前出现。
func _refresh_notes() -> void:
	if rendered_notes_target == interaction_target_index and rendered_notes_count == simulation.notes.size():
		return
	rendered_notes_target = interaction_target_index
	rendered_notes_count = simulation.notes.size()
	var target_name: String = String(simulation.students[interaction_target_index].name)
	var lines: Array[String] = ["我 ⇄ %s · 已送达纸条" % target_name]
	for note in simulation.notes:
		var sender: int = int(note.sender_index)
		var recipient: int = int(note.target_index)
		if sender == 0 and recipient == interaction_target_index:
			lines.append("我 → %s：%s" % [target_name, note.text])
		elif recipient == 0 and sender == interaction_target_index:
			lines.append("%s → 我：%s" % [target_name, note.text])
	if lines.size() == 1:
		lines.append("暂无送达记录；填写纸条可发送或回复。")
	notes_text.text = "\n".join(lines)


# 持续时长和启动资源直接格式化自配表；不把策划文档数值复制到界面。
func _interaction_cost_summary(action_id: String) -> String:
	var action: Dictionary = configuration.actions[action_id]
	var duration_text: String = "瞬时"
	if action.kind == "duration":
		duration_text = "%s秒" % _interaction_number(float(action.duration_min_s))
		if not is_equal_approx(float(action.duration_min_s), float(action.duration_max_s)):
			duration_text = "%s～%s秒" % [_interaction_number(float(action.duration_min_s)), _interaction_number(float(action.duration_max_s))]
	var costs: Array[String] = []
	for effect in configuration.phase_effects(action_id, "start"):
		if effect.type == "resource" and float(effect.value) < 0.0:
			costs.append(_resource_effect_text(effect))
	return "%s %s · %s" % [action.name, duration_text, "启动无资源费" if costs.is_empty() else "、".join(costs)]


# 鼠标说明展开真实阶段效果，有限面板仍能检查完成收益和失败原因。
func _interaction_tooltip(action_id: String, unavailable_reason: String, target_index: int = -1) -> String:
	var lines: Array[String] = [_interaction_cost_summary(action_id)]
	for phase in ["start", "tick", "complete", "instant"]:
		var phase_name: String = {"start": "启动", "tick": "持续", "complete": "完成", "instant": "立即"}[phase]
		for effect in configuration.phase_effects(action_id, phase):
			var detail: String = _resource_effect_text(effect) if effect.type == "resource" else String(effect.description)
			lines.append("%s：%s" % [phase_name, detail])
	if action_id == "report":
		lines.append(_report_consequence_text(target_index))
	if not unavailable_reason.is_empty():
		lines.append("不可用：" + unavailable_reason)
	return "\n".join(lines)


# 当前搭档采用双方共同的有效互动关系判断，不从选中人物或动作名称猜测。
func _is_player_interaction_partner(target_index: int = -1) -> bool:
	var target: int = interaction_target_index if target_index < 0 else target_index
	for interaction in simulation.interactions:
		if String(interaction.status) != "active":
			continue
		if (int(interaction.initiator_index) == 0 and int(interaction.target_index) == target) or (int(interaction.target_index) == 0 and int(interaction.initiator_index) == target):
			return true
	return false


# 已确认的同组举报例外需要在点击前可见，普通举报仍保持自己的持续动作。
func _report_consequence_text(target_index: int = -1) -> String:
	if _is_player_interaction_partner(target_index):
		return "举报当前搭档会结束双方旧互动；对方强制回课表，我按课表自然重新选择；未完成纸条不送达。"
	return "举报立即结算，不改变我的当前持续动作。"


# 显示资源对象、数值和周期，比例效果保留当前上限语义而非猜测固定点数。
func _resource_effect_text(effect: Dictionary) -> String:
	var recipient: String = {"self": "我", "target": "对方", "both": "双方", "winner": "胜者", "loser": "败者"}[String(effect.recipient)]
	var resource_name: String = {"focus": "专注", "stamina": "体力"}[String(effect.resource)]
	var amount: float = float(effect.value)
	var amount_text: String = ("+" if amount >= 0.0 else "-") + _interaction_number(absf(amount))
	if effect.mode == "max_ratio":
		amount_text = ("+" if amount >= 0.0 else "-") + _interaction_number(absf(amount) * 100.0) + "%各自当前上限"
	var text: String = "%s%s%s" % [recipient, resource_name, amount_text]
	if effect.period_s != null:
		text += " / %s秒" % _interaction_number(float(effect.period_s))
	return text


# 配置数值只去掉无意义的小数零，不在显示层另行抽样或限制精度。
func _interaction_number(value: float) -> String:
	return str(value).trim_suffix(".0")


# 显示配置中的所有当天时段；未配置课程的天数明确说明，不推造课程。
func _refresh_timetable() -> void:
	var lines: Array[String] = ["第%d天 · 当天课表" % simulation.day, ""]
	for period in configuration.periods:
		var subject_name: String = ""
		if String(period.kind) == "lesson":
			for row in configuration.tables.schedule:
				if int(row.day) == simulation.day and String(row.period_id) == String(period.id):
					subject_name = String(configuration.subjects[row.subject_id].name)
					break
			if subject_name.is_empty():
				subject_name = "本局课程已结束"
		var start = _clock(round(float(period.start_time) * 86400.0)).left(5)
		var finish = _clock(round(float(period.end_time) * 86400.0)).left(5)
		lines.append("%s—%s  %s%s" % [start, finish, period.name, " · " + subject_name if not subject_name.is_empty() else ""])
	timetable_text.text = "\n".join(lines)


# 系统拖动仅绑定课程时间空白区域，按钮事件不会传播到这里。
func _on_drag_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if desktop != null and desktop.is_initialized():
			desktop.start_drag()


# 顶栏请求由控制器保存缩放偏好，再由信号更新唯一界面布局。
func _toggle_window_scale() -> void:
	if desktop == null or not desktop.is_initialized():
		_show_window_error("桌面功能尚未初始化，请在设置中重试桌面功能。")
		return
	desktop.request_zoom(2 if window_scale == 1 else 1)


# 置顶按钮只反映控制器确认后的真实置顶状态。
func _toggle_pinned() -> void:
	if desktop == null or not desktop.is_initialized():
		pin_button.set_pressed_no_signal(false)
		_show_window_error("桌面功能尚未初始化，请在设置中重试桌面功能。")
		return
	desktop.set_pinned(not desktop.pinned)


# 原生初始化是独立生命周期，失败允许明确重试而不新建或覆盖游戏局。
func _initialize_desktop() -> void:
	if desktop != null:
		if desktop.is_initialized():
			return
		desktop.shutdown()
		remove_child(desktop)
		desktop.queue_free()
	desktop = DESKTOP_SCRIPT.new()
	add_child(desktop)
	desktop.failure.connect(_show_window_error)
	desktop.zoom_requested.connect(_set_window_scale)
	desktop.pin_changed.connect(_on_pin_changed)
	desktop.hide_requested.connect(_on_window_hidden)
	desktop.restore_requested.connect(_on_window_restored)
	desktop.quit_requested.connect(_request_exit)
	var result: Error = desktop.initialize(get_window())
	if result != OK:
		return
	window_scale = desktop.pixel_scale
	_on_pin_changed(desktop.pinned)
	_apply_layout()


# 隐藏成功信号只停止视觉帧；根节点与四名同学继续按真实时间运行。
func _on_window_hidden() -> void:
	_close_student_context()
	_close_player_dialogs()
	room.set_animation_enabled(false)


# 恢复后从当前权威状态刷新视觉，不补算第二次收益。
func _on_window_restored() -> void:
	room.set_animation_enabled(true)
	_refresh_interface()


# 控制器发出真实置顶状态后再同步按钮，不从按钮状态猜测窗口状态。
func _on_pin_changed(value: bool) -> void:
	pin_button.set_pressed_no_signal(value)


# 关闭入口等待真实Win32隐藏和核验，不把请求或最小化当作托盘成功。
func _hide_to_tray() -> void:
	_close_student_context()
	if desktop == null or not desktop.is_initialized():
		_show_window_error("桌面托盘尚未初始化，窗口保持可见。请在设置中重试桌面功能。")
		return
	var result: Error = await desktop.hide_to_tray()
	if result != OK:
		await _present_pending_errors()


# 真正退出必须先成功保存当前局和窗口偏好；任何失败均恢复窗口保留现场。
func _request_exit() -> void:
	_close_student_context()
	if exit_in_progress:
		return
	exit_in_progress = true
	if simulation == null or fatal_error:
		_queue_error("当前游戏已停止或尚未成功初始化，请修复错误并重新读取配表后再保存退出。")
		await _present_pending_errors()
		exit_in_progress = false
		return
	if not is_instance_valid(desktop) or not desktop.is_initialized():
		_show_window_error("桌面功能尚未初始化，无法确认窗口偏好已保存。请在设置中重试桌面功能。")
		await _present_pending_errors()
		exit_in_progress = false
		return
	# 原生辅助程序需要窗口消息泵；退出也逐帧等待，不能在主线程直接回收在途工作线程。
	while desktop.is_transitioning():
		await get_tree().process_frame
		if not is_instance_valid(desktop) or not desktop.is_initialized():
			_show_window_error("等待窗口操作期间桌面功能已停止，当前游戏保留，请重试桌面功能后再保存退出。")
			await _present_pending_errors()
			exit_in_progress = false
			return
	if not _save_session(false):
		await _present_pending_errors()
		exit_in_progress = false
		return
	if desktop.persist_preferences() != OK:
		await _present_pending_errors()
		exit_in_progress = false
		return
	desktop.shutdown()
	get_tree().quit()


# 窗口和偏好失败需要可见提示，但不因此停止健康的权威模拟器。
func _show_window_error(message: String) -> void:
	status_label.text = "窗口操作失败"
	_queue_error(message)


# 合并同一原生操作中的错误，避免失败信号触发递归恢复窗口。
func _queue_error(message: String) -> void:
	_close_student_context()
	_close_player_dialogs()
	if message not in pending_errors:
		pending_errors.append(message)
	if not error_presentation_active:
		call_deferred("_present_pending_errors")


# 恢复真正隐藏的窗口后再展示错误，等待期间仍让Godot主线程泵送原生消息。
func _present_pending_errors() -> void:
	if error_presentation_active:
		while error_presentation_active:
			await get_tree().process_frame
		return
	if pending_errors.is_empty():
		return
	error_presentation_active = true
	if desktop != null and desktop.is_initialized():
		while desktop.is_transitioning():
			await get_tree().process_frame
		if desktop.hidden_to_tray:
			var result: Error = await desktop.restore_window()
			if result != OK and desktop.error_message not in pending_errors:
				pending_errors.append(desktop.error_message)
	error_dialog.dialog_text = "\n\n".join(pending_errors)
	pending_errors.clear()
	error_dialog.popup_centered()
	error_presentation_active = false

# 开发时钟入口明确标记，推进仍经过相同的行为树和数值结算。
func _build_dialogs() -> void:
	error_dialog = AcceptDialog.new()
	error_dialog.title = "运行错误"
	error_dialog.ok_button_text = "确定"
	error_dialog.min_size = Vector2i(560, 180)
	add_child(error_dialog)
	restart_dialog = ConfirmationDialog.new()
	restart_dialog.title = "重新开始"
	restart_dialog.ok_button_text = "重新开始"
	restart_dialog.cancel_button_text = "取消"
	restart_dialog.dialog_text = "重新创建本地班级，将替换当前进度。"
	restart_dialog.confirmed.connect(_restart_session)
	add_child(restart_dialog)
	debug_dialog = AcceptDialog.new()
	debug_dialog.title = "开发工具"
	debug_dialog.ok_button_text = "关闭"
	debug_dialog.min_size = Vector2i(460, 220)
	add_child(debug_dialog)
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	debug_dialog.add_child(content)
	var morning = _button("开发时钟：第1天 08:00", "进入独立的开发存档，使用正常课表与动作规则")
	morning.pressed.connect(_enter_debug_morning)
	content.add_child(morning)
	var row = HBoxContainer.new()
	content.add_child(row)
	row.add_child(_label("推进分钟", 14))
	advance_input = LineEdit.new()
	advance_input.text = "10"
	advance_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(advance_input)
	var advance = _button("推进", "推进开发时钟并执行全部真实事件")
	advance.pressed.connect(_advance_debug_time)
	row.add_child(advance)
	var computer = _button("回到电脑时间", "恢复正式本地存档并对齐当前课表")
	computer.pressed.connect(_return_to_computer_time)
	content.add_child(computer)
	_build_attribute_dialog()
	_build_personal_action_dialog()
	_build_pair_action_dialog()


# 四项基础属性逐点分配，显示真实剩余点数；提高上限不赠送当前资源。
func _build_attribute_dialog() -> void:
	attribute_dialog = AcceptDialog.new()
	attribute_dialog.name = "AttributeDialog"
	attribute_dialog.title = "我的属性"
	attribute_dialog.ok_button_text = "关闭"
	attribute_dialog.min_size = Vector2i(280, 218)
	add_child(attribute_dialog)
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	attribute_dialog.add_child(content)
	attribute_points_label = _label("", 14)
	content.add_child(attribute_points_label)
	var grid = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	content.add_child(grid)
	for attribute_id: String in ATTRIBUTE_NAMES:
		var title: Label = _label(ATTRIBUTE_NAMES[attribute_id], 12)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(title)
		var value: Label = _label("", 12)
		value.custom_minimum_size.x = 40
		grid.add_child(value)
		attribute_value_labels[attribute_id] = value
		var button: Button = _button("+", "%s增加1点" % ATTRIBUTE_NAMES[attribute_id])
		button.name = "Allocate_" + attribute_id
		button.custom_minimum_size = Vector2(28, 26)
		button.pressed.connect(_allocate_selected_attribute.bind(attribute_id))
		grid.add_child(button)
		attribute_buttons[attribute_id] = button


# 个人行动以选项、真实效果和明确开始按钮组成，长效果在固定区域滚动。
func _build_personal_action_dialog() -> void:
	personal_action_dialog = AcceptDialog.new()
	personal_action_dialog.name = "PersonalActionDialog"
	personal_action_dialog.title = "我的行动"
	personal_action_dialog.ok_button_text = "关闭"
	personal_action_dialog.min_size = Vector2i(300, 258)
	add_child(personal_action_dialog)
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	personal_action_dialog.add_child(content)
	personal_action_picker = OptionButton.new()
	personal_action_picker.name = "PersonalActionPicker"
	personal_action_picker.fit_to_longest_item = false
	personal_action_picker.custom_minimum_size.y = 26
	personal_action_picker.item_selected.connect(_on_personal_action_selected)
	content.add_child(personal_action_picker)
	personal_action_text = _text_area("PersonalActionDescription")
	personal_action_text.custom_minimum_size = Vector2(0, 96)
	personal_action_text.add_theme_font_size_override("normal_font_size", 11)
	content.add_child(personal_action_text)
	personal_action_reason = _label("", 11, MUTED)
	personal_action_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(personal_action_reason)
	personal_action_button = _action_button("focus", "开始", "开始本人选中的行动")
	personal_action_button.name = "PersonalActionStart"
	personal_action_button.custom_minimum_size.y = 28
	personal_action_button.pressed.connect(_start_personal_action)
	content.add_child(personal_action_button)


# 双人窗口保持固定滚动说明区，1倍尺寸下仍能选动作、选科和明确发动。
func _build_pair_action_dialog() -> void:
	pair_action_dialog = AcceptDialog.new()
	pair_action_dialog.name = "PairActionDialog"
	pair_action_dialog.title = "同学互动"
	pair_action_dialog.ok_button_text = "关闭"
	pair_action_dialog.min_size = Vector2i(300, 276)
	pair_action_dialog.visibility_changed.connect(_on_pair_dialog_hidden)
	add_child(pair_action_dialog)
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	pair_action_dialog.add_child(content)
	pair_action_picker = OptionButton.new()
	pair_action_picker.name = "PairActionPicker"
	pair_action_picker.fit_to_longest_item = false
	pair_action_picker.custom_minimum_size.y = 26
	pair_action_picker.item_selected.connect(_on_pair_action_selected)
	content.add_child(pair_action_picker)
	pair_subject_picker = OptionButton.new()
	pair_subject_picker.name = "PairSubjectPicker"
	pair_subject_picker.fit_to_longest_item = false
	pair_subject_picker.custom_minimum_size.y = 26
	pair_subject_picker.item_selected.connect(_on_pair_subject_selected)
	content.add_child(pair_subject_picker)
	pair_action_text = _text_area("PairActionDescription")
	pair_action_text.custom_minimum_size.y = 80
	pair_action_text.add_theme_font_size_override("normal_font_size", 11)
	content.add_child(pair_action_text)
	pair_action_reason = _label("", 11, MUTED)
	pair_action_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(pair_action_reason)
	pair_action_button = _action_button("focus", "开始互动", "开始与该同学的互动")
	pair_action_button.name = "PairActionStart"
	pair_action_button.custom_minimum_size.y = 28
	pair_action_button.pressed.connect(_start_pair_action)
	content.add_child(pair_action_button)
# 保持字体和控件高度稳定，动态内容不会改变固定工具尺寸。
func _label(text_value: String, font_size: int, color: Color = INK) -> Label:
	var label = Label.new()
	label.text = text_value
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


# 按钮文字对应明确操作，补充鼠标提示方便理解作用对象。
func _button(text_value: String, tooltip: String) -> Button:
	var button = Button.new()
	button.text = text_value
	button.tooltip_text = tooltip
	button.custom_minimum_size.y = 32
	return button


# 进度条只负责显示状态，不持有独立的资源数值。
func _progress(color: Color, height: float) -> ProgressBar:
	var progress = ProgressBar.new()
	progress.custom_minimum_size.y = height
	progress.show_percentage = false
	var background_style = _box(Color("dae4dc"), Color("dae4dc"))
	var fill_style = _box(color, color)
	# 进度条不继承按钮留白，确保小窗口仍容纳完整状态栏。
	for style in [background_style, fill_style]:
		style.content_margin_top = 0
		style.content_margin_bottom = 0
	progress.add_theme_stylebox_override("background", background_style)
	progress.add_theme_stylebox_override("fill", fill_style)
	return progress


# 新建或读取状态后创建四棵共享蓝图实例，再开放自主决策。
func _start_session(read_save: bool) -> void:
	_close_student_context()
	_close_player_dialogs()
	if is_instance_valid(behavior):
		remove_child(behavior)
		behavior.queue_free()
	# 只有完整通过初始化和读档的状态才能成为当前游戏，失败后重试必须重新读档。
	simulation = null
	if configuration == null:
		_fail("请先修复并重新读取配表，再开始游戏。")
		return
	var next_simulation = ClassroomSimulation.new()
	if next_simulation.setup(configuration) != OK:
		_fail(next_simulation.error_message)
		return
	if read_save and FileAccess.file_exists(SAVE_PATH):
		if next_simulation.load_file(SAVE_PATH) != OK:
			_fail(next_simulation.error_message)
			return
	simulation = next_simulation
	_attach_behavior()


# 绑定运行状态与树回调；角色原先的在途动作不会被重新开始。
func _attach_behavior() -> void:
	behavior = ClassroomBehaviorController.new()
	add_child(behavior)
	behavior.setup(simulation)
	simulation.decision_handler = behavior.decide
	if simulation.advance(0.0) != OK:
		_fail(simulation.error_message)
		# 首轮决策也属于初始化，失败状态不能被重读配表误认为有效游戏。
		simulation = null
		return
	fatal_error = false
	_close_player_dialogs()
	room.set_view_location("auto")
	scene_picker.select(0)
	room.bind_game(simulation)
	selected_index = 0
	room.selected_index = 0
	rendered_log_count = 0
	log_text.clear()
	interaction_target_index = 1
	interaction_target_picker.clear()
	for index in range(1, simulation.students.size()):
		interaction_target_picker.add_item(String(simulation.students[index].name), index)
	interaction_target_picker.select(0)
	note_input.clear()
	note_drafts.clear()
	current_report_violation = {}
	rendered_notes_target = -1
	rendered_notes_count = -1
	_reset_round_interface()
	last_ticks = Time.get_ticks_usec()
	_refresh_interface()


# 明确确认后的重新开始才替换旧存档。
func _restart_session() -> void:
	_start_session(false)
	if not fatal_error:
		_save_session(true)


# 查看任何同学都不会修改唯一的玩家控制索引。
func _select_student(index: int) -> void:
	attribute_dialog.hide()
	selected_index = index
	room.selected_index = index
	status_effects_text.get_v_scroll_bar().value = 0.0
	inventory_text.get_v_scroll_bar().value = 0.0
	inspector_tabs.current_tab = 0
	_set_panel_visible(true)
	_refresh_interface()


# 专注指令每次点击直接提交，不加冷却、次数限制或手动保护状态。
func _focus_player() -> void:
	if simulation == null or fatal_error:
		return
	# 到期与控件刷新之间可能仍收到上一帧点击；结束局保持只读，不把正常局末当成致命错误。
	if simulation.is_round_finished():
		_refresh_interface()
		return
	if simulation.focus_command(0) != OK:
		_fail(simulation.error_message)
		return
	_refresh_interface()


# 自己的持续动作复用统一执行入口，与自主动作保持同一费用和结算语义。
func _manual_action(action_id: String) -> bool:
	if simulation == null or fatal_error:
		return false
	var result: Error = simulation.start_action(0, action_id, true)
	if result == ERR_UNAVAILABLE:
		_queue_error(simulation.error_message)
		_refresh_interface()
		return false
	if result != OK:
		_fail(simulation.error_message)
		return false
	status_label.text = "开始%s" % configuration.actions[action_id].name
	_refresh_interface()
	return true


# 界面只读取已初始化的权威状态，不能用默认资源伪装初始化成功。
func _refresh_interface() -> void:
	if simulation == null or fatal_error:
		return
	var context = simulation.course_context()
	var subject_name = String(context.subject_name)
	course_label.text = String(context.period_name) + (" · " + subject_name if not subject_name.is_empty() else "")
	course_label.tooltip_text = course_label.text
	clock_label.text = "第%d天 %s%s" % [simulation.day, _clock(simulation.clock_seconds), " [开发]" if simulation.is_debug_time else ""]
	# 1倍工具栏完整保留开发标记和分钟；精确到秒的时刻仍在悬停提示中可查。
	if simulation.is_debug_time and window_scale == 1:
		clock_label.text = "[开发] %d天 %s" % [simulation.day, _clock(simulation.clock_seconds).left(5)]
	clock_label.tooltip_text = "第%d天 %s\n%s" % [
		simulation.day, _clock(simulation.clock_seconds),
		"独立开发时钟，不覆盖正式进度" if simulation.is_debug_time else "电脑当天时间与课表",
	]
	if simulation.is_round_finished():
		course_label.text = "本局已结束"
		course_label.tooltip_text = "七天局已结束，可查阅榜单、保存或手动重新开始。"
	var location: String = room.get_view_location()
	scene_caption.text = "%d / 4 在%s" % [_count_at_location(location), ClassroomView.LOCATION_NAMES[location]]
	scene_picker.tooltip_text = "观察%s · 我在%s" % [ClassroomView.LOCATION_NAMES[location], ClassroomView.LOCATION_NAMES[simulation.student_location(0)]]
	for index in roster_buttons.size():
		var member: Dictionary = simulation.students[index]
		roster_buttons[index].text = String(member.name)
		roster_buttons[index].tooltip_text = "%s · %s" % [member.name, _action_name(member)]
		roster_buttons[index].add_theme_stylebox_override("normal", _box(Color("e2eff1") if selected_index == index else Color("f4f8f5"), Color("91b6c0") if selected_index == index else Color("c8d6cd")))
	var student: Dictionary = simulation.students[selected_index]
	selected_name.text = String(student.name) + (" · 我" if selected_index == 0 and student.name != "我" else "")
	var action: Dictionary = student.current_action
	selected_action.text = _action_name(student)
	if not action.is_empty():
		var remaining = maxf(0.0, float(action.ends_at) - simulation.elapsed_s)
		selected_action.text += "   剩余 " + _duration(remaining)
		action_progress.value = 100.0 * (1.0 - remaining / float(action.duration_s))
	else:
		action_progress.value = 0
	selected_action.tooltip_text = _student_activity_summary(selected_index)
	var max_focus = simulation.get_resource_max(selected_index, "focus")
	var max_stamina = simulation.get_resource_max(selected_index, "stamina")
	focus_label.text = "专注    %.1f / %.0f" % [student.focus, max_focus]
	stamina_label.text = "体力    %.1f / %.0f" % [student.stamina, max_stamina]
	focus_bar.max_value = max_focus
	focus_bar.value = student.focus
	stamina_bar.max_value = max_stamina
	stamina_bar.value = student.stamina
	knowledge_label.text = "语文 %.1f   数学 %.1f\n英语 %.1f   体育 %.1f" % [student.knowledge.chinese, student.knowledge.math, student.knowledge.english, student.knowledge.physical]
	var attributes: Dictionary = student.attributes
	attributes_label.text = "基础 专注力 %s · 自律性 %s\n健康 %s · 智力 %s · 待分配 %d" % [attributes.attention, attributes.discipline, attributes.health, attributes.intelligence, student.unspent_points]
	var round_finished: bool = simulation.is_round_finished()
	focus_button.disabled = round_finished
	rest_button.disabled = round_finished
	sleep_button.disabled = round_finished or not simulation.can_start_action(0, "sleep")
	while rendered_log_count < simulation.logs.size():
		var entry: Dictionary = simulation.logs[rendered_log_count]
		log_text.add_text("%s  %s  %s\n" % [_clock(entry.clock_seconds), entry.name, entry.message])
		rendered_log_count += 1
	footer_label.text = "专注 %.0f · 体力 %.0f" % [simulation.students[0].focus, simulation.students[0].stamina]
	footer_label.tooltip_text = "我的专注 %.1f / %.0f · 体力 %.1f / %.0f" % [simulation.students[0].focus, simulation.get_resource_max(0, "focus"), simulation.students[0].stamina, simulation.get_resource_max(0, "stamina")]
	_refresh_timetable()
	_refresh_interaction_interface()
	_refresh_student_context()
	_refresh_status_effects()
	_refresh_inventory_interface()
	_refresh_attribute_interface()
	_refresh_personal_action_interface()
	_refresh_pair_action_interface()
	_refresh_round_interface()
	room.refresh_state()


# 有效值由模拟器计算，状态名称、幅度与持续方式从实际实例及当前配表读取。
func _refresh_status_effects() -> void:
	if simulation == null or fatal_error:
		return
	var student: Dictionary = simulation.students[selected_index]
	var lines := PackedStringArray([
		"有效 专注力 %s · 自律性 %s" % [simulation.effective_attribute(selected_index, "attention"), simulation.effective_attribute(selected_index, "discipline")],
		"健康 %s · 智力 %s" % [simulation.effective_attribute(selected_index, "health"), simulation.effective_attribute(selected_index, "intelligence")],
	])
	if student.buffs.is_empty():
		lines.append("暂无生效状态")
	for instance in student.buffs:
		var definition: Dictionary = configuration.buffs[instance.buff_id]
		var lifetime: String = "随当前动作结束" if instance.expires_at == null else "剩余 " + _duration(float(instance.expires_at) - simulation.elapsed_s)
		lines.append("%s · %s" % [definition.name, lifetime])
		if definition.knowledge_redirect == "selected_subject":
			lines.append("知识转入：" + String(configuration.subjects[instance.selected_subject_id].name))
		var corrections := PackedStringArray()
		for field in [["focus_delta", "专注力"], ["discipline_delta", "自律性"], ["health_delta", "健康"], ["intelligence_delta", "智力"]]:
			var delta: float = definition[field[0]]
			if delta != 0.0:
				corrections.append("%s %s%s" % [field[1], "+" if delta > 0.0 else "", delta])
		if float(definition.knowledge_multiplier) != 1.0:
			corrections.append("知识倍率 ×%s" % definition.knowledge_multiplier)
		if not corrections.is_empty():
			lines.append(" · ".join(corrections))
		lines.append(String(definition.description))
	_update_readonly_text(status_effects_text, "\n".join(lines))


# 只遍历真实正数量物品；配表顺序决定显示顺序，查看不抽奖、不扣物品或改随机流。
func _refresh_inventory_interface() -> void:
	if simulation == null or fatal_error:
		return
	var student: Dictionary = simulation.students[selected_index]
	inventory_owner_label.text = "%s的背包" % student.name
	var entries := PackedStringArray()
	for definition in configuration.tables.items:
		if student.inventory.has(definition.id) and student.inventory[definition.id] > 0:
			entries.append("%s × %d\n%s" % [definition.name, student.inventory[definition.id], definition.description])
	_update_readonly_text(inventory_text, "暂无物品" if entries.is_empty() else "\n\n".join(entries))
	_sync_action_picker(inventory_action_picker, _inventory_action_ids())
	var reason: String = "当前没有已开放的自用物品"
	if inventory_action_picker.selected >= 0:
		var action_id: String = inventory_action_picker.get_item_metadata(inventory_action_picker.selected)
		reason = simulation.action_unavailable_reason(0, action_id)
		inventory_action_picker.tooltip_text = _personal_action_description(action_id) if selected_index == 0 else "只能使用自己的物品"
	if selected_index != 0:
		reason = "只能使用自己的物品"
	inventory_action_picker.disabled = selected_index != 0 or inventory_action_picker.item_count == 0
	inventory_use_button.disabled = not reason.is_empty()
	inventory_use_button.tooltip_text = "对自己使用选中的物品" if reason.is_empty() else reason
	inventory_use_reason.text = reason


# 内容未变时保留选择，倒计时更新时保留滚动位置，避免持续刷新把查看位置推回顶部。
func _update_readonly_text(control: RichTextLabel, content: String) -> void:
	if control.text == content:
		return
	var scroll_bar: VScrollBar = control.get_v_scroll_bar()
	var previous_scroll: float = scroll_bar.value
	control.text = content
	scroll_bar.value = previous_scroll


# 以真实动作场景统计在教室的人数。
func _count_in_classroom() -> int:
	return _count_at_location("classroom")


# 人数与当前镜头使用同一真实地点来源，不把切镜头当作整班移动。
func _count_at_location(location: String) -> int:
	var total = 0
	for index: int in simulation.students.size():
		if simulation.student_location(index) == location:
			total += 1
	return total


# 持续动作的名称统一来自配表，不在界面维护第二套名称映射。
func _action_name(student: Dictionary) -> String:
	if simulation.is_round_finished():
		return "本局已结束"
	var action: Dictionary = student.current_action
	return "等待活动" if action.is_empty() else String(configuration.actions[String(action.action_id)].name)


# 格式化一天内时间，不使用宿主时区覆盖玩家本地时钟。
func _clock(seconds: float) -> String:
	var total = int(seconds)
	return "%02d:%02d:%02d" % [total / 3600, (total % 3600) / 60, total % 60]


# 剩余时间向上显示到秒，显示归零不作为动作完成的触发条件。
func _duration(seconds: float) -> String:
	var total = int(ceil(seconds))
	return "%02d:%02d" % [total / 60, total % 60]


# 保存分别写入正式或开发存档；开发时间不会覆盖正式进度。
func _save_session(show_status: bool) -> bool:
	if simulation == null or fatal_error:
		return false
	var destination = DEBUG_SAVE_PATH if simulation.is_debug_time else SAVE_PATH
	if simulation.save_file(destination) != OK:
		_fail(simulation.error_message)
		return false
	if show_status:
		status_label.text = "已保存 " + _clock(simulation.clock_seconds)
	return true


# 配表导出后原地应用新费率，抽出的时长和已经发生的结果保持原值。
func _reload_configuration() -> void:
	var replacement = GameConfig.new()
	if replacement.load_file() != OK:
		_fail(replacement.error_message)
		return
	if simulation == null:
		configuration = replacement
		_start_session(true)
		# 初始化失败必须保留停止状态，不能继续显示配表更新成功。
		if fatal_error:
			return
	elif simulation.apply_config(replacement) != OK:
		_fail(simulation.error_message)
		return
	configuration = replacement
	config_modified_at = FileAccess.get_modified_time(CONFIG_PATH)
	fatal_error = false
	last_ticks = Time.get_ticks_usec()
	status_label.text = "配表已更新"
	_refresh_interface()


# 更多菜单集中保存之外的低频操作。
func _on_menu(id: int) -> void:
	match id:
		0:
			_reload_configuration()
		1:
			restart_dialog.popup_centered()
		2:
			debug_dialog.popup_centered()
		3:
			_initialize_desktop()
		4:
			_show_round_boards()


# 进入开发时钟前保存正式进度，然后建立独立的真实规则测试局。
func _enter_debug_morning() -> void:
	if simulation == null or fatal_error:
		return
	if not _save_session(false):
		return
	_start_session(false)
	if fatal_error:
		return
	if simulation.set_debug_time(1, 28800.0) != OK:
		_fail(simulation.error_message)
		return
	_refresh_interface()
	debug_dialog.hide()


# 开发工具只改变显式测试时钟，真实结算和随机动作仍由同一执行器完成。
func _advance_debug_time() -> void:
	_close_student_context()
	if simulation == null or fatal_error:
		return
	if not simulation.is_debug_time:
		error_dialog.dialog_text = "请先选择开发时钟，再推进时间。"
		error_dialog.popup_centered()
		return
	if not advance_input.text.is_valid_float() or float(advance_input.text) <= 0:
		error_dialog.dialog_text = "推进分钟必须为大于0的数字。"
		error_dialog.popup_centered()
		return
	if simulation.advance_for_test(float(advance_input.text) * 60.0) != OK:
		_fail(simulation.error_message)
		return
	last_ticks = Time.get_ticks_usec()
	_refresh_interface()


# 恢复正式存档时重新对齐电脑课表，关闭和测试期间不补收益。
func _return_to_computer_time() -> void:
	if simulation != null and not fatal_error:
		if not _save_session(false):
			return
	_start_session(true)
	debug_dialog.hide()


# 错误会停止结算并保留现场，用户可从菜单明确重新读取修正后的配置。
func _fail(message: String) -> void:
	fatal_error = true
	push_error(message)
	status_label.text = "运行已停止"
	error_dialog.dialog_text = message
	_queue_error(message)
