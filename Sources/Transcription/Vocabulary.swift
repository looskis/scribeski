/// Words the transcriber should expect (DESIGN §3: biasing matters more than model choice).
/// A starting list; P3.4 adds the agency's own terms and the client's name from the form.
public enum Vocabulary {
    public static let `default` = [
        "SNAP", "TANF", "SSI", "SSDI", "CPS", "IEP", "ADLs", "IADLs", "WIC", "Medi-Cal", "Medicaid",
        "PHQ-9", "GAD-7", "HSA", "IHSS", "CalFresh", "Section 8", "SI", "HI",
        "sertraline", "fluoxetine", "trazodone", "quetiapine", "buprenorphine", "naloxone",
    ]
}
