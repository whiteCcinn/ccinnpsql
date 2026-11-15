import Foundation
import PostgresKit
import PostgresWire
import Testing

extension IT {
    static func client(_ version: String, poolingMode: PoolingMode = .auto) async throws -> PostgresClient {
        try await PostgresClient.connect(configuration(version), poolSize: 4, poolingMode: poolingMode)
    }
}

@Suite("Metadata integration", .enabled(if: IT.enabled), .serialized)
struct MetadataIntegrationTests {
    @Test(arguments: IT.versions)
    func serverFactsAndCatalog(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        let info = client.serverInfo
        #expect(info.version.majorRelease == version)
        #expect(info.pooler == .none)
        #expect(info.poolingMode == .direct)
        #expect(info.isSuperuser)
        #expect(info.node != nil)
        #expect(info.extensionNamed("pg_stat_statements") != nil)

        let databases = try await client.databases()
        #expect(databases.contains { $0.name == "ccinn" && ($0.sizeBytes ?? 0) > 0 })
        let schemas = try await client.schemas()
        #expect(schemas.contains { $0.name == "shop" && $0.comment == "Demo storefront" })
        #expect(schemas.first { $0.name == "pg_catalog" }?.isSystem == true)

        let contents = try await client.schemaContents("shop")
        let names = Set(contents.relations.map(\.name))
        #expect(names.isSuperset(of: ["customers", "orders", "order_items", "products", "events", "events_archive", "paid_orders",
                                      "daily_revenue", "top_products", "invoice_numbers"]))
        #expect(contents.relations.first { $0.name == "paid_orders" }?.kind == .view)
        #expect(contents.relations.first { $0.name == "daily_revenue" }?.kind == .materializedView)
        #expect(contents.relations.first { $0.name == "invoice_numbers" }?.kind == .sequence)
        #expect(contents.routines.contains { $0.name == "order_total" && $0.arguments == "p_order bigint" && $0.volatility == "s" })
        #expect(contents.types.contains { $0.name == "order_status" && $0.kind == .enumeration })
        #expect(contents.types.contains { $0.name == "email" && $0.kind == .domain })
        #expect(contents.types.contains { $0.name == "money_amount" && $0.kind == .composite })
        // Inheritance child nested under its parent.
        let events = contents.tree.first { $0.relation.name == "events" }
        #expect(events?.children.map(\.relation.name) == ["events_archive"])

        if client.serverInfo.version.atLeast(10) {
            let measurements = try #require(contents.tree.first { $0.relation.name == "measurements" })
            #expect(measurements.relation.kind == .partitionedTable)
            #expect(measurements.children.map(\.relation.name) == ["measurements_2025", "measurements_2026", "measurements_2027"])
            #expect(measurements.children.first?.relation.partitionBound?.contains("FOR VALUES FROM") == true)
            #expect((contents.relations.first { $0.name == "measurements" }?.totalBytes ?? 0) > 0) // sum of partitions
            #expect(!contents.tree.contains { $0.relation.name == "measurements_2025" })
        }
        if client.serverInfo.version.atLeast(11) {
            #expect(contents.routines.contains { $0.name == "archive_events" && $0.kind == .procedure })
        }
        let extensions = try await client.extensions()
        #expect(extensions.contains { $0.name == "pg_stat_statements" && $0.isInstalled })
    }

    @Test(arguments: IT.versions)
    func tableInsights(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        let contents = try await client.schemaContents("shop")
        let customers = try #require(contents.relations.first { $0.name == "customers" })
        let columns = try await client.columns(of: customers)
        #expect(columns.map(\.name) == ["id", "email", "name", "country", "created_at"])
        #expect(columns.first?.defaultExpression?.contains("nextval") == true)
        #expect(columns[1].comment == "Login e-mail")
        #expect(columns[1].averageWidth != nil) // ANALYZE ran

        let constraints = try await client.constraints(of: customers)
        #expect(constraints.contains { $0.kind == .primaryKey && $0.definition == "PRIMARY KEY (id)" })
        #expect(constraints.contains { $0.kind == .unique })

        let products = try #require(contents.relations.first { $0.name == "products" })
        let indexes = try await client.indexes(of: products)
        #expect(indexes.contains { $0.name == "products_sku_key" && $0.isUnique && $0.columnNumbers == [0] })
        #expect(indexes.first { $0.name == "products_unused_idx" }?.isUnused == true)
        #expect(indexes.first { $0.name == "products_pkey" }?.isPrimary == true)
        #expect(indexes.first { $0.name == "products_title_idx" }?.bloat != nil)

        let triggers = try await client.triggers(of: customers)
        #expect(triggers.first?.name == "customers_touch")

        let statistics = try await client.statistics(of: products)
        #expect((statistics.heapBytes ?? 0) > 0)
        #expect(statistics.deadTuples != nil)
        #expect((statistics.updated ?? 0) > 0)
        #expect(statistics.bloat != nil)
        #expect(statistics.transactionIDAge != nil)

        let orders = try #require(contents.relations.first { $0.name == "orders" })
        let ddl = try await client.ddl(for: orders)
        #expect(ddl.contains("CREATE TABLE shop.orders ("))
        #expect(ddl.contains("REFERENCES shop.customers(id) ON DELETE CASCADE") || ddl.contains("REFERENCES customers(id) ON DELETE CASCADE"))
        #expect(ddl.contains("CREATE INDEX orders_customer_idx"))

        let view = try #require(contents.relations.first { $0.name == "paid_orders" })
        #expect(try await client.ddl(for: view).hasPrefix("CREATE OR REPLACE VIEW shop.paid_orders AS"))

        let daily = try #require(contents.relations.first { $0.name == "daily_revenue" })
        let mv = try await client.materializedViewInfo(daily)
        #expect(mv.isPopulated && mv.hasUniqueIndex && mv.concurrentRefreshBlocker == nil)
        try await client.refreshMaterializedView(daily, concurrently: true)
        let top = try #require(contents.relations.first { $0.name == "top_products" })
        #expect(try await client.materializedViewInfo(top).concurrentRefreshBlocker != nil)

        let sequence = try #require(contents.relations.first { $0.name == "invoice_numbers" })
        let info = try await client.sequenceInfo(sequence)
        #expect(info.lastValue == 1900)
        #expect(info.isNearlyExhausted)
        #expect(try await client.ddl(for: sequence).contains("INCREMENT BY 10"))

        let routine = try #require(contents.routines.first { $0.name == "order_total" })
        #expect(try await client.functionDetail(routine).definition?.contains("CREATE OR REPLACE FUNCTION shop.order_total") == true)
        let status = try #require(contents.types.first { $0.name == "order_status" })
        #expect(try await client.typeDetail(status).enumLabels == ["new", "paid", "shipped", "cancelled"])
        let email = try #require(contents.types.first { $0.name == "email" })
        #expect(try await client.typeDetail(email).baseType == "text")
        // Review finding 6: range types open on every version (pg_range.rngmultitypid is PostgreSQL 14+).
        _ = try await client.simpleQuery("DROP TYPE IF EXISTS public.ccinnpsql_it_range; CREATE TYPE public.ccinnpsql_it_range AS RANGE (subtype = numeric)")
        let range = try #require(try await client.schemaContents("public").types.first { $0.name == "ccinnpsql_it_range" })
        #expect(try await client.typeDetail(range).baseType == "numeric")
        _ = try await client.simpleQuery("DROP TYPE public.ccinnpsql_it_range")
        #expect(try await client.grants(of: customers).contains { $0.grantee == "ccinn" && $0.privilege == "SELECT" })

        let preview = try await client.preview(orders, limit: 5)
        #expect(preview.lastRowSet?.rows.count == 5)
        #expect(preview.lastRowSet?.columns.first { $0.name == "status" }?.typeName == "order_status")

        if client.serverInfo.version.atLeast(10) {
            let measurements = try #require(contents.relations.first { $0.name == "measurements" })
            let partitioning = try await client.partitioning(of: measurements)
            #expect(partitioning.partitionKey == "RANGE (recorded_at)")
            #expect(partitioning.children.count == 3)
            let partitionedDDL = try await client.ddl(for: measurements)
            #expect(partitionedDDL.contains("PARTITION BY RANGE (recorded_at)"))
            let child = try #require(contents.relations.first { $0.name == "measurements_2026" })
            #expect(try await client.ddl(for: child).contains("PARTITION OF shop.measurements"))
        }
    }

    @Test(arguments: IT.versions)
    func operations(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        // A lock wait: A holds a row lock, B and C wait for it.
        let holder = try await IT.connect(version)
        let waiterB = try await IT.connect(version)
        let waiterC = try await IT.connect(version)
        _ = try await holder.simpleQuery("BEGIN; UPDATE shop.customers SET country = 'MY' WHERE id = 1")
        let b = Task { try await waiterB.simpleQuery("UPDATE shop.customers SET country = 'SG' WHERE id = 1") }
        let c = Task { try await waiterC.simpleQuery("UPDATE shop.customers SET country = 'JP' WHERE id = 1") }
        try await Task.sleep(for: .milliseconds(700))

        let snapshot = try await client.activity()
        #expect(snapshot.node != nil)
        let holderPID = try #require(holder.backendKey?.processID)
        let tree = BlockingTree.build(snapshot.sessions)
        let root = try #require(tree.first { $0.session.pid == holderPID })
        #expect(root.blockedCount >= 2)
        #expect(snapshot.sessions.first { $0.pid == waiterB.backendKey?.processID }?.isWaitingOnLock == true)

        let locks = try await client.locks()
        #expect(locks.contains { !$0.granted && $0.pid == waiterB.backendKey?.processID })

        // Guarded terminate on the right node; a wrong fingerprint signals nothing.
        let wrong = NodeFingerprint(postmasterStartMicros: 1, serverAddress: "", serverPort: 0)
        await #expect(throws: PostgresError.self) { _ = try await client.terminateBackend(holderPID, observedOn: wrong) }
        #expect(try await client.terminateBackend(holderPID, observedOn: snapshot.node))
        _ = try await b.value
        _ = try await c.value
        await waiterB.close()
        await waiterC.close()
        await holder.close()

        let slotName = "ccinnpsql_it_slot"
        _ = try? await client.query("SELECT pg_drop_replication_slot($1)", [.text(slotName)])
        _ = try await client.query("SELECT pg_create_logical_replication_slot($1, 'test_decoding')", [.text(slotName)])
        let replication = try await client.replication()
        #expect(replication.isInRecovery == false)
        #expect(replication.currentLSN != nil)
        #expect(replication.slots.contains { $0.name == slotName && !$0.isActive && $0.isRisky })
        _ = try await client.query("SELECT pg_drop_replication_slot($1)", [.text(slotName)])

        _ = try await client.progress()
        let (availability, statements) = try await client.topStatements(limit: 10)
        #expect(availability == .available)
        #expect(!statements.isEmpty)
        let settings = try await client.settings()
        #expect(settings.contains { $0.name == "shared_preload_libraries" && $0.setting?.contains("pg_stat_statements") == true })
        #expect(settings.first { $0.name == "shared_buffers" }?.displayValue == "32.0 MB")
        let roles = try await client.roles()
        #expect(roles.contains { $0.name == "md5_user" })
        if client.serverInfo.version.atLeast(10) { #expect(roles.contains { $0.name == "md5_user" && $0.memberOf.contains("pg_monitor") }) }
        let overview = try await client.overview()
        #expect((overview.uptimeSeconds ?? 0) > 0)
        #expect(overview.databases.contains { $0.name == "ccinn" })
        #expect(overview.totalConnections > 0)
        let maintenance = try await client.maintenanceCandidates()
        #expect(maintenance.contains { $0.name == "products" })
        let unused = try await client.unusedIndexes()
        #expect(unused.contains { $0.index == "products_unused_idx" })
    }

    /// Review finding 11: browsing a schema must not wait behind DDL on one of its tables (the size functions
    /// take AccessShareLock); the locked table simply has no size.
    @Test(arguments: IT.versions)
    func metadataDoesNotWaitBehindDDL(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        let locker = try await IT.connect(version)
        defer { Task { await locker.close() } }
        _ = try await locker.simpleQuery("BEGIN; LOCK TABLE shop.products IN ACCESS EXCLUSIVE MODE")
        let started = ContinuousClock.now
        let contents = try await client.schemaContents("shop")
        let products = try #require(contents.relations.first { $0.name == "products" })
        #expect(products.totalBytes == nil)
        #expect(contents.relations.first { $0.name == "customers" }?.totalBytes != nil)
        // Index sizes only lock the index, which LOCK TABLE does not: still available, without waiting.
        #expect(try await client.unusedIndexes().contains { $0.index == "products_unused_idx" })
        #expect(ContinuousClock.now - started < .seconds(5), "the schema listing waited for the lock")
        #expect(try await client.records("SELECT current_setting('lock_timeout') AS t").first?.text("t") == "5s")
        // Catalog functions such as pg_get_indexdef lock the table themselves: they give up after the lock timeout
        // (55P03) instead of stalling for the whole statement budget.
        for detail in [{ _ = try await client.indexes(of: products) }, { _ = try await client.statistics(of: products) }] as [@Sendable () async throws -> Void] {
            let attempt = ContinuousClock.now
            do {
                try await detail()
            } catch let error as PostgresError {
                #expect(error.sqlState == "55P03", "\(error)")
            }
            #expect(ContinuousClock.now - attempt < .seconds(10), "a detail query waited for the lock")
        }
        _ = try await locker.simpleQuery("ROLLBACK")
        let unlocked = try await client.schemaContents("shop")
        #expect(unlocked.relations.first { $0.name == "products" }?.totalBytes != nil)
    }

    @Test(arguments: IT.versions)
    func sessionsAndListener(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("SET search_path TO shop, public")
        _ = try await session.run("SET application_name = 'it-session'")
        _ = try await session.run("BEGIN")
        _ = try await session.run("SET statement_timeout = '5s'")
        _ = try await session.run("ROLLBACK")
        // Review finding 9: scripts are tracked statement by statement (rolled-back settings are not replayed).
        _ = try await session.run("BEGIN; SET work_mem = '8MB'; ROLLBACK", mode: .simple)
        _ = try await session.run("BEGIN; SET lock_timeout = '3s'; SAVEPOINT s; SET work_mem = '9MB'; ROLLBACK TO SAVEPOINT s; COMMIT", mode: .simple)
        await #expect(throws: PostgresError.self) { _ = try await session.run("SET work_mem = '10MB'; SELECT 1/0", mode: .simple) }
        #expect(try await session.run("SHOW work_mem").lastRowSet?.scalar != "10MB")
        #expect(await session.replayedSettings == ["SET search_path TO shop, public", "SET application_name = 'it-session'",
                                                   "SET lock_timeout = '3s'"])
        // Kill the session's backend: the next statement reconnects and replays the settings.
        let pid = try #require(await session.backendProcessID)
        let snapshot = try await client.activity()
        #expect(try await client.terminateBackend(pid, observedOn: snapshot.node))
        try await Task.sleep(for: .milliseconds(200))
        _ = try? await session.run("SELECT 1") // the dead connection is noticed here
        let path = try await session.run("SHOW search_path").lastRowSet?.scalar
        #expect(path == "shop, public")
        #expect(try await session.run("SELECT count(*) FROM customers").lastRowSet?.scalar == "200")
        #expect(try await session.run("SHOW statement_timeout").lastRowSet?.scalar == "0")
        #expect(try await session.run("SHOW lock_timeout").lastRowSet?.scalar == "3s")
        #expect(try await session.run("SHOW work_mem").lastRowSet?.scalar == "4MB")
        // Review finding 7: COPY exports run on the session (search_path, temporary tables).
        _ = try await session.run("CREATE TEMP TABLE export_me AS SELECT 41 + 1 AS answer")
        let exported = CopyCollector()
        let tag = try await session.copyOut("COPY (SELECT (SELECT count(*) FROM customers) AS customers, answer FROM export_me -- note\n) TO STDOUT WITH (FORMAT csv, HEADER)") { chunk in
            await exported.append(chunk)
        }
        #expect(tag?.rowCount == 1)
        #expect(await exported.text == "customers,answer\n200,42\n")
        await session.close()

        let listener = try await PostgresListener.open(client: client)
        try await listener.listen("jobs")
        try await listener.notify("jobs", payload: "hello")
        var iterator = listener.notifications.makeAsyncIterator()
        let note = await iterator.next()
        #expect(note?.channel == "jobs")
        #expect(note?.payload == "hello")
        listener.close()
    }
}
