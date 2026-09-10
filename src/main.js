const $ = (s) => document.querySelector(s);
let current = "01",
  history = [],
  activePoint = null,
  attachment = null;
let points = [
  {
    title: "雨后的窗户",
    text: "看到雨后的窗户，想起小时候放学。",
    messages: [
      "看到雨后的窗户，想起小时候放学。",
      "想把这段感觉写进故事。标题还没想好。",
    ],
    x: -85,
    y: -35,
    z: 60,
  },
  {
    title: "底片显影",
    text: "学习像底片显影，旧经验在新条件下显现。",
    messages: ["学习像底片显影，旧经验在新条件下显现。"],
    x: 65,
    y: 50,
    z: 10,
  },
  {
    title: "故事的开头",
    text: "从一个声音开始讲述故事。",
    messages: ["从一个声音开始讲述故事。"],
    x: -60,
    y: 85,
    z: -40,
  },
  {
    title: "跨领域的共鸣",
    text: "不同背景的人怎样产生新的理解？",
    messages: ["不同背景的人怎样产生新的理解？"],
    x: 105,
    y: -65,
    z: -55,
  },
  {
    title: "日常的灵感",
    text: "记录一闪而过的瞬间。",
    messages: ["记录一闪而过的瞬间。"],
    x: 10,
    y: -100,
    z: 15,
  },
  {
    title: "多个美的终态",
    text: "魔方不同的颜色排布也可以是美。",
    messages: ["魔方不同的颜色排布也可以是美。"],
    x: -110,
    y: 20,
    z: -80,
  },
  {
    title: "不可言传",
    text: "先留下感受，不强迫解释。",
    messages: ["先留下感受，不强迫解释。"],
    x: 40,
    y: 10,
    z: 115,
  },
];
let edges = [
  [0, 1],
  [0, 2],
  [0, 6],
  [1, 3],
  [3, 5],
  [4, 6],
  [2, 5],
];
function toast(t) {
  $("#toast").textContent = t;
  $("#toast").hidden = false;
  clearTimeout(window.tt);
  window.tt = setTimeout(() => ($("#toast").hidden = true), 2600);
}
function go(id, push = true) {
  if (push && id !== current) history.push(current);
  current = id;
  document.querySelectorAll(".screen").forEach((e) => {
    e.classList.toggle("active", e.id === "s" + id);
    e.classList.remove("target");
  });
  $("#jump").value = id;
  $("#s" + id).classList.add("target");
  $("#s" + id).scrollIntoView({ behavior: "smooth", block: "start" });
  requestAnimationFrame(draw);
}
function renderChat() {
  const m = $("#messages");
  m.replaceChildren();
  if (activePoint === null) {
    m.innerHTML =
      '<div class="welcome"><h3>此刻，想到什么？</h3><p>一句话、一张图，或一段声音。</p></div>';
    $("#chatTitle").textContent = "新点子";
  } else {
    const p = points[activePoint];
    $("#chatTitle").textContent = p.title;
    p.messages.forEach((t) => {
      const el = document.createElement("div");
      el.className = "chatmsg";
      el.textContent = t;
      m.append(el);
    });
    if (p.image) {
      let el = document.createElement("div");
      el.className = "chatmsg";
      let img = document.createElement("img");
      img.src = p.image;
      img.alt = "本次添加的图片";
      el.append(img);
      m.append(el);
    }
  }
  m.scrollTop = m.scrollHeight;
}
async function send() {
  let t = $("#chatInput").value.trim();
  if (!t && !attachment) return;
  const isNewPoint = activePoint === null;
  if (activePoint === null) {
    activePoint = points.length;
    points.push({
      title: t.slice(0, 14) || "图片想法",
      text: t || "一张图片",
      messages: [],
      x: (Math.random() - 0.5) * 180,
      y: (Math.random() - 0.5) * 180,
      z: (Math.random() - 0.5) * 180,
    });
  }
  let p = points[activePoint];
  if (t) p.messages.push(t);
  if (attachment) {
    p.image = attachment;
    attachment = null;
    $("#attachmentTray").hidden = true;
  }
  $("#chatInput").value = "";
  $("#chatInput").style.height = "auto";
  $("#saveStatus").textContent = "正在保存到 SQLite…";
  renderChat();
  if (/梳理|整理|帮我|换个角度/.test(t)) {
    let el = document.createElement("div");
    el.className = "assistantmsg";
    el.innerHTML =
      '可以，我们先确认这次要处理的内容。<div class="inlineactions"><button data-go="05">确认范围并继续</button></div>';
    $("#messages").append(el);
    el.scrollIntoView({ block: "nearest" });
  }
  populate();
  draw();

  try {
    if (t) {
      if (isNewPoint) {
        const { point } = await PointVerseApi.createPoint({ ...p, text: t });
        p.id = point.id;
      } else {
        await PointVerseApi.appendMessage(p.id, t);
      }
    }
    $("#saveStatus").textContent = "已保存到本地 SQLite";
  } catch (error) {
    console.error(error);
    $("#saveStatus").textContent = "保存失败 · 输入仍保留";
    toast("SQLite 保存失败，请检查本地服务");
  }
}

async function syncFromDatabase() {
  try {
    const { points: savedPoints } = await PointVerseApi.listPoints();
    if (savedPoints.length) {
      points = savedPoints.map((point) => ({
        ...point,
        messages: point.messages.map((message) => message.content),
      }));
      activePoint = null;
      populate();
      renderChat();
      draw();
    }
    $("#saveStatus").textContent = "SQLite 本地存储 · 已同步";
  } catch (error) {
    console.error(error);
    $("#saveStatus").textContent = "本地服务未连接 · 当前会话模式";
    toast("SQLite 未连接，当前内容只保留在页面中");
  }
}
function populate() {
  const sel = $("#nodeSelect");
  sel.replaceChildren(new Option("选择点子…", ""));
  points.forEach((p, i) => sel.add(new Option(p.title, i)));
}
let yaw = 0.35,
  pitch = -0.2,
  zoom = 1,
  selected = null,
  projected = [],
  drag = null,
  pointers = new Map(),
  pinch = 0;
const canvas = $("#graphCanvas"),
  ctx = canvas.getContext("2d");
function draw() {
  let r = canvas.getBoundingClientRect();
  if (!r.width || !r.height) return;
  let dpr = devicePixelRatio || 1;
  canvas.width = r.width * dpr;
  canvas.height = r.height * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, r.width, r.height);
  let unit = Math.min(r.width, r.height) / 340;
  projected = points.map((p, i) => {
    let x = p.x * Math.cos(yaw) + p.z * Math.sin(yaw),
      z = -p.x * Math.sin(yaw) + p.z * Math.cos(yaw),
      y = p.y * Math.cos(pitch) - z * Math.sin(pitch);
    z = p.y * Math.sin(pitch) + z * Math.cos(pitch);
    let k = (340 / (340 + z)) * zoom * unit;
    return {
      i,
      x: r.width / 2 + x * k,
      y: r.height / 2 + y * k,
      z,
      r: Math.max(4, 7 * k),
    };
  });
  edges.forEach(([a, b]) => {
    if (selected !== null && a !== selected && b !== selected) return;
    ctx.beginPath();
    ctx.moveTo(projected[a].x, projected[a].y);
    ctx.lineTo(projected[b].x, projected[b].y);
    ctx.strokeStyle = selected === null ? "#d5d5d5" : "#888";
    ctx.lineWidth = 1;
    ctx.stroke();
  });
  let q = $("#graphSearch").value.trim();
  [...projected]
    .sort((a, b) => b.z - a.z)
    .forEach((p) => {
      let match =
        !q || points[p.i].title.includes(q) || points[p.i].text.includes(q);
      ctx.globalAlpha = match ? 1 : 0.15;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r + (p.i === selected ? 3 : 0), 0, Math.PI * 2);
      ctx.fillStyle = p.i === selected ? "#111" : "#777";
      ctx.fill();
      if (p.i === selected) {
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r + 8, 0, Math.PI * 2);
        ctx.strokeStyle = "#999";
        ctx.stroke();
      }
      ctx.font = "11px system-ui";
      ctx.textAlign = "center";
      ctx.fillStyle = "#444";
      ctx.fillText(points[p.i].title.slice(0, 12), p.x, p.y + p.r + 17);
    });
  ctx.globalAlpha = 1;
}
function select(i, focus = false) {
  selected = i;
  $("#nodeSelect").value = i;
  let p = points[i];
  if (focus) {
    yaw = Math.atan2(-p.x, p.z);
    pitch = Math.atan2(p.y, Math.hypot(p.x, p.z));
    zoom = 1.25;
  }
  let el = $("#nodePreview");
  el.replaceChildren();
  let tag = document.createElement("small");
  tag.textContent = "私人点子 · " + p.messages.length + " 条消息";
  let h = document.createElement("h3");
  h.textContent = p.title;
  let t = document.createElement("p");
  t.textContent = p.text;
  let b = document.createElement("button");
  b.textContent = "打开对话 →";
  b.dataset.action = "openNode";
  el.append(tag, h, t, b);
  draw();
}
canvas.addEventListener("pointerdown", (e) => {
  canvas.setPointerCapture(e.pointerId);
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  drag = { x: e.clientX, y: e.clientY, total: 0 };
  if (pointers.size === 2) {
    let a = [...pointers.values()];
    pinch = Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y);
  }
});
canvas.addEventListener("pointermove", (e) => {
  if (!pointers.has(e.pointerId)) return;
  let prev = pointers.get(e.pointerId);
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (pointers.size === 2) {
    let a = [...pointers.values()],
      n = Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y);
    if (pinch) zoom = Math.max(0.45, Math.min(2.8, (zoom * n) / pinch));
    pinch = n;
    drag.total = 99;
  } else {
    let dx = e.clientX - prev.x,
      dy = e.clientY - prev.y;
    yaw += dx * 0.009;
    pitch += dy * 0.009;
    drag.total += Math.abs(dx) + Math.abs(dy);
  }
  draw();
});
function end(e) {
  if (drag && drag.total < 8 && pointers.size === 1) {
    let r = canvas.getBoundingClientRect(),
      x = e.clientX - r.left,
      y = e.clientY - r.top;
    let hit = [...projected]
      .reverse()
      .find((p) => Math.hypot(p.x - x, p.y - y) < p.r + 15);
    if (hit) select(hit.i);
  }
  pointers.delete(e.pointerId);
  pinch = 0;
  if (!pointers.size) drag = null;
}
canvas.addEventListener("pointerup", end);
canvas.addEventListener("pointercancel", (e) => {
  pointers.delete(e.pointerId);
  drag = null;
});
canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    zoom = Math.max(0.45, Math.min(2.8, zoom * Math.exp(-e.deltaY * 0.001)));
    draw();
  },
  { passive: false },
);
canvas.addEventListener("keydown", (e) => {
  if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) {
    e.preventDefault();
    yaw += e.key === "ArrowLeft" ? -0.15 : e.key === "ArrowRight" ? 0.15 : 0;
    pitch += e.key === "ArrowUp" ? -0.15 : e.key === "ArrowDown" ? 0.15 : 0;
    draw();
  }
});
new ResizeObserver(draw).observe(canvas);
$("#nodeSelect").onchange = (e) => {
  if (e.target.value !== "") select(Number(e.target.value), true);
};
$("#graphSearch").oninput = () => {
  let q = $("#graphSearch").value.trim(),
    i = points.findIndex((p) => p.title.includes(q) || p.text.includes(q));
  if (q && i >= 0) select(i, true);
  else draw();
};
document.addEventListener("click", (e) => {
  let b = e.target.closest("button");
  if (!b) return;
  if (b.dataset.go) {
    go(b.dataset.go);
    return;
  }
  let a = b.dataset.action;
  if (a === "newChat") {
    activePoint = null;
    attachment = null;
    $("#attachmentTray").hidden = true;
    $("#chatInput").value = "";
    renderChat();
    go("01");
  } else if (a === "sendChat") send();
  else if (a === "openNode") {
    activePoint = selected;
    renderChat();
    go("01");
  } else if (a === "addFile") $("#fileInput").click();
  else if (a === "voice") toast("语音入口示意，当前不录音");
  else if (a === "zoomIn") {
    zoom = Math.min(2.8, zoom * 1.2);
    draw();
  } else if (a === "zoomOut") {
    zoom = Math.max(0.45, zoom / 1.2);
    draw();
  } else if (a === "rotateGraph") {
    yaw += 0.4;
    draw();
  } else if (a === "resetGraph") {
    yaw = 0.35;
    pitch = -0.2;
    zoom = 1;
    selected = null;
    $("#graphSearch").value = "";
    draw();
  } else if (a === "back") go(history.pop() || "03", false);
  else if (a === "generate") {
    if (!$("#scope").checked) return toast("请选择会话内容");
    go("12");
  } else if (a === "fail")
    $("#generation").innerHTML =
      '<strong>生成失败或超时</strong><p>原始内容已保留。</p><button data-go="05">重新确认</button>';
  else if (a === "cancel") {
    $("#generation").innerHTML =
      '<strong>已取消</strong><p>未调用模型，不产生费用。</p><button data-go="01">返回对话</button>';
  } else if (a === "attach" || a === "saveResult") {
    toast("已保留示例结果");
    go("04");
  } else if (a === "transcript") $("#transcript").hidden = false;
  else if (a === "attachment") {
    go("01");
    toast("可从底部＋添加本地图片");
  } else if (a === "revealText")
    $("#received").textContent = "示例转写：雨后的窗户让我想起放学。";
  else if (a === "resonate") {
    if (!$("#reply").value.trim()) return toast("先写下回应");
    toast("已保存示例共振点");
    go("03");
  } else if (a === "retry") {
    toast("重试成功（示例）");
    go("01");
  } else if (a === "closeRec") $("#recCard").hidden = true;
  else if (a === "settings" || a === "audio") {
    $("#dialogText").textContent =
      "离线交互原型：不上传、不调用模型；演示数据刷新后重置。";
    $("#dialog").showModal();
  } else if (a === "feedback") toast("已记录示例反馈");
  if (b.dataset.detail) {
    $("#detailContent").textContent =
      b.dataset.detail === "原始内容"
        ? activePoint === null
          ? points[0].text
          : points[activePoint].messages.join("\n")
        : b.dataset.detail === "生成结果"
          ? "生成结果与原话分开保存。"
          : "关系为示例推断，尚未确认。";
  }
  if (b.dataset.rec) {
    $("#recCard").hidden = false;
    $("#recCard").textContent =
      b.dataset.rec === "另一种观点"
        ? "暂无有证据的反驳观点。"
        : "可能互补：旧经验在新条件下显现。";
  }
});
$("#chatInput").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    send();
  }
});
$("#chatInput").oninput = (e) => {
  e.target.style.height = "auto";
  e.target.style.height = Math.min(140, e.target.scrollHeight) + "px";
};
$("#fileInput").onchange = (e) => {
  let f = e.target.files[0];
  if (!f) return;
  if (!f.type.startsWith("image/")) return toast("请选择图片");
  if (f.size > 10 * 1024 * 1024) return toast("演示图片请小于 10MB");
  let reader = new FileReader();
  reader.onload = () => {
    attachment = reader.result;
    $("#attachmentTray").textContent = "待发送图片：" + f.name;
    $("#attachmentTray").hidden = false;
  };
  reader.readAsDataURL(f);
  e.target.value = "";
};
$("#overview").onclick = () => {
  document.body.classList.remove("single");
  $("#overview").setAttribute("aria-pressed", "true");
  $("#demo").setAttribute("aria-pressed", "false");
  draw();
};
$("#demo").onclick = () => {
  document.body.classList.add("single");
  $("#demo").setAttribute("aria-pressed", "true");
  $("#overview").setAttribute("aria-pressed", "false");
  go(current, false);
};
$("#jump").onchange = (e) => go(e.target.value);
$("#closeDialog").onclick = () => $("#dialog").close();
populate();
renderChat();
$("#s01").classList.add("active");
syncFromDatabase();

let processAction = null,
  processEvents = [],
  branchItems = [],
  mergeCandidate = null,
  merged = null,
  queuePaused = false;
function eventRecord(t) {
  processEvents.push(new Date().toLocaleTimeString() + " " + t);
  document.querySelector("#eventLog").textContent = processEvents.join("\n");
}
function processSource() {
  return activePoint === null ? 0 : activePoint;
}
function updateAction() {
  document.querySelector("#goalDisplay").textContent = processAction.goal;
  document.querySelector("#processState").textContent =
    "状态：" + processAction.state;
}
function branchesUI() {
  let root = document.querySelector("#branches");
  root.replaceChildren();
  branchItems.forEach((br, i) => {
    let c = document.createElement("div");
    c.className = "box";
    let lab = document.createElement("label"),
      ck = document.createElement("input");
    ck.type = "checkbox";
    ck.dataset.branch = i;
    ck.checked = true;
    lab.append(ck, document.createTextNode(" " + br.name));
    let txt = document.createElement("p");
    txt.textContent =
      "源点：" +
      br.source.title +
      " · " +
      br.source.messages.length +
      "条消息快照";
    c.append(lab, txt);
    root.append(c);
  });
}
document.addEventListener("click", (e) => {
  const el = e.target.closest("[data-process]");
  if (!el) return;
  const a = el.dataset.process;
  if (a === "more") {
    $("#dialogText").innerHTML =
      '<button data-go="13">形成行动</button> <button data-go="15">探索分支</button> <button data-go="16">过程记录</button>';
    $("#dialog").showModal();
    return;
  }
  if (a === "confirm") {
    if (queuePaused) return toast("已暂停新行动，请先恢复接收");
    let goal = $("#actionGoal").value.trim(),
      criteria = $("#actionCriteria").value.trim();
    if (!goal || !criteria) return toast("请填写目标和完成标准");
    if (
      processAction &&
      !["完成", "失败", "取消"].includes(processAction.state)
    )
      return toast("已有进行中的行动，请先完成或取消");
    processAction = {
      goal,
      criteria,
      source: JSON.parse(JSON.stringify(points[processSource()])),
      state: "就绪",
      observed: false,
    };
    updateAction();
    eventRecord("用户确认行动：" + goal);
    $("#actionSource").textContent = "来源：" + processAction.source.title;
    go("14");
  } else if (
    ["start", "pause", "resume", "complete", "failed", "cancelAction"].includes(
      a,
    )
  ) {
    if (!processAction) return toast("请先形成行动");
    let allowed = {
      start: ["就绪"],
      pause: ["进行中"],
      resume: ["暂停"],
      complete: ["进行中"],
      failed: ["进行中"],
      cancelAction: ["就绪", "进行中", "暂停"],
    };
    if (!allowed[a].includes(processAction.state))
      return toast("当前状态不能执行此操作");
    if (
      a === "complete" &&
      (!processAction.observed || $("#assessment").value !== "达到完成标准")
    )
      return toast("先保存观测，并确认达到完成标准");
    processAction.state = {
      start: "进行中",
      pause: "暂停",
      resume: "进行中",
      complete: "完成",
      failed: "失败",
      cancelAction: "取消",
    }[a];
    updateAction();
    eventRecord("行动状态：" + processAction.state);
  } else if (a === "feedback") {
    if (!processAction) return toast("请先形成行动");
    if (!$("#observation").value.trim()) return toast("请记录实际观察");
    processAction.observed = true;
    $("#feedbackRecord").textContent =
      $("#observation").value +
      "；证据：" +
      ($("#evidence").value || "未提供") +
      "；判断：" +
      $("#assessment").value;
    eventRecord("保存观测与反馈");
  } else if (a === "branch") {
    let name = $("#branchName").value.trim();
    if (!name) return toast("请输入分支视角");
    let source = JSON.parse(JSON.stringify(points[processSource()]));
    branchItems.push({ name, source });
    $("#branchSource").textContent = "源点：" + source.title;
    branchesUI();
    eventRecord("创建分支：" + name);
  } else if (a === "previewMerge") {
    let chosen = [...document.querySelectorAll("[data-branch]:checked")].map(
      (c) => branchItems[Number(c.dataset.branch)],
    );
    if (chosen.length < 2) return toast("至少选择两个分支");
    if (!$("#mergeText").value.trim()) return toast("写下合并内容和保留的差异");
    mergeCandidate = {
      text: $("#mergeText").value,
      branches: JSON.parse(JSON.stringify(chosen)),
    };
    $("#mergePreview").hidden = false;
    $("#mergePreview").textContent =
      "来源：" +
      chosen.map((b) => b.name).join("、") +
      "。候选：" +
      mergeCandidate.text +
      "。确认后生成新点，保留源分支。";
  } else if (a === "merge") {
    if (!mergeCandidate) return toast("先预览合并");
    let result = {
      title: "合并探索",
      text: mergeCandidate.text,
      messages: [mergeCandidate.text],
      x: 30,
      y: 60,
      z: -50,
      branches: mergeCandidate.branches,
    };
    points.push(result);
    merged = result;
    mergeCandidate = null;
    populate();
    draw();
    eventRecord("生成合并点；源分支保留");
    toast("合并点已加入3D空间");
  } else if (a === "undoMerge") {
    if (!merged) return toast("没有可撤销合并");
    let i = points.indexOf(merged);
    if (i >= 0) {
      points.splice(i, 1);
      if (activePoint === i) activePoint = null;
      else if (activePoint > i) activePoint--;
      selected = null;
    }
    merged = null;
    populate();
    draw();
    eventRecord("撤销合并，保留源分支");
  } else if (a === "limits") {
    if (!$("#concurrency").checkValidity() || !$("#retryLimit").checkValidity())
      return toast("限制范围为并发1–3、重试0–3");
    eventRecord(
      "保存演示限制：并发" +
        $("#concurrency").value +
        "，重试" +
        $("#retryLimit").value,
    );
    toast("仅保存配置示意，不连接执行器");
  } else if (a === "stopQueue" || a === "resumeQueue") {
    queuePaused = a === "stopQueue";
    $("#queueState").textContent = queuePaused
      ? "已暂停新行动"
      : "可接收手工行动";
    eventRecord($("#queueState").textContent);
  }
});
document.addEventListener("click", (e) => {
  if (e.target.closest("#dialog [data-go]")) $("#dialog").close();
});
