# Animation Enhancer（Godot 4.3）

只增强原生 Animation 面板的编辑体验，**不替换面板、不引入自定义动画运行时、不改引擎源码**。
所有动画数据仍然是原生 `Animation` 资源。

当前版本：**0.3.1-prototype（P0 自动 K 帧 + 阶段 C 轨道合并 + 阶段 D 筛选缓解）**

---

## 已实现（P0）

- 在 **Inspector** 修改下列属性时自动写入关键帧：
  - 变换：`position` / `rotation` / `scale`
  - CanvasItem 开关属性：`visible` / `modulate` / `self_modulate` / `z_index`
	（`Node3D` 只有 `visible`；`Node2D` / `Control` 四个都支持）
- 在 **2D / 3D 视口**用 gizmo 拖动、旋转、缩放选中节点，**松开鼠标**时自动写入关键帧。
- 轨道不存在时自动创建，且使用正确的原生轨道类型：
  - `Node3D` 变换 → `POSITION_3D` / `ROTATION_3D` / `SCALE_3D`
  - `Node2D` 变换、以及所有开关属性 → `VALUE`（路径带 `:position` / `:visible` 等子名）
  - `visible` 这类布尔属性用 `UPDATE_DISCRETE`（离散更新），避免线性插值在中间权重处抖动
- 同一时间点重复修改 → 更新原关键帧，不产生重复帧。
- 不同时间点修改 → 新增关键帧。
- **停手才写**：数值框拖动 / 滚动条拉动时不会每步写一帧，而是等最后一次修改后 `settle_delay`（默认 0.3s）再写一次，
  撤销栈里只留一条 `自动K帧：…`。
- `RESET` 轨道自动补全（`0s`），且记录的是**属性被修改之前**的值；**已有 RESET 值绝不覆盖**。
  - RESET 里缺这条路径就补，所以**手动删掉 RESET 轨道后再 K 帧会自动补回**（按路径查重，不会重复创建）。
- 所有修改都进入 `EditorUndoRedoManager`，可正常撤销 / 重做。
  - 撤销顺序：先回退关键帧，再回退属性值本身。
  - 同一时间点的连续修改合并为一次撤销。
- 主工具栏提供 `自动K帧 ON/OFF` 开关。
- **安全默认 + 按场景记忆**：编辑器启动时开关为 **OFF**；之后**每个场景各自记住自己的开关状态**，
  在场景标签页之间来回切换不会互相影响；**关闭某个场景会忘掉它的状态**，重新打开回到 OFF。

## 已实现（阶段 C）：重复轨道自动合并

原生「Paste Tracks」会把轨道**追加**到动画末尾且不做任何重复检测（`animation_track_editor.cpp:6252`）。
而 Godot 的变换轨道是**累加**的（`animation_mixer.cpp:1233`），所以粘贴一次物体会移动两倍 ——
这才是「粘贴后动画坏掉」的真正原因。插件会在粘贴后自动合并：

- 触发：**任何**提交导致当前动画的轨道数变多，且出现 `(类型, 路径)` 重复轨道；
- 合并：保留索引最小的那条 → 并入重复轨道**独有**的时间点 → 同时间点保留原轨道的值 → 删除重复轨道；
- 整次合并是**一条 undo action**，撤销后轨道数量、内容、顺序完全还原（用 `track_swap` 换回原索引）；
- 撤销/重做**不会**触发重新合并，所以撤销不会被立刻吃掉；
- 不合并 `TYPE_METHOD`（同路径是两次独立调用）、`TYPE_AUDIO`、`TYPE_BEZIER`。

## 阶段 D（可选缓解）：筛选下点击关键帧时间轴变空

**这不是「已修复」，是一个默认关闭的取舍开关，请先读完再决定要不要开。**

根因在引擎：点击关键帧会把 `AnimationTrackKeyEdit`（一个纯 `Object`）推进 Inspector，
`EditorNode::_edit_current()` 为此清空场景树选中 → `EditorSelection.selection_changed`
→ 原生 `_update_tracks()` 在筛选开启时把所有轨道跳过 → 时间轴变空。

插件侧唯一的入口是 `EditorSelection`。把节点加回去确实能让轨道回来，但
`SceneTreeDock::_selection_changed()` 会顺带 `push_item(node)`，**Inspector 必然从关键帧编辑器切回节点属性**
（已实测确认，并写成断言）。而 `EditorInspector.edit()` 没有开放给脚本，
`EditorInterface.inspect_object()` 又会再次清空选中形成死循环，所以补救不了。

因此提供工具栏开关 `保持选中 OFF/ON`：

| 状态 | 点关键帧后 |
|---|---|
| `OFF`（默认） | 与原生完全一致：时间轴变空 |
| `ON` | 时间轴保持可见；**代价**是 Inspector 切回节点属性 |

真正两全的修法只有改引擎一行（见 `docs/02` §11.6）。上游 4.4 / 4.5 仍未修复此行为。

## 未实现 / 不由本插件负责

| 项目 | 状态 | 原因 |
|---|---|---|
| 骨骼工具（Skeleton3D pose）自动 K 帧 | 不支持 | `Skeleton3D` 骨骼 pose 走 `insert_bone_key` 那条私有路径，公开 API 拿不到 |
| 节点筛选状态彻底修复 | 做不到（插件侧） | 根因在 `EditorNode::_edit_current()`；插件只能提供有代价的缓解 |

视口 gizmo 的 K 帧不是调用 `AnimationTrackEditor::insert_transform_key()`（那个类没注册进 ClassDB，脚本拿不到），
而是监听 `EditorUndoRedoManager.history_changed`：原生在**松开鼠标**时才 `create_action("Translate"/"Rotate"/"Scale")`
并提交，插件在这个事件里对比选中节点变换与快照，有差异才写帧。

详见 `docs/01-技术可行性调查报告.md`。

---

## 安装

1. 把 `addons/animation_enhancer/` 复制到你的 Godot 4.3 项目。
2. 打开项目 → **项目 → 项目设置 → 插件** → 启用 **Animation Enhancer**。
3. 主工具栏出现 `自动K帧 ON` 按钮即为加载成功。

## 使用

1. 场景中放一个 `AnimationPlayer`，新建并选中一个动画。
2. 把时间轴拖到目标时间。
3. 点开工具栏的 `自动K帧 OFF` 变成 `ON`（开关状态按场景分别记住，切回该场景会自动恢复）。
4. 选中目标节点，用下面任意方式改属性：
   - Inspector 里改 Position / Rotation / Scale / Visible / Modulate / Self Modulate / Z Index；
   - 在 2D / 3D 视口用 gizmo 拖动、旋转、缩放。
5. 轨道与关键帧会自动出现在原生 Animation 面板中，`RESET` 自动补全。

## 已知限制

- 视口 gizmo 的 K 帧依赖「原生把这次拖拽提交为一个 undo action」，所以：
  - 只对**当前选中**的节点生效；
  - 拖拽中途不写帧，**松开鼠标**后才写；
  - 如果某个自定义工具的拖拽没有走 `EditorUndoRedoManager`，本插件无法感知。
- **骨骼工具**（Skeleton3D pose）不在范围内。
- 播放中（`is_playing()` 为真）会跳过写入，避免把动画中间值当作基础值。
- **RESET 的「修改前的值」来自快照**：插件在选中节点时、以及每次写入后记录属性值。
  选中节点后立刻拖动 gizmo，快照仍是拖拽前的值，结果正确；但如果插件是在节点已被动画/工具改动后才首次看到它，
  会退化为用当前值并提示 `（已补 RESET，基础值取自当前值）`。
- **拖拽时间轴预览**时 `is_playing()` 仍为 false，此时节点属性已被动画改写；若在这个状态下首次创建轨道，
  RESET 可能记录到动画中间值。建议在 `0s` 或未预览状态下首次打帧。
- 只处理 `position` / `rotation` / `scale` / `visible` / `modulate` / `self_modulate` / `z_index` 这 7 个属性；
  其他属性（如 `text`、`material`）不会自动 K 帧。
- **补建 RESET 时不会刷新面板的动画下拉列表**：新建 RESET 会改动 `AnimationLibrary`，
  面板监听到后会把时间轴光标拨回 0（`_update_player() → _animation_selected() → player.stop()`），
  所以插件在提交这一瞬屏蔽了 `player` 的信号。代价是 RESET 要等下一次面板刷新
  （新建/复制/删除动画、切场景恢复面板状态等）才出现在下拉列表里，但动画数据本身已就绪。
  详见 `docs/02-原型测试记录.md` §12。
- 场景切换检测依赖 `EditorSelection.selection_changed` + 每次编辑前的场景根核对，不做轮询；
  如果某个操作既不改选中、也不产生 undo action，就不会触发检测（正常编辑流程都会经过）。
- **多选节点**在 Inspector 里编辑属性时不会写关键帧（原生 `MultiNodeEdit` 路径不经过 undo commit，被主动跳过）；
  但多选后在视口拖拽会逐节点写入。
- 停手判定为 `settle_delay`（默认 0.3s）。编辑器保存 / 运行前会调用 `_apply_changes()` 立即补写。
- 时间容差为 `clampf(anim.step * 0.5, 0.0001, 0.05)` 秒。
- **重复轨道合并**（阶段 C）的边界：
  - 只在「当前正在编辑的那个动画」上生效（面板选中的动画），不会扫描整个动画库；
  - 只在**轨道数增加**的那次提交上触发。打开一个本来就带重复轨道的旧场景不会被自动清理，
	需要再粘贴一次（或手动加一条轨道）才会触发；
  - 同时间点冲突时**保留原轨道的值**，粘贴进来的值被丢弃 —— 因为变换轨道是累加的，
	合并的目标是恢复「只有一条轨道时」的那条曲线；
  - 合并会连插值方式、循环包裹、启用状态一并沿用**被保留的那条**轨道；
  - 撤销/重做不触发重新合并；但重做一次粘贴后，重复轨道会保持未合并状态（需要下一次提交才合并）；
  - 合并记录保存在插件节点上，插件被禁用后这些记录失效（此时场景的 undo 历史也已不可用）。

## 自测

数据层（无需编辑器）：

```bash
godot --headless --path <project> --script res://tests/test_track_ops.gd
```

期望输出 `---- 结果: 100 通过, 0 失败 ----`。

编辑器内集成自测（真实 `EditorUndoRedoManager`，复刻 Inspector 与视口 gizmo 两条链路）：

```bash
godot --headless --editor --path <project> --anim-enhancer-selftest
```

期望输出 `---- 编辑器集成自测: 51 通过, 0 失败 ----`。

`tests/editor_selftest` 这个插件**不带 `--anim-enhancer-selftest` 参数时是空操作**，可以常驻启用；
带参数启动会自动跑完用例并退出编辑器。用例中途报错时会由 60s 看门狗强制退出（退出码 2），避免进程挂死。
