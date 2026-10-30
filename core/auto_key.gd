@tool
extends Node

## P0 自动 K 帧：事件驱动，无轮询。
##
## 三个事件入口：
## 1. EditorInspector.property_edited —— Inspector 改属性（含数值框拖动）。
## 2. EditorUndoRedoManager.history_changed —— 任何 action 提交后。视口 gizmo 拖动/缩放在
##    松开鼠标时才 commit（Node3DEditorViewport::commit_transform，n3d.cpp:4770），
##    因此这里能拿到「拖拽结束」这一个时机；此时对比节点变换与快照，有差异才 K 帧。
## 3. EditorUndoRedoManager.version_changed —— 撤销/重做后刷新快照，避免过期快照造成误判。
##
## 两条重要时序约束（源码依据见 docs/02）：
## - property_edited 是在 Inspector 自己的 undo action 提交过程中发出的
##   （EditorInspector::_edit_set → add_do_method(this,"emit_signal",...) → commit_action），
##   此刻调用 create_action 会被判为 nested action 并顶掉 Inspector 的 action，
##   所以这里只「记录 + 延迟写入」，绝不在信号里写动画数据。
## - 写入统一延迟 settle_delay 秒：数值框拖动/滚动条拉动时每步都会触发事件，
##   立刻写会让撤销栈被刷屏，并且插在 Inspector 的 action 之间会打断它自己的 MERGE_ENDS 合并。
##   等到用户停手再写一次，撤销栈里就只剩一条「自动K帧」。
##
## 明确边界：骨骼工具的自动 K 帧不在本模块范围内。

signal status_changed(text: String, ok: bool)

const Context := preload("res://addons/animation_enhancer/core/anim_context.gd")
const TrackOps := preload("res://addons/animation_enhancer/core/track_ops.gd")

## 变换属性（Node3D 用 3D 轨道，Node2D 用带子名的值轨道）
const TRANSFORM_PROPS := ["position", "rotation", "scale"]
## CanvasItem 上的开关类属性：一律用带子名的值轨道（Sprite:visible 等）
const EXTRA_PROPS := ["visible", "modulate", "self_modulate", "z_index"]
const SUPPORTED_PROPS := ["position", "rotation", "scale", "visible", "modulate", "self_modulate", "z_index"]

var enabled := true
## 停手多久后才写入（秒）。数值框拖动/滚动条拉动期间会不断重置。
var settle_delay := 0.3
## 打开后会把每一次跳过原因打印到输出面板，便于定位「为什么没 K 帧」。
var verbose := false
## 每次事件入口先调用它（插件用它检测场景是否已经切换，必要时把 enabled 关掉）。
var before_event: Callable = Callable()

var _editor_interface: EditorInterface
var _undo_redo: Object
var _inspector: EditorInspector
var _selection: EditorSelection
var _busy := false
var _pending: Array[Dictionary] = []
## "instance_id|prop" -> 写入轨道时的值（即属性被修改前的状态）
var _base: Dictionary = {}
var _last_status := ""
var _timer: Timer


func setup(editor_interface: EditorInterface, undo_redo: Object) -> void:
	_editor_interface = editor_interface
	_undo_redo = undo_redo
	_inspector = editor_interface.get_inspector()
	_selection = editor_interface.get_selection()

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_flush)
	add_child(_timer)

	if _inspector == null:
		status_changed.emit("无法获取 Inspector，自动 K 帧不可用", false)
		return

	if not _inspector.property_edited.is_connected(_on_property_edited):
		_inspector.property_edited.connect(_on_property_edited)

	if _selection != null and not _selection.selection_changed.is_connected(_on_selection_changed):
		_selection.selection_changed.connect(_on_selection_changed)

	if _undo_redo is EditorUndoRedoManager:
		var urm := _undo_redo as EditorUndoRedoManager
		if not urm.history_changed.is_connected(_on_history_changed):
			urm.history_changed.connect(_on_history_changed)
		if not urm.version_changed.is_connected(_on_version_changed):
			urm.version_changed.connect(_on_version_changed)

	_snapshot_selection()
	status_changed.emit("已就绪：Inspector + 视口自动 K 帧待命", true)


func cleanup() -> void:
	if _inspector != null and _inspector.property_edited.is_connected(_on_property_edited):
		_inspector.property_edited.disconnect(_on_property_edited)
	if _selection != null and _selection.selection_changed.is_connected(_on_selection_changed):
		_selection.selection_changed.disconnect(_on_selection_changed)
	if _undo_redo is EditorUndoRedoManager:
		var urm := _undo_redo as EditorUndoRedoManager
		if urm.history_changed.is_connected(_on_history_changed):
			urm.history_changed.disconnect(_on_history_changed)
		if urm.version_changed.is_connected(_on_version_changed):
			urm.version_changed.disconnect(_on_version_changed)
	if _timer != null:
		_timer.stop()
	_pending.clear()
	_base.clear()


## 切换 / 关闭场景时清空上下文（旧场景的节点已经失效）。
func reset_context() -> void:
	if _timer != null:
		_timer.stop()
	_pending.clear()
	_base.clear()


## 编辑器要保存 / 运行 / 切走时立刻落盘，避免待写入的帧被丢掉。
func flush_now() -> void:
	if _pending.is_empty():
		return
	_flush()


# ---------------------------------------------------------------- 事件入口（只记录，不写入）

func _on_property_edited(property: StringName) -> void:
	if _inspector == null or _busy:
		return
	if before_event.is_valid():
		before_event.call()
	if not enabled:
		return

	# 原生把 emit_signal("property_edited") 同时登记为该 action 的 do 与 undo 方法
	# （editor_inspector.cpp:3906-3907），所以「撤销 / 重做 Inspector 的属性修改」也会触发本回调。
	# 正常编辑发生在 commit 期间（is_committing_action() == true），撤销/重做走 undo()/redo()。
	if _undo_redo is EditorUndoRedoManager and not (_undo_redo as EditorUndoRedoManager).is_committing_action():
		if verbose:
			print("[AnimationEnhancer] 跳过 %s：撤销/重做过程中的属性变更" % property)
		return

	var obj := _inspector.get_edited_object()
	if not (obj is Node):
		return
	var node := obj as Node
	if not node.is_inside_tree():
		return

	# 向量属性展开后是 "position:x" 形式，取基名
	var prop := String(property).get_slice(":", 0)
	if not _supported(node, prop):
		return

	var value: Variant = _track_value(node, prop)
	if value == null:
		return
	_enqueue(node, prop, value)


## 任何 action 提交后触发。视口 gizmo 的平移/旋转/缩放在松开鼠标时才走到这里
## （Node3DEditorViewport::commit_transform → create_action("Translate"/"Rotate"/"Scale") → commit_action）。
func _on_history_changed() -> void:
	if _busy or _selection == null:
		return
	if before_event.is_valid():
		before_event.call()
	if not enabled:
		return
	_capture_selection_changes(true)


func _on_version_changed() -> void:
	# 撤销 / 重做后节点值会变，快照必须跟着刷新，否则下一次 history_changed 会误判成「用户改了变换」。
	_snapshot_selection()


## 读刚提交的那个 action 的名字，把捕获范围限定到单一属性。
## 3D 视口 gizmo 用 TTRC("Translate"/"Rotate"/"Scale")（宏展开就是原文，不随界面语言变化，见 core/string/ustring.h:562），
## 所以可以安全匹配。这样「旋转」不会因为枢轴/浮点漂移顺带把 position 也 K 一帧。
##
## 关键：action 落在哪个 history 取决于 create_action 的 context，而不是「当前编辑场景」。
## Node3DEditorViewport::commit_transform 的 context 来自选中的节点，所以必须优先探测
## **节点自身**所属的 history；探测场景根会在「节点不在该场景 history 里」时读错，
## 实测编辑器里开着一个 Node2D 场景（history=1）而 gizmo 动作落到 GLOBAL(0)，
## 只探测 history 1 会永远读到空串，限制形同不存在。
func _action_prop_hint(node: Node) -> String:
	if not (_undo_redo is EditorUndoRedoManager):
		return ""
	for hid in _candidate_history_ids(node):
		match _history_action_name(hid):
			"Translate":
				return "position"
			"Rotate":
				return "rotation"
			"Scale":
				return "scale"
	return ""


## 可能承载本次 action 的 history：节点自身 → 当前编辑场景 → GLOBAL(0)。
## get_object_history_id 对未登记的节点返回负数（INVALID_HISTORY），必须过滤掉，
## 否则 get_history_undo_redo 会打出引擎错误。
func _candidate_history_ids(node: Node) -> Array:
	var urm := _undo_redo as EditorUndoRedoManager
	var raw: Array = []
	if node != null and is_instance_valid(node):
		raw.append(urm.get_object_history_id(node))
	if _editor_interface != null:
		var root := _editor_interface.get_edited_scene_root()
		if root != null:
			raw.append(urm.get_object_history_id(root))
	raw.append(0)

	var out: Array = []
	for id in raw:
		var hid := int(id)
		if hid >= 0 and not out.has(hid):
			out.append(hid)
	return out


func _history_action_name(hid: int) -> String:
	var urm := _undo_redo as EditorUndoRedoManager
	var urd: UndoRedo = urm.get_history_undo_redo(hid)
	if urd == null:
		return ""
	return String(urd.get_current_action_name())


# ---------------------------------------------------------------- 采集

## 对比选中节点的当前属性与快照，把有差异的属性入队。事件驱动，无轮询。
## restrict_to_action 为 true 时，按刚提交的 action 名把检查范围收窄到单一属性
## （视口 gizmo 的一次拖拽只该动一个属性；匹配不到 action 名时不收窄，保持旧行为）。
func _capture_selection_changes(restrict_to_action: bool = false) -> void:
	for node in _selection.get_selected_nodes():
		var only_prop := ""
		if restrict_to_action:
			only_prop = _action_prop_hint(node)
		for prop in SUPPORTED_PROPS:
			if not only_prop.is_empty() and prop != only_prop:
				continue
			if not _supported(node, prop):
				continue
			var value: Variant = _track_value(node, prop)
			if value == null:
				continue
			var key := _base_key(node, prop)
			if not _base.has(key):
				# 第一次见到这个属性：只建立快照，不认为是修改
				_base[key] = value
				continue
			if TrackOps.values_equal(_base[key], value):
				continue
			_enqueue(node, prop, value)


func _enqueue(node: Node, prop: String, value: Variant) -> void:
	var ctx := Context.resolve(_editor_interface, node)
	var item := {
		"node": node,
		"prop": prop,
		"value": value,
		"anim": String(ctx.anim_name),
		"time": float(ctx.time),
	}

	for i in _pending.size():
		var p := _pending[i]
		if p.get("node") == node and String(p.get("prop")) == prop:
			_pending[i] = item
			_restart_timer()
			return

	_pending.append(item)
	_restart_timer()


func _restart_timer() -> void:
	if _timer == null:
		return
	_timer.start(settle_delay)


# ---------------------------------------------------------------- 写入

func _flush() -> void:
	if _timer != null:
		_timer.stop()
	if not enabled:
		_pending.clear()
		return
	if _busy:
		_restart_timer()
		return

	var batch := _pending
	_pending = []
	for item in batch:
		_write(item)
	_refresh_unkeyed(batch)


## 把本批里「没有写入」的属性快照对齐到当前值。
## 场景：旋转时被 action 名限制掉、没有 K 帧的 position。若不同步快照，它下次会被
## 当成「用户刚改动过」而误 K 一帧，且 RESET 会取到更早的过期值。
## 必须排除本批真正写入的属性 —— _write 已经把旧快照当作 RESET 基础值消费掉了。
func _refresh_unkeyed(batch: Array) -> void:
	if batch.is_empty():
		return
	var touched: Array = []
	var written: Dictionary = {}
	for item in batch:
		var n = item.get("node")
		if n == null or not is_instance_valid(n):
			continue
		written[_base_key(n, String(item.get("prop")))] = true
		if not touched.has(n):
			touched.append(n)

	for n in touched:
		if not n.is_inside_tree():
			continue
		for prop in SUPPORTED_PROPS:
			var key := _base_key(n, prop)
			if written.has(key) or not _supported(n, prop):
				continue
			var value: Variant = _track_value(n, prop)
			if value != null:
				_base[key] = value


func _write(item: Dictionary) -> void:
	var node: Node = item.get("node")
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return

	var prop := String(item.get("prop"))
	if not _supported(node, prop):
		return

	# 事件之后值又被改回去了（撤销 / 动画重新应用 / 又改了一次）→ 丢弃，不写过期值
	var current: Variant = _track_value(node, prop)
	if current == null or not TrackOps.values_equal(current, item.get("value")):
		if verbose:
			print("[AnimationEnhancer] 丢弃 %s.%s：等待期间值已变化" % [node.name, prop])
		return

	var ctx := Context.resolve(_editor_interface, node)
	if ctx.player == null or ctx.animation == null:
		_report("跳过：%s" % ctx.message, false)
		return

	if String(ctx.anim_name) != String(item.get("anim")):
		_report("跳过：编辑过程中切换了动画，未写入 %s.%s" % [node.name, prop], false)
		return

	var player: AnimationPlayer = ctx.player
	if player.is_playing():
		# 播放中节点值来自动画本身，写入会把动画中间值当成基础值
		_report("跳过：AnimationPlayer 正在播放，避免写入动画中间值", false)
		return

	var track_type := -1
	var subname := ""
	if node is Node3D and Context.TRACK_3D.has(prop):
		track_type = Context.TRACK_3D[prop]
	elif EXTRA_PROPS.has(prop):
		# visible / modulate / self_modulate / z_index → 值轨道，路径带子名
		track_type = Animation.TYPE_VALUE
		subname = prop
	elif node is Node2D and Context.TRACK_2D.has(prop):
		track_type = Animation.TYPE_VALUE
		subname = prop
	else:
		return

	var value: Variant = item.get("value")
	var time: float = item.get("time")

	# RESET 用「修改前」的值：优先取快照，没有快照时退化为当前值并提示
	var key := _base_key(node, prop)
	var has_base := _base.has(key)
	var base_value: Variant = _base[key] if has_base else value

	_busy = true
	var res: Dictionary = TrackOps.key_property(
		_undo_redo, player, ctx.animation, node, track_type, subname, time, value, true, base_value
	)
	_busy = false

	# 无论是否写入，都把快照更新为当前值，作为下一次修改的「修改前」状态
	_base[key] = value

	if not res.get("ok", false):
		_report("失败：%s" % res.get("message", "未知错误"), false)
		return
	if res.get("noop", false):
		return

	var msg := "已写入 %s.%s @ %.3fs" % [node.name, prop, time]
	if res.get("created_track", false):
		msg += "（新建轨道）"
	if res.get("reset_created", false):
		msg += "（已补 RESET）" if has_base else "（已补 RESET，基础值取自当前值）"
	_report(msg, true)


# ---------------------------------------------------------------- 基础值快照

func _snapshot_selection() -> void:
	if _selection == null:
		return
	for node in _selection.get_selected_nodes():
		_snapshot_node(node)


func _snapshot_node(node: Node) -> void:
	for prop in SUPPORTED_PROPS:
		if _supported(node, prop):
			_base[_base_key(node, prop)] = _track_value(node, prop)


func _base_key(node: Node, prop: String) -> String:
	return "%d|%s" % [node.get_instance_id(), prop]


func _supported(node: Node, prop: String) -> bool:
	if node is Node3D:
		# Node3D 没有 modulate / self_modulate / z_index，只有 visible
		return Context.TRACK_3D.has(prop) or prop == "visible"
	if node is CanvasItem:
		# Node2D / Control 都是 CanvasItem：四个开关属性都支持
		if node is Node2D and Context.TRACK_2D.has(prop):
			return true
		return EXTRA_PROPS.has(prop)
	return false


## 取「写入轨道时使用的值」：TYPE_ROTATION_3D 轨道只接受 Quaternion，写 Vector3 会被引擎拒绝。
func _track_value(node: Node, prop: String) -> Variant:
	if node is Node3D and prop == "rotation":
		return (node as Node3D).transform.basis.get_rotation_quaternion()
	return node.get(prop)


func _on_selection_changed() -> void:
	_snapshot_selection()


## 相同提示不重复打印（连续编辑时避免刷屏）。
func _report(text: String, ok: bool) -> void:
	if text == _last_status:
		return
	_last_status = text
	status_changed.emit(text, ok)
