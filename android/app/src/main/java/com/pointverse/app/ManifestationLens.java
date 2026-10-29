package com.pointverse.app;

/** Expression presets are prompts, independent of the eventual output medium. */
final class ManifestationLens {
    static final String[] IDS={"original","poetic","dream","playful","abstract","minimal","retro"};
    static final String[] NAMES={"原貌","诗意","梦境","幽默","抽象","极简","复古"};
    static final String[] PROMPTS={
        "Preserve the original meaning with a grounded, sincere expression. Do not add an unrelated story.",
        "Use lyrical imagery and gentle metaphors to express the idea's emotional undertone, with restraint.",
        "Express the core idea through dreamlike associations, fluid space and surprising juxtapositions.",
        "Use playful wit and a gentle, surprising reinterpretation; do not mock the person or invent factual claims.",
        "Express the underlying relationships and emotions through abstract shapes, rhythm and symbolic structure.",
        "Reduce the idea to its essentials; use few elements, restraint and generous breathing room.",
        "Give the idea a nostalgic expression with a coherent vintage atmosphere, without changing its central meaning."};
    static String id(int index){return IDS[Math.max(0,Math.min(index,IDS.length-1))];}
    static String prompt(String id){for(int i=0;i<IDS.length;i++)if(IDS[i].equals(id))return PROMPTS[i];return PROMPTS[0];}
    static String name(String id){for(int i=0;i<IDS.length;i++)if(IDS[i].equals(id))return NAMES[i];return NAMES[0];}
}
