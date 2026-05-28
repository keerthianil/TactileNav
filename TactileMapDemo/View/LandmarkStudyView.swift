import SwiftUI
import TactileMapLogging
import TactileMapFeedback

struct LandmarkStudyView: View {
    let condition: StudyCondition
    @StateObject private var vm: MapViewModel
    @Environment(\.dismiss) private var dismiss

    init(condition: StudyCondition) {
        self.condition = condition
        _vm = StateObject(wrappedValue: MapViewModel(condition: condition))
    }

    var body: some View {
        MapCanvasViewV2(document: vm.document, policy: vm.policy)
            .ignoresSafeArea()
            .navigationTitle(condition.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                vm.policy.stopAll()
                vm.logger.endSession()
            }
    }
}
