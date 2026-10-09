-- Audit-log schema for Invoice Automation (database: invoice_automation_logs).
--
-- On a fresh clone this file is loaded automatically by docker/initdb/00-databases-and-schema.sql
-- (first start of an empty volume only). To apply it to a stack that is already running:
--   docker exec -i postgres_invoice_automation psql -U odoo -d invoice_automation_logs < init.sql
-- It is idempotent (IF NOT EXISTS / OR REPLACE), so re-running it is safe.
--
-- This file does NOT create databases: CREATE DATABASE cannot run inside this script's connection
-- and has no IF NOT EXISTS in PostgreSQL. That lives in docker/initdb/00-databases-and-schema.sql.

-- Create invoice_deliveries table for WhatsApp delivery tracking
CREATE TABLE IF NOT EXISTS invoice_deliveries (
  id SERIAL PRIMARY KEY,
  invoice_id INTEGER NOT NULL,
  invoice_number VARCHAR(100) NOT NULL,
  customer_id INTEGER,
  customer_name VARCHAR(255),
  customer_phone VARCHAR(20) NOT NULL, -- E.164 without the 'whatsapp:' prefix (max 16 chars); '' when skipped
  delivery_channel VARCHAR(50) DEFAULT 'whatsapp', -- currently always 'whatsapp'
  delivery_status VARCHAR(50) NOT NULL, -- 'sent' (accepted by Twilio, NOT proof of delivery) | 'skipped_no_phone' | 'failed'
  attempt_count INTEGER DEFAULT 1,
  max_attempts INTEGER DEFAULT 3, -- reserved for future retry logic, not implemented
  sent_at TIMESTAMP,
  error_message TEXT,
  error_code VARCHAR(50),
  twilio_sid VARCHAR(100), -- Twilio message SID (written for 'sent' rows)
  pdf_size INTEGER, -- Size of PDF in bytes
  response_time_ms INTEGER, -- API response time in milliseconds
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_invoice_id ON invoice_deliveries(invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoice_number ON invoice_deliveries(invoice_number);
CREATE INDEX IF NOT EXISTS idx_customer_phone ON invoice_deliveries(customer_phone);
CREATE INDEX IF NOT EXISTS idx_delivery_status ON invoice_deliveries(delivery_status);
CREATE INDEX IF NOT EXISTS idx_sent_at ON invoice_deliveries(sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_created_at ON invoice_deliveries(created_at DESC);

-- Grant permissions to odoo user
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO odoo;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO odoo;

-- Auto-update updated_at on any row change
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_invoice_deliveries_updated_at ON invoice_deliveries;
CREATE TRIGGER update_invoice_deliveries_updated_at
BEFORE UPDATE ON invoice_deliveries
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Daily summary view. success_percentage = sent / all rows that day (skips and failures count against it).
CREATE OR REPLACE VIEW invoice_delivery_success_rate AS
SELECT
  DATE(created_at) as delivery_date,
  COUNT(*) as total_attempts,
  SUM(CASE WHEN delivery_status = 'sent' THEN 1 ELSE 0 END) as successful_sends,
  SUM(CASE WHEN delivery_status = 'skipped_no_phone' THEN 1 ELSE 0 END) as skipped_no_phone,
  ROUND(
    100.0 * SUM(CASE WHEN delivery_status = 'sent' THEN 1 ELSE 0 END) / COUNT(*),
    2
  ) as success_percentage,
  SUM(CASE WHEN delivery_status = 'failed' THEN 1 ELSE 0 END) as failed_sends
FROM invoice_deliveries
GROUP BY DATE(created_at)
ORDER BY delivery_date DESC;

SELECT 'invoice_deliveries schema ready.' as status;
