import Foundation
import TabProtocol

/// Builds simulator steps from words and options, the same for a command
/// such as `tab simulator tap @e3 --hold 1` as for one step of
/// `tab simulator batch "tap @e3 --hold 1"`.
enum SimulatorSteps {
    /// Options a step takes with a value.
    static let values = ["--label", "--id", "--count", "--hold", "--duration", "--distance", "--timeout"]
    static let flags = ["--gone"]
    /// The verbs `batch` runs.
    static let verbs = ["tap", "swipe", "scroll", "type", "fill", "key", "press", "wait", "wait-for", "open", "launch",
                        "terminate", "location"]

    struct Input {
        var words: [String]
        var values: [String: String] = [:]
        var flags: Set<String> = []

        func number(_ name: String, default fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
            guard let text = values[name] else { return fallback }
            guard let value = Double(text), range.contains(value) else {
                throw CLIError("\(name) must be a number from \(SimulatorTarget.number(range.lowerBound)) to \(SimulatorTarget.number(range.upperBound))")
            }
            return value
        }
    }

    /// The target of `--label`, `--id`, a ref such as `@e3`, or `X Y` points
    /// starting at word `index`; returns it and the words it took.
    static func target(_ input: Input, at index: Int = 0) throws -> (SimulatorTarget, Int) {
        if let label = input.values["--label"] { return (.label(label), 0) }
        if let identifier = input.values["--id"] { return (.identifier(identifier), 0) }
        guard index < input.words.count else {
            throw CLIError("name what to act on: a ref such as @e3 from tab simulator snapshot, X Y in points, --label TEXT or --id ID")
        }
        let word = input.words[index]
        if word.hasPrefix("@") {
            let ref = String(word.dropFirst())
            guard ref.count > 1, ref.hasPrefix("e"), Int(ref.dropFirst()) != nil else {
                throw CLIError("\(word) isn't a ref; refs look like @e3")
            }
            return (.ref(ref), 1)
        }
        if let point = point(word) { return (point, 1) }
        guard index + 1 < input.words.count, let x = Double(word), let y = Double(input.words[index + 1]) else {
            throw CLIError("\(word) isn't a target: use a ref such as @e3, X Y in points, --label TEXT or --id ID")
        }
        guard x >= 0, y >= 0 else { throw CLIError("X and Y are points from the screen's top left") }
        return (.point(x: x, y: y), 2)
    }

    /// `X,Y` as one word.
    private static func point(_ word: String) -> SimulatorTarget? {
        let parts = word.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]), x >= 0, y >= 0 else { return nil }
        return .point(x: x, y: y)
    }

    private static func expect(_ input: Input, _ count: Int, _ usage: String) throws {
        guard input.words.count == count else { throw CLIError("usage: \(usage)") }
    }

    /// The step `verb` names.
    static func step(_ verb: String, _ input: Input) throws -> SimulatorStep {
        switch verb {
        case "tap":
            let (target, used) = try target(input)
            try expect(input, used, "tap @REF|X Y|--label TEXT|--id ID [--count N] [--hold SECONDS]")
            return .tap(target, count: Int(try input.number("--count", default: 1, 1 ... 10)),
                        hold: try input.number("--hold", default: 0, 0 ... 30))
        case "swipe":
            let (from, used) = try target(Input(words: input.words))
            let (to, more) = try target(Input(words: input.words), at: used)
            try expect(input, used + more, "swipe X1 Y1 X2 Y2 [--duration SECONDS]")
            return .swipe(from: from, to: to, duration: try input.number("--duration", default: 0.3, 0.05 ... 10))
        case "scroll":
            guard let first = input.words.first, let direction = SimulatorDirection(rawValue: first) else {
                throw CLIError("usage: scroll up|down|left|right [@REF] [--distance FRACTION]")
            }
            var within: SimulatorTarget?
            if input.words.count > 1 || input.values["--label"] != nil || input.values["--id"] != nil {
                let (target, used) = try target(input, at: 1)
                try expect(input, 1 + used, "scroll up|down|left|right [@REF|--label TEXT|--id ID] [--distance FRACTION]")
                within = target
            }
            return .scroll(direction, distance: try input.number("--distance", default: 0.5, 0.05 ... 1), within: within)
        case "type":
            try expect(input, 1, "type TEXT")
            return .type(input.words[0])
        case "fill":
            let (target, used) = try target(input)
            try expect(input, used + 1, "fill @REF|--label TEXT|--id ID TEXT")
            return .fill(target, text: input.words[used])
        case "key":
            try expect(input, 1, "key NAME, such as return, backspace, tab, up or cmd+a")
            return .key(input.words[0])
        case "press":
            try expect(input, 1, "press home|back|recents|lock")
            guard let button = SimulatorButton(rawValue: input.words[0]) else {
                throw CLIError("buttons are home, back, recents and lock")
            }
            return .button(button)
        case "wait":
            try expect(input, 1, "wait SECONDS")
            guard let seconds = Double(input.words[0]), (0 ... 60).contains(seconds) else {
                throw CLIError("wait takes seconds from 0 to 60")
            }
            return .wait(seconds: seconds)
        case "wait-for":
            let (target, used) = try target(input)
            try expect(input, used, "wait-for @REF|--label TEXT|--id ID [--gone] [--timeout SECONDS]")
            if case .point = target { throw CLIError("wait-for waits for an element: @REF, --label TEXT or --id ID") }
            return .waitFor(target, gone: input.flags.contains("--gone"), timeout: try input.number("--timeout", default: 5, 0 ... 120))
        case "open":
            try expect(input, 1, "open URL")
            return .openURL(input.words[0])
        case "launch":
            try expect(input, 1, "launch APP")
            return .launch(app: input.words[0])
        case "terminate":
            try expect(input, 1, "terminate APP")
            return .terminate(app: input.words[0])
        case "location":
            try expect(input, 2, "location LATITUDE LONGITUDE")
            guard let latitude = Double(input.words[0]), let longitude = Double(input.words[1]),
                  (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else {
                throw CLIError("location takes a latitude from -90 to 90 and a longitude from -180 to 180")
            }
            return .location(latitude: latitude, longitude: longitude)
        default:
            throw CLIError("unknown step \(verb); steps are \(verbs.joined(separator: ", "))")
        }
    }

    /// One `batch` step, such as `tap @e3` or `type "hello world"`.
    static func parse(_ text: String) throws -> SimulatorStep {
        var tokens = try words(text)
        guard !tokens.isEmpty else { throw CLIError("a batch step is empty") }
        let verb = tokens.removeFirst()
        var input = Input(words: [])
        var iterator = tokens.makeIterator()
        while let token = iterator.next() {
            if values.contains(token) {
                guard let value = iterator.next() else { throw CLIError("missing value for \(token) in \"\(text)\"") }
                input.values[token] = value
            } else if flags.contains(token) {
                input.flags.insert(token)
            } else if token.hasPrefix("--") {
                throw CLIError("unknown option \(token) in \"\(text)\"")
            } else {
                input.words.append(token)
            }
        }
        return try step(verb, input)
    }

    /// Splits a step into words like a shell: spaces separate them, and
    /// single or double quotes keep spaces in one.
    static func words(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if quote != nil { throw CLIError("a quote isn't closed in \"\(text)\"") }
        if started { words.append(current) }
        return words
    }
}

extension CLIArguments {
    /// The words, values and flags a step reads.
    var stepInput: SimulatorSteps.Input {
        SimulatorSteps.Input(words: words, values: values, flags: flags)
    }

    var simulator: String? { value("--simulator") }

    /// A drive of `steps` that settles and reports what changed when asked.
    func drive(_ steps: [SimulatorStep]) -> CLICommand {
        drive(SimulatorDrive(steps: steps, settle: flag("--settle")))
    }

    func drive(_ drive: SimulatorDrive, output: CLISimulatorOutput = CLISimulatorOutput()) -> CLICommand {
        .manage(ManageInvocation(json: json, action: .simulator(.drive(simulator: simulator, drive: drive, output: output))))
    }
}
