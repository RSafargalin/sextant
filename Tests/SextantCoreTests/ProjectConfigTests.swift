import Foundation
import Testing
@testable import SextantCore

@Suite("Rules path from the config")
struct ConfigRulesPathTests {
    @Test("A relative path resolves against the project root, an absolute one is used as is")
    func rulesPathResolution() {
        // The config key belongs to the project, while an MCP server's working directory is chosen
        // by the client — a relative path would be looked up elsewhere and lint over MCP would fail.
        let relative = ProjectConfig(rules: "rules/hygiene.json")
        #expect(relative.rulesPath(projectRoot: "/repo/app") == "/repo/app/rules/hygiene.json")

        let absolute = ProjectConfig(rules: "/etc/rules.json")
        #expect(absolute.rulesPath(projectRoot: "/repo/app") == "/etc/rules.json")

        #expect(ProjectConfig(rules: nil).rulesPath(projectRoot: "/repo") == nil)
        #expect(ProjectConfig(rules: "").rulesPath(projectRoot: "/repo") == nil)
    }
}
