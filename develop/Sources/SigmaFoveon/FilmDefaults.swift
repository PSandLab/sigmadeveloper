// film defaults

public extension FilmSimSettings {
    func selecting(film index: Int) -> FilmSimSettings {
        guard FilmSimData.films.indices.contains(index) else { return self }
        var s = self
        s.film = index
        let stock = FilmSimData.films[index]
        let defaults = FilmSimData.stockDefaults[stock.key]

        // Reversal stocks are scanned as positives; negatives print on their companion paper
        s.negative = stock.isPositive
        if let paper = defaults?.paper,
           let match = FilmSimData.papers.first(where: { $0.key == paper }) {
            s.paper = match.index
        }

        // Halation reflects the stock's anti-halation layer: weak layers (the
        // consumer C41 stocks) show the classic red glow; strong layers and
        // remjet-backed cine stocks stay clean.
        let fresh = FilmSimSettings()   // model defaults
        s.halation = defaults?.halation ?? false
        s.halationStrength = defaults?.halationStrength ?? fresh.halationStrength

        // Stock-independent process trims return to their defaults; the new
        // film×paper pair re-derives its neutral balance via the nil defaults.
        s.couplers = fresh.couplers
        s.couplersRadius = fresh.couplersRadius
        s.grain = fresh.grain
        s.grainSize = fresh.grainSize
        s.grainUniformity = fresh.grainUniformity
        s.halationRadius = fresh.halationRadius
        s.halationMidtones = fresh.halationMidtones
        s.evPaper = nil
        s.filterC = nil
        s.filterM = nil
        s.filterY = nil
        return s
    }
}

extension FilmSimData {
    /// What selecting a stock implies, keyed by stock key. `paper` is the
    /// spektrafilm `target_print`; `halation` follows `antihalation` (weak →
    /// visible glow, strong/remjet → clean).
    struct StockDefaults {
        let paper: String?
        let halation: Bool
        let halationStrength: Float
    }

    static let stockDefaults: [String: StockDefaults] = {
        let endura = "kodak_portra_endura"
        let crystal = "fujifilm_crystal_archive_typeii"
        let cine = "kodak_2383"
        func clean(_ paper: String?) -> StockDefaults {
            StockDefaults(paper: paper, halation: false, halationStrength: 0.35)
        }
        func glowy(_ paper: String?) -> StockDefaults {
            StockDefaults(paper: paper, halation: true, halationStrength: 0.5)
        }
        return [
            "kodak_ektar_100": clean(endura),
            "kodak_portra_160": clean(endura),
            "kodak_portra_400": clean(endura),
            "kodak_portra_800": clean(endura),
            "kodak_portra_800_push1": clean(endura),
            "kodak_portra_800_push2": clean(endura),
            "kodak_gold_200": glowy(endura),
            "kodak_ultramax_400": glowy(endura),
            "kodak_vision3_50d": clean(cine),
            "kodak_vision3_250d": clean(cine),
            "kodak_vision3_200t": clean(cine),
            "kodak_vision3_500t": clean(cine),
            "kodak_verita_200d": clean(cine),
            "fujifilm_pro_400h": clean(crystal),
            "fujifilm_xtra_400": glowy(crystal),
            "fujifilm_c200": glowy(crystal),
            "kodak_ektachrome_100": clean(nil),
            "kodak_kodachrome_64": glowy(nil),
            "fujifilm_provia_100f": clean(nil),
            "fujifilm_velvia_100": clean(nil),
        ]
    }()
}
