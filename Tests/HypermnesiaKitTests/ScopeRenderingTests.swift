import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Scope Rendering")
struct ScopeRenderingTests {

    private let project = "github.com/acme/scope-test"

    private func node(_ type: MemoryType, _ title: String, _ data: MemoryData,
                      status: MemoryStatus = .confirmed, confidence: Double = 1.0) -> MemoryNode {
        MemoryNode(projectId: project, type: type, status: status, title: title,
                   summary: "s", data: data, confidence: confidence)
    }

    // MARK: - Conventions

    @Test("scoped convention renders Applies-to and Does-NOT-apply-to sub-lines")
    func scopedConventionRendersBothSublines() throws {
        let conv = ConventionData(
            rule: "Require actor_id on data endpoints",
            appliesWhen: "endpoints that read or mutate per-user records",
            excludesWhen: "aggregate or health/stats endpoints"
        )
        let ctx = try #require(MemoryHydrator.format([node(.convention, "Auth rule", .convention(conv))]))
        #expect(ctx.contains("- Require actor_id on data endpoints"))
        #expect(ctx.contains("Applies to: endpoints that read or mutate per-user records"))
        #expect(ctx.contains("Does NOT apply to: aggregate or health/stats endpoints"))
    }

    @Test("convention with only appliesWhen renders only Applies-to sub-line")
    func conventionAppliesWhenOnly() throws {
        let conv = ConventionData(
            rule: "Use tabs for indentation",
            appliesWhen: "all Swift source files"
        )
        let ctx = try #require(MemoryHydrator.format([node(.convention, "Tabs", .convention(conv))]))
        #expect(ctx.contains("Applies to: all Swift source files"))
        #expect(!ctx.contains("Does NOT apply to:"))
    }

    @Test("convention with only excludesWhen renders only Does-NOT-apply-to sub-line")
    func conventionExcludesWhenOnly() throws {
        let conv = ConventionData(
            rule: "Always validate role before write",
            excludesWhen: "idempotent read-only endpoints"
        )
        let ctx = try #require(MemoryHydrator.format([node(.convention, "Role check", .convention(conv))]))
        #expect(!ctx.contains("Applies to:"))
        #expect(ctx.contains("Does NOT apply to: idempotent read-only endpoints"))
    }

    @Test("scopeless convention renders bare rule line — back-compat")
    func scopelessConventionRendersBareLine() throws {
        let conv = ConventionData(rule: "Use tabs")
        let ctx = try #require(MemoryHydrator.format([node(.convention, "Tabs", .convention(conv))]))
        #expect(ctx.contains("- Use tabs"))
        #expect(!ctx.contains("Applies to:"))
        #expect(!ctx.contains("Does NOT apply to:"))
    }

    // MARK: - Concerns

    @Test("scoped concern renders Applies-to and Does-NOT-apply-to sub-lines")
    func scopedConcernRendersBothSublines() throws {
        let concern = ConcernData(
            issue: "JWT stored in localStorage is vulnerable to XSS",
            severity: "high",
            appliesWhen: "browser-based clients storing tokens",
            excludesWhen: "server-side or native clients"
        )
        let ctx = try #require(MemoryHydrator.format([node(.concern, "XSS risk", .concern(concern))]))
        #expect(ctx.contains("Applies to: browser-based clients storing tokens"))
        #expect(ctx.contains("Does NOT apply to: server-side or native clients"))
    }

    @Test("scopeless concern renders bare concern line — back-compat")
    func scopelessConcernRendersBareLine() throws {
        let concern = ConcernData(issue: "N+1 query risk", severity: "medium")
        let ctx = try #require(MemoryHydrator.format([node(.concern, "N+1", .concern(concern))]))
        #expect(ctx.contains("- N+1 [medium]: N+1 query risk"))
        #expect(!ctx.contains("Applies to:"))
        #expect(!ctx.contains("Does NOT apply to:"))
    }
}
