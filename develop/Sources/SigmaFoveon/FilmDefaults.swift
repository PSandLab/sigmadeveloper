// film defaults

public extension FilmSimSettings {
    func selecting(film index: Int) -> FilmSimSettings {
        guard FilmSimData.films.indices.contains(index) else { return self }
        var s = self
        s.film = index
        let stock = FilmSimData.films[index]

        // Reversal stocks are scanned as positives; negatives print on companion paper
        s.negative = stock.isPositive
        if let key = stock.targetPaperKey,
           let match = FilmSimData.papers.first(where: { $0.key == key }) {
            s.paper = match.index
        }

        let fresh = FilmSimSettings()   // model defaults

        // stock anti-halation layer class: weak layers
        s.halation = stock.antihalation != .strong
        s.halationStrength = stock.antihalation.defaultHalationStrength
        s.halationColor = nil           // class default, resolved in kernelParams

        // Reversal (E-6/K-14) development has a much weaker interimage/DIR effect
        // than C-41; spektrafilm's positive-family inhibition gammas run ≈ 0.36×
        // the negative ones, so scale the model default accordingly?
        s.couplers = stock.isPositive ? fresh.couplers * 0.36 : fresh.couplers

        // Stock-independent process trims return to their defaults; the new
        // film×paper pair re-derives its neutral balance via the nil defaults.
        s.couplersRadius = fresh.couplersRadius
        s.grain = fresh.grain
        s.grainSize = fresh.grainSize
        s.grainUniformity = fresh.grainUniformity
        s.grainAmount = fresh.grainAmount
        s.grainSaturation = fresh.grainSaturation
        s.halationRadius = fresh.halationRadius
        s.halationMidtones = fresh.halationMidtones
        s.evPaper = nil
        s.filterC = nil
        s.filterM = nil
        s.filterY = nil
        return s
    }
}

public extension Antihalation {
    /// Per-channel halo strength for the kernel
    var halationColor: SIMD3<Float> {
        switch self {
        case .strong: return SIMD3(0.8, 0.267, 0)
        case .weak:   return SIMD3(0.8, 0.2, 0)
        case .no:     return SIMD3(0.8, 0.267, 0.04)
        }
    }

    /// Default halo scale
    var defaultHalationStrength: Float {
        switch self {
        case .strong: return 0.09
        case .weak:   return 0.5
        case .no:     return 1.9
        }
    }
}
