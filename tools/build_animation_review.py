"""从真实动画清单生成可离线打开的交互验收页及首帧总览，不自动批准素材。"""

import argparse
import base64
import hashlib
import json
import math
from collections import Counter
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from review_pixel_animations import DEFAULT_FONT, load_frame, positive_integer, read_manifest


# 界面与导出总览均保留透明区域的棋盘背景，不修改任何输入帧。
CHECKER = ("#dce2e1", "#eef1ee")


def collect_clips(validated):
    """读取真实PNG及清单元数据；尺寸不符在界面显式显示，不修图或伪造帧。"""
    clips = []
    first_frames = []
    for item in validated:
        source = item["manifest"]
        images = []
        dimensions = []
        for path in item["paths"]:
            if path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                raise ValueError(f"交互页仅接受真实PNG单帧：{path}")
            decoded = load_frame(path)
            dimensions.append(list(decoded.size))
            images.append("data" + ":image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii"))
        category = source.get("category", source["id"][0] if source["id"][0] in "AB" else "未分组")
        if not isinstance(category, str) or not category.strip():
            raise ValueError(f"{source['id']}.category 必须是非空字符串")
        clips.append({
            "id": source["id"], "label": source["label"], "category": category,
            "direction": source["direction"], "review_status": source["review_status"],
            "loop": source["loop"], "canvas": source["canvas"], "anchor": source.get("anchor"),
            "durations": item["durations"], "dimensions": dimensions,
            "frame_paths": [str(path) for path in item["paths"]], "images": images,
            "notes": source.get("notes", ""),
        })
        first_frames.append(load_frame(item["paths"][0]))
    return clips, first_frames


def wrapped_lines(text, font, maximum_width):
    """按实际字宽拆行，中文和英文标签均不以裁字方式隐藏。"""
    result = []
    line = ""
    for character in str(text):
        if character == "\n":
            result.append(line)
            line = ""
        elif line and font.getlength(line + character) > maximum_width:
            result.append(line)
            line = character
        else:
            line += character
    result.append(line)
    return result


def create_overview(clips, first_frames, output, font_path, scale, columns):
    """按分类绘制真实首帧和原样标签，整数最近邻放大并记录素材数量。"""
    font = ImageFont.truetype(str(font_path), 18)
    small = ImageFont.truetype(str(font_path), 14)
    heading = ImageFont.truetype(str(font_path), 25)
    image_width = max(frame.width for frame in first_frames) * scale
    image_height = max(frame.height for frame in first_frames) * scale
    cell_width = max(300, image_width + 32)
    label_lines = [wrapped_lines(clip["label"], font, cell_width - 28) for clip in clips]
    maximum_lines = max(len(lines) for lines in label_lines)
    cell_height = image_height + 36 + maximum_lines * 25 + 90
    categories = list(dict.fromkeys(clip["category"] for clip in clips))
    rows = sum(math.ceil(sum(clip["category"] == category for clip in clips) / columns) for category in categories)
    result = Image.new("RGB", (columns * cell_width + 32, 112 + rows * cell_height + len(categories) * 48 + 48), "#f5f7f8")
    draw = ImageDraw.Draw(result)
    draw.text((20, 16), "动画素材首帧总览 · 供人工审核", font=heading, fill="#162e35")
    total_frames = sum(len(clip["images"]) for clip in clips)
    draw.text((20, 55), f"共 {len(clips)} 组素材 / {total_frames} 帧；审核状态原样来自清单；本页不自动判定通过。", font=font, fill="#425c65")
    y = 112
    for category in categories:
        indices = [index for index, clip in enumerate(clips) if clip["category"] == category]
        draw.text((20, y), f"{category} 类 · {len(indices)} 组", font=heading, fill="#162e35")
        y += 48
        for position, index in enumerate(indices):
            x = 16 + position % columns * cell_width
            top = y + position // columns * cell_height
            draw.rounded_rectangle((x + 3, top + 3, x + cell_width - 8, top + cell_height - 9), radius=8, fill="white", outline="#bdcbd0")
            # 只在预览画布上叠棋盘，输入图像的大小和透明像素保持不变。
            image_top = top + 18
            for row in range(0, image_height, 12):
                for column in range(0, image_width, 12):
                    color = CHECKER[(row // 12 + column // 12) % 2]
                    draw.rectangle((x + 16 + column, image_top + row, x + 16 + min(column + 11, image_width - 1), image_top + min(row + 11, image_height - 1)), fill=color)
            first = first_frames[index]
            enlarged = first.resize((first.width * scale, first.height * scale), Image.Resampling.NEAREST)
            result.paste(enlarged, (x + 16, image_top), enlarged)
            clip = clips[index]
            text_y = top + image_height + 30
            for line in label_lines[index]:
                draw.text((x + 15, text_y), line, font=font, fill="#162e35")
                text_y += 25
            draw.text((x + 15, top + image_height + 34 + maximum_lines * 25), clip["id"], font=small, fill="#45616b")
            draw.text((x + 15, top + image_height + 56 + maximum_lines * 25), f"{len(clip['images'])} 帧 / {clip['direction']} / {'循环' if clip['loop'] else '单次'}", font=small, fill="#45616b")
            draw.text((x + 15, top + image_height + 78 + maximum_lines * 25), clip["review_status"], font=small, fill="#8b4b19")
        y += math.ceil(len(indices) / columns) * cell_height
    draw.text((20, y + 8), "总览只展示首帧；完整播放、逐帧和锚点请打开同目录 review.html。", font=font, fill="#425c65")
    result.save(output, format="PNG")


HTML_TEMPLATE = r'''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>动画素材 · 交互审核</title>
<style>
:root{font-family:"Microsoft YaHei",system-ui,sans-serif;color:#19343c;background:#f2f5f7;font-size:14px}*{box-sizing:border-box}body{margin:0}button,select,input{font:inherit}button,select{border:1px solid #bdcbd3;background:white;border-radius:7px;padding:8px 12px;color:#183a45}button{cursor:pointer}button:hover{border-color:#137b92}button:disabled{opacity:.45;cursor:default}button.active{background:#174b5b;color:white;border-color:#174b5b}header{background:#173f4d;color:white;padding:22px 28px}h1{font-size:23px;margin:0 0 9px}header p{margin:5px 0;color:#d4e8ee}main{display:grid;grid-template-columns:minmax(340px,42%) minmax(360px,1fr);gap:20px;padding:20px;align-items:start}.panel{background:white;border:1px solid #d7e0e5;border-radius:14px;padding:20px}.player{position:sticky;top:16px}h2{font-size:20px;margin:0 0 8px;overflow-wrap:anywhere}.sub{font-size:12px;color:#617b84;overflow-wrap:anywhere}.stage{min-height:350px;max-height:65vh;overflow:auto;display:flex;align-items:center;justify-content:center;background:#dce2e1;border-radius:8px;margin:17px 0;padding:24px}.stage canvas{image-rendering:pixelated;flex:none;border:1px solid #879aa0}canvas.thumb{display:block;image-rendering:pixelated}.controls{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:10px 0}.controls label{display:flex;gap:6px;align-items:center}.framebar{width:100%;accent-color:#176d85}.detail{display:grid;grid-template-columns:90px 1fr;gap:7px 12px;margin-top:16px;overflow-wrap:anywhere}.detail dt{color:#617b84}.detail dd{margin:0}.notice{background:#fff7e8;color:#81521b;padding:11px;border-radius:6px;margin-top:12px}.fatal{background:#fde5e3;color:#a52b22;white-space:pre-wrap;padding:20px}.librarytop{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.search{width:100%;padding:10px;border:1px solid #bdcbd3;border-radius:7px}.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:10px;margin-top:12px}.card{text-align:left;display:flex;flex-direction:column;gap:7px;padding:12px;min-width:0}.card.selected{border:2px solid #16768c;padding:11px;background:#eff8fb}.thumbbox{height:146px;display:flex;align-items:center;justify-content:center;background:#e6eceb;border-radius:4px;overflow:hidden}.card strong{font-size:13px;overflow-wrap:anywhere}.card small{font-size:11px;overflow-wrap:anywhere;color:#5a747c}.status{font-size:12px;color:#986123}.hidden{display:none!important}summary{cursor:pointer;margin-top:12px}pre{font-size:11px;overflow:auto;white-space:pre-wrap;max-height:180px}.keys{font-size:12px;color:#617b84;line-height:1.7}.counter{font-size:13px;color:#516f78;margin:10px 0}.playing{color:#137656}.stop{color:#986123}@media(max-width:950px){main{grid-template-columns:1fr}.player{position:static}.stage{min-height:280px}}
</style>
<header><h1>动画素材 · 交互审核</h1><p id="summary"></p><p>真实 PNG 已全部嵌入，可离线打开。选择片段后播放或逐帧检查；审核状态原样读取清单，页面不会自动判定通过。</p></header>
<main><section class="panel player"><h2 id="label"></h2><div id="clipid" class="sub"></div><div class="stage"><canvas id="player" aria-label="所选动画预览"></canvas></div>
<div class="controls"><button id="play">播放</button><button id="replay">从头重播</button><button id="previous">上一帧</button><button id="next">下一帧</button><span id="frame"></span></div>
<input id="scrubber" class="framebar" type="range" min="0" value="0" step="1" aria-label="逐帧进度">
<div class="controls"><label>速度 <select id="speed"><option value="0.25">0.25×</option><option value="0.5">0.5×</option><option value="1" selected>1×</option><option value="2">2×</option><option value="4">4×</option></select></label><label>倍率 <select id="scale"><option>1</option><option>2</option><option selected>4</option><option>6</option><option>8</option></select></label><label><input type="checkbox" id="anchor" checked>脚锚点</label><span id="playstate" class="stop">已暂停</span></div>
<dl id="detail" class="detail"></dl><div id="warning" class="notice hidden"></div><details><summary>源文件与逐帧时长</summary><pre id="source"></pre></details><p class="keys">空格：播放/暂停 · ← / →：上一帧/下一帧 · R：从头重播。单次片段播完停在最后一帧；重播不会改成循环。</p></section>
<section class="panel"><h2>素材库</h2><div class="librarytop" id="filters"></div><input class="search" id="search" placeholder="搜索中文标签、ID、方向或审核状态" aria-label="搜索素材"><div id="count" class="counter"></div><div id="cards" class="cards"></div></section></main>
<script type="application/json" id="manifest">__REVIEW_DATA__</script>
<script>
"use strict";
// 只消费清单里的真实PNG及播放元数据，不改变审核状态或素材内容。
const DATA = JSON.parse(document.querySelector('#manifest').textContent);
const $ = selector => document.querySelector(selector);
const player = $('#player'), context = player.getContext('2d');
// 播放状态只管理预览时间轴；切片、逐帧和调速时同步清除旧时间累计。
let selected = 0, currentFrame = 0, playing = false, accumulated = 0, lastTime = null, selectedCategory = '全部';
// 解码缓存按清单顺序存放真实PNG，卡片数组用于选择高亮与筛选。
const decoded = DATA.clips.map(() => []);
const categoryButtons = [];
const cardButtons = [];

// 暂停播放并把解码或初始化失败直接显示在页面顶部。
function fatal(error) {
  playing = false;
  const message = document.createElement('div');
  message.className = 'fatal'; message.textContent = '预览失败：' + error.message;
  document.body.prepend(message);
}

// 在目标画布绘制透明棋盘，不向素材原图写入背景。
function checker(ctx, width, height, size) {
  // 棋盘直接画在最终整数像素画布，不向源图添加背景。
  for(let y=0;y<height;y+=size) for(let x=0;x<width;x+=size) {
    ctx.fillStyle = ((x/size+y/size)%2===0) ? '#dce2e1' : '#eef1ee';
    ctx.fillRect(x,y,size,size);
  }
}

// 以整数最近邻绘制真实帧，可额外叠加清单声明的锚点。
function paint(target, image, scale, anchor, showAnchor) {
  target.width = image.naturalWidth * scale; target.height = image.naturalHeight * scale;
  const ctx = target.getContext('2d'); ctx.imageSmoothingEnabled = false;
  checker(ctx,target.width,target.height,scale*4);
  ctx.drawImage(image,0,0,target.width,target.height);
  if(showAnchor && anchor !== null) {
    const x=anchor[0]*scale, y=anchor[1]*scale;
    ctx.fillStyle='#db2062';ctx.fillRect(x-5*scale,y,11*scale,Math.max(1,scale));ctx.fillRect(x,y-5*scale,Math.max(1,scale),11*scale);
    ctx.strokeStyle='#17a6ba';ctx.lineWidth=1;ctx.strokeRect(x+.5,y+.5,scale,scale);
  }
}

// 绘制当前帧，并同步进度、播放按钮与末帧提示。
function showFrame() {
  const clip=DATA.clips[selected], image=decoded[selected][currentFrame];
  if(!image) return;
  paint(player,image,Number($('#scale').value),clip.anchor,$('#anchor').checked);
  $('#frame').textContent=`第 ${currentFrame+1} / ${clip.images.length} 帧 · ${clip.durations[currentFrame]} ms`;
  $('#scrubber').value=String(currentFrame);
  $('#play').textContent=playing ? '暂停' : '播放';
  $('#playstate').textContent=playing ? '播放中' : (!clip.loop && currentFrame===clip.images.length-1 ? '单次片段已到末帧' : '已暂停');
  $('#playstate').className=playing ? 'playing' : 'stop';
}

// 将一项真实清单元数据加入详情列表。
function detailLine(term,value) {
  const dt=document.createElement('dt'), dd=document.createElement('dd');
  dt.textContent=term;dd.textContent=value;$('#detail').append(dt,dd);
}

// 切换动画时重置时间轴，并展示该动画的来源及审核边界。
function selectClip(index) {
  selected=index;currentFrame=0;playing=false;accumulated=0;lastTime=null;
  const clip=DATA.clips[index];$('#label').textContent=clip.label;$('#clipid').textContent=clip.id;
  $('#scrubber').max=String(clip.images.length-1);$('#detail').replaceChildren();
  detailLine('分类',clip.category);detailLine('方向',clip.direction);detailLine('播放模式',clip.loop?'循环':'单次，末帧停止');
  detailLine('审核状态',clip.review_status);detailLine('声明画布',clip.canvas.join(' × '));
  detailLine('脚锚点',clip.anchor===null?'未声明，不猜测':`(${clip.anchor.join(', ')})`);
  detailLine('原速时长',clip.durations.reduce((sum,n)=>sum+n,0)+' ms');
  const mismatch=clip.dimensions.some(size=>size[0]!==clip.canvas[0] || size[1]!==clip.canvas[1]);
  $('#warning').classList.toggle('hidden',!mismatch);
  $('#warning').textContent=mismatch?'输入帧尺寸与声明画布不同；页面按每帧真实尺寸显示，未缩放修复。':'';
  const note=clip.notes ? '\n备注：'+(typeof clip.notes==='string'?clip.notes:JSON.stringify(clip.notes)) : '';
  $('#source').textContent=clip.frame_paths.map((path,i)=>`#${String(i).padStart(2,'0')} · ${clip.durations[i]} ms · ${clip.dimensions[i].join('×')}\n${path}`).join('\n\n')+note;
  cardButtons.forEach((button,i)=>button.classList.toggle('selected',i===index));showFrame();
}

// 设置播放状态；已结束的单次动画再次播放时从首帧开始。
function setPlaying(value) {
  const clip=DATA.clips[selected];
  if(value && !clip.loop && currentFrame===clip.images.length-1) currentFrame=0;
  playing=value;accumulated=0;lastTime=null;showFrame();
}

// 暂停并移动一帧，停在片段边缘供逐帧检查。
function step(direction) {
  playing=false;accumulated=0;lastTime=null;
  currentFrame=Math.max(0,Math.min(DATA.clips[selected].images.length-1,currentFrame+direction));showFrame();
}

// 按真实逐帧时长推进预览，单次片段结束后保留末帧。
function tick(time) {
  // 每帧使用清单声明时长；单次动画播完最后一帧后停止，不冒充循环。
  if(lastTime===null) lastTime=time;
  const elapsed=time-lastTime;lastTime=time;
  if(playing) {
    const clip=DATA.clips[selected];accumulated+=elapsed*Number($('#speed').value);
    while(playing && accumulated>=clip.durations[currentFrame]) {
      accumulated-=clip.durations[currentFrame];
      if(currentFrame+1<clip.images.length) currentFrame++;
      else if(clip.loop) currentFrame=0;
      else {playing=false;accumulated=0;}
    }
    showFrame();
  }
  requestAnimationFrame(tick);
}

// 按分类与搜索内容更新卡片可见性及计数。
function filterCards() {
  const query=$('#search').value.trim().toLowerCase();let visible=0;
  DATA.clips.forEach((clip,i)=> {
    const matches=(selectedCategory==='全部' || clip.category===selectedCategory) && [clip.label,clip.id,clip.direction,clip.review_status].join(' ').toLowerCase().includes(query);
    cardButtons[i].classList.toggle('hidden',!matches);if(matches) visible++;
  });
  $('#count').textContent=`当前显示 ${visible} / ${DATA.clips.length} 组素材`;
  categoryButtons.forEach(button=>button.classList.toggle('active',button.dataset.category===selectedCategory));
}

// 完整解码嵌入PNG后创建卡片、绑定控件并启动预览时钟。
async function initialize() {
  const totalFrames=DATA.clips.reduce((sum,clip)=>sum+clip.images.length,0);
  $('#summary').textContent=`${DATA.clips.length} 组素材 · ${totalFrames} 帧 · 清单：${DATA.manifest_name} · 校验摘要 ${DATA.manifest_sha256.slice(0,12)}`;
  await Promise.all(DATA.clips.flatMap((clip,index)=>clip.images.map((uri,frame)=>new Promise((resolve,reject)=> {
    const image=new Image();image.onload=()=>{decoded[index][frame]=image;resolve();};image.onerror=()=>reject(new Error(`PNG解码失败：${clip.id} 第${frame+1}帧`));image.src=uri;
  }))));
  for(const category of ['全部',...new Set(DATA.clips.map(clip=>clip.category))]) {
    const button=document.createElement('button');button.type='button';button.dataset.category=category;
    button.textContent=category==='全部'?'全部':`${category} 类`;
    button.onclick=()=>{selectedCategory=category;filterCards();};categoryButtons.push(button);$('#filters').append(button);
  }
  DATA.clips.forEach((clip,index)=> {
    const button=document.createElement('button');button.type='button';button.className='card';button.dataset.clip=clip.id;
    const box=document.createElement('div');box.className='thumbbox';const canvas=document.createElement('canvas');canvas.className='thumb';
    const image=decoded[index][0], scale=Math.max(1,Math.min(3,Math.floor(140/image.naturalHeight),Math.floor(200/image.naturalWidth)));
    paint(canvas,image,scale,null,false);box.append(canvas);
    const label=document.createElement('strong');label.textContent=clip.label;const info=document.createElement('small');info.textContent=`${clip.id}\n${clip.images.length}帧 · ${clip.direction} · ${clip.loop?'循环':'单次'}`;
    const status=document.createElement('span');status.className='status';status.textContent=clip.review_status;
    button.append(box,label,info,status);button.onclick=()=>selectClip(index);cardButtons.push(button);$('#cards').append(button);
  });
  $('#play').onclick=()=>setPlaying(!playing);$('#replay').onclick=()=>{currentFrame=0;setPlaying(true);};
  $('#previous').onclick=()=>step(-1);$('#next').onclick=()=>step(1);
  $('#scale').onchange=showFrame;$('#anchor').onchange=showFrame;$('#speed').onchange=()=>{lastTime=null;};
  $('#scrubber').oninput=()=>{playing=false;currentFrame=Number($('#scrubber').value);accumulated=0;lastTime=null;showFrame();};
  $('#search').oninput=filterCards;
  document.addEventListener('keydown',event=> {
    if(['INPUT','SELECT','TEXTAREA'].includes(event.target.tagName)) return;
    if(event.code==='Space'){event.preventDefault();setPlaying(!playing);}
    else if(event.code==='ArrowLeft'){event.preventDefault();step(-1);}
    else if(event.code==='ArrowRight'){event.preventDefault();step(1);}
    else if(event.key.toLowerCase()==='r'){currentFrame=0;setPlaying(true);}
  });
  selectClip(0);filterCards();requestAnimationFrame(tick);
}
initialize().catch(fatal);
</script></html>'''


def main():
    """集中校验输入后生成离线资料；源图、清单和审核状态均只读。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--asset-root", type=Path)
    parser.add_argument("--font", type=Path, default=Path(DEFAULT_FONT))
    parser.add_argument("--overview-scale", type=int, default=4)
    parser.add_argument("--columns", type=int, default=4)
    args = parser.parse_args()
    positive_integer(args.overview_scale, "--overview-scale")
    positive_integer(args.columns, "--columns")
    manifest_path = args.manifest.resolve(strict=True)
    _, validated, _ = read_manifest(manifest_path, args.asset_root)
    output_dir = args.output_dir.resolve() if args.output_dir else manifest_path.parent
    font_path = args.font.resolve(strict=True)
    outputs = {output_dir / "review.html", output_dir / "overview.png"}
    inputs = {manifest_path, font_path} | {path for item in validated for path in item["paths"]}
    if inputs & outputs:
        raise ValueError(f"输出会覆盖输入素材：{inputs & outputs}")
    clips, first_frames = collect_clips(validated)
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "manifest_name": manifest_path.name,
        "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "visual_approval": "not_assessed_by_script", "clips": clips,
    }
    # JSON中的结束标签不能逃出数据脚本，界面文字统一使用textContent。
    serialized = json.dumps(payload, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    (output_dir / "review.html").write_text(HTML_TEMPLATE.replace("__REVIEW_DATA__", serialized), encoding="utf-8")
    create_overview(clips, first_frames, output_dir / "overview.png", font_path, args.overview_scale, args.columns)
    print(json.dumps({
        "review_html": str(output_dir / "review.html"), "overview_png": str(output_dir / "overview.png"),
        "clip_count": len(clips), "frame_count": sum(len(clip["images"]) for clip in clips),
        "categories": dict(Counter(clip["category"] for clip in clips)), "visual_approval": "not_assessed_by_script",
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
