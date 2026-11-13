import ChrysaApplication
import ChrysaAdapters
import ChrysaPresentation

@MainActor
enum AppComposition {
    static func makeViewModel(
        seedDemoData: Bool = false,
        inMemoryOnly: Bool = false,
        settingsStore: AppSettingsStore? = nil,
        taskStore: TaskStore? = nil,
        coordinator: PipelineCoordinator? = nil
    ) -> StudioViewModel {
        let ephemeral = seedDemoData || inMemoryOnly
        return StudioViewModel(
            seedDemoData: seedDemoData,
            inMemoryOnly: inMemoryOnly,
            settingsStore: settingsStore ?? AppSettingsStore(inMemoryOnly: ephemeral),
            taskStore: taskStore ?? TaskStore(inMemoryOnly: ephemeral),
            coordinator: coordinator ?? PipelineCoordinator(
                services: DefaultWorkflowServices(),
                jobStore: JobStore(inMemoryOnly: ephemeral),
                gameLibrary: LaunchGameStore(inMemoryOnly: ephemeral)
            )
        )
    }
}
