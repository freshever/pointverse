import Foundation

public enum LCCCatalog {
    public struct Term: Decodable, Identifiable, Sendable {
        public let id: String
        public let code: String
        public let englishTitle: String
        public let parentID: String?
        public let sourceURL: String
        public let sourcePage: Int
        public let kind: String
        public var chineseTitle: String? { translations[code] }
        public var displayTitle: String { "\(code) · \(chineseTitle ?? englishTitle)" }
        /// Independent UI alias; never changes the official name or stable ID.
        public var friendlyTitle: String { friendlyNames[code] ?? chineseTitle ?? englishTitle }
    }
    public struct Source: Decodable, Sendable {
        public let url: String
        public let sha256: String
        public let lastModified: String?
        public let pageCount: Int
    }
    public struct Snapshot: Decodable, Sendable {
        public let schemaVersion: Int
        public let scheme: String
        public let snapshotID: String
        public let retrievedAt: String
        public let indexURL: String
        public let rightsURL: String
        public let coverage: String
        public let sources: [Source]
        public let terms: [Term]
    }

    public static let snapshot: Snapshot? = {
        guard let url = Bundle.module.url(forResource: "lcc-outline", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Snapshot.self, from: data),
              value.schemaVersion == 1, value.scheme == "LCC" else { return nil }
        let ids = Set(value.terms.map(\.id))
        guard ids.count == value.terms.count,
              value.terms.filter({ $0.parentID == nil }).count == 21,
              value.terms.allSatisfy({ $0.parentID == nil || ids.contains($0.parentID!) }) else { return nil }
        let parents = Dictionary(uniqueKeysWithValues: value.terms.map { ($0.id, $0.parentID) })
        for term in value.terms {
            var seen = Set<String>()
            var current: String? = term.id
            while let id = current {
                guard seen.insert(id).inserted else { return nil }
                current = parents[id] ?? nil
            }
        }
        return value
    }()
    public static let byID: [String: Term] = Dictionary(uniqueKeysWithValues: (snapshot?.terms ?? []).map { ($0.id, $0) })
    public static func friendlyTitle(_ id: String) -> String {
        byID[id]?.friendlyTitle ?? PointFacetEngine.title(id)
    }

    private static let friendlyNames: [String: String] = [
        "A": "综合知识", "B": "思想与信仰", "C": "历史研究", "D": "世界历史",
        "E": "美洲历史", "F": "美洲各地历史", "G": "地理与生活方式", "H": "社会与经济",
        "J": "政治与公共事务", "K": "法律", "L": "教育与学习", "M": "音乐", "N": "艺术与设计",
        "P": "语言与文学", "Q": "科学探索", "R": "医疗与健康", "S": "农业与种植", "T": "工程与生活技术",
        "U": "军事", "V": "海军事务", "Z": "图书与信息整理", "ZA": "信息与知识管理",
        "BC": "逻辑与推理", "BD": "哲学思考", "BF": "心理与情绪", "BH": "审美", "BJ": "伦理与道德",
        "BL": "宗教与神话", "CT": "人物与传记", "CC": "考古发现", "DS": "亚洲历史",
        "GA": "地图与制图", "GB": "地形与自然环境", "GC": "海洋", "GE": "环境保护",
        "GF": "人与环境", "GN": "人类与文化", "GR": "民间故事与传统", "GT": "习俗与礼仪", "GV": "运动与休闲",
        "HB": "经济与人口", "HC": "经济发展", "HD": "产业与工作", "HE": "交通与通信", "HF": "商业与营销",
        "HG": "金融与投资", "HJ": "税收与公共财政", "HM": "社会观察", "HN": "社会变迁与问题",
        "HQ": "家庭、婚姻与女性议题", "HT": "社区与社会群体", "HV": "社会福利与犯罪问题",
        "LB": "教学与学习方法", "LC": "教育专题", "ML": "音乐研究", "MT": "音乐学习",
        "NA": "建筑设计", "NC": "绘画与插画设计", "ND": "绘画", "NE": "版画", "NK": "装饰与工艺设计", "NX": "跨领域艺术",
        "PE": "英语", "PN": "文学与写作", "QA": "数学", "QA71-90": "计算工具与机器",
        "QA75-76.95": "计算设备", "QA75.5-76.95": "计算机与人工智能", "QA76.75-76.765": "软件开发",
        "QB": "宇宙与天文", "QC": "物理世界", "QD": "化学", "QE": "地球与地质", "QH": "生命与自然",
        "QK": "植物", "QL": "动物", "QM": "人体结构", "QP": "身体如何运作", "QR": "微生物",
        "RA": "公共卫生", "RC": "内科与身心健康", "RM": "治疗与用药", "RS": "药学", "RT": "护理",
        "SB": "园艺与植物栽培", "SD": "森林", "SF": "养殖与兽医", "SH": "水产与渔业",
        "TA": "工程与土木建设", "TC": "水利与海洋工程", "TD": "环境与卫生工程", "TH": "建筑与装修",
        "TJ": "机械", "TK": "电气与电子", "TL": "汽车与航空航天", "TP": "化工", "TR": "摄影",
        "TS": "制造与生产", "TT": "手工制作", "TX": "居家生活与烹饪"
    ]

    public static var facetTerms: [PointFacetTerm] {
        (snapshot?.terms ?? []).map { term in
            .init(id: term.id, title: term.displayTitle, parentID: term.parentID, dimension: .domain,
                  keywords: candidateKeywords[term.code] ?? [])
        }
    }

    /// App-maintained Chinese display translations, NOT official LCC Chinese captions.
    private static let translations: [String: String] = [
        "A": "综合著作", "B": "哲学、心理学与宗教", "C": "历史辅助学科", "D": "世界史及地区史",
        "E": "美洲史", "F": "美洲地区史", "G": "地理、人类学与休闲", "H": "社会科学",
        "J": "政治学", "K": "法律", "L": "教育", "M": "音乐及音乐研究", "N": "美术",
        "P": "语言与文学", "Q": "自然科学", "R": "医学", "S": "农业", "T": "技术",
        "U": "军事科学", "V": "海军科学", "Z": "书目学、图书馆学与信息资源",
        "AC": "文集与丛书", "AE": "百科全书", "AG": "辞书与参考资料", "AM": "博物馆",
        "B-BJ": "哲学与心理学", "BC": "逻辑学", "BD": "思辨哲学", "BF": "心理学", "BH": "美学", "BJ": "伦理学",
        "BL": "宗教、神话与理性主义", "BM": "犹太教", "BP": "伊斯兰教、巴哈伊信仰与神智学", "BQ": "佛教",
        "BR": "基督教", "BS": "圣经", "BT": "教义神学", "BV": "实践神学", "BX": "基督教宗派",
        "CC": "考古学", "CT": "传记", "DA": "英国史", "DC": "法国史", "DD": "德国史",
        "DE": "希腊罗马史", "DF": "希腊史", "DG": "意大利、马耳他与罗马史", "DS": "亚洲史", "DT": "非洲史",
        "GA": "数学地理与制图", "GB": "自然地理", "GC": "海洋学", "GE": "环境科学", "GF": "人文生态与人文地理",
        "GN": "人类学", "GR": "民俗学", "GT": "风俗礼仪", "GV": "休闲与体育",
        "HA": "统计学", "HB": "经济理论与人口学", "HC": "经济史与经济状况", "HD": "产业、土地与劳动",
        "HE": "交通与通信", "HF": "商业", "HG": "金融", "HJ": "公共财政", "HM": "社会学", "HN": "社会史与社会问题",
        "HQ": "家庭、婚姻与妇女", "HS": "社团", "HT": "社区、阶级与种族", "HV": "社会福利与犯罪学", "HX": "社会主义、共产主义与无政府主义",
        "JA": "政治学总论", "JC": "政治理论", "JF": "政治制度与公共行政", "JX": "国际法旧类", "JZ": "国际关系", "KZ": "国际法",
        "LA": "教育史", "LB": "教育理论与实践", "LC": "教育专题", "LD": "美国院校", "LE": "美洲其他地区院校", "LG": "亚洲、非洲、大洋洲院校",
        "ML": "音乐文献", "MT": "音乐教学", "NA": "建筑艺术", "NB": "雕塑", "NC": "绘画设计与插图", "ND": "绘画", "NE": "版画", "NK": "装饰艺术", "NX": "综合艺术",
        "PA": "古典语言与文学", "PE": "英语", "PL": "东亚、非洲及大洋洲语言与文学", "PN": "文学总论", "PQ": "罗曼语文学", "PR": "英国文学", "PS": "美国文学", "PZ": "小说与青少年文学",
        "QA": "数学", "QB": "天文学", "QC": "物理学", "QD": "化学", "QE": "地质学", "QH": "自然史与生物学",
        "QK": "植物学", "QL": "动物学", "QM": "人体解剖学", "QP": "生理学", "QR": "微生物学",
        "QA71-90": "仪器与机器", "QA75-76.95": "计算机器", "QA75.5-76.95": "电子计算机与计算机科学", "QA76.75-76.765": "计算机软件",
        "RA": "医学公共事务", "RB": "病理学", "RC": "内科学", "RD": "外科学", "RE": "眼科学", "RF": "耳鼻喉科学", "RG": "妇产科学",
        "RJ": "儿科学", "RK": "牙科学", "RL": "皮肤科学", "RM": "治疗学与药理学", "RS": "药学", "RT": "护理学", "RZ": "其他医学体系",
        "SB": "植物栽培", "SD": "林业", "SF": "畜牧与兽医", "SH": "水产与渔业", "SK": "狩猎与野生动物利用",
        "TA": "工程总论与土木工程", "TC": "水利与海洋工程", "TD": "环境与卫生工程", "TE": "公路工程", "TF": "铁路工程", "TG": "桥梁工程",
        "TH": "建筑施工", "TJ": "机械工程", "TK": "电气、电子与核工程", "TL": "车辆、航空与航天", "TN": "采矿与冶金", "TP": "化工技术",
        "TR": "摄影", "TS": "制造业", "TT": "手工艺", "TX": "家政学", "ZA": "信息资源"
    ]

    /// Prototype routing hints authored by PointVerse. These are NOT part of LCC.
    /// Unmapped text remains unassigned; importing a taxonomy does not create a classifier.
    private static let candidateKeywords: [String: [String]] = [
        "A": ["百科全书", "encyclopedia"], "BC": ["逻辑学", "逻辑推理", "logic"], "BD": ["哲学", "自由意志", "philosophy"],
        "BF": ["心理学", "认知心理", "psychology"], "BJ": ["伦理", "道德", "ethics"], "BQ": ["佛教", "Buddhism"],
        "DS": ["中国历史", "唐代", "亚洲历史"], "CC": ["考古", "archaeology"], "CT": ["传记", "biography"],
        "G": ["旅行", "旅游", "travel"], "GV": ["跑步", "游泳", "运动训练", "马拉松", "running", "exercise", "marathon"],
        "GE": ["环境科学", "环境保护", "生态保护"], "GA": ["制图", "cartography"], "GN": ["人类学", "anthropology"],
        "HB": ["经济学", "经济理论", "economics"], "HG": ["金融", "投资", "债券", "现金流", "finance"],
        "HF": ["商业", "营销", "市场营销", "commerce"], "HM": ["社会学", "sociology"], "HQ": ["家庭关系", "婚姻"],
        "J": ["政治", "politics"], "K": ["法律", "法学", "law"], "LB": ["教育", "教学", "学习方法", "education"],
        "M": ["音乐", "爵士", "钢琴", "交响曲", "music"], "ND": ["绘画", "油画", "painting"], "NA": ["建筑设计", "architecture"],
        "PN": ["文学", "小说", "写作", "诗歌", "writing", "novel"], "PE": ["英语学习", "English grammar"],
        "QA": ["数学", "mathematics"], "QA75.5-76.95": ["计算机", "人工智能", "大模型", "embedding", "Core ML", "机器学习", "AI", "语音识别", "computer"],
        "QA76.75-76.765": ["Swift", "Rust", "编程", "代码", "iOS", "程序", "数据库", "编译", "并发", "内存", "循环引用", "SQLite", "programming", "database", "memory management"],
        "QB": ["天文", "黑洞", "望远镜", "星系", "astronomy"], "QC": ["物理", "量子", "physics"], "QD": ["化学", "chemistry"],
        "QH": ["生物学", "生态学", "biology"], "QK": ["植物学", "botany"], "QL": ["动物学", "zoology"],
        "R": ["医学", "医疗", "健康", "health"], "RC": ["睡眠", "失眠", "sleep", "insomnia"], "RT": ["护理", "nursing"],
        "SB": ["园艺", "植物栽培", "薄荷", "多肉", "gardening"], "TR": ["摄影", "photography"],
        "TX": ["烹饪", "做饭", "晚餐", "面团", "意面", "cooking"], "TH": ["装修", "建筑施工"], "TK": ["电路", "电子工程", "electronics"],
        "ZA": ["知识管理", "信息检索", "信息资源"], "Z": ["图书馆", "书目", "library"]
    ]
}
