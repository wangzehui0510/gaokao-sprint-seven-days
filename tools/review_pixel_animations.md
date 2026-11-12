# PixelLab 动画检查工具

`review_pixel_animations.py` 只读取真实素材，生成客观指标和检查预览，不修改、对齐、补帧、缩放或修复源文件，也不会自动判定视觉验收通过。

## 运行

```powershell
& 'C:/Users/admin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/review_pixel_animations.py --manifest .artifacts/pixel_animation_qa/manifest.json --asset-root . --output-dir .artifacts/pixel_animation_qa/review
```

已用上述运行时的 Pillow 12.3.0 验证。默认中文字体为 `C:/Windows/Fonts/msyh.ttc`，可通过 `--font` 指定其他字体。`--scale` 默认 8，仅用于最近邻放大预览；`--columns` 默认 4，仅控制接触表排版。

## 清单契约

```json
{
  "schema_version": 1,
  "clips": [
    {
      "id": "A01_write_north",
      "label": "北向书写",
      "direction": "north",
      "frame_paths": [
        "assets/pixel/student01/poses/study_0.png",
        "assets/pixel/student01/poses/study_1.png"
      ],
      "duration_ms": 450,
      "reference_path": "assets/pixel/student01/poses/study_0.png",
      "canvas": [32, 48],
      "anchor": [16, 44],
      "loop": true,
      "review_status": "pending"
    }
  ]
}
```

- `id` 唯一，仅含英文字母、数字、下划线、连字符，作为输出子目录名。
- `label`、`direction`、`review_status` 为非空字符串，检查工具原样记录。`review_status` 不等于工具自动批准。
- `frame_paths` 为非空、按播放顺序排列的单帧图像路径数组。输入顺序不会排序或去重。
- `duration_ms` 为正整数，或与帧数相同的正整数数组，单位毫秒。
- `canvas` 为声明的 `[宽,高]`，必须是正整数。尺寸不符会记录指标与标记，不会修改源图。
- `anchor` 可省略或为 `null`；提供时必须为整数 `[x,y]`。工具不猜测锚点。
- `reference_path` 可省略或为 `null`；提供时记录参考图指标以及它与第一帧的差异。
- `loop` 必须是布尔值。`true` 导出无限循环 GIF；`false` 不写 GIF 循环扩展。
- 相对路径默认以清单所在目录为根；指定 `--asset-root` 后，以该目录为根。绝对路径直接使用。
- 缺少必填字段、无效路径、重复 `id`、错误类型、输出覆盖输入均显式报错。

## 输出和判断边界

每个 `<输出目录>/<id>/` 生成：

- `strip.png`：原尺寸透明横条，不重采样。各帧尺寸不同，放到最大宽高的格子左上角；`strip_frame_rects` 明确记录各源图的位置与原始宽高。
- `contact_sheet.png`：棋盘背景、整数最近邻放大的逐帧图，标注从 `#00` 开始的帧号及请求时长。
- `preview.gif`：同一放大倍率、棋盘背景的动图。GIF 只有有限调色板和 10 毫秒时间粒度；实际编码帧数、时长、循环信息均回读记录。连续相同帧可能被编码器合并，横条与接触表仍保留全部输入帧。
- `metrics.json`：该片段的尺寸、透明度分布、可见包围盒、锚点相对包围盒、颜色数、文件 SHA-256、透明度加权重心、相邻帧和首尾差异、边缘接触等指标。

总输出 `review.json` 汇总全部片段并记录清单摘要。包围盒的左上角包含、右下角不包含；逐像素差异忽略完全透明像素中不可见的 RGB，同时另记完整 RGBA 差异数量。不同尺寸的图像明确标为不可逐像素比较。

`review_flags` 仅列出值得检查的事实，例如空帧、尺寸不同、边缘接触、半透明像素、连续重复帧、首尾相同或 GIF 时长变化。边缘接触不能证明裁切，首尾相同也不能证明循环自然；人体结构、身份一致性、道具表达及循环节奏需要人工检查。`visual_approval` 始终为 `not_assessed_by_script`。
