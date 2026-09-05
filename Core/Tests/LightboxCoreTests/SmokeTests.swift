import Testing
import Foundation
import GRDB
@testable import LightboxCore

@Test func packageBuildsAndFTS5IsAvailable() throws {
    let dbq = try DatabaseQueue()
    try dbq.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(body)")
        try db.execute(sql: "INSERT INTO probe (body) VALUES (?)", arguments: ["quarterly invoice"])
    }
    let hits = try dbq.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM probe WHERE probe MATCH ?", arguments: ["invoice"])
    }
    #expect(hits == 1)
    #expect(LightboxCore.version == "0.1.0")
}
