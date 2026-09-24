import ScribeskiCore

/// Scores computed in code from extracted items. The model never does clinical arithmetic.
///
/// Values are strings, as the page stores them. A derivation returns nil unless **every**
/// input is filled with an integer: a partial PHQ-9 has no total.
public enum Derivations {
    public static let known: Set<String> = ["phq9_total", "phq9_band", "gad7_total", "gad7_band"]

    /// Computes `function` over `inputs`, reading each input's value from `values`.
    ///
    /// Inputs may be the items themselves or, for a band, a single total that was derived
    /// first; either way the band is taken from the sum.
    public static func compute(_ function: String, inputs: [String], values: [String: FieldValue]) -> String? {
        guard let total = sum(inputs, values) else { return nil }
        switch function {
        case "phq9_total", "gad7_total": return String(total)
        case "phq9_band": return phq9Band(total)
        case "gad7_band": return gad7Band(total)
        default: return nil
        }
    }

    public static func compute(_ derivation: FormMapping.Derivation, values: [String: FieldValue]) -> String? {
        compute(derivation.function, inputs: derivation.inputs, values: values)
    }

    static func sum(_ inputs: [String], _ values: [String: FieldValue]) -> Int? {
        guard !inputs.isEmpty else { return nil }
        var total = 0
        for key in inputs {
            guard case .single(let s)? = values[key],
                  let n = Int(s.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
            total += n
        }
        return total
    }

    /// MINIMAL 0–4, MILD 5–9, MODERATE 10–14, MODERATELY_SEVERE 15–19, SEVERE 20–27.
    public static func phq9Band(_ total: Int) -> String? {
        switch total {
        case 0...4: "MINIMAL"
        case 5...9: "MILD"
        case 10...14: "MODERATE"
        case 15...19: "MODERATELY_SEVERE"
        case 20...27: "SEVERE"
        default: nil
        }
    }

    /// MINIMAL 0–4, MILD 5–9, MODERATE 10–14, SEVERE 15–21.
    public static func gad7Band(_ total: Int) -> String? {
        switch total {
        case 0...4: "MINIMAL"
        case 5...9: "MILD"
        case 10...14: "MODERATE"
        case 15...21: "SEVERE"
        default: nil
        }
    }
}
