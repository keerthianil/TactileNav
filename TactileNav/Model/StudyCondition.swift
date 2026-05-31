import TactileMapFeedback

// MARK: - Study Condition

enum StudyCondition: String, CaseIterable, Identifiable {
    case practiceNL      = "practiceNL"
    case practiceSpatial = "practiceSpatial"
    case practiceIcons   = "practiceIcons"
    case naturalLanguage = "naturalLanguage"
    case spatialAudio    = "spatialAudio"
    case auditoryIcons   = "auditoryIcons"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .practiceNL:      return "Practice: Natural Language"
        case .practiceSpatial: return "Practice: Spatial Audio"
        case .practiceIcons:   return "Practice: Auditory Icons"
        case .naturalLanguage: return "Condition 1: Natural Language"
        case .spatialAudio:    return "Condition 2: Spatialized Audio"
        case .auditoryIcons:   return "Condition 3: Auditory Icons"
        }
    }

    var mapFileName: String { "demo_building" }

    var shortLogName: String {
        switch self {
        case .practiceNL:      return "PracticeNL"
        case .practiceSpatial: return "PracticeSpatial"
        case .practiceIcons:   return "PracticeIcons"
        case .naturalLanguage: return "NL"
        case .spatialAudio:    return "SpatialAudio"
        case .auditoryIcons:   return "AuditoryIcons"
        }
    }

    @MainActor
    func makeFeedbackPolicy() -> any FeedbackPolicy {
        switch self {
        case .practiceNL, .naturalLanguage:    return NLFeedbackService()
        case .practiceSpatial, .spatialAudio:  return SpatialFeedbackService()
        case .practiceIcons, .auditoryIcons:   return IconsFeedbackService()
        }
    }
}
