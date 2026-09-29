#!/usr/bin/env python3
"""Offline diagnostic corpus for the dense semantic planet layout.

Uses the original multilingual-e5-small weights. The app's Core ML INT8 model
can differ slightly, but the token prefix, masked mean pooling and L2 norm match.
"""

import argparse
import json
import math
import uuid
from pathlib import Path

import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer


BASE_CASES = [
    ("哲学", "自由意志是否只是大脑活动的主观解释？"),
    ("哲学", "什么样的知识才算真正可靠？"),
    ("哲学", "个人身份会随着记忆的改变而改变吗？"),
    ("哲学", "道德判断能否脱离具体文化？"),
    ("编程", "Swift actor 如何避免并发数据竞争？"),
    ("编程", "用 Rust 实现一个高性能 JSON 解析器。"),
    ("编程", "数据库索引为什么能加快范围查询？"),
    ("编程", "修复 iOS 界面滚动时的内存泄漏。"),
    ("烹饪", "番茄炒蛋先炒鸡蛋还是先炒番茄？"),
    ("烹饪", "把面团发酵两小时再放进烤箱。"),
    ("烹饪", "川菜里的花椒为什么会让舌头发麻？"),
    ("烹饪", "晚餐做一碗蘑菇奶油意面。"),
    ("天文", "詹姆斯韦布望远镜观测早期星系。"),
    ("天文", "黑洞事件视界以内的信息能逃逸吗？"),
    ("天文", "今晚用双筒望远镜寻找木星的卫星。"),
    ("天文", "脉冲星的自转为何如此稳定？"),
    ("园艺", "给阳台上的薄荷浇水并修剪枝叶。"),
    ("园艺", "多肉植物在冬天需要减少浇水。"),
    ("园艺", "土壤酸碱度会影响绣球花的颜色。"),
    ("园艺", "把番茄幼苗移栽到光照充足的花盆。"),
    ("音乐", "爵士乐的即兴演奏依赖和声进行。"),
    ("音乐", "练习钢琴左手的琶音和节奏。"),
    ("音乐", "这首交响曲的第二乐章让人想起海浪。"),
    ("音乐", "用合成器制作一段电子舞曲。"),
    ("金融", "长期债券价格为何对利率更敏感？"),
    ("金融", "检查本月家庭预算和储蓄比例。"),
    ("金融", "分散投资能否降低组合波动？"),
    ("金融", "企业现金流与利润并不总是一致。"),
    ("运动", "今天跑五公里并记录心率。"),
    ("运动", "力量训练后肌肉为什么需要恢复时间？"),
    ("运动", "游泳自由泳时如何调整换气节奏？"),
    ("运动", "周末和朋友打一场羽毛球。"),
    ("历史", "丝绸之路如何改变欧亚之间的贸易？"),
    ("历史", "研究唐代城市的商业生活。"),
    ("历史", "工业革命为什么首先发生在英国？"),
    ("历史", "整理祖父留下的旧照片和家族故事。"),
    ("医疗", "发烧时应该如何记录体温变化？"),
    ("医疗", "疫苗如何训练免疫系统识别病原体？"),
    ("医疗", "睡眠不足对血压会有什么影响？"),
    ("医疗", "预约牙医检查一颗持续疼痛的牙齿。"),
    ("旅行", "规划去冰岛看极光的冬季行程。"),
    ("旅行", "查询东京地铁去浅草寺的换乘路线。"),
    ("旅行", "徒步穿越山谷时要提前查看天气。"),
    ("旅行", "在海边小镇住三天体验当地生活。"),
    ("文学", "小说的叙述者可能并不可靠。"),
    ("文学", "读完诗歌后思考意象与节奏的关系。"),
    ("文学", "写一个发生在未来城市的短篇故事。"),
    ("文学", "比较两位作家笔下的孤独主题。"),
]

PERSPECTIVES = [
    "从初学者的角度梳理核心概念",
    "记录一个可以亲自验证的具体问题",
    "比较不同方法的优势与局限",
    "思考它在五年后的可能变化",
    "寻找一个生活中的反例",
    "把关键过程拆成三个步骤",
    "分析背后的原因和影响",
    "整理成下次可以继续探索的线索",
]

INTENTS = [
    "重点关注其中最容易忽略的细节",
    "看看它与其他领域是否存在联系",
    "尝试提出一个与常见观点不同的判断",
    "保留尚未确定的部分以后再验证",
]


def expanded_cases(count=1024):
    """Create a deterministic, varied corpus without duplicating exact text."""
    result = list(BASE_CASES)
    generated_index = 0
    while len(result) < count:
        topic, sentence = BASE_CASES[generated_index % len(BASE_CASES)]
        round_index = generated_index // len(BASE_CASES)
        perspective = PERSPECTIVES[round_index % len(PERSPECTIVES)]
        intent = INTENTS[(round_index // len(PERSPECTIVES) + generated_index) % len(INTENTS)]
        stem = sentence.rstrip("。？！?")
        result.append((topic, f"{stem}；{perspective}，{intent}。"))
        generated_index += 1
    return result


CASES = expanded_cases()


def encode(model_path):
    tokenizer = AutoTokenizer.from_pretrained(model_path, local_files_only=True)
    model = AutoModel.from_pretrained(model_path, local_files_only=True).eval()
    vectors = []
    torch.set_num_threads(4)
    with torch.inference_mode():
        for start in range(0, len(CASES), 8):
            texts = ["query: " + sentence for _, sentence in CASES[start:start + 8]]
            tokens = tokenizer(texts, padding="max_length", truncation=True, max_length=128, return_tensors="pt")
            hidden = model(**tokens).last_hidden_state
            mask = tokens["attention_mask"].unsqueeze(-1)
            pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1)
            pooled = torch.nn.functional.normalize(pooled, dim=1)
            vectors.extend(pooled.cpu().numpy())
    return np.asarray(vectors, dtype=np.float64)


def layout(vectors):
    ids = [uuid.uuid5(uuid.NAMESPACE_DNS, f"pointverse-distribution-{i}").bytes for i in range(len(vectors))]
    similarities = vectors @ vectors.T
    n = len(vectors)
    seeds = [0]
    limit = min(12, max(1, math.ceil(math.sqrt(n) * 1.7)))
    while len(seeds) < limit:
        candidates = [i for i in range(n) if i not in seeds]
        candidate = max(candidates, key=lambda i: (1 - max(similarities[i, seeds]), -i))
        if 1 - max(similarities[candidate, seeds]) < 0.10:
            break
        seeds.append(candidate)
    communities = np.argmax(similarities[:, seeds], axis=1)
    centers = []
    for index in range(len(seeds)):
        y = 1 - 2 * (index + 0.5) / len(seeds)
        longitude = index * math.pi * (3 - math.sqrt(5))
        radius = math.sqrt(max(0, 1 - y * y))
        centers.append(np.array([radius * math.cos(longitude), y, radius * math.sin(longitude)]))
    positions = []
    for index, item in enumerate(ids):
        a = int.from_bytes(item[:2], "big") / 65535
        b = int.from_bytes(item[2:4], "big") / 65535
        radius = math.sqrt(a) * 0.13
        bearing = b * 2 * math.pi
        center = centers[communities[index]]
        east = np.array([-center[2], 0, center[0]])
        east /= np.linalg.norm(east)
        north = np.cross(center, east)
        positions.append(center * math.cos(radius) + east * math.sin(radius) * math.cos(bearing) + north * math.sin(radius) * math.sin(bearing))
    positions = np.asarray(positions, dtype=np.float64)
    for iteration in range(120):
        forces = np.zeros_like(positions)
        for community in range(len(seeds)):
            members = np.flatnonzero(communities == community)
            for member_offset, i in enumerate(members):
                for j in members[member_offset + 1:]:
                    angle = max(0.025, math.acos(float(np.clip(positions[i] @ positions[j], -1, 1))))
                    tangent_i = positions[j] - positions[i] * (positions[i] @ positions[j])
                    tangent_j = positions[i] - positions[j] * (positions[i] @ positions[j])
                    tangent_i /= max(np.linalg.norm(tangent_i), 1e-6)
                    tangent_j /= max(np.linalg.norm(tangent_j), 1e-6)
                    repulsion = min(0.003, 0.00008 / (angle * angle + 0.002))
                    forces[i] -= tangent_i * repulsion
                    forces[j] -= tangent_j * repulsion
                    similarity = similarities[i, j]
                    if similarity >= 0.85:
                        strength = float(np.clip((similarity - 0.85) / 0.15, 0, 1))
                        target = 0.14 - strength * 0.105
                        attraction = (angle - target) * (0.016 + strength * 0.032)
                        forces[i] += tangent_i * attraction
                        forces[j] += tangent_j * attraction
        cooling = 0.3 + 0.7 * (120 - iteration) / 120
        positions += forces * cooling
        positions /= np.linalg.norm(positions, axis=1, keepdims=True)
        for i in range(n):
            center = centers[communities[i]]
            projection = float(np.clip(positions[i] @ center, -1, 1))
            angle = math.acos(projection)
            if angle > 0.22:
                radial = positions[i] - center * projection
                radial /= np.linalg.norm(radial)
                positions[i] = center * math.cos(0.22) + radial * math.sin(0.22)
    return positions, similarities, communities, len(seeds)


def report(positions, similarities, communities, community_count):
    n = len(positions)
    angle_from_center = np.arccos(np.clip(positions[:, 2], -1, 1))
    latitudes = np.degrees(np.arcsin(positions[:, 1]))
    longitudes = np.degrees(np.arctan2(positions[:, 2], positions[:, 0]))
    angles = np.arccos(np.clip(positions @ positions.T, -1, 1))
    np.fill_diagonal(similarities, -np.inf)
    np.fill_diagonal(angles, np.inf)
    nearest_semantic = np.argsort(-similarities, axis=1)[:, :5]
    nearest_geographic = np.argsort(angles, axis=1)[:, :5]
    recall = np.mean([len(set(a) & set(b)) / 5 for a, b in zip(nearest_semantic, nearest_geographic)])
    topics = np.array([topic for topic, _ in CASES])
    same_topic = [(i, j) for i in range(n) for j in range(i + 1, n) if topics[i] == topics[j]]
    different_topic = [(i, j) for i in range(n) for j in range(i + 1, n) if topics[i] != topics[j]]
    mean_angle = lambda pairs: float(np.degrees(np.mean([angles[i, j] for i, j in pairs])))
    print(f"Point: {n}; topic: {len(set(topics))}")
    print(f"semantic communities: {community_count}; occupied sphere sectors: {len(set(communities))}")
    print(f"max angle from original globe center: {np.degrees(angle_from_center.max()):.1f}° (no global cap)")
    print(f"latitude range: {latitudes.min():.1f}° .. {latitudes.max():.1f}°")
    print(f"longitude range: {longitudes.min():.1f}° .. {longitudes.max():.1f}° (camera convention)")
    print(f"Neighbor Recall@5: {recall:.3f}")
    print(f"same-topic mean angle: {mean_angle(same_topic):.2f}°")
    print(f"different-topic mean angle: {mean_angle(different_topic):.2f}°")
    print("\nTopic centers (latitude, longitude, within-topic mean angle):")
    for topic in dict.fromkeys(topics):
        indices = np.flatnonzero(topics == topic)
        center = positions[indices].mean(axis=0)
        center /= np.linalg.norm(center)
        within = [(i, j) for i in indices for j in indices if i < j]
        print(f"  {topic:4s} {math.degrees(math.asin(center[1])):+6.1f}° {math.degrees(math.atan2(center[2], center[0])):+6.1f}°  {mean_angle(within):5.1f}°")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="intfloat/multilingual-e5-small")
    parser.add_argument("--export-json", type=Path)
    args = parser.parse_args()
    positions, similarities, communities, community_count = layout(encode(args.model))
    report(positions, similarities, communities, community_count)
    if args.export_json:
        cases = []
        for index, ((topic, sentence), point) in enumerate(zip(CASES, positions)):
            cases.append({
                "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"pointverse-distribution-{index}")),
                "topic": topic,
                "communityID": f"demo-community-{communities[index]}",
                "text": sentence,
                "latitude": round(math.degrees(math.asin(float(point[1]))), 6),
                "longitude": round(math.degrees(math.atan2(float(point[2]), float(point[0]))), 6),
            })
        args.export_json.write_text(json.dumps(cases, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
