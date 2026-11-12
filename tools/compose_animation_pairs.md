# 双人动画接触预览合成器

`compose_animation_pairs.py` 只按显式计划选择真实源帧并合成双人站位预览，不修改生产素材。每个场景始终标为 `paired_contact_pending`，没有插帧、镜像、拉伸、自动补帧或自动批准。

## 运行

```powershell
& 'C:/Users/admin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/compose_animation_pairs.py --plan path/to/pairs_plan.json
```

默认输出到计划所在目录的 `paired_review/`。可用 `--output-dir` 指定隔离验证目录，`--scale` 和 `--columns` 调整检查预览的整数放大倍率及逐帧表列数。默认使用 Windows 微软雅黑字体，可通过 `--font` 显式指定其他中文字体。依赖 Pillow 与同目录 `review_pixel_animations.py`。

## 计划契约

```json
{
  "manifest_path": "curated_manifest.json",
  "scenes": [
    {
      "id": "pair_receive",
      "label": "递接书本接触待审",
      "canvas": [128, 96],
      "duration_ms": 160,
      "loop": false,
      "background_color": "#00000000",
      "actors": [
        {"clip_id": "真实源片段ID一", "position": [0, 16], "frame_indices": [0, 1, 2]},
        {"clip_id": "真实源片段ID二", "position": [64, 16], "frame_indices": [0, 1, 2]}
      ],
      "static_rectangles": [
        {"rect": [20, 70, 110, 78], "fill": "#b39169", "outline": "#64472d"}
      ]
    }
  ]
}
```

示例ID是契约说明，运行时必须替换成真实清单已有ID，不会生成替代素材。

- `manifest_path` 相对计划文件所在目录解析；源清单中的相对帧路径仍相对源清单目录。
- 每个场景的 `id` 唯一，作为输出目录名；`label` 原样使用，建议中文。
- `canvas` 为正整数宽高，`background_color` 是明确颜色。八位十六进制可表示透明度，如 `#00000000`。
- `position` 是源帧**左上角**的整数坐标，不是脚点，不进行自动对齐。
- `frame_indices` 为从0开始的源帧索引，各角色数组必须等长。工具严格按给定顺序取帧，不重排，不为了同步而增加、替换或截短。计划若显式重复索引，会如实重复并记录。
- `duration_ms` 是正整数或与合成帧数等长的正整数数组，作为合成预览时间轴；源帧原本时长同时记录在来源证据中。
- `actors` 数组顺序由后到前叠加；通常为两名角色，工具不推断发起者与目标身份。
- `static_rectangles` 可为空数组。矩形先于所有角色绘制，只是明确标注的环境/接触示意，不代表已有正式家具美术。坐标采用**左上含、右下不含**，`outline` 可省略或为null。
- 每张源帧必须完整落在合成画布内。超出边界会显式报错，不能静默裁掉身体或道具。

## 输出

```text
paired_review/
  pairs_manifest.json
  composition_sources.json
  <scene_id>/frame_00.png ...
  review/review.json
  review/<scene_id>/strip.png
  review/<scene_id>/contact_sheet.png
  review/<scene_id>/preview.gif
  review/<scene_id>/metrics.json
```

`pairs_manifest.json` 可直接交给 `review_pixel_animations.py` 或 `build_animation_review.py`。其中 `direction=paired` 表示合成视图，不猜测两名角色统一朝向；真实方向、索引和位置可通过源清单及证据核对。

`composition_sources.json` 保存计划与源清单绝对路径、SHA-256、每个角色的位置与索引数组、每个输出帧的实际源路径/源摘要/源索引/原时长，以及合成帧摘要。复现时使用相同计划、源清单、源帧及像素合成顺序；任何来源变化都可通过摘要发现。

所有图片先在原始尺寸用RGBA叠加，只有检查预览会最近邻整数放大。GIF存在调色板和10毫秒时长粒度限制，完整PNG与逐帧接触表是核对源像素的依据。接触是否合理、道具是否真正交接、人物是否穿模始终需要人工逐帧检查。
