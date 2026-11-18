//! SliceModel: one plate of the app, over one zs_app of the core.
//!
//! The core slices on its own threads and calls the event function there.
//! The event function only moves the event to the main queue. All calls
//! into the core run on the main thread, as include/zslice-app.h asks.
//!
//! A change of the model or of a setting calls zs_app_request_slice. That
//! stops a slice that runs and starts a new one, so the view always shows
//! the current settings, and the main thread never waits for a slice.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation
import Observation

/// Takes the events of the core from its threads to the main queue. The
/// core holds an unretained pointer to it, and zs_app_free stops the slice
/// before the model releases it.
private final class EventBridge: @unchecked Sendable {
    weak var model: SliceModel?

    func post(_ event: Int32, _ progress: Double, _ status: Int32) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.model?.handle(event: event, progress: progress, status: status) }
        }
    }
}

private func onCoreEvent(user: UnsafeMutableRawPointer?, event: Int32, progress: Double, status: Int32) {
    guard let user else { return }
    Unmanaged<EventBridge>.fromOpaque(user).takeUnretainedValue().post(event, progress, status)
}

/// The text of a status code of the core.
func statusText(_ rc: Int32) -> String {
    String(cString: zs_status_string(rc))
}

@MainActor
@Observable
final class SliceModel {
    enum State: Equatable {
        case empty, ready, slicing, done, failed(String)
    }

    @ObservationIgnored let core: OpaquePointer
    @ObservationIgnored private let bridge: Unmanaged<EventBridge>

    private(set) var name = ""
    private(set) var state = State.empty
    private(set) var progress = 0.0
    private(set) var stats: zs_stats?
    /// Counts the slice results, so a view can load each new one.
    private(set) var resultGeneration = 0

    init() {
        let b = EventBridge()
        bridge = Unmanaged.passRetained(b)
        var app: OpaquePointer?
        let rc = zs_app_new(onCoreEvent, bridge.toOpaque(), &app)
        guard rc == 0, let app else { fatalError("zslice: zs_app_new failed: \(statusText(rc))") }
        core = app
        b.model = self
    }

    isolated deinit {
        zs_app_free(core)
        bridge.release()
    }

    /// Loads an STL or 3MF file, and starts a slice.
    func load(name: String, data: Data) throws {
        let rc = data.withUnsafeBytes { buf in
            zs_app_load_stl(core, name, buf.bindMemory(to: UInt8.self).baseAddress, buf.count)
        }
        guard rc == 0 else { throw CoreError(code: rc) }
        self.name = name
        stats = nil
        state = .ready
        requestSlice()
    }

    func requestSlice() {
        let rc = zs_app_request_slice(core)
        if rc == 0 {
            state = .slicing
            progress = 0
        } else {
            state = .failed(statusText(rc))
        }
    }

    fileprivate func handle(event: Int32, progress: Double, status: Int32) {
        // An event of an old slice can still come: the state of the core
        // decides.
        switch Int(event) {
        case Int(ZS_EVENT_PROGRESS.rawValue):
            if zs_app_state(core) == Int32(ZS_STATE_SLICING.rawValue) { self.progress = progress }
        case Int(ZS_EVENT_SLICED.rawValue):
            guard zs_app_state(core) == Int32(ZS_STATE_DONE.rawValue) else { return }
            var s = zs_stats()
            stats = zs_app_stats(core, &s) == 0 ? s : nil
            state = .done
            self.progress = 1
            resultGeneration += 1
        case Int(ZS_EVENT_FAILED.rawValue):
            if zs_app_state(core) == Int32(ZS_STATE_FAILED.rawValue) { state = .failed(statusText(status)) }
        default:
            break
        }
    }
}

struct CoreError: LocalizedError {
    let code: Int32
    var errorDescription: String? { statusText(code) }
}
