@tool
class_name AnimEnhancerTrackOps
extends RefCounted

## 原生动画数据操作层：只使用 Animation / AnimationPlayer 的公开 API。
## 所有修改都通过 undo_redo 的 do/undo 方法配对完成，与原生 _confirm_insert 保持一致。
##
## 兼容性说明（Godot 4.3）：
## - UndoRedo.add_do_method(callable)                —— 单 Callable 参数
## - EditorUndoRedoManager.add_do_method(obj, m, …)  —— 可变参数
## 因此统一通过 _add_do / _add_undo 适配。
##
## 历史归属（重要）：
## create_action 传入场景内节点作为 context，让 action 落到「当前场景」的 undo history，
## 否则 Resource 目标会被解析到 GLOBAL_HISTORY，与场景编辑混在一起且不会出现在场景撤销列表里。

const EPS_MIN := 0.0001
const EPS_MAX := 0.05
## RESET 动画的默认时长。原生 AnimationTrackEditor::_create_and_get_reset_animation()
## 用的是 ANIM_MIN_LENGTH(0.001)；Animation.new() 默认是 1.0，必须显式设置。
const RESET_LENGTH := 0.001


# ---------------------------------------------------------------- undo 适配层

static func _add_do(undo_redo: Object, target: Object, method: StringName, args: Array = []) -> void:
	if undo_redo is EditorUndoRedoManager:
		undo_redo.callv("add_do_method", [target, method] + args)
	else:
		undo_redo.call("add_do_method", Callable(target, method).bindv(args))


static func _add_undo(undo_redo: Object, target: Object, method: StringName, args: Array = []) -> void:
	if undo_redo is EditorUndoRedoManager:
		undo_redo.callv("add_undo_method", [target, method] + args)
	else:
		undo_redo.call("add_undo_method", Callable(target, method).bindv(args))


## 用场景内节点作为 context 建 action，保证 history 归属正确。
## 建完立刻 force_fixed_history()：Animation 资源（内置资源、空路径）与场景节点可能被解析到
## 不同 history（GLOBAL=0 / 场景=1），不锁定就会打印
## "UndoRedo history mismatch: expected 0, got 1"，并把同一次操作分散到不同撤销栈。
static func _create_action(undo_redo: Object, name: String, merge_mode: int, context: Object) -> void:
	if undo_redo is EditorUndoRedoManager:
		undo_redo.call("create_action", name, merge_mode, context)
		undo_redo.call("force_fixed_history")
	else:
		undo_redo.call("create_action", name, merge_mode)


# ---------------------------------------------------------------- 查询工具

## 时间容差：随动画步长推导，既容忍浮点误差，又不会覆盖相邻帧的关键帧。
static func time_epsilon(anim: Animation) -> float:
	if anim == null or anim.step <= 0.0:
		return EPS_MIN
	return clampf(anim.step * 0.5, EPS_MIN, EPS_MAX)


## 按 (轨道类型, 轨道路径) 查找轨道，不依赖显示名称。
static func find_track(anim: Animation, path: NodePath, track_type: int) -> int:
	if anim == null:
		return -1
	for i in anim.get_track_count():
		if anim.track_get_type(i) == track_type and anim.track_get_path(i) == path:
			return i
	return -1


## 只按路径查找（RESET 查重用：同一路径不应出现两条轨道）。
static func find_track_by_path(anim: Animation, path: NodePath) -> int:
	if anim == null:
		return -1
	for i in anim.get_track_count():
		if anim.track_get_path(i) == path:
			return i
	return -1


## 查找与 time 在容差内的关键帧索引。
static func find_key_at(anim: Animation, track: int, time: float) -> int:
	if anim == null or track < 0 or track >= anim.get_track_count():
		return -1
	var eps := time_epsilon(anim)
	for k in anim.track_get_key_count(track):
		if absf(anim.track_get_key_time(track, k) - time) <= eps:
			return k
	return -1


## 轨道路径必须以 AnimationPlayer.root_node 为基准，而不是以 AnimationPlayer 自身为基准。
static func build_path(player: AnimationPlayer, node: Node, subname: String) -> NodePath:
	var root: Node = player.get_node_or_null(player.root_node)
	if root == null or node == null:
		return NodePath()
	var rel: NodePath = root.get_path_to(node)
	if rel.is_empty():
		rel = NodePath(".")
	if subname.is_empty():
		return rel
	return NodePath(String(rel) + ":" + subname)


static func values_equal(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == b
	if typeof(a) != typeof(b):
		return false
	if a is float:
		return is_equal_approx(a, b)
	if a is Vector2 or a is Vector3 or a is Quaternion or a is Color:
		return a.is_equal_approx(b)
	return a == b


# ---------------------------------------------------------------- 主操作

## 写入一次属性关键帧（必要时创建轨道、必要时补全 RESET）。
## reset_value 为「属性被修改之前」的基础值；传 null 表示退化为当前值。
##
## 副作用约定：新建 RESET 时本函数会临时屏蔽 player 的信号，避免编辑器的
## animation_list_changed 联动把时间轴光标拨回 0（详见下方 commit_action 处注释）。
## 返回 { ok, noop, created_track, track, reset_created, message }
static func key_property(
	undo_redo: Object,
	player: AnimationPlayer,
	anim: Animation,
	node: Node,
	track_type: int,
	subname: String,
	time: float,
	value: Variant,
	create_reset: bool = true,
	reset_value: Variant = null
) -> Dictionary:
	var result := {
		"ok": false,
		"noop": false,
		"created_track": false,
		"track": -1,
		"reset_created": false,
		"message": "",
	}

	if undo_redo == null or player == null or anim == null or node == null:
		result.message = "参数不完整"
		return result
	if not player.is_inside_tree() or not node.is_inside_tree():
		result.message = "节点不在场景树中"
		return result

	var path := build_path(player, node, subname)
	if path.is_empty():
		result.message = "无法计算轨道路径（root_node 无效）"
		return result

	var is_value_track := track_type == Animation.TYPE_VALUE
	# 布尔属性（visible）必须用离散更新：线性插值会在 0.5 权重处抖动。
	var update_mode := Animation.UPDATE_DISCRETE if typeof(value) == TYPE_BOOL else Animation.UPDATE_CONTINUOUS
	var track := find_track(anim, path, track_type)
	var created_track := track < 0

	# 已有关键帧时的旧值，用于判断是否真的需要一次新的 undo 记录
	var old_key := -1
	var old_value: Variant = null
	var value_changed := true
	if not created_track:
		old_key = find_key_at(anim, track, time)
		if old_key >= 0:
			old_value = anim.track_get_key_value(track, old_key)
			value_changed = not values_equal(old_value, value)

	# RESET 补全判断：不看「是否新建轨道」，只要 RESET 里缺这条路径就补。
	# 这样用户手动删掉 RESET 轨道后，下次在任意动画里 K 帧会重新补上。
	var is_reset_anim := player.has_animation("RESET") and player.get_animation("RESET") == anim
	var existing_reset: Animation = player.get_animation("RESET") if player.has_animation("RESET") else null
	# 查重必须带轨道类型：Node3D 的 position / rotation / scale 三条轨道共用同一个节点路径，
	# 只按路径判断会让后两条被误认为「RESET 里已经有了」。
	var need_reset := create_reset and not is_reset_anim and (existing_reset == null or find_track(existing_reset, path, track_type) < 0)

	if not value_changed and not need_reset:
		result.ok = true
		result.noop = true
		result.track = track
		result.message = "值未变化"
		return result

	# 同一时间点的连续更新（拖动数值框）合并成一次 undo，避免撤销栈被刷屏；
	# 新建轨道/新增关键帧不参与合并，否则「撤销」会把建轨道和后续修改一起回退。
	var action_name := "自动K帧：%s%s" % [String(path), ("" if subname.is_empty() else ":" + subname)]
	var merge_mode := UndoRedo.MERGE_DISABLE
	if created_track:
		action_name = "自动K帧(新建)：%s%s" % [String(path), ("" if subname.is_empty() else ":" + subname)]
	elif old_key >= 0:
		merge_mode = UndoRedo.MERGE_ALL
	_create_action(undo_redo, action_name, merge_mode, player)

	if created_track:
		# do 方法按顺序执行，因此此刻的轨道数量就是新轨道的索引
		track = anim.get_track_count()
		_add_do(undo_redo, anim, "add_track", [track_type])
		_add_do(undo_redo, anim, "track_set_path", [track, path])
		if is_value_track:
			_add_do(undo_redo, anim, "value_track_set_update_mode", [track, update_mode])
		_add_do(undo_redo, anim, "track_insert_key", [track, time, value])
		_add_undo(undo_redo, anim, "remove_track", [track])
	elif old_key >= 0:
		# 同时间点：更新原关键帧，undo 恢复旧值
		_add_do(undo_redo, anim, "track_set_key_value", [track, old_key, value])
		_add_undo(undo_redo, anim, "track_set_key_value", [track, old_key, old_value])
	else:
		_add_do(undo_redo, anim, "track_insert_key", [track, time, value])
		_add_undo(undo_redo, anim, "track_remove_key_at_time", [track, time])

	# RESET 补全：绝不覆盖已有 RESET 值，且用「修改前」的基础值
	var reset_created := false
	if need_reset:
		var reset_anim := _ensure_reset_animation(player, undo_redo)
		if reset_anim != null and find_track(reset_anim, path, track_type) < 0:
			var ridx := reset_anim.get_track_count()
			var base: Variant = value if reset_value == null else reset_value
			_add_do(undo_redo, reset_anim, "add_track", [track_type])
			_add_do(undo_redo, reset_anim, "track_set_path", [ridx, path])
			if is_value_track:
				_add_do(undo_redo, reset_anim, "value_track_set_update_mode", [ridx, update_mode])
			_add_do(undo_redo, reset_anim, "track_insert_key", [ridx, 0.0, base])
			_add_undo(undo_redo, reset_anim, "remove_track", [ridx])
			reset_created = true

	# 创建 RESET 会改动 AnimationLibrary，AnimationMixer 随即发出 animation_list_changed；
	# Animation 面板是延迟监听它的：_update_player() → _animation_selected() → player.stop()
	# → current_animation_changed("") → frame->set_value(0) + track_editor->set_anim_pos(0)，
	# 把用户刚拖到的播放头拨回 0。这条链在写关键帧之后才跑，插件侧没有任何公开 API 能写回
	# 时间轴光标（AnimationTrackEditor 的方法没有绑定给脚本），所以只能在建 RESET 的这一瞬
	# 屏蔽 player 自身的信号，让这条联动链根本不启动。
	# 代价：面板的动画下拉列表要等下一次刷新才会出现 RESET（详见 docs/02 §12）。
	var suppress_signals := need_reset and existing_reset == null
	var was_blocked := player.is_blocking_signals()
	if suppress_signals:
		player.set_block_signals(true)
	undo_redo.call("commit_action")
	if suppress_signals:
		player.set_block_signals(was_blocked)

	result.ok = true
	result.created_track = created_track
	result.track = track
	result.reset_created = reset_created
	return result


## 取得 RESET 动画；不存在时创建，并登记可撤销的 add_animation。
static func _ensure_reset_animation(player: AnimationPlayer, undo_redo: Object) -> Animation:
	if player.has_animation("RESET"):
		var existing := player.get_animation("RESET")
		# 旧版本插件建的 RESET 没设长度，用到了 Animation 默认的 1s。顺手修正为 0.001s（可撤销）。
		if existing != null and is_equal_approx(existing.length, 1.0):
			_add_do(undo_redo, existing, "set_length", [RESET_LENGTH])
			_add_undo(undo_redo, existing, "set_length", [1.0])
		return existing

	var reset_anim := Animation.new()
	reset_anim.resource_name = "RESET"
	reset_anim.length = RESET_LENGTH

	var lib := player.get_animation_library("")
	if lib == null:
		lib = AnimationLibrary.new()
		_add_do(undo_redo, player, "add_animation_library", ["", lib])
		_add_undo(undo_redo, player, "remove_animation_library", [""])

	_add_do(undo_redo, lib, "add_animation", ["RESET", reset_anim])
	_add_undo(undo_redo, lib, "remove_animation", ["RESET"])
	return reset_anim
