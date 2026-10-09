-- Runs ONCE, on the first start of an EMPTY postgres_data volume (official postgres image behaviour:
-- every file in /docker-entrypoint-initdb.d is executed with psql against the default database).
--
-- Creates the two extra databases the stack needs and loads the audit schema into the right one.
-- Odoo's own database (`odoo`) is created by the postgres image itself, because POSTGRES_USER=odoo.
--
-- Nothing here touches an existing volume. To apply the schema to a stack that is already running:
--   docker exec -i postgres_invoice_automation psql -U odoo -d invoice_automation_logs < init.sql

CREATE DATABASE n8n_db;
CREATE DATABASE invoice_automation_logs;

\connect invoice_automation_logs
\i /schema/init.sql
