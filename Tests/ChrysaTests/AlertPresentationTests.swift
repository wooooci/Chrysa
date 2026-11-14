import AppKit
import SwiftUI
import Testing
import ChrysaCore
import ChrysaApplication
import ChrysaAdapters
@testable import ChrysaPresentation

struct AlertPresentationTests {
    @MainActor
    @Test
    func optionalBindingIsPresentClearsValueOnDismiss() {
        var value: String? = nil
        let optionalBinding = Binding<String?>(
            get: { value },
            set: { value = $0 }
        )
        let flag = optionalBinding.isPresent()

        #expect(!flag.wrappedValue)

        value = "pending"
        #expect(flag.wrappedValue)

        flag.wrappedValue = true
        #expect(value == "pending")

        flag.wrappedValue = false
        #expect(value == nil)
        #expect(!flag.wrappedValue)
    }

    @MainActor
    @Test
    func mainViewLaunchErrorAlertPresentsAndDismisses() async {
        _ = NSApplication.shared

        let vm = StudioViewModel(
            inMemoryOnly: true,
            settingsStore: AppSettingsStore(inMemoryOnly: true),
            taskStore: TaskStore(inMemoryOnly: true),
            coordinator: PipelineCoordinator(
                services: DefaultWorkflowServices(),
                jobStore: JobStore(inMemoryOnly: true)
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 860, height: 580),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: ThingsStudioMainView(vm: vm, isSnapshotMode: false))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let rendered = await pumpMainRunLoop(until: { window.contentView?.fittingSize != .zero }, timeout: 1.0)
        #expect(rendered)

        vm.launchErrorAlert = StudioViewModel.LaunchErrorNotice(
            title: "Pentiment",
            message: "无法定位可执行文件"
        )

        let presented = await pumpMainRunLoop(until: { window.attachedSheet != nil }, timeout: 2.0)
        #expect(presented)

        if let sheetContent = window.attachedSheet?.contentView {
            let texts = collectTextValues(in: sheetContent)
            #expect(texts.contains("无法启动「Pentiment」"))
            #expect(texts.contains("无法定位可执行文件"))

            let okButton = collectButtons(in: sheetContent).first { $0.title == "好" }
            #expect(okButton != nil)
            okButton?.performClick(nil)
        }

        let dismissed = await pumpMainRunLoop(
            until: { window.attachedSheet == nil && vm.launchErrorAlert == nil },
            timeout: 2.0
        )
        #expect(dismissed)
    }

    @MainActor
    private func pumpMainRunLoop(until condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private func collectButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let button = view as? NSButton {
            result.append(button)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectButtons(in: subview))
        }
        return result
    }

    @MainActor
    private func collectTextValues(in view: NSView) -> [String] {
        var result: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            result.append(field.stringValue)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectTextValues(in: subview))
        }
        return result
    }
}
