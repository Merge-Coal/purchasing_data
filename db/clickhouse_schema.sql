-- ============================================================
-- PT Merge Mining Industri — Procurement ClickHouse Schema
-- Generated: 2026-05-11
-- Engine strategy:
--   ReplacingMergeTree(version) for current-state tables
--   MergeTree for append-only audit/history tables
-- ============================================================

-- ── Master Data ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS companies (
    company_id          String,
    company_name        String,
    legal_name          String,
    npwp                String          DEFAULT '',
    address             String          DEFAULT '',
    city                LowCardinality(String) DEFAULT '',
    country             LowCardinality(String) DEFAULT 'ID',
    base_currency       FixedString(3)  DEFAULT 'IDR',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY company_id;

CREATE TABLE IF NOT EXISTS departments (
    department_id       String,
    company_id          String,
    department_code     String          DEFAULT '',
    department_name     String,
    parent_department_id String         DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, department_id);

CREATE TABLE IF NOT EXISTS cost_centers (
    cost_center_id      String,
    company_id          String,
    cost_center_code    String          DEFAULT '',
    cost_center_name    String,
    department_id       String          DEFAULT '',
    manager_user_id     String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, cost_center_id);

CREATE TABLE IF NOT EXISTS purposes (
    purpose_id           String,
    company_id           String,
    label                String,
    sort_order           UInt16          DEFAULT 0,
    status               LowCardinality(String) DEFAULT 'active',
    version              UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted           UInt8           DEFAULT 0,
    created_at           DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at           DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, purpose_id);

CREATE TABLE IF NOT EXISTS gl_accounts (
    gl_account_id       String,
    company_id          String,
    account_code        String,
    account_name        String,
    account_type        LowCardinality(String) DEFAULT 'expense',
    normal_balance      LowCardinality(String) DEFAULT 'debit',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, gl_account_id);

CREATE TABLE IF NOT EXISTS tax_codes (
    tax_code            String,
    company_id          String,
    tax_name            String,
    tax_type            LowCardinality(String),
    rate                Decimal(9, 6)   DEFAULT 0,
    direction           LowCardinality(String) DEFAULT 'add',
    gl_account_id       String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, tax_code);

CREATE TABLE IF NOT EXISTS payment_terms (
    payment_term_id     String,
    company_id          String,
    payment_term_name   String,
    days_due            UInt16          DEFAULT 0,
    description         String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, payment_term_id);

CREATE TABLE IF NOT EXISTS users (
    user_id             UUID            DEFAULT generateUUIDv4(),
    legacy_user_id      Nullable(Int64),
    company_id          String,
    username            String,
    password_hash       String,
    role                LowCardinality(String),
    full_name           String          DEFAULT '',
    email               String          DEFAULT '',
    department_id       String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_username username TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, user_id);

CREATE TABLE IF NOT EXISTS app_sessions (
    session_id          String,
    user_id             String          DEFAULT '',
    session_data        String          DEFAULT '',
    expires_at          DateTime64(3, 'Asia/Jakarta'),
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY session_id;

-- ── Vendor Master ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS vendors (
    vendor_id           String,
    company_id          String,
    vendor_code         String          DEFAULT '',
    vendor_name         String,
    category            LowCardinality(String) DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    contact_person      String          DEFAULT '',
    phone               String          DEFAULT '',
    mobile              String          DEFAULT '',
    email               String          DEFAULT '',
    address             String          DEFAULT '',
    city                LowCardinality(String) DEFAULT '',
    country             LowCardinality(String) DEFAULT 'ID',
    npwp                String          DEFAULT '',
    payment_term_id     String          DEFAULT '',
    default_currency    FixedString(3)  DEFAULT 'IDR',
    tax_profile         LowCardinality(String) DEFAULT '',
    risk_rating         LowCardinality(String) DEFAULT '',
    onboarding_date     Nullable(Date),
    blocked_reason      String          DEFAULT '',
    search_text         String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_vendor_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, vendor_id);

CREATE TABLE IF NOT EXISTS vendor_bank_accounts (
    vendor_bank_id      UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    vendor_id           String,
    bank_name           String,
    branch_name         String          DEFAULT '',
    account_number      String,
    account_holder_name String,
    currency            FixedString(3)  DEFAULT 'IDR',
    is_primary          UInt8           DEFAULT 0,
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, vendor_bank_id);

CREATE TABLE IF NOT EXISTS vendor_documents (
    vendor_document_id  UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    vendor_id           String,
    document_type       LowCardinality(String),
    document_number     String          DEFAULT '',
    issued_date         Nullable(Date),
    expiry_date         Nullable(Date),
    file_url            String          DEFAULT '',
    verification_status LowCardinality(String) DEFAULT 'pending',
    verified_by_user_id String          DEFAULT '',
    verified_at         Nullable(DateTime64(3, 'Asia/Jakarta')),
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, vendor_document_id);

-- ── Item Master ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS item_categories (
    category_id         String,
    company_id          String,
    category_name       String,
    parent_category_id  String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, category_id);

CREATE TABLE IF NOT EXISTS items (
    item_id             String,
    company_id          String,
    base_item_id        String          DEFAULT '',
    item_code           String          DEFAULT '',
    name_en             String          DEFAULT '',
    name_cn             String          DEFAULT '',
    category_id         String          DEFAULT '',
    category_name       LowCardinality(String) DEFAULT '',
    spec                String          DEFAULT '',
    uom                 LowCardinality(String) DEFAULT 'pcs',
    department_id       String          DEFAULT '',
    item_type           LowCardinality(String) DEFAULT 'expense',
    default_gl_account_id String        DEFAULT '',
    min_order_qty       Decimal(18, 4)  DEFAULT 0,
    lead_time_days      UInt16          DEFAULT 0,
    status              LowCardinality(String) DEFAULT 'active',
    search_text         String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_item_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, item_id);

CREATE TABLE IF NOT EXISTS item_vendor_prices (
    item_vendor_price_id UUID           DEFAULT generateUUIDv4(),
    company_id          String,
    item_id             String,
    vendor_id           String,
    currency            FixedString(3)  DEFAULT 'IDR',
    unit_price          Decimal(18, 2),
    min_qty             Decimal(18, 4)  DEFAULT 0,
    valid_from          Date            DEFAULT today(),
    valid_to            Nullable(Date),
    source_type         LowCardinality(String) DEFAULT 'manual',
    source_document_id  String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, item_id, vendor_id, valid_from, item_vendor_price_id);

-- ── Approval Workflow ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS approval_workflows (
    workflow_id         UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    workflow_name       String,
    document_type       LowCardinality(String),
    status              LowCardinality(String) DEFAULT 'active',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, workflow_id);

CREATE TABLE IF NOT EXISTS approval_steps (
    approval_step_id    UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    workflow_id         String,
    step_no             UInt16,
    step_name           String,
    approver_role       LowCardinality(String) DEFAULT '',
    approver_user_id    String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, workflow_id, step_no, approval_step_id);

-- ── Approval Actions (append-only) ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS approval_actions (
    approval_action_id  UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    document_type       LowCardinality(String),
    document_id         String,
    document_item_id    String          DEFAULT '',
    workflow_id         String          DEFAULT '',
    step_no             UInt16          DEFAULT 0,
    actor_user_id       String,
    actor_name          String,
    action              LowCardinality(String),
    action_at           DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    from_status         LowCardinality(String) DEFAULT '',
    to_status           LowCardinality(String) DEFAULT '',
    approved_qty        Nullable(Decimal(18, 4)),
    notes               String          DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(action_at)
ORDER BY (company_id, document_type, document_id, action_at, approval_action_id);

-- ── Purchase Requests ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS purchase_requests (
    pr_id               UUID            DEFAULT generateUUIDv4(),
    legacy_pr_id        Nullable(Int64),
    company_id          String,
    pr_number           String,
    requester_user_id   String,
    requested_by_name   String          DEFAULT '',
    department_id       String          DEFAULT '',
    cost_center_id      String          DEFAULT '',
    pr_date             Date            DEFAULT today(),
    needed_by_date      Nullable(Date),
    priority            LowCardinality(String) DEFAULT 'normal',
    status              LowCardinality(String) DEFAULT 'draft',
    total_estimated_amount Decimal(18, 2) DEFAULT 0,
    currency            FixedString(3)  DEFAULT 'IDR',
    notes               String          DEFAULT '',
    search_text         String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_pr_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(pr_date)
ORDER BY (company_id, pr_date, pr_id);

CREATE TABLE IF NOT EXISTS purchase_request_items (
    pr_item_id          UUID            DEFAULT generateUUIDv4(),
    legacy_pr_item_id   Nullable(Int64),
    company_id          String,
    pr_id               String,
    line_no             UInt16,
    item_id             String,
    item_description    String          DEFAULT '',
    requested_qty       Decimal(18, 4),
    approved_qty        Decimal(18, 4)  DEFAULT 0,
    uom                 LowCardinality(String),
    estimated_unit_price Decimal(18, 2) DEFAULT 0,
    estimated_total_price Decimal(18, 2) DEFAULT 0,
    department_id       String          DEFAULT '',
    cost_center_id      String          DEFAULT '',
    gl_account_id       String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'pending',
    notes               String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, pr_id, line_no, pr_item_id);

-- ── RFQ (Request for Quote) ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS request_for_quotes (
    rfq_id              UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    rfq_number          String,
    rfq_date            Date            DEFAULT today(),
    requested_by_user_id String,
    due_date            Nullable(Date),
    status              LowCardinality(String) DEFAULT 'draft',
    notes               String          DEFAULT '',
    search_text         String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_rfq_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(rfq_date)
ORDER BY (company_id, rfq_date, rfq_id);

CREATE TABLE IF NOT EXISTS request_for_quote_items (
    rfq_item_id         UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    rfq_id              String,
    pr_item_id          String          DEFAULT '',
    line_no             UInt16,
    item_id             String,
    description         String          DEFAULT '',
    requested_qty       Decimal(18, 4),
    uom                 LowCardinality(String),
    target_price        Decimal(18, 2)  DEFAULT 0,
    notes               String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, rfq_id, line_no, rfq_item_id);

-- ── Supplier Quotations ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS supplier_quotations (
    quotation_id        UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    rfq_id              String,
    vendor_id           String,
    quotation_number    String          DEFAULT '',
    quotation_date      Date            DEFAULT today(),
    valid_until         Nullable(Date),
    currency            FixedString(3)  DEFAULT 'IDR',
    subtotal_amount     Decimal(18, 2)  DEFAULT 0,
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    total_amount        Decimal(18, 2)  DEFAULT 0,
    status              LowCardinality(String) DEFAULT 'received',
    notes               String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(quotation_date)
ORDER BY (company_id, quotation_date, quotation_id);

CREATE TABLE IF NOT EXISTS supplier_quotation_items (
    quotation_item_id   UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    quotation_id        String,
    rfq_item_id         String          DEFAULT '',
    item_id             String,
    quoted_qty          Decimal(18, 4),
    uom                 LowCardinality(String),
    unit_price          Decimal(18, 2),
    discount_amount     Decimal(18, 2)  DEFAULT 0,
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    total_price         Decimal(18, 2),
    lead_time_days      UInt16          DEFAULT 0,
    is_selected         UInt8           DEFAULT 0,
    notes               String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, quotation_id, quotation_item_id);

-- ── Purchase Orders ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS purchase_orders (
    po_id               UUID            DEFAULT generateUUIDv4(),
    legacy_po_id        Nullable(Int64),
    company_id          String,
    po_number           String,
    primary_pr_id       String          DEFAULT '',
    vendor_id           String,
    vendor_name         String          DEFAULT '',
    po_date             Date            DEFAULT today(),
    expected_delivery_date Nullable(Date),
    currency            FixedString(3)  DEFAULT 'IDR',
    exchange_rate       Decimal(18, 6)  DEFAULT 1,
    payment_term_id     String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'draft',
    subtotal_amount     Decimal(18, 2)  DEFAULT 0,
    discount_amount     Decimal(18, 2)  DEFAULT 0,
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    withholding_amount  Decimal(18, 2)  DEFAULT 0,
    total_amount        Decimal(18, 2)  DEFAULT 0,
    notes               String          DEFAULT '',
    search_text         String          DEFAULT '',
    created_by_user_id  String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_po_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(po_date)
ORDER BY (company_id, po_date, po_id);

CREATE TABLE IF NOT EXISTS purchase_order_items (
    po_item_id          UUID            DEFAULT generateUUIDv4(),
    legacy_po_item_id   Nullable(Int64),
    company_id          String,
    po_id               String,
    line_no             UInt16,
    pr_item_id          String          DEFAULT '',
    quotation_item_id   String          DEFAULT '',
    item_id             String,
    item_description    String          DEFAULT '',
    ordered_qty         Decimal(18, 4),
    received_qty        Decimal(18, 4)  DEFAULT 0,
    invoiced_qty        Decimal(18, 4)  DEFAULT 0,
    uom                 LowCardinality(String),
    unit_price          Decimal(18, 2),
    discount_amount     Decimal(18, 2)  DEFAULT 0,
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    total_price         Decimal(18, 2),
    gl_account_id       String          DEFAULT '',
    cost_center_id      String          DEFAULT '',
    vendor_name         String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'open',
    notes               String          DEFAULT '',
    purpose             String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, po_id, line_no, po_item_id);

CREATE TABLE IF NOT EXISTS purchase_order_tax_lines (
    po_tax_line_id      UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    po_id               String,
    tax_code            String,
    tax_name            String,
    tax_type            LowCardinality(String),
    rate                Decimal(9, 6)   DEFAULT 0,
    direction           LowCardinality(String) DEFAULT 'add',
    base_amount         Decimal(18, 2)  DEFAULT 0,
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    gl_account_id       String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, po_id, po_tax_line_id);

-- ── Goods Receipts ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS goods_receipts (
    receipt_id          UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    receipt_number      String,
    po_id               String,
    vendor_id           String,
    receipt_date        Date            DEFAULT today(),
    received_by_user_id String,
    warehouse_location  String          DEFAULT '',
    status              LowCardinality(String) DEFAULT 'draft',
    notes               String          DEFAULT '',
    search_text         String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_receipt_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(receipt_date)
ORDER BY (company_id, receipt_date, receipt_id);

CREATE TABLE IF NOT EXISTS goods_receipt_items (
    receipt_item_id     UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    receipt_id          String,
    po_item_id          String,
    item_id             String,
    received_qty        Decimal(18, 4),
    accepted_qty        Decimal(18, 4)  DEFAULT 0,
    rejected_qty        Decimal(18, 4)  DEFAULT 0,
    uom                 LowCardinality(String),
    condition_status    LowCardinality(String) DEFAULT 'accepted',
    notes               String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, receipt_id, receipt_item_id);

-- ── Supplier Invoices ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS supplier_invoices (
    invoice_id          UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    invoice_number      String,
    vendor_id           String,
    po_id               String          DEFAULT '',
    invoice_date        Date,
    due_date            Nullable(Date),
    currency            FixedString(3)  DEFAULT 'IDR',
    subtotal_amount     Decimal(18, 2)  DEFAULT 0,
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    withholding_amount  Decimal(18, 2)  DEFAULT 0,
    total_amount        Decimal(18, 2)  DEFAULT 0,
    paid_amount         Decimal(18, 2)  DEFAULT 0,
    status              LowCardinality(String) DEFAULT 'draft',
    notes               String          DEFAULT '',
    search_text         String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_invoice_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(invoice_date)
ORDER BY (company_id, invoice_date, invoice_id);

CREATE TABLE IF NOT EXISTS supplier_invoice_items (
    invoice_item_id     UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    invoice_id          String,
    po_item_id          String          DEFAULT '',
    receipt_item_id     String          DEFAULT '',
    item_id             String,
    invoice_qty         Decimal(18, 4),
    uom                 LowCardinality(String),
    unit_price          Decimal(18, 2),
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    total_price         Decimal(18, 2),
    gl_account_id       String          DEFAULT '',
    cost_center_id      String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, invoice_id, invoice_item_id);

CREATE TABLE IF NOT EXISTS supplier_invoice_tax_lines (
    invoice_tax_line_id UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    invoice_id          String,
    tax_code            String,
    tax_name            String,
    tax_type            LowCardinality(String),
    rate                Decimal(9, 6)   DEFAULT 0,
    direction           LowCardinality(String) DEFAULT 'add',
    base_amount         Decimal(18, 2)  DEFAULT 0,
    tax_amount          Decimal(18, 2)  DEFAULT 0,
    gl_account_id       String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, invoice_id, invoice_tax_line_id);

-- ── Payments ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS payments (
    payment_id          UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    payment_number      String,
    invoice_id          String,
    vendor_id           String,
    payment_date        Date            DEFAULT today(),
    payment_method      LowCardinality(String) DEFAULT 'bank_transfer',
    bank_reference      String          DEFAULT '',
    currency            FixedString(3)  DEFAULT 'IDR',
    amount              Decimal(18, 2),
    status              LowCardinality(String) DEFAULT 'draft',
    notes               String          DEFAULT '',
    search_text         String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    INDEX idx_payment_text search_text TYPE tokenbf_v1(1024, 3, 0) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(payment_date)
ORDER BY (company_id, payment_date, payment_id);

-- ── GL Export (append-only) ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS gl_exports (
    gl_export_id        UUID            DEFAULT generateUUIDv4(),
    legacy_log_id       Nullable(Int64),
    company_id          String,
    source_document_type LowCardinality(String),
    source_document_id  String,
    export_number       String          DEFAULT '',
    export_date         Date            DEFAULT today(),
    filename            String,
    status              LowCardinality(String) DEFAULT 'generated',
    exported_by_user_id String          DEFAULT '',
    notes               String          DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(export_date)
ORDER BY (company_id, export_date, gl_export_id);

CREATE TABLE IF NOT EXISTS gl_export_lines (
    gl_export_line_id   UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    gl_export_id        String,
    line_no             UInt16,
    posting_date        Date,
    gl_account_id       String,
    account_code        String,
    account_name        String,
    debit_amount        Decimal(18, 2)  DEFAULT 0,
    credit_amount       Decimal(18, 2)  DEFAULT 0,
    currency            FixedString(3)  DEFAULT 'IDR',
    description         String          DEFAULT '',
    cost_center_id      String          DEFAULT '',
    source_document_type LowCardinality(String) DEFAULT '',
    source_document_id  String          DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(posting_date)
ORDER BY (company_id, posting_date, gl_export_id, line_no);

-- ── Budget ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS budget_headers (
    budget_id           UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    fiscal_year         UInt16,
    budget_name         String,
    currency            FixedString(3)  DEFAULT 'IDR',
    status              LowCardinality(String) DEFAULT 'draft',
    notes               String          DEFAULT '',
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, fiscal_year, budget_id);

CREATE TABLE IF NOT EXISTS budget_lines (
    budget_line_id      UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    budget_id           String,
    fiscal_period       String,
    department_id       String          DEFAULT '',
    cost_center_id      String          DEFAULT '',
    gl_account_id       String          DEFAULT '',
    item_category_id    String          DEFAULT '',
    budget_amount       Decimal(18, 2)  DEFAULT 0,
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    updated_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (company_id, budget_id, fiscal_period, budget_line_id);

CREATE TABLE IF NOT EXISTS budget_movements (
    budget_movement_id  UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    budget_line_id      String,
    movement_date       Date            DEFAULT today(),
    movement_type       LowCardinality(String),
    source_document_type LowCardinality(String) DEFAULT '',
    source_document_id  String          DEFAULT '',
    amount              Decimal(18, 2),
    description         String          DEFAULT '',
    created_by_user_id  String          DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(movement_date)
ORDER BY (company_id, movement_date, budget_line_id, budget_movement_id);

-- ── Audit and History (all append-only) ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS status_history (
    status_history_id   UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    entity_type         LowCardinality(String),
    entity_id           String,
    from_status         LowCardinality(String) DEFAULT '',
    to_status           LowCardinality(String),
    changed_by_user_id  String,
    changed_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    reason              String          DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(changed_at)
ORDER BY (company_id, entity_type, entity_id, changed_at, status_history_id);

CREATE TABLE IF NOT EXISTS procurement_events (
    event_id            UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    event_time          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    event_type          LowCardinality(String),
    entity_type         LowCardinality(String),
    entity_id           String,
    actor_user_id       String          DEFAULT '',
    actor_name          String          DEFAULT '',
    source_system       LowCardinality(String) DEFAULT 'procurement_app',
    idempotency_key     String          DEFAULT '',
    before_json         String          DEFAULT '',
    after_json          String          DEFAULT '',
    metadata_json       String          DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (company_id, event_time, entity_type, entity_id, event_id);

CREATE TABLE IF NOT EXISTS attachments (
    attachment_id       UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    entity_type         LowCardinality(String),
    entity_id           String,
    file_name           String,
    file_url            String,
    mime_type           String          DEFAULT '',
    file_size_bytes     UInt64          DEFAULT 0,
    uploaded_by_user_id String,
    uploaded_at         DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(uploaded_at)
ORDER BY (company_id, entity_type, entity_id, attachment_id);

CREATE TABLE IF NOT EXISTS comments (
    comment_id          UUID            DEFAULT generateUUIDv4(),
    company_id          String,
    entity_type         LowCardinality(String),
    entity_id           String,
    author_user_id      String,
    comment_text        String,
    created_at          DateTime64(3, 'Asia/Jakarta') DEFAULT now64(3),
    version             UInt64          DEFAULT toUInt64(toUnixTimestamp64Milli(now64(3))),
    is_deleted          UInt8           DEFAULT 0
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(created_at)
ORDER BY (company_id, entity_type, entity_id, comment_id);

-- ── Migrations ────────────────────────────────────────────────────────────────
-- Run these on existing deployments to add columns added after initial schema
ALTER TABLE purchase_order_items ADD COLUMN IF NOT EXISTS purpose String DEFAULT '';
