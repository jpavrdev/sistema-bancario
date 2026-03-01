# Fintech Core Engine

> **[Versão em Português](README.pt-br.md)**

**A production-grade financial engine built for correctness, concurrency safety, and regulatory compliance.**

This system handles the full lifecycle of credit contracts — from origination through installment tracking, payment processing, interest/penalty accrual, renegotiation, and eventual LGPD data anonymization — while guaranteeing zero duplicate charges, zero lost events, and full auditability required by Brazilian Central Bank (BACEN) regulations.

---

## Table of Contents

- [Problem Statement](#problem-statement)
- [Tech Stack](#tech-stack)
- [Architecture Overview](#architecture-overview)
- [Key Design Decisions](#key-design-decisions)
  - [Dual Concurrency Control](#dual-concurrency-control)
  - [Webhook Idempotency](#webhook-idempotency)
  - [Transactional Outbox Pattern](#transactional-outbox-pattern)
  - [Fail-Safe Partitioning](#fail-safe-partitioning)
  - [LGPD Compliance vs. Financial Retention](#lgpd-compliance-vs-financial-retention)
- [Database Schema](#database-schema)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Running Locally](#running-locally)
  - [Running Tests](#running-tests)
- [Operational Runbooks](#operational-runbooks)
- [Architecture Decision Records](#architecture-decision-records)
- [License](#license)

---

## Problem Statement

Financial systems face a unique convergence of hard problems:

| Problem | Consequence if Ignored |
|---|---|
| Duplicate webhook delivery | Customer charged twice for the same payment |
| Concurrent batch + real-time writes | Stale balance reads → incorrect interest calculations |
| Broker unavailability (Kafka/RabbitMQ down) | Lost events → downstream systems out of sync |
| Partition not created on month rollover | Hard INSERT failure → total system outage at midnight |
| LGPD right-to-erasure vs. BACEN 5-year retention | Regulatory fine from either side |

This engine addresses **all five** at the database and application level, with defense-in-depth strategies documented and tested.

---

## Tech Stack

| Layer | Technology | Rationale |
|---|---|---|
| **Runtime** | C# / .NET 9 | High throughput, predictable GC, native OpenTelemetry, AOT-ready |
| **Database** | PostgreSQL 15+ | ACID transactions, PL/pgSQL business logic, native partitioning, RLS |
| **Data Access** | Dapper | Micro-ORM for calling PL/pgSQL functions directly — zero ORM overhead on the hot path |
| **Data Access (read)** | EF Core *(optional)* | LINQ projections for dashboards and analytical queries only |
| **Messaging** | RabbitMQ via MassTransit | Decoupled event transport; MassTransit abstracts the broker for future migration |
| **Connection Pool** | PgBouncer (transaction mode) | Multiplexes thousands of app connections into a controlled backend pool |
| **Observability** | OpenTelemetry + Prometheus + Grafana | Distributed tracing, custom metrics (outbox backlog, partition health) |
| **Containers** | Docker + Docker Compose | Full local environment: PostgreSQL, PgBouncer, RabbitMQ, application |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          API Gateway / Load Balancer                     │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                  ┌────────────▼────────────┐
                  │   .NET 9 API Service     │
                  │  (Minimal APIs + Dapper) │
                  │                          │
                  │  ┌────────────────────┐  │
                  │  │ Payment Webhook    │──┼──→ calls registrar_pagamento_pessimista()
                  │  │ Handler            │  │     via Dapper (SELECT FOR UPDATE)
                  │  └────────────────────┘  │
                  │  ┌────────────────────┐  │
                  │  │ Batch Accrual Job  │──┼──→ calls aplicar_encargos()
                  │  │ (Hosted Service)   │  │     via Dapper (Advisory Lock + SKIP LOCKED)
                  │  └────────────────────┘  │
                  │  ┌────────────────────┐  │
                  │  │ Outbox Relay       │──┼──→ calls consumir_outbox_eventos()
                  │  │ (Hosted Service)   │  │     via Dapper (FOR UPDATE SKIP LOCKED)
                  │  └────────────────────┘  │
                  └────────────┬─────────────┘
                               │
              ┌────────────────▼────────────────┐
              │          PgBouncer               │
              │    (Transaction Pooling Mode)    │
              └────────────────┬────────────────┘
                               │
              ┌────────────────▼────────────────┐
              │     PostgreSQL 15+ Cluster       │
              │                                  │
              │  ┌──────────┐ ┌───────────────┐  │
              │  │ bancario │ │ Partitioned   │  │
              │  │ schema   │ │ Tables +      │  │
              │  │ (tables, │ │ DEFAULT       │  │
              │  │ functions,│ │ partitions    │  │
              │  │ triggers) │ │               │  │
              │  └──────────┘ └───────────────┘  │
              └──────────────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Outbox Relay       │
                    │  publishes events   │
                    │  via MassTransit    │
                    └──────────┬──────────┘
                               │
              ┌────────────────▼────────────────┐
              │         RabbitMQ Cluster          │
              │  (Quorum Queues in Production)   │
              └────────────────┬────────────────┘
                               │
              ┌────────────────▼────────────────┐
              │     Downstream Consumers         │
              │  (Notifications, Scoring,        │
              │   Accounting, Analytics)         │
              └─────────────────────────────────┘
```

---

## Key Design Decisions

### Dual Concurrency Control

The engine uses **two concurrency strategies** for different workloads:

| Strategy | Use Case | Mechanism | Why |
|---|---|---|---|
| **Pessimistic Locking** | Webhook payment processing | `SELECT FOR UPDATE` on the installment row | Guarantees idempotency: first worker processes, second blocks and detects the already-paid state |
| **Optimistic Concurrency Control (OCC)** | Batch interest accrual | `UPDATE ... WHERE versao = N` (Compare-And-Swap) | Avoids holding row locks across thousands of records; conflicts trigger retry |

**Architectural invariant:** The pessimistic transaction performs **zero external I/O** (no HTTP calls, no broker writes). All side-effects flow through the outbox. This prevents PgBouncer connection pinning under load.

### Webhook Idempotency

Payment gateways deliver webhooks with **at-least-once** semantics. The engine handles duplicates at two levels:

1. **Idempotency key check** — Before acquiring the row lock, the function checks if a payment with the same `codigo_transacao` already exists. If so, it returns the previous result immediately (no mutation, no lock).
2. **State-based guard** — After acquiring the lock, if the installment is already `paga`, the function returns gracefully. This handles the race condition where two workers pass the idempotency check simultaneously.
3. **`ON CONFLICT DO NOTHING`** — Final safety net against the microsecond window between SELECT and INSERT.

Three layers. Zero duplicate charges.

### Transactional Outbox Pattern

The system **never** performs dual writes (database + broker in the same operation). Instead:

1. Business logic writes to the database **and** inserts an event into `outbox_eventos` — **in the same transaction**.
2. A dedicated relay (Hosted Service) polls `outbox_eventos` using `FOR UPDATE SKIP LOCKED`, publishes to RabbitMQ via MassTransit, and marks events as published.
3. If RabbitMQ is down, events accumulate in the outbox. The relay drains them when the broker recovers. **The payment flow is never blocked by broker unavailability.**

`SKIP LOCKED` enables **horizontal scaling** of the relay: multiple instances consume different events without contention.

### Fail-Safe Partitioning

Both `encargos_aplicados` (interest/penalties) and `audit_log` are partitioned by month (`PARTITION BY RANGE`). Three defense layers prevent the catastrophic failure of a missing partition:

| Layer | Mechanism | Purpose |
|---|---|---|
| **Prevention** | `manter_particoes_futuras(3)` runs daily via pg_cron | Creates partitions 3 months ahead |
| **Safety Net** | `DEFAULT` partition on both tables | Catches INSERTs when no matching partition exists |
| **Detection** | `vw_alerta_particao_default` monitored every 30 min | Alerts if any row lands in DEFAULT (operational anomaly) |

If the cron job fails, the system has a **3-month buffer** before the DEFAULT partition is needed. If DEFAULT does activate, `migrar_default_encargos()` moves rows to the correct partition once it's created.

### LGPD Compliance vs. Financial Retention

Brazilian regulations create a direct conflict:

- **LGPD (Art. 18):** Right to data erasure
- **BACEN (Res. 4.658):** 5-year minimum retention of financial records

The resolution:

1. **Data segregation** — Personal data (name, CPF, email, phone) lives **exclusively** in the `usuarios` table. All other tables reference users by UUID only.
2. **Deferred anonymization** — Erasure requests are queued until all regulatory retention periods expire (LGPD Art. 16, §I permits this).
3. **Irreversible pseudonymization** — `anonimizar_usuario()` replaces personal data with salted SHA-256 hashes via `pgcrypto`. The record survives; the personal data doesn't.
4. **Audit log isolation** — The audit trigger captures **only UUIDs and transactional diffs**, never personal data. This is enforced by a column whitelist, not a blacklist.
5. **Backup consistency** — The anonymization request log is re-applied after any disaster recovery restore.

---

## Database Schema

The entire schema is defined in a single, atomic migration file:

```
migrations/
└── 001_init_schema.sql    # Single source of truth (BEGIN/COMMIT)
```

**9 sections, strict dependency order:**

| # | Section | Contents |
|---|---|---|
| 1 | Extensions | `pgcrypto` |
| 2 | Roles & ENUMs | `app_readonly`, `app_user`, `app_jobs`, `app_dba` + 6 enum types |
| 3 | Base Tables | `usuarios`, `contratos`, `parcelas` (with OCC `versao`), `pagamentos`, `acordos` |
| 4 | Partitioned Tables | `encargos_aplicados`, `audit_log` (monthly range) + DEFAULT partitions + dynamic creation |
| 5 | Outbox | `outbox_eventos` (Transactional Outbox for MassTransit/RabbitMQ) |
| 6 | Indexes | B-Tree (operational), BRIN (chronological append-only), partial indexes |
| 7 | Business Functions | Pessimistic payment, OCC payment, batch accrual, LGPD anonymization, archiving, outbox consumer |
| 8 | Triggers | Audit (BACEN), outbox events, status validation, delete protection |
| 9 | Security | GRANTs (least privilege), RLS (tenant isolation), role timeouts |

---

## Project Structure

```
fintech-core-engine/
├── src/
│   ├── Api/                          # Minimal API endpoints (Presentation)
│   │   ├── Endpoints/
│   │   │   ├── PaymentEndpoints.cs
│   │   │   ├── ContractEndpoints.cs
│   │   │   └── AdminEndpoints.cs
│   │   └── Program.cs
│   │
│   ├── Application/                  # Use cases and orchestration
│   │   ├── Payments/
│   │   │   ├── ProcessWebhookCommand.cs
│   │   │   └── ProcessWebhookHandler.cs
│   │   ├── Accrual/
│   │   │   ├── RunAccrualCommand.cs
│   │   │   └── RunAccrualHandler.cs
│   │   └── Compliance/
│   │       ├── AnonymizeUserCommand.cs
│   │       └── AnonymizeUserHandler.cs
│   │
│   ├── Infrastructure/               # Data access and external integrations
│   │   ├── Database/
│   │   │   ├── DapperConnectionFactory.cs
│   │   │   ├── PaymentRepository.cs
│   │   │   └── OutboxRepository.cs
│   │   ├── Messaging/
│   │   │   ├── OutboxRelayService.cs       # Hosted Service: polls outbox, publishes via MassTransit
│   │   │   └── MassTransitConfiguration.cs
│   │   └── BackgroundJobs/
│   │       └── AccrualJobService.cs        # Hosted Service: daily interest/penalty accrual
│   │
│   └── Domain/                       # POCOs, enums, result types (no ORM entities)
│       ├── PaymentResult.cs
│       ├── AccrualResult.cs
│       └── Enums/
│
├── tests/
│   ├── Integration/                  # Tests against real PostgreSQL (Testcontainers)
│   └── Unit/
│
├── migrations/
│   └── 001_init_schema.sql           # Single atomic migration (the source of truth)
│
├── docker/
│   ├── docker-compose.yml            # PostgreSQL + PgBouncer + RabbitMQ
│   └── pgbouncer/
│       └── pgbouncer.ini
│
├── docs/
│   └── adr/                          # Architecture Decision Records
│       ├── 001-pessimistic-vs-occ.md
│       ├── 002-dapper-over-ef-core.md
│       ├── 003-transactional-outbox.md
│       └── 004-lgpd-anonymization.md
│
├── .editorconfig
├── .gitignore
├── Directory.Build.props
├── fintech-core-engine.sln
└── README.md
```

---

## Getting Started

### Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| [.NET SDK](https://dotnet.microsoft.com/) | 9.0+ | Build and run the application |
| [Docker](https://www.docker.com/) | 24+ | Local infrastructure (PostgreSQL, PgBouncer, RabbitMQ) |
| [Docker Compose](https://docs.docker.com/compose/) | v2+ | Orchestrate local containers |

### Running Locally

**1. Start infrastructure:**

```bash
docker compose -f docker/docker-compose.yml up -d
```

This starts:
- **PostgreSQL 15** on port `5432`
- **PgBouncer** on port `6432` (transaction pooling mode)
- **RabbitMQ** on port `5672` (management UI at `http://localhost:15672`)

**2. Apply the database migration:**

```bash
psql -h localhost -p 5432 -U postgres -d banco_financeiro \
  -v ON_ERROR_STOP=1 -f migrations/001_init_schema.sql
```

**3. Run the application:**

```bash
cd src/Api
dotnet run
```

The API will be available at `https://localhost:5001`. Swagger UI at `/swagger`.

**4. Verify the stack:**

```bash
# Check database health
psql -h localhost -p 6432 -U svc_api -d banco_financeiro \
  -c "SELECT * FROM bancario.vw_health_check;"

# Check RabbitMQ
curl -s http://guest:guest@localhost:15672/api/overview | jq .queue_totals

# Check outbox relay
curl -s https://localhost:5001/health | jq
```

### Running Tests

```bash
# Unit tests
dotnet test tests/Unit/

# Integration tests (requires Docker — uses Testcontainers)
dotnet test tests/Integration/
```

---

## Operational Runbooks

| Scenario | Action |
|---|---|
| Outbox backlog growing | Check RabbitMQ connectivity. Monitor `outbox_pendentes` metric. Restart relay if stuck. |
| Rows in DEFAULT partition | Run `SELECT bancario.manter_particoes_futuras(3);` then `SELECT bancario.migrar_default_encargos();` |
| LGPD anonymization request | Verify retention period via `vw_usuarios_elegiveis_anonimizacao`. Call `bancario.anonimizar_usuario(uuid)`. |
| Disaster recovery restore | After restore, re-apply pending anonymizations from the request log. |
| PgBouncer pool saturation | Check for long-running transactions: `SELECT * FROM pg_stat_activity WHERE state = 'idle in transaction';` |

---

## Architecture Decision Records

| ADR | Title | Status |
|---|---|---|
| [ADR-001](docs/adr/001-pessimistic-vs-occ.md) | Pessimistic locking for webhooks, OCC for batch processing | Accepted |
| [ADR-002](docs/adr/002-dapper-over-ef-core.md) | Dapper as primary data access, EF Core as optional read layer | Accepted |
| [ADR-003](docs/adr/003-transactional-outbox.md) | PostgreSQL-native outbox over MassTransit outbox | Accepted |
| [ADR-004](docs/adr/004-lgpd-anonymization.md) | Deferred pseudonymization with salted hash | Accepted |

---

## License

This project is licensed under the [MIT License](LICENSE).
