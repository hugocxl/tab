import Foundation

/// A session's readable name, such as `wispy-cedar`, made from its ID so
/// every build and client derives the same one without storing it. Names can
/// repeat; an ID always tells sessions apart.
public enum SessionName {
    public static func of(_ session: SessionId) -> String {
        let bytes = session.uuid.uuid
        return "\(adjectives[Int(bytes.0) & 0x7F])-\(nouns[Int(bytes.1) & 0x7F])"
    }

    /// Whether `text` has a name's shape: two lowercase words joined by `-`.
    public static func isName(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLowercase } }
    }

    static let adjectives: [String] = [
        "amber", "ancient", "autumn", "bold", "brave", "breezy", "bright", "brisk", "calm", "candid", "cheerful",
        "chilly", "clever", "cloudy", "cosmic", "crimson", "crisp", "curious", "dapper", "daring", "dawn", "dusky",
        "eager", "early", "easy", "electric", "emerald", "fancy", "fearless", "fiery", "fluffy", "fond", "frosty",
        "gentle", "giant", "gilded", "glad", "glowing", "golden", "graceful", "grand", "green", "hazy", "hidden",
        "hollow", "humble", "icy", "indigo", "ivory", "jade", "jolly", "keen", "kind", "lively", "lofty", "lucky",
        "lunar", "mellow", "merry", "midnight", "mighty", "misty", "modest", "mossy", "nimble", "noble", "olive",
        "opal", "patient", "peaceful", "plucky", "polar", "proud", "quick", "quiet", "rapid", "rosy", "royal",
        "rustic", "sandy", "scarlet", "serene", "shady", "shiny", "silent", "silver", "simple", "sleek", "sly",
        "smooth", "snowy", "solar", "spry", "starry", "steady", "stormy", "sunny", "swift", "tender", "tidy",
        "tranquil", "twilight", "velvet", "vivid", "wandering", "warm", "wild", "windy", "wise", "wispy", "witty",
        "young", "zesty", "azure", "balmy", "blissful", "cozy", "dewy", "distant", "feathery", "hearty", "oaken",
        "pale", "radiant", "sturdy", "sublime", "verdant", "amiable",
    ]

    static let nouns: [String] = [
        "acorn", "alder", "aspen", "badger", "basil", "beacon", "birch", "bison", "bloom", "brook", "canyon",
        "cedar", "cliff", "clover", "comet", "coral", "cove", "crane", "creek", "cricket", "cypress", "dune",
        "eagle", "ember", "falcon", "fern", "finch", "fjord", "flint", "forest", "fox", "galaxy", "garnet", "geyser",
        "glacier", "grove", "harbor", "hawk", "hazel", "heron", "hill", "holly", "island", "ivy", "juniper",
        "kestrel", "lagoon", "lake", "lark", "laurel", "lily", "lotus", "lynx", "maple", "marsh", "meadow", "meteor",
        "mesa", "mint", "moon", "moss", "nebula", "oak", "ocean", "orchid", "osprey", "otter", "owl", "palm",
        "panda", "pebble", "pine", "planet", "plum", "pond", "poppy", "prairie", "quartz", "rain", "raven", "reef",
        "ridge", "river", "robin", "sage", "salmon", "sequoia", "shore", "sparrow", "spruce", "star", "stone",
        "stream", "summit", "swan", "thistle", "thunder", "tide", "tiger", "trail", "tulip", "tundra", "valley",
        "violet", "volcano", "walnut", "wave", "willow", "wolf", "wren", "yarrow", "zephyr", "bay", "breeze",
        "delta", "garden", "atoll", "bramble", "cloud", "dawnlight", "glade", "heath", "lichen", "marigold",
        "jasper", "kelp", "larch", "nectar",
    ]
}
