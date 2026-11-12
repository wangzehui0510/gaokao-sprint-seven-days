# 动画交互审核页生成器

`build_animation_review.py` 读取真实动画清单，生成可直接离线打开的 `review.html` 和真实首帧总览 `overview.png`。不修改源图或清单，不自动批准素材，不补帧、不修图。页面审核状态直接使用清单的 `review_status`。

## 运行

```powershell
& 'C:/Users/admin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/build_animation_review.py --manifest assets/pixel/student01/animation_batches/2026-11-11/curated_manifest.json
```

默认在清单所在目录输出两个文件。相对帧路径也以清单目录为根；可用 `--asset-root` 明确指定其他素材根目录。隔离验证使用：

```powershell
& 'C:/Users/admin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/build_animation_review.py --manifest assets/pixel/student01/animation_batches/2026-11-11/raw_review_manifest.json --output-dir .artifacts/animation_review_test
```

依赖 Pillow 及同目录的 `review_pixel_animations.py` 输入校验函数。默认中文字体 `C:/Windows/Fonts/msyh.ttc`，可用 `--font` 指定；总览整数放大倍率用 `--overview-scale`，每行列数用 `--columns` 指定。

## 清单字段

沿用 `review_pixel_animations.md` 的 `schema_version=1`、`clips` 契约：`id`、`label`、`direction`、`frame_paths`、`duration_ms`、`canvas`、`loop`、`review_status` 必填，`anchor` 可空。所有输入帧必须为真实单帧 PNG。

- `label` 原样显示。中文名称应写在清单里，生成器不会根据英文 ID 猜测或自动翻译动画内容。
- `category` 可选，提供时原样作为分类。没有此字段时，ID 首字母为 A/B 则分为 A/B 类，其他 ID 明确显示“未分组”。
- `duration_ms` 可以是统一正整数毫秒数，也可以是与帧数相同的正整数数组。播放严格使用各帧实际声明时长。
- `notes` 可选，作为清单备注显示，不影响播放及审核状态。
- 帧尺寸与 `canvas` 不一致时，交互页明确警示并按真实尺寸绘制，不静默缩放修复。缺失文件、重复 ID、非法字段、非 PNG 输入明确报错。

## 交互检查

- A/B 分类与文字搜索；点击卡片选择动画。卡片显示真实首帧、标签、方向、帧数、循环与审核状态。
- 真实 Canvas 播放，PNG 全部作为 data URI 内嵌，无网络、服务器或相邻图片文件依赖。最近邻整数放大，可选 1/2/4/6/8 倍。
- 播放/暂停、从头重播、上一帧/下一帧、逐帧滑块、0.25/0.5/1/2/4 倍速度；可显示或隐藏清单声明的脚锚点。
- `loop=false` 播完停在最后一帧，从头重播仍为单次；`loop=true` 按清单循环。
- 空格播放/暂停，左右方向键逐帧，R 从头重播。输入框与下拉控件内不抢快捷键。
- 页面记录清单文件名、SHA-256 摘要、素材组数和总帧数；逐帧源路径、真实尺寸与时长可展开核查。

`overview.png` 依分类排列真实首帧，以原样标签（中文清单则为中文标签）、ID、帧数、方向、循环与审核状态标注，并记录总素材数和总帧数。总览不代替完整动画审核；动态检查请使用 HTML，避免 GIF 的调色板和时间粒度损失。

只有人工或上游审核流程可以改变清单里的验收结论。本工具输出始终标记 `visual_approval=not_assessed_by_script`。
