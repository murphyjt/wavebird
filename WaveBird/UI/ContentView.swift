import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: BridgeCoordinator
    @State private var sheetEntryID: String?
    @State private var showSetupSheet = false
    // Live device IDs already in .ready at the moment the setup sheet opens.
    // We auto-dismiss the sheet when a *new* device transitions to .ready, not
    // when one that was already there is re-iterated by SwiftUI.
    @State private var setupSheetBaselineReadyIDs: Set<DeviceID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if coordinator.listEntries.isEmpty {
                emptyState
            } else {
                controllerList
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Set up Game Controller...") { showSetupSheet = true }
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
        .sheet(isPresented: Binding(
            get: { sheetEntryID != nil },
            set: { if !$0 { sheetEntryID = nil } }
        )) {
            if let id = sheetEntryID {
                ControllerDetailSheet(coordinator: coordinator, entryID: id) {
                    sheetEntryID = nil
                }
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            SetupSheet { showSetupSheet = false }
        }
        .sheet(isPresented: Binding(
            get: { coordinator.pairingPrompt != nil },
            set: { if !$0 { coordinator.declinePairing() } }
        )) {
            if let prompt = coordinator.pairingPrompt {
                PairingSheet(coordinator: coordinator, prompt: prompt)
            }
        }
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
    }

    // Stable-orderable snapshot for onChange diffing.
    private var currentReadyIDs: Set<DeviceID> {
        Set(coordinator.devices.compactMap {
            $0.value.connectionState == .ready ? $0.key : nil
        })
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Controllers")
                    .font(.headline)
            }
            Spacer()
            Toggle("Scan for Controllers", isOn: Binding(
                get: { coordinator.isScanning },
                set: { _ in Task { await coordinator.toggleScan() } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var emptyState: some View {
        HStack {
            VStack(spacing: 12) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No controller connected")
                    .font(.headline)
                Text("Hold the SYNC Button on the Nintendo Switch 2 Controller that you'd like to pair.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(width: 384)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    private var controllerList: some View {
        VStack(spacing: 8) {
            ForEach(coordinator.listEntries) { entry in
                if let record = entry.live {
                    LiveControllerRow(record: record, paired: entry.paired) {
                        sheetEntryID = entry.id
                    }
                } else if let paired = entry.paired {
                    OfflineControllerRow(paired: paired) {
                        sheetEntryID = entry.id
                    }
                }
            }
        }
    }
}
