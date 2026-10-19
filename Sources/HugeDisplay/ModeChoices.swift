import HugeDisplayCore

/// A logical resolution the user can pick. Identity is (width, height, HiDPI); `isNative`
/// is presentation only and deliberately excluded from equality.
struct ResolutionChoice: Hashable, Identifiable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    var isNative: Bool = false

    var id: String { "\(width)x\(height)-\(isHiDPI ? "hi" : "lo")" }

    var title: String {
        var s = "\(width) × \(height)"
        if isHiDPI { s += " · HiDPI" }
        if isNative { s += " · Native" }
        return s
    }

    init(width: Int, height: Int, isHiDPI: Bool, isNative: Bool = false) {
        self.width = width
        self.height = height
        self.isHiDPI = isHiDPI
        self.isNative = isNative
    }

    init(_ mode: DisplayModeOption) {
        self.init(width: mode.width, height: mode.height, isHiDPI: mode.isHiDPI, isNative: mode.isNative)
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Derives resolution / refresh-rate pickers from the flat mode list the Modes service returns.
enum ModeChoices {
    /// Unique resolutions in the service's order (largest first). Includes `current` if the
    /// service list omits it so the picker always has a valid selection.
    static func resolutions(from modes: [DisplayModeOption], current: DisplayModeOption?) -> [ResolutionChoice] {
        var result: [ResolutionChoice] = []
        var index: [ResolutionChoice: Int] = [:]
        for mode in modes {
            let choice = ResolutionChoice(mode)
            if let i = index[choice] {
                if mode.isNative { result[i].isNative = true }
            } else {
                index[choice] = result.count
                result.append(choice)
            }
        }
        if let current {
            let choice = ResolutionChoice(current)
            if index[choice] == nil { result.append(choice) }
        }
        return result
    }

    /// Modes for one resolution, one per distinct refresh rate, highest first.
    static func rates(in modes: [DisplayModeOption], for choice: ResolutionChoice) -> [DisplayModeOption] {
        var seen = Set<Int>()
        return modes
            .filter { ResolutionChoice($0) == choice }
            .sorted { $0.refreshRate > $1.refreshRate }
            .filter { seen.insert(rateKey($0.refreshRate)).inserted }
    }

    /// Best mode for a newly chosen resolution: keep the current refresh rate when possible.
    static func mode(for choice: ResolutionChoice, preferredRate: Double?, in modes: [DisplayModeOption]) -> DisplayModeOption? {
        let options = rates(in: modes, for: choice)
        if let preferredRate, let match = options.first(where: { rateKey($0.refreshRate) == rateKey(preferredRate) }) {
            return match
        }
        return options.first
    }

    static func rateKey(_ rate: Double) -> Int { Int((rate * 100).rounded()) }

    static func rateLabel(_ rate: Double) -> String {
        if rate <= 0 { return "Default" }
        if abs(rate - rate.rounded()) < 0.05 { return "\(Int(rate.rounded())) Hz" }
        return String(format: "%.2f Hz", rate)
    }
}
