@tool
class_name AnimEnhancerTrackMerge
extends Node

## 阶段 C：重复轨道合并。
##
## ## 为什么重复轨道必须处理
##
## 原生 Animation 面板的「Paste Tracks」把轨道**追加到末尾**：
## `int base_track = animation->get_track_count();` … `add_track(...)`
## （editor/animation_track_editor.cpp:6252 起）。粘贴到同一个动画里就产生
## 「同类型 + 同路径」的重复轨道。
##
## 而 Godot 的变换轨道**不是后者覆盖前者，而是累加**：
##   `t->loc += (loc - t->init_loc) * blend;`   （scene/animation/animation_mixer.cpp:1233）
##   旋转：`t->rot = t->rot * Quaternion().slerp(init_rot.inverse() * rot, blend)`（:1320，四元数相乘）
##   缩放：相乘
## 实测两条 (1,0,0) / (9,0,0) 的 POSITION_3D 轨道，播放后节点位置是 **(10,0,0)**。
## 也就是说粘贴一次，物体就会移动两倍距离 —— 这就是「粘贴后动画坏掉」的真正原因。
## TYPE_VALUE 轨道则是赋值语义（:1459 `t->value = value`），后者覆盖前者。
##
## ## 合并规则
##
## 1. 保留**索引最小**的那条（面板里位置不变，用户看到的行不跳）；
## 2. 把后面重复轨道的关键帧并进来，**同时间点保留原轨道的值**（不覆盖）；
## 3. 删掉重复轨道。
##
## ## 为什么执行体是这个 Node 本身，而不是内部类
##
## `EditorUndoRedoManager.add_do_method` 只接受 `(Object, method, ...)`，
## 内部包成 `Callable(obj, method)`（editor/editor_undo_redo_manager.cpp:156），
## 而 Callable 只保存 ObjectID、**不会给 RefCounted 增加引用计数**，
## 所以执行体必须是挂在树上的 Node，否则被回收后会变成失效调用。
## 同一个实例服务多次合并，用自增 id 区分各自的记录（见 `_ops`）。
##
## ## 撤销
##
## 恢复时用 `track_swap` 把追加到末尾的轨道换回原索引，保证撤销后顺序与原来一致。

const TrackOps := preload("res://addons/animation_enhancer/core/track_ops.gd")

## 可以安全合并的轨道类型。
## 刻意排除 TYPE_METHOD（同路径的两条方法轨道是两次独立调用）、
## TYPE_AUDIO（同路径是两路独立音频）、TYPE_BEZIER（依附于值轨道）、TYPE_ANIMATION。
const MERGEABLE_TYPES := [
	Animation.TYPE_VALUE,
	Animation.TYPE_POSITION_3D,
	Animation.TYPE_ROTATION_3D,
	Animation.TYPE_SCALE_3D,
	Animation.TYPE_BLEND_SHAPE,
]

## 合并 id -> {anim, records}
var _ops: Dictionary = {}
var _next_id := 0


# ---------------------------------------------------------------- 扫描（静态工具）

## 找出「同类型 + 同路径」的重复轨道。
## 返回 [{keep: 保留的轨道索引, dupe: 要删除的轨道索引}]，按 dupe **降序**排列
## —— 先删大索引，前面记录的小索引才不会失效。
static func find_groups(anim: Animation) -> Array:
	var out: Array = []
	if anim == null:
		return out

	var first: Dictionary = {}
	for i in anim.get_track_count():
		var t := anim.track_get_type(i)
		if not MERGEABLE_TYPES.has(t):
			continue
		var key := "%d|%s" % [t, String(anim.track_get_path(i))]
		if first.has(key):
			out.append({"keep": int(first[key]), "dupe": i})
		else:
			first[key] = i

	out.sort_custom(func(a, b): return int(a["dupe"]) > int(b["dupe"]))
	return out


## 抓取一条轨道的完整数据（类型、路径、插值设置、全部关键帧）。
static func snapshot(anim: Animation, idx: int) -> Dictionary:
	var keys: Array = []
	for k in anim.track_get_key_count(idx):
		keys.append({
			"time": anim.track_get_key_time(idx, k),
			"value": anim.track_get_key_value(idx, k),
			"transition": anim.track_get_key_transition(idx, k),
		})

	var snap := {
		"index": idx,
		"type": anim.track_get_type(idx),
		"path": String(anim.track_get_path(idx)),
		"interp": anim.track_get_interpolation_type(idx),
		"loop_wrap": anim.track_get_interpolation_loop_wrap(idx),
		"enabled": anim.track_is_enabled(idx),
		"keys": keys,
	}
	if snap["type"] == Animation.TYPE_VALUE:
		snap["update_mode"] = anim.value_track_get_update_mode(idx)
	if snap["type"] == Animation.TYPE_AUDIO:
		snap["use_blend"] = anim.audio_track_is_use_blend(idx)
	return snap


## 把 snapshot 的内容写进 idx（调用前该索引必须是一条刚 add_track 出来的空轨道）。
static func restore(anim: Animation, idx: int, snap: Dictionary) -> void:
	anim.track_set_path(idx, NodePath(String(snap["path"])))
	anim.track_set_interpolation_type(idx, int(snap["interp"]))
	anim.track_set_interpolation_loop_wrap(idx, bool(snap["loop_wrap"]))
	anim.track_set_enabled(idx, bool(snap["enabled"]))
	if int(snap["type"]) == Animation.TYPE_VALUE:
		anim.value_track_set_update_mode(idx, int(snap["update_mode"]))
	if int(snap["type"]) == Animation.TYPE_AUDIO:
		anim.audio_track_set_use_blend(idx, bool(snap["use_blend"]))
	for k in snap["keys"]:
		anim.track_insert_key(idx, float(k["time"]), k["value"], float(k["transition"]))


# ---------------------------------------------------------------- 合并入口

## 在当前动画上合并重复轨道。没有重复时不创建 action、返回 merged=0。
## context 用于确定 undo history 归属（一般传场景内的 AnimationPlayer）。
func merge(undo_redo: Object, anim: Animation, context: Object, label := "合并重复轨道") -> Dictionary:
	var result := {"merged": 0, "keys_added": 0}
	if undo_redo == null or anim == null:
		return result

	var groups := find_groups(anim)
	if groups.is_empty():
		return result

	_prune()

	var id := _next_id
	_next_id += 1
	_ops[id] = {"anim": anim, "records": []}

	TrackOps._create_action(undo_redo, label, UndoRedo.MERGE_DISABLE, context)
	TrackOps._add_do(undo_redo, self, "do_op", [id])
	TrackOps._add_undo(undo_redo, self, "undo_op", [id])
	undo_redo.call("commit_action")

	var added := 0
	for r in _ops[id]["records"]:
		added += (r["added"] as Array).size()

	result["merged"] = groups.size()
	result["keys_added"] = added
	return result


## 丢掉动画已经失效的记录，避免长时间编辑后无限增长。
func _prune() -> void:
	for id in _ops.keys():
		var a = _ops[id].get("anim")
		if a == null or not is_instance_valid(a):
			_ops.erase(id)


# ---------------------------------------------------------------- do / undo 执行体

func do_op(id: int) -> void:
	if not _ops.has(id):
		return
	var entry: Dictionary = _ops[id]
	var anim: Animation = entry["anim"]
	entry["records"] = []
	if not is_instance_valid(anim):
		return

	for g in find_groups(anim):
		var keep: int = int(g["keep"])
		var dupe: int = int(g["dupe"])
		var count := anim.get_track_count()
		if keep < 0 or dupe >= count or keep >= count:
			continue

		var snap := snapshot(anim, dupe)
		var keep_path := String(anim.track_get_path(keep))
		var keep_type := anim.track_get_type(keep)

		# 并入重复轨道独有的时间点；同时间点保留原轨道的值（不覆盖）
		var added: Array = []
		for k in snap["keys"]:
			var t: float = float(k["time"])
			if TrackOps.find_key_at(anim, keep, t) >= 0:
				continue
			anim.track_insert_key(keep, t, k["value"], float(k["transition"]))
			added.append(t)

		anim.remove_track(dupe)
		entry["records"].append({
			"snap": snap,
			"added": added,
			"keep_path": keep_path,
			"keep_type": keep_type,
		})


func undo_op(id: int) -> void:
	if not _ops.has(id):
		return
	var entry: Dictionary = _ops[id]
	var anim: Animation = entry["anim"]
	if not is_instance_valid(anim):
		return

	var records: Array = entry["records"]
	# 与 do 相反的顺序恢复：先恢复后删的轨道，索引才对得上
	for i in range(records.size() - 1, -1, -1):
		var r: Dictionary = records[i]

		# 1) 把并进去的关键帧撤掉（只撤真正加进去的那些时间点）
		var keep := TrackOps.find_track(anim, NodePath(String(r["keep_path"])), int(r["keep_type"]))
		if keep >= 0:
			for t in r["added"]:
				var ki := TrackOps.find_key_at(anim, keep, float(t))
				if ki >= 0:
					anim.track_remove_key(keep, ki)

		# 2) 重建被删掉的轨道：追加到末尾 → 填内容 → 换回原索引
		var snap: Dictionary = r["snap"]
		var idx := anim.add_track(int(snap["type"]))
		restore(anim, idx, snap)
		var orig: int = int(snap["index"])
		if idx != orig and orig >= 0 and orig < anim.get_track_count():
			anim.track_swap(idx, orig)
