@tool
extends RefCounted

## 自动 K 帧开关的「按场景记忆」策略。
##
## 做成纯数据模块（不碰编辑器 API）的原因：这条策略最容易出错的地方是状态机本身
## ——记住 / 恢复 / 遗忘三者的顺序，而不是取场景标识。抽出来后可以在 headless
## 下用普通单元测试跑全部分支，不必依赖 GUI 切标签页。
##
## 规则：
## 1. 每个场景各自记住自己的开关；
## 2. 切到某场景时恢复它的记忆，没有记忆就回到默认 OFF；
## 3. 场景被关闭后忘掉它的记忆，重新打开回到 OFF。

## 没有记忆时的默认状态。
const DEFAULT_ENABLED := false

## 场景标识 -> 该场景的自动 K 帧开关
var states: Dictionary = {}
## 当前所在场景的标识（"" 表示没有打开任何场景）
var current_key := ""


## 场景标识：优先用文件路径（同一场景重开也能记住），未保存场景用实例 id。
func key_for(root: Node) -> String:
	if root == null:
		return ""
	var path := root.scene_file_path
	if not path.is_empty():
		return path
	return "unsaved:%d" % root.get_instance_id()


## 切到 new_key，返回该场景应采用的开关状态。
## 同一场景重复调用是幂等的（不会把当前状态写成"旧场景的记忆"）。
func enter(new_key: String, current_enabled: bool) -> bool:
	if new_key == current_key:
		return current_enabled
	# 先把旧场景的开关存下来；没有打开场景时（""）不存
	if not current_key.is_empty():
		states[current_key] = current_enabled
	current_key = new_key
	return bool(states.get(new_key, DEFAULT_ENABLED))


## 忘掉已关闭场景的记忆。未保存场景没有文件路径可比对，保留。
func prune(open_scenes: PackedStringArray) -> void:
	for k in states.keys():
		var ks := String(k)
		if ks.begins_with("unsaved:"):
			continue
		if not open_scenes.has(ks):
			states.erase(k)
