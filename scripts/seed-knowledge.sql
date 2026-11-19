-- Knowledge base demo (integration tests and screenshots): every kind of relationship the knowledge base reads.
-- Declared foreign keys (one across schemas, one NOT VALID, one NOT ENFORCED on PostgreSQL 18), one join that is only
-- in a view definition and in names (report_adx_hour.dsp_id -> dsp.id), a partitioned table, a view and a
-- materialized view. Idempotent.
DROP SCHEMA IF EXISTS kb_demo CASCADE;
DROP SCHEMA IF EXISTS kb_ref CASCADE;

CREATE SCHEMA kb_ref;
CREATE TABLE kb_ref.country (code char(2) PRIMARY KEY, name text NOT NULL);

CREATE SCHEMA kb_demo;
COMMENT ON SCHEMA kb_demo IS 'Knowledge base demo';

CREATE TABLE kb_demo.publisher (
    id bigint PRIMARY KEY,
    name text NOT NULL,
    country_code char(2) REFERENCES kb_ref.country (code)
);
CREATE TABLE kb_demo.app (id bigint PRIMARY KEY, publisher_id bigint NOT NULL, name text);
ALTER TABLE kb_demo.app ADD CONSTRAINT app_publisher_fk FOREIGN KEY (publisher_id) REFERENCES kb_demo.publisher (id) NOT VALID;
CREATE TABLE kb_demo.dsp (id bigint PRIMARY KEY, name text NOT NULL, tenant text NOT NULL, code text NOT NULL, UNIQUE (tenant, code));
COMMENT ON TABLE kb_demo.dsp IS 'Demand-side platforms';
CREATE TABLE kb_demo.dsp_budget (dsp_id bigint NOT NULL, month date NOT NULL, amount numeric(18, 2), PRIMARY KEY (dsp_id, month));

CREATE TABLE kb_demo.report_adx_hour (
    dt date NOT NULL,
    hour smallint NOT NULL,
    dsp_id bigint NOT NULL,
    app_id bigint NOT NULL REFERENCES kb_demo.app (id),
    dsp_request bigint,
    revenue numeric(18, 6),
    PRIMARY KEY (dt, hour, dsp_id, app_id)
) PARTITION BY RANGE (dt);
COMMENT ON TABLE kb_demo.report_adx_hour IS 'ADX hourly report';
COMMENT ON COLUMN kb_demo.report_adx_hour.dsp_id IS 'DSP';
CREATE TABLE kb_demo.report_adx_hour_2026 PARTITION OF kb_demo.report_adx_hour FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE VIEW kb_demo.v_dsp_report AS
SELECT r.dt, d.name AS dsp_name, sum(r.dsp_request) AS requests
FROM kb_demo.report_adx_hour r JOIN kb_demo.dsp d ON r.dsp_id = d.id
GROUP BY r.dt, d.name;

CREATE MATERIALIZED VIEW kb_demo.mv_app_day AS
SELECT r.dt, a.name AS app_name, sum(r.revenue) AS revenue
FROM kb_demo.report_adx_hour r JOIN kb_demo.app a ON r.app_id = a.id
GROUP BY r.dt, a.name
WITH NO DATA;

-- PostgreSQL 18: a declared foreign key the server never checks.
DO $$
BEGIN
    IF current_setting('server_version_num')::int >= 180000 THEN
        EXECUTE 'ALTER TABLE kb_demo.dsp_budget ADD CONSTRAINT dsp_budget_dsp_fk FOREIGN KEY (dsp_id) REFERENCES kb_demo.dsp (id) NOT ENFORCED';
    END IF;
END
$$;
