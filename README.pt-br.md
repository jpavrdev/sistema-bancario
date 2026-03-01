# Fintech Core Engine

> **[English version](README.md)**

**Motor financeiro de produção projetado para correção transacional, segurança de concorrência e conformidade regulatória brasileira.**

Este sistema gerencia o ciclo de vida completo de contratos de crédito — da originação ao acompanhamento de parcelas, processamento de pagamentos, cálculo de juros e multas, renegociação e anonimização de dados pessoais (LGPD) — garantindo **zero cobranças duplicadas**, **zero eventos perdidos** e **rastreabilidade total** exigida pelo Banco Central do Brasil (BACEN).

---

## Sumário

- [O Problema](#o-problema)
- [Stack Tecnológica](#stack-tecnológica)
- [Visão Geral da Arquitetura](#visão-geral-da-arquitetura)
- [Decisões Arquiteturais](#decisões-arquiteturais)
  - [Controle de Concorrência Dual](#controle-de-concorrência-dual)
  - [Idempotência de Webhooks](#idempotência-de-webhooks)
  - [Transactional Outbox Pattern](#transactional-outbox-pattern)
  - [Particionamento à Prova de Falhas](#particionamento-à-prova-de-falhas)
  - [LGPD vs. Retenção Financeira BACEN](#lgpd-vs-retenção-financeira-bacen)
- [Schema do Banco de Dados](#schema-do-banco-de-dados)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Como Rodar](#como-rodar)
  - [Pré-requisitos](#pré-requisitos)
  - [Rodando Localmente](#rodando-localmente)
  - [Rodando os Testes](#rodando-os-testes)
- [Runbooks Operacionais](#runbooks-operacionais)
- [Architecture Decision Records](#architecture-decision-records)
- [Licença](#licença)

---

## O Problema

Sistemas financeiros enfrentam uma convergência única de problemas difíceis. Ignorar qualquer um deles resulta em perda financeira, quebra regulatória ou indisponibilidade:

| Problema | Consequência se Ignorado |
|---|---|
| Webhook entregue mais de uma vez pelo gateway | Cliente cobrado duas vezes pelo mesmo pagamento |
| Escritas concorrentes entre batch noturno e API real-time | Leitura de saldo stale → cálculo de juros incorreto |
| Broker de mensageria fora do ar (RabbitMQ/Kafka) | Eventos perdidos → sistemas downstream dessincronizados |
| Partição mensal não criada na virada do mês | Falha hard no INSERT → indisponibilidade total à meia-noite |
| Direito ao esquecimento (LGPD Art. 18) vs. retenção BACEN (5 anos) | Multa regulatória de qualquer um dos lados |

Este motor resolve **os cinco** no nível de banco de dados e aplicação, com estratégias de defesa em profundidade documentadas e testadas.

---

## Stack Tecnológica

| Camada | Tecnologia | Justificativa |
|---|---|---|
| **Runtime** | C# / .NET 9 | Alto throughput, GC previsível, OpenTelemetry nativo, suporte a AOT |
| **Banco de Dados** | PostgreSQL 15+ | Transações ACID, lógica de negócio em PL/pgSQL, particionamento nativo, Row-Level Security |
| **Acesso a Dados (hot path)** | Dapper | Micro-ORM para chamar functions PL/pgSQL diretamente — zero overhead de ORM no caminho crítico |
| **Acesso a Dados (leitura)** | EF Core *(opcional)* | Projeções LINQ para dashboards e queries analíticas |
| **Mensageria** | RabbitMQ via MassTransit | Transporte desacoplado de eventos; MassTransit abstrai o broker permitindo migração futura para Kafka |
| **Pool de Conexões** | PgBouncer (transaction mode) | Multiplexa milhares de conexões da aplicação em um pool controlado de conexões backend |
| **Observabilidade** | OpenTelemetry + Prometheus + Grafana | Tracing distribuído, métricas customizadas (backlog do outbox, saúde das partições) |
| **Containers** | Docker + Docker Compose | Ambiente local completo: PostgreSQL, PgBouncer, RabbitMQ, aplicação |

### Por que Dapper e não Entity Framework Core?

O motor financeiro tem lógica pesada em PL/pgSQL — funções como `registrar_pagamento_pessimista`, `aplicar_encargos`, `anonimizar_usuario` e o consumer do outbox com `SKIP LOCKED`. A aplicação C# é um **orquestrador**: ela chama essas functions e interpreta o retorno.

O EF Core foi desenhado para mapear objetos em tabelas e gerar SQL. Quando a lógica já está no banco, o ORM trabalha contra você: change tracking desnecessário, `DbContext` configurado com `HasQueryFilter` para RLS que já existe no PostgreSQL, chamadas via `FromSqlRaw` que anulam o propósito do ORM. Com PgBouncer em transaction pooling, o change tracker segurando referências em memória é um vetor de connection leak.

Dapper é um método de extensão sobre `IDbConnection`. Ele executa SQL, mapeia o resultado para um POCO e sai do caminho. Para o hot path transacional, é a escolha correta.

### Por que RabbitMQ e não Kafka?

O Kafka brilha quando o caso de uso exige **replay de eventos** e event sourcing — o offset é controlado pelo consumidor, tópicos são logs append-only. Mas o Kafka é pesado para operar: ZooKeeper/KRaft, brokers com estado, rebalanceamento de partições. Localmente, o `docker-compose` com Kafka é uma experiência penosa.

Nosso replay vem da **própria tabela de outbox** no PostgreSQL, não do broker. O broker é um canal de transporte, não um log de eventos. Para esse caso de uso, o RabbitMQ é mais que suficiente: startup em segundos, management UI integrada, quorum queues maduras em produção, consumo de memória previsível.

O **MassTransit** abstrai o transporte. Se um dia migrarmos para Kafka, é mudança de configuração, não de código.

---

## Visão Geral da Arquitetura

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        API Gateway / Load Balancer                       │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                  ┌────────────▼────────────┐
                  │   .NET 9 API Service     │
                  │  (Minimal APIs + Dapper) │
                  │                          │
                  │  ┌────────────────────┐  │
                  │  │ Webhook de         │──┼──→ chama registrar_pagamento_pessimista()
                  │  │ Pagamento          │  │     via Dapper (SELECT FOR UPDATE)
                  │  └────────────────────┘  │
                  │  ┌────────────────────┐  │
                  │  │ Job de Encargos    │──┼──→ chama aplicar_encargos()
                  │  │ (Hosted Service)   │  │     via Dapper (Advisory Lock + SKIP LOCKED)
                  │  └────────────────────┘  │
                  │  ┌────────────────────┐  │
                  │  │ Outbox Relay       │──┼──→ chama consumir_outbox_eventos()
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
              │  │ schema   │ │ Tabelas       │  │
              │  │ bancario │ │ Particionadas │  │
              │  │ (tabelas,│ │ + partições   │  │
              │  │ funções, │ │ DEFAULT       │  │
              │  │ triggers)│ │               │  │
              │  └──────────┘ └───────────────┘  │
              └──────────────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Outbox Relay       │
                    │  publica eventos    │
                    │  via MassTransit    │
                    └──────────┬──────────┘
                               │
              ┌────────────────▼────────────────┐
              │         RabbitMQ Cluster          │
              │   (Quorum Queues em Produção)    │
              └────────────────┬────────────────┘
                               │
              ┌────────────────▼────────────────┐
              │     Consumidores Downstream       │
              │  (Notificações, Score de Crédito,│
              │   Contabilidade, Analytics)       │
              └─────────────────────────────────┘
```

---

## Decisões Arquiteturais

### Controle de Concorrência Dual

O motor usa **duas estratégias de concorrência** para workloads diferentes:

| Estratégia | Caso de Uso | Mecanismo | Por Quê |
|---|---|---|---|
| **Lock Pessimista** | Processamento de webhook de pagamento | `SELECT FOR UPDATE` na linha da parcela | Garante idempotência: primeiro worker processa, segundo bloqueia e detecta estado já liquidado |
| **Optimistic Concurrency Control (OCC)** | Cálculo de encargos em lote | `UPDATE ... WHERE versao = N` (Compare-And-Swap) | Evita manter row locks em milhares de registros; conflitos disparam retry |

**Invariante arquitetural:** A transação pessimista realiza **zero I/O externo** — nenhuma chamada HTTP, nenhuma escrita no broker. Todos os efeitos colaterais fluem pelo outbox. Isso previne pinning de conexões no PgBouncer durante picos de tráfego.

Por que isso importa: o PgBouncer em transaction mode só devolve a conexão ao pool quando a transação fecha. Se a transação pessimista fizer uma chamada HTTP para um serviço de notificação (round-trip de 200ms), essa conexão fica presa por toda a duração. Com 10 mil webhooks simultâneos, o pool satura. Com a transação sendo puramente local ao banco (poucos milissegundos), o pinning é insignificante.

### Idempotência de Webhooks

Gateways de pagamento (Stripe, PagSeguro, Adyen, Stone) entregam webhooks com semântica **at-least-once**. O mesmo `codigo_transacao` pode chegar 2, 5, 10 vezes. O motor trata duplicatas em três camadas:

1. **Verificação de idempotency key** — Antes de adquirir o lock na parcela, a function verifica se já existe um pagamento com o mesmo `codigo_transacao`. Se sim, retorna o resultado anterior imediatamente (sem mutação, sem lock adquirido).

2. **Guarda por estado** — Após adquirir o lock, se a parcela já está `paga`, a function retorna graciosamente. Isso trata a race condition onde dois workers passam pela verificação de idempotência simultaneamente.

3. **`ON CONFLICT DO NOTHING`** — Safety net final contra a janela de microssegundos entre o SELECT e o INSERT.

Três camadas. Zero cobranças duplicadas.

### Transactional Outbox Pattern

O sistema **nunca** faz dual write — gravar no banco **e** publicar no broker na mesma operação. O padrão adotado:

1. A lógica de negócio grava no banco **e** insere um evento em `outbox_eventos` — **na mesma transação**. Se a transação falhar, o evento nunca existiu. Se commitar, o evento está garantido.

2. Um relay dedicado (Hosted Service em .NET) faz polling em `outbox_eventos` usando `FOR UPDATE SKIP LOCKED`, publica no RabbitMQ via MassTransit e marca os eventos como publicados.

3. Se o RabbitMQ estiver fora do ar, os eventos se acumulam no outbox. O relay os drena quando o broker volta. **O fluxo de pagamentos nunca é bloqueado por indisponibilidade do broker.**

O `SKIP LOCKED` permite **escalar horizontalmente** o relay: múltiplas instâncias consomem eventos diferentes sem contenção entre si. Cada instância pega um subconjunto do backlog; nenhuma bloqueia a outra.

### Particionamento à Prova de Falhas

As tabelas `encargos_aplicados` (juros e multas) e `audit_log` (auditoria BACEN) são particionadas por mês (`PARTITION BY RANGE`). Três camadas de defesa impedem a falha catastrófica de uma partição inexistente:

| Camada | Mecanismo | Propósito |
|---|---|---|
| **Prevenção** | `manter_particoes_futuras(3)` executada diariamente via pg_cron | Cria partições com 3 meses de antecedência |
| **Rede de Segurança** | Partição `DEFAULT` em ambas as tabelas | Captura INSERTs quando nenhuma partição mensal correspondente existe |
| **Detecção** | View `vw_alerta_particao_default` monitorada a cada 30 min | Alerta se qualquer linha cair na DEFAULT (anomalia operacional) |

Se o cron job falhar, o sistema tem um **buffer de 3 meses** antes de a partição DEFAULT ser acionada. Se a DEFAULT capturar dados, a function `migrar_default_encargos()` move as linhas para a partição correta assim que ela for criada.

**O cenário de pesadelo — INSERT falhando na virada do mês porque a partição não existe — simplesmente não acontece.** A DEFAULT absorve os dados; o alerta notifica a equipe; a migração corrige. Três camadas, zero downtime.

### LGPD vs. Retenção Financeira BACEN

A regulação brasileira cria um conflito direto que toda Fintech precisa resolver:

- **LGPD (Lei 13.709/2018, Art. 18, inciso VI):** O titular tem direito à eliminação dos dados pessoais tratados com base no consentimento.
- **BACEN (Resolução 4.658 + CMN 4.893):** Instituições financeiras devem manter registros de operações por no mínimo **5 anos**.
- **Código Civil (Art. 205):** Prescrição geral de **10 anos** para ações de cobrança.

**A solução adotada:**

1. **Segregação de dados** — Dados pessoais (nome, CPF, e-mail, telefone) vivem **exclusivamente** na tabela `usuarios`. Todas as outras tabelas referenciam o usuário por UUID. Nenhuma tabela transacional contém dado pessoal.

2. **Anonimização diferida** — Quando o titular solicita eliminação, o sistema verifica obrigações regulatórias ativas (contratos abertos, prazo BACEN não expirado). Se existirem, a solicitação é **enfileirada** com data futura de execução. A anonimização só ocorre quando todas as obrigações legais expiram. Isso está previsto no Art. 16, inciso I da LGPD, que permite retenção por obrigação legal.

3. **Pseudonimização irreversível** — A function `anonimizar_usuario()` substitui:
   - Nome e sobrenome → `"ANONIMIZADO"`
   - CPF → Hash SHA-256 com salt via `pgcrypto` (prefixo `ANON` + 7 chars do hash, mantendo unicidade do campo)
   - Data de nascimento → `1900-01-01` (valor sentinela)
   - Estado civil e sexo → `NULL` / `nao_informado`

   O registro **não é deletado**. As foreign keys de contratos, parcelas e pagamentos continuam válidas. A integridade referencial é preservada. O dado pessoal é irrecuperável.

4. **Isolamento do audit_log** — A trigger de auditoria captura **apenas UUIDs e diffs transacionais**, nunca dados pessoais. Isso é enforçado por design: a function de auditoria opera com whitelist de colunas (adição explícita), não blacklist (exclusão por omissão). Uma coluna nova em qualquer tabela **não aparece automaticamente** no audit_log.

5. **Consistência com backups** — A tabela de solicitações de anonimização funciona como um log. Após qualquer restore de disaster recovery, um job verifica e reaplica anonimizações pendentes.

**View de elegibilidade:** `vw_usuarios_elegiveis_anonimizacao` lista todos os usuários cujos contratos estão encerrados há mais de 5 anos e que são candidatos à pseudonimização.

---

## Schema do Banco de Dados

Todo o schema está definido em um único arquivo de migration atômico:

```
migrations/
└── 001_init_schema.sql    # Fonte única de verdade (BEGIN/COMMIT)
```

**9 seções em ordem estrita de dependência:**

| # | Seção | Conteúdo |
|---|---|---|
| 1 | Extensões | `pgcrypto` |
| 2 | Roles e ENUMs | `app_readonly`, `app_user`, `app_jobs`, `app_dba` + 6 tipos enumerados |
| 3 | Tabelas Base | `usuarios`, `contratos`, `parcelas` (com `versao` para OCC), `pagamentos`, `acordos` |
| 4 | Tabelas Particionadas | `encargos_aplicados`, `audit_log` (range mensal) + partições DEFAULT + criação dinâmica |
| 5 | Outbox | `outbox_eventos` (Transactional Outbox para MassTransit/RabbitMQ) |
| 6 | Índices | B-Tree (operacional), BRIN (append-only cronológico), índices parciais |
| 7 | Funções de Negócio | Pagamento pessimista, pagamento OCC, encargos em lote, anonimização LGPD, archiving, consumer do outbox |
| 8 | Triggers | Auditoria BACEN, eventos do outbox, validação de status, bloqueio de DELETE |
| 9 | Segurança | GRANTs (menor privilégio), RLS (isolamento por tenant), timeouts por role |

**Hierarquia de roles (Princípio do Menor Privilégio):**

```
app_readonly  ← SELECT em todas as tabelas (dashboards, BI)
    └── app_user  ← INSERT + UPDATE nas tabelas operacionais (API principal)
            └── app_jobs  ← Encargos, reconciliação, limpeza do outbox
                    └── app_dba  ← Archiving, LGPD, manutenção de partições
```

Nenhuma role tem permissão de `DELETE` em tabelas financeiras. A trigger `fn_bloquear_delete` é defesa em profundidade: mesmo que um GRANT seja concedido por engano, o DELETE é bloqueado no nível da trigger.

---

## Estrutura do Projeto

```
fintech-core-engine/
├── src/
│   ├── Api/                          # Endpoints Minimal API (Apresentação)
│   │   ├── Endpoints/
│   │   │   ├── PaymentEndpoints.cs
│   │   │   ├── ContractEndpoints.cs
│   │   │   └── AdminEndpoints.cs
│   │   └── Program.cs
│   │
│   ├── Application/                  # Casos de uso e orquestração
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
│   ├── Infrastructure/               # Acesso a dados e integrações externas
│   │   ├── Database/
│   │   │   ├── DapperConnectionFactory.cs
│   │   │   ├── PaymentRepository.cs
│   │   │   └── OutboxRepository.cs
│   │   ├── Messaging/
│   │   │   ├── OutboxRelayService.cs       # Hosted Service: poll outbox → publica via MassTransit
│   │   │   └── MassTransitConfiguration.cs
│   │   └── BackgroundJobs/
│   │       └── AccrualJobService.cs        # Hosted Service: cálculo diário de juros/multas
│   │
│   └── Domain/                       # POCOs, enums, tipos de resultado (sem entidades ORM)
│       ├── PaymentResult.cs
│       ├── AccrualResult.cs
│       └── Enums/
│
├── tests/
│   ├── Integration/                  # Testes contra PostgreSQL real (Testcontainers)
│   └── Unit/
│
├── migrations/
│   └── 001_init_schema.sql           # Migration atômica única (fonte de verdade)
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

## Como Rodar

### Pré-requisitos

| Ferramenta | Versão | Propósito |
|---|---|---|
| [.NET SDK](https://dotnet.microsoft.com/) | 9.0+ | Compilar e executar a aplicação |
| [Docker](https://www.docker.com/) | 24+ | Infraestrutura local (PostgreSQL, PgBouncer, RabbitMQ) |
| [Docker Compose](https://docs.docker.com/compose/) | v2+ | Orquestrar os containers locais |

### Rodando Localmente

**1. Subir a infraestrutura:**

```bash
docker compose -f docker/docker-compose.yml up -d
```

Isso inicia:
- **PostgreSQL 15** na porta `5432`
- **PgBouncer** na porta `6432` (transaction pooling mode)
- **RabbitMQ** na porta `5672` (management UI em `http://localhost:15672`, user: `guest`, senha: `guest`)

**2. Aplicar a migration do banco:**

```bash
psql -h localhost -p 5432 -U postgres -d banco_financeiro \
  -v ON_ERROR_STOP=1 -f migrations/001_init_schema.sql
```

O script roda dentro de uma transação única (`BEGIN/COMMIT`). Se qualquer statement falhar, o banco permanece intacto — zero estado parcial.

**3. Rodar a aplicação:**

```bash
cd src/Api
dotnet run
```

A API estará disponível em `https://localhost:5001`. Swagger UI em `/swagger`.

**4. Verificar a stack:**

```bash
# Health check do banco de dados
psql -h localhost -p 6432 -U svc_api -d banco_financeiro \
  -c "SELECT * FROM bancario.vw_health_check;"

# Health check do RabbitMQ
curl -s http://guest:guest@localhost:15672/api/overview | jq .queue_totals

# Health check da aplicação
curl -s https://localhost:5001/health | jq
```

### Rodando os Testes

```bash
# Testes unitários
dotnet test tests/Unit/

# Testes de integração (requer Docker — usa Testcontainers)
dotnet test tests/Integration/
```

Os testes de integração sobem um container PostgreSQL efêmero via [Testcontainers](https://dotnet.testcontainers.org/), aplicam a migration `001_init_schema.sql` e rodam os cenários contra um banco real. Sem mocks de banco de dados.

---

## Runbooks Operacionais

| Cenário | Ação |
|---|---|
| Backlog do outbox crescendo | Verificar conectividade com RabbitMQ. Monitorar métrica `outbox_pendentes`. Reiniciar relay se estiver travado. |
| Linhas na partição DEFAULT | Executar `SELECT bancario.manter_particoes_futuras(3);` e depois `SELECT bancario.migrar_default_encargos();` |
| Solicitação de anonimização LGPD | Verificar elegibilidade via `vw_usuarios_elegiveis_anonimizacao`. Chamar `SELECT bancario.anonimizar_usuario(uuid);` |
| Restore de disaster recovery | Após o restore, reaplicar anonimizações pendentes a partir do log de solicitações. |
| Saturação do pool PgBouncer | Verificar transações longas: `SELECT * FROM pg_stat_activity WHERE state = 'idle in transaction';` |
| Job de encargos não executou | Verificar logs do Hosted Service. Executar manualmente: `SELECT bancario.aplicar_encargos(CURRENT_DATE);` |

---

## Architecture Decision Records

| ADR | Título | Status |
|---|---|---|
| [ADR-001](docs/adr/001-pessimistic-vs-occ.md) | Lock pessimista para webhooks, OCC para processamento em lote | Aceita |
| [ADR-002](docs/adr/002-dapper-over-ef-core.md) | Dapper como acesso primário, EF Core como camada opcional de leitura | Aceita |
| [ADR-003](docs/adr/003-transactional-outbox.md) | Outbox nativo do PostgreSQL sobre outbox do MassTransit | Aceita |
| [ADR-004](docs/adr/004-lgpd-anonymization.md) | Pseudonimização diferida com hash salteado | Aceita |

---

## Licença

Este projeto está licenciado sob a [MIT License](LICENSE).
