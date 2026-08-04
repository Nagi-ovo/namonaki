import Foundation
import Testing
@testable import Namonaki

struct DanmakuLengthPolicyTests {
    @Test func retriesOnlyShorterProbeLimits() {
        #expect(DanmakuLengthPolicy.advertisedLimit == 60)
        #expect(DanmakuLengthPolicy.retryLimits(afterRejectedLength: 100) == [60, 50, 40, 30, 20])
        #expect(DanmakuLengthPolicy.retryLimits(afterRejectedLength: 60) == [50, 40, 30, 20])
        #expect(DanmakuLengthPolicy.retryLimits(afterRejectedLength: 50) == [40, 30, 20])
        #expect(DanmakuLengthPolicy.retryLimits(afterRejectedLength: 40) == [30, 20])
        #expect(DanmakuLengthPolicy.retryLimits(afterRejectedLength: 30) == [20])
        #expect(DanmakuLengthPolicy.retryLimits(afterRejectedLength: 20).isEmpty)
    }

    @Test func truncatesByVisibleCharacters() {
        let text = "甲👨‍👩‍👧‍👦乙丙"

        #expect(DanmakuLengthPolicy.truncate(text, to: 3) == "甲👨‍👩‍👧‍👦乙")
        #expect(DanmakuLengthPolicy.truncate(text, to: 10) == text)
    }

    @Test func usesDetectedLimitForLaterMessages() {
        let text = String(repeating: "字", count: 50)

        #expect(DanmakuLengthPolicy.firstAttempt(text, detectedLimit: nil).count == 50)
        #expect(DanmakuLengthPolicy.firstAttempt(text, detectedLimit: 30).count == 30)
    }

    @Test func persistsLimitsPerAccount() {
        let suite = "DanmakuLimitStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DanmakuLimitStore(defaults: defaults)

        #expect(store.activate(uid: 101) == nil)
        store.save(limit: 40, uid: 101)
        #expect(DanmakuLimitStore(defaults: defaults).currentLimit == 40)

        #expect(store.activate(uid: 202) == nil)
        store.save(limit: 30, uid: 202)
        #expect(store.activate(uid: 101) == 40)
        #expect(store.activate(uid: 202) == 30)
    }

    @Test func migratesCurrentLimitWhenUIDWasNotKnownYet() {
        let suite = "DanmakuLimitStoreMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DanmakuLimitStore(defaults: defaults)

        store.save(limit: 40, uid: nil)
        #expect(store.activate(uid: 101) == 40)

        store.clearCurrentAccount()
        #expect(store.currentLimit == nil)
        #expect(store.currentUID == nil)
        #expect(store.activate(uid: 101) == 40)
    }
}
