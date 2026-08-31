import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: BridgeCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showSetupSheet = false
    // Live device IDs already in .ready at the moment the setup sheet opens.
    // We auto-dismiss the sheet when a *new* device transitions to .ready, not
    // when one that was already there is re-iterated by SwiftUI.
    @State private var setupSheetBaselineReadyIDs: Set<DeviceID> = []
    @State private var forgetConfirmation: ForgetConfirmation?

    private struct ForgetConfirmation: Identifiable {
        let serial: String
        let displayName: String
        var id: String { serial }
    }

    // Split into `presentation` plus the reaction chain below: as one
    // expression this exceeded the Swift type-checker's time limit on a clean
    // Release build. It type-checked fine incrementally, so it only ever
    // failed in CI. Keep them separate.
    var body: some View {
        presentation
        .onChange(of: showSetupSheet) { _, isOpen in
            if isOpen {
                setupSheetBaselineReadyIDs = Set(coordinator.devices.compactMap {
                    $0.value.connectionState == .ready ? $0.key : nil
                })
            } else {
                setupSheetBaselineReadyIDs = []
            }
        }
        .onChange(of: currentReadyIDs) { _, nowReady in
            // A device readied while the setup sheet is open — handoff.
            guard showSetupSheet else { return }
            if !nowReady.subtracting(setupSheetBaselineReadyIDs).isEmpty {
                showSetupSheet = false
            }
        }
        // Bring the app forward when a profile picker needs answering. The
        // LTK-pair sheet never triggers foregrounding under profile-first
        // ordering: it always fires after a VHID is built, so the user has
        // either just engaged with the picker or the controller is known
        // (and we want the sheet to sit quietly in the background).
        // ignoringOtherApps: true is required — macOS 14+'s parameterless
        // activate() is treated as a "cooperative" request that won't
        // override the frontmost app for a background-triggered event like
        // a controller connecting. We also openWindow("main") so the sheet
        // has a host if the user previously closed the window.
        .onChange(of: coordinator.awaitingProfileSelectionID) { _, newID in
            guard newID != nil else { return }
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        // Accessory mode (Hide dock icon) suppresses the Window scene's
        // ability to host a sheet — the prompt would sit invisibly and
        // time out. Flip back to .regular while any prompt is up, then
        // restore the user's preference when everything closes.
        .onChange(of: coordinator.hasActivePrompt) { _, hasPrompt in
            if hasPrompt {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
            } else {
                let hideDock = UserDefaults.standard.bool(forKey: "WaveBird.hideDockIcon")
                NSApp.setActivationPolicy(hideDock ? .accessory : .regular)
            }
        }
        // 10 s timer for the Joy-Con partner sheet. The key string re-keys
        // when either the waiting Joy-Con or the covering LTK sheet changes,
        // so the timer only counts down once the partner sheet is actually
        // on screen.
        .task(id: partnerSheetTimerKey) {
            guard coordinator.joyConWaitingForPartnerID != nil,
                  coordinator.pairingPrompt == nil else { return }
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { return }
            if coordinator.joyConWaitingForPartnerID != nil,
               coordinator.pairingPrompt == nil {
                coordinator.acknowledgeJoyConWaitingForPartner()
            }
        }
        // 30 s timer for the LTK-pair sheet. Times out without recording a
        // decline so the controller's next .ready can re-prompt.
        .task(id: coordinator.pairingPrompt?.deviceID) {
            guard coordinator.pairingPrompt != nil else { return }
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { return }
            if coordinator.pairingPrompt != nil {
                coordinator.timeoutPairingPrompt()
            }
        }
    }

    // The view proper: content plus the sheets and alerts it presents.
    private var presentation: some View {
        VStack(spacing: 8) {
            if let reason = coordinator.transportUnavailableReason {
                transportBanner(reason)
                    .padding(.horizontal, 20)
            }
            if let issue = coordinator.hidAccessIssue {
                HIDAccessBanner(issue: issue)
                    .padding(.horizontal, 20)
            }
            if coordinator.listEntries.isEmpty {
                emptyState
            } else {
                controllerList
            }
        }
        .frame(minWidth: 480, minHeight: 280, maxHeight: 420)
        .toolbar {
            if coordinator.hasUnpairedJoyCon {
                ToolbarItem(placement: .primaryAction) {
                    Button("Pair Joy-Cons") {
                        Task { await coordinator.pairJoyCons() }
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Profiles…") { openWindow(id: "profiles") }

                Button {
                    showSetupSheet = true
                } label: {
                    Label("Set up Game Controller", systemImage: "plus")
                }
                .help("Set up Game Controller…")
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            SetupSheet { showSetupSheet = false }
        }
        .alert(
            "Are you sure you want to forget \u{201C}\(forgetConfirmation?.displayName ?? "")\u{201D}?",
            isPresented: Binding(
                get: { forgetConfirmation != nil },
                set: { if !$0 { forgetConfirmation = nil } }
            ),
            presenting: forgetConfirmation
        ) { confirm in
            Button("Forget", role: .destructive) {
                let serial = confirm.serial
                forgetConfirmation = nil
                Task { @MainActor in
                    await coordinator.forgetController(serial: serial)
                }
            }
            Button("Cancel", role: .cancel) { forgetConfirmation = nil }
        } message: { _ in
            Text("This device will not reconnect automatically. You will have to connect it again if you want to use it later.")
        }
        .sheet(isPresented: Binding(
            get: { coordinator.pairingPrompt != nil },
            set: { if !$0 { coordinator.declinePairing() } }
        )) {
            if let prompt = coordinator.pairingPrompt {
                PairingSheet(coordinator: coordinator, prompt: prompt)
            }
        }
        .sheet(item: Binding(
            get: { coordinator.awaitingProfileSelectionID },
            set: { newValue in
                if newValue == nil { Task { await coordinator.dismissProfilePicker() } }
            }
        )) { id in
            ProfilePickerSheet(coordinator: coordinator, deviceID: id)
        }
        .sheet(item: Binding(
            get: { coordinator.joyConWaitingForPartnerID },
            set: { newValue in
                // Sheet dismissed → clear the waiting marker. The next .ready
                // for either Joy-Con will re-arm it.
                if newValue == nil { coordinator.acknowledgeJoyConWaitingForPartner() }
            }
        )) { id in
            JoyConPartnerSheet(
                coordinator: coordinator,
                connectedSide: coordinator.devices[id].map { record in
                    JoyConPairProfile.isLeft(productID: record.advertisement.productID) ? .left : .right
                } ?? .left
            ) {
                coordinator.acknowledgeJoyConWaitingForPartner()
            }
        }
    }

    // Composite re-key for the partner-sheet timer's .task(id:). DeviceID? +
    // Bool inside a String avoids hand-rolling Hashable on a synthesised key.
    private var partnerSheetTimerKey: String {
        let waiting = coordinator.joyConWaitingForPartnerID?.raw.uuidString ?? "none"
        let ltk = coordinator.pairingPrompt != nil ? "ltk" : "clear"
        return "\(waiting)|\(ltk)"
    }

    private func openDetail(for id: String) {
        openWindow(id: "controller-detail", value: id)
    }

    // Stable-orderable snapshot for onChange diffing.
    private var currentReadyIDs: Set<DeviceID> {
        Set(coordinator.devices.compactMap {
            $0.value.connectionState == .ready ? $0.key : nil
        })
    }

    private func transportBanner(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Controller Connected", systemImage: "gamecontroller")
        } description: {
            Text("Hold the SYNC Button on the Nintendo Switch 2 Controller that you'd like to pair.")
        }
    }

    private var controllerList: some View {
        Form {
            Section("Controllers") {
                ForEach(coordinator.listEntries) { entry in
                    if let record = entry.live {
                        let pair = coordinator.joyConPair
                        let isPairLeft = pair?.leftID == record.id
                        LiveControllerRow(
                            record: record,
                            paired: entry.paired,
                            isVHIDActive: entry.vhidActive,
                            displayNameOverride: isPairLeft ? coordinator.listDisplayName(for: entry) : nil,
                            vhidActiveOverride: isPairLeft ? coordinator.joyConPairVHIDActive : nil,
                            onSplit: isPairLeft ? {
                                Task { await coordinator.splitJoyConPair() }
                                // The detail window keys off this entry's L serial.
                                // After split it would re-resolve as a solo L row;
                                // closing matches the explicit-split UX in the
                                // detail sheet's own Split button.
                                dismissWindow(id: "controller-detail")
                            } : nil,
                            onSelect: { openDetail(for: entry.id) },
                            onDisconnect: { Task { await coordinator.disconnectController(record.id) } },
                            onForget: isPairLeft ? nil : entry.serial.map { serial in
                                {
                                    forgetConfirmation = ForgetConfirmation(
                                        serial: serial,
                                        displayName: coordinator.listDisplayName(for: entry)
                                    )
                                }
                            }
                        )
                    } else if let paired = entry.paired {
                        OfflineControllerRow(
                            paired: paired,
                            onSelect: { openDetail(for: entry.id) },
                            onForget: {
                                forgetConfirmation = ForgetConfirmation(
                                    serial: paired.serial,
                                    displayName: paired.displayName
                                )
                            }
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
