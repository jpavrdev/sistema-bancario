-- =============================================================================
-- 001_init_schema.sql
-- SISTEMA BANCÁRIO — DDL DE PRODUÇÃO CONSOLIDADO (PostgreSQL 15+)
--
-- Artefato aprovado pelo Comitê Técnico de Engenharia de Dados.
-- Consolidação final: modelagem, hiperescala, segurança e Day-2 Ops.
--
-- Executar: psql -U postgres -d banco_financeiro -f 001_init_schema.sql
--
-- Ordem de dependência (9 seções):
--   1. Extensões
--   2. Roles e ENUMs
--   3. Tabelas Base (com OCC, LGPD, constraints)
--   4. Tabelas Particionadas + DEFAULT + partições dinâmicas
--   5. Tabela de Fila (outbox_eventos)
--   6. Índices (B-Tree, BRIN, parciais)
--   7. Funções de Negócio
--   8. Triggers (auditoria JSONB, outbox, validações, defense-in-depth)
--   9. Segurança Final (GRANTs, RLS, Views, Timeouts)
-- =============================================================================

-- ┌──────────────────────────────────────────────────────────────────────────┐
-- │                    REUNIÃO DO COMITÊ TÉCNICO                            │
-- ├──────────────────────────────────────────────────────────────────────────┤
-- │                                                                         │
-- │  Arquiteto (A): "Estrutura de dependência está fechada. Confirmo:       │
-- │    mantemos as duas estratégias de concorrência — lock pessimista       │
-- │    para API real-time e OCC (versao + CAS) para batch/liquidação."      │
-- │                                                                         │
-- │  DBRE (B): "Sim, ambas ficam. Mas meu ponto principal: o app_user.     │
-- │    Esse role da aplicação NÃO pode ter DELETE nem DROP em nenhuma       │
-- │    tabela financeira. INSERT + UPDATE + SELECT, ponto. O trigger        │
-- │    fn_bloquear_delete é defense-in-depth, mas o GRANT é a primeira     │
-- │    barreira."                                                           │
-- │                                                                         │
-- │  A: "Concordo. E a partição DEFAULT para encargos e audit_log?"         │
-- │                                                                         │
-- │  B: "Inegociável. Sem DEFAULT, um INSERT em mês sem partição explode   │
-- │    em produção à meia-noite. Dados caem na DEFAULT, a function          │
-- │    manter_particoes_futuras cria a partição correta, e                  │
-- │    migrar_default_encargos move os registros. Duas camadas."            │
-- │                                                                         │
-- │  A: "Encontrei três bugs na versão anterior que corrigi:                │
-- │    1) A multa não atualizava saldo_devedor — encargo era inserido       │
-- │       mas a dívida não subia. Agora o CTE faz INSERT + UPDATE.          │
-- │    2) aplicar_encargos modificava saldo_devedor sem incrementar         │
-- │       a coluna versao. Isso quebra o OCC — pagamento concorrente        │
-- │       passava com saldo stale. Agora versao sobe junto.                 │
-- │    3) fn_bloquear_delete impedia migrar_default_encargos de fazer       │
-- │       o DELETE da DEFAULT. Agora a trigger aceita bypass via GUC        │
-- │       bancario.bypass_delete_lock (escopo de transação)."               │
-- │                                                                         │
-- │  B: "Excelente. Aprovo. E toda function leva SET search_path para      │
-- │    CVE-2018-1058. hash_cpf sai do retorno da anonimização. Um          │
-- │    arquivo, 9 seções, BEGIN/COMMIT. Produção."                          │
-- │                                                                         │
-- │  A: "Fechado."                                                          │
-- │                                                                         │
-- └──────────────────────────────────────────────────────────────────────────┘

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 1: EXTENSÕES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Schema dedicado (isolamento do public)
CREATE SCHEMA IF NOT EXISTS bancario;
SET search_path = bancario, public;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 2: ROLES E ENUMS
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 2.1 Roles ─────────────────────────────────────────────────────────────
-- Hierarquia: app_readonly ⊂ app_user ⊂ app_jobs ⊂ app_dba
-- Todas NOLOGIN (group roles). Login users concretos criados via Vault.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_readonly') THEN
        CREATE ROLE app_readonly NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_jobs') THEN
        CREATE ROLE app_jobs NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_dba') THEN
        CREATE ROLE app_dba NOLOGIN;
    END IF;
END;
$$;

GRANT app_readonly TO app_user;
GRANT app_user     TO app_jobs;
GRANT app_jobs     TO app_dba;

-- Login users concretos (senhas via Vault/Secrets Manager — NUNCA hardcode)
-- CREATE USER svc_api       LOGIN IN ROLE app_user;
-- CREATE USER svc_batch     LOGIN IN ROLE app_jobs;
-- CREATE USER svc_dba       LOGIN IN ROLE app_dba;
-- CREATE USER svc_dashboard LOGIN IN ROLE app_readonly;

-- ─── 2.2 Tipos Enumerados (idempotentes via DO + EXCEPTION) ───────────────

DO $$ BEGIN CREATE TYPE bancario.tipo_estado_civil AS ENUM (
    'solteiro','casado','divorciado','viuvo','uniao_estavel'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE bancario.tipo_sexo AS ENUM (
    'masculino','feminino','outro','nao_informado'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE bancario.tipo_forma_pagamento AS ENUM (
    'pix','debito','credito','boleto','transferencia_bancaria'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE bancario.tipo_status_contrato AS ENUM (
    'ativo','quitado','inadimplente','cancelado','renegociado'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE bancario.tipo_status_parcela AS ENUM (
    'pendente','paga','parcialmente_paga','atrasada','cancelada','renegociada'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN CREATE TYPE bancario.tipo_encargo AS ENUM (
    'multa_atraso','juros_mora','taxa_administrativa'
); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 3: TABELAS BASE
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 3.1 USUÁRIOS (+ colunas LGPD) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bancario.usuarios (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cpf                   VARCHAR(11) UNIQUE NOT NULL,
    nome                  VARCHAR(100) NOT NULL,
    sobrenome             VARCHAR(100) NOT NULL,
    data_nascimento       DATE NOT NULL,
    estado_civil          bancario.tipo_estado_civil,
    sexo                  bancario.tipo_sexo,
    anonimizado_em        TIMESTAMPTZ,
    motivo_anonimizacao   TEXT,
    criado_em             TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    atualizado_em         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ─── 3.2 CONTRATOS ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bancario.contratos (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id              UUID NOT NULL REFERENCES bancario.usuarios(id) ON DELETE RESTRICT,
    descricao               VARCHAR(255) NOT NULL,
    valor_total_financiado  NUMERIC(15, 2) NOT NULL,
    taxa_juros_mensal       NUMERIC(7, 6) NOT NULL,
    taxa_multa_atraso       NUMERIC(7, 6) NOT NULL,
    status                  bancario.tipo_status_contrato NOT NULL DEFAULT 'ativo',
    data_assinatura         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    criado_em               TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT chk_valor_financiado_positivo CHECK (valor_total_financiado > 0),
    CONSTRAINT chk_taxa_juros_nao_negativa   CHECK (taxa_juros_mensal >= 0),
    CONSTRAINT chk_taxa_multa_nao_negativa   CHECK (taxa_multa_atraso >= 0)
);

-- ─── 3.3 PARCELAS (coluna OCC: versao) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS bancario.parcelas (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contrato_id      UUID NOT NULL REFERENCES bancario.contratos(id) ON DELETE RESTRICT,
    numero_parcela   INT NOT NULL,
    valor_principal  NUMERIC(15, 2) NOT NULL,
    data_vencimento  DATE NOT NULL,
    status           bancario.tipo_status_parcela NOT NULL DEFAULT 'pendente',
    saldo_devedor    NUMERIC(15, 2) NOT NULL,
    versao           INT NOT NULL DEFAULT 1,
    criado_em        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT uq_contrato_parcela           UNIQUE (contrato_id, numero_parcela),
    CONSTRAINT chk_valor_principal_positivo   CHECK (valor_principal > 0),
    CONSTRAINT chk_saldo_devedor_nao_negativo CHECK (saldo_devedor >= 0)
);

-- ─── 3.4 PAGAMENTOS ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bancario.pagamentos (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parcela_id        UUID NOT NULL REFERENCES bancario.parcelas(id) ON DELETE RESTRICT,
    valor_pago        NUMERIC(15, 2) NOT NULL,
    data_pagamento    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    forma_pagamento   bancario.tipo_forma_pagamento NOT NULL,
    codigo_transacao  VARCHAR(100) NOT NULL UNIQUE,
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT chk_valor_pago_positivo CHECK (valor_pago > 0)
);

-- ─── 3.5 ACORDOS / RENEGOCIAÇÕES ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bancario.acordos (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id            UUID NOT NULL REFERENCES bancario.usuarios(id) ON DELETE RESTRICT,
    contrato_original_id  UUID NOT NULL REFERENCES bancario.contratos(id) ON DELETE RESTRICT,
    novo_contrato_id      UUID NOT NULL REFERENCES bancario.contratos(id) ON DELETE RESTRICT,
    data_acordo           TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    desconto_concedido    NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
    saldo_renegociado     NUMERIC(15, 2) NOT NULL,
    observacoes           TEXT,

    CONSTRAINT chk_desconto_nao_negativo       CHECK (desconto_concedido >= 0),
    CONSTRAINT chk_saldo_renegociado_positivo  CHECK (saldo_renegociado > 0),
    CONSTRAINT chk_contratos_diferentes        CHECK (contrato_original_id <> novo_contrato_id)
);

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 4: TABELAS PARTICIONADAS + DEFAULT + PARTIÇÕES DINÂMICAS
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 4.1 ENCARGOS APLICADOS — PARTITION BY RANGE (data_referencia) ────────
CREATE TABLE IF NOT EXISTS bancario.encargos_aplicados (
    id              BIGINT GENERATED ALWAYS AS IDENTITY,
    parcela_id      UUID NOT NULL REFERENCES bancario.parcelas(id) ON DELETE RESTRICT,
    tipo            bancario.tipo_encargo NOT NULL,
    valor           NUMERIC(15, 2) NOT NULL,
    data_referencia DATE NOT NULL,
    justificativa   TEXT,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    PRIMARY KEY (id, data_referencia),

    CONSTRAINT chk_encargo_valor_positivo CHECK (valor > 0)
) PARTITION BY RANGE (data_referencia);

-- DEFAULT: rede de segurança — INSERTs nunca falham mesmo sem partição do mês
CREATE TABLE IF NOT EXISTS bancario.encargos_aplicados_default
    PARTITION OF bancario.encargos_aplicados DEFAULT;

-- ─── 4.2 AUDIT LOG — PARTITION BY RANGE (executado_em) ───────────────────
CREATE TABLE IF NOT EXISTS bancario.audit_log (
    id              BIGINT GENERATED ALWAYS AS IDENTITY,
    tabela          VARCHAR(63) NOT NULL,
    registro_id     TEXT NOT NULL,
    operacao        VARCHAR(10) NOT NULL CHECK (operacao IN ('INSERT', 'UPDATE', 'DELETE')),
    dados_antigos   JSONB,
    dados_novos     JSONB,
    usuario_db      VARCHAR(63) NOT NULL DEFAULT current_user,
    usuario_app     VARCHAR(100),
    ip_origem       INET,
    executado_em    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    PRIMARY KEY (id, executado_em)
) PARTITION BY RANGE (executado_em);

-- DEFAULT: rede de segurança
CREATE TABLE IF NOT EXISTS bancario.audit_log_default
    PARTITION OF bancario.audit_log DEFAULT;

-- ─── 4.3 PARTIÇÕES DINÂMICAS ─────────────────────────────────────────────
-- Gera partições mês a mês: jan/ano_corrente até 15 meses à frente.
-- Idempotente: verifica pg_class antes de criar.
DO $$
DECLARE
    v_start  DATE := make_date(EXTRACT(YEAR FROM CURRENT_DATE)::INT, 1, 1);
    v_end    DATE := (date_trunc('month', CURRENT_DATE) + INTERVAL '15 months')::DATE;
    v_cursor DATE;
    v_next   DATE;
    v_name   TEXT;
BEGIN
    v_cursor := v_start;

    WHILE v_cursor < v_end LOOP
        v_next := v_cursor + INTERVAL '1 month';

        -- encargos_aplicados
        v_name := FORMAT('encargos_aplicados_%s_%s',
                         EXTRACT(YEAR FROM v_cursor)::INT,
                         LPAD(EXTRACT(MONTH FROM v_cursor)::INT::TEXT, 2, '0'));
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_name) THEN
            EXECUTE FORMAT(
                'CREATE TABLE bancario.%I PARTITION OF bancario.encargos_aplicados '
                'FOR VALUES FROM (%L) TO (%L)',
                v_name, v_cursor, v_next
            );
        END IF;

        -- audit_log
        v_name := FORMAT('audit_log_%s_%s',
                         EXTRACT(YEAR FROM v_cursor)::INT,
                         LPAD(EXTRACT(MONTH FROM v_cursor)::INT::TEXT, 2, '0'));
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_name) THEN
            EXECUTE FORMAT(
                'CREATE TABLE bancario.%I PARTITION OF bancario.audit_log '
                'FOR VALUES FROM (%L) TO (%L)',
                v_name, v_cursor::TIMESTAMPTZ, v_next::TIMESTAMPTZ
            );
        END IF;

        v_cursor := v_next;
    END LOOP;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 5: TABELA DE FILA — TRANSACTIONAL OUTBOX
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS bancario.outbox_eventos (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo_evento     VARCHAR(100) NOT NULL,
    aggregate_type  VARCHAR(63) NOT NULL,
    aggregate_id    UUID NOT NULL,
    payload         JSONB NOT NULL,
    metadata        JSONB,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    publicado_em    TIMESTAMPTZ,
    tentativas      INT NOT NULL DEFAULT 0,
    erro_ultimo     TEXT
);

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 6: ÍNDICES (B-TREE E BRIN)
-- ═══════════════════════════════════════════════════════════════════════════

-- USUARIOS
CREATE INDEX IF NOT EXISTS idx_usuarios_anonimizados
    ON bancario.usuarios (anonimizado_em)
    WHERE anonimizado_em IS NOT NULL;

-- CONTRATOS
CREATE INDEX IF NOT EXISTS idx_contratos_usuario_status
    ON bancario.contratos (usuario_id, status);

-- PARCELAS
CREATE INDEX IF NOT EXISTS idx_parcelas_status_vencimento
    ON bancario.parcelas (status, data_vencimento)
    WHERE status IN ('pendente', 'parcialmente_paga', 'atrasada');

CREATE INDEX IF NOT EXISTS idx_parcelas_contrato_numero
    ON bancario.parcelas (contrato_id, numero_parcela);

-- PAGAMENTOS
CREATE INDEX IF NOT EXISTS idx_pagamentos_parcela_data
    ON bancario.pagamentos (parcela_id, data_pagamento);

CREATE INDEX IF NOT EXISTS idx_pagamentos_data
    ON bancario.pagamentos (data_pagamento);

-- (UNIQUE em codigo_transacao já cria B-Tree — hash index redundante removido)

-- ENCARGOS (BRIN: append-only cronológico)
CREATE INDEX IF NOT EXISTS idx_encargos_data_brin
    ON bancario.encargos_aplicados USING BRIN (data_referencia)
    WITH (pages_per_range = 32);

CREATE INDEX IF NOT EXISTS idx_encargos_parcela_tipo
    ON bancario.encargos_aplicados (parcela_id, tipo);

-- ACORDOS
CREATE INDEX IF NOT EXISTS idx_acordos_contrato_original
    ON bancario.acordos (contrato_original_id);

CREATE INDEX IF NOT EXISTS idx_acordos_usuario
    ON bancario.acordos (usuario_id);

-- AUDIT LOG
CREATE INDEX IF NOT EXISTS idx_audit_tabela_registro
    ON bancario.audit_log (tabela, registro_id);

CREATE INDEX IF NOT EXISTS idx_audit_executado_brin
    ON bancario.audit_log USING BRIN (executado_em);

-- OUTBOX
CREATE INDEX IF NOT EXISTS idx_outbox_pendentes
    ON bancario.outbox_eventos (criado_em)
    WHERE publicado_em IS NULL;

CREATE INDEX IF NOT EXISTS idx_outbox_tipo_aggregate
    ON bancario.outbox_eventos (tipo_evento, aggregate_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 7: FUNÇÕES DE NEGÓCIO
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 7.1 PAGAMENTO PESSIMISTA ─────────────────────────────────────────────
-- Lock pessimista (SELECT FOR UPDATE) + idempotência de webhook.
-- Ideal para: API real-time, operações unitárias.
CREATE OR REPLACE FUNCTION bancario.registrar_pagamento_pessimista(
    p_parcela_id        UUID,
    p_valor_pago        NUMERIC(15, 2),
    p_forma_pagamento   bancario.tipo_forma_pagamento,
    p_codigo_transacao  VARCHAR(100)
)
RETURNS TABLE (
    pagamento_id    UUID,
    novo_saldo      NUMERIC(15, 2),
    novo_status     bancario.tipo_status_parcela,
    foi_idempotente BOOLEAN
)
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE
    v_existing_id    UUID;
    v_saldo_atual    NUMERIC(15, 2);
    v_status_atual   bancario.tipo_status_parcela;
    v_pagamento_id   UUID;
    v_novo_saldo     NUMERIC(15, 2);
    v_novo_status    bancario.tipo_status_parcela;
BEGIN
    -- PASSO 0: IDEMPOTÊNCIA — webhook duplicado retorna resultado original
    SELECT pg.id INTO v_existing_id
      FROM pagamentos pg WHERE pg.codigo_transacao = p_codigo_transacao;

    IF FOUND THEN
        RETURN QUERY
            SELECT v_existing_id, p.saldo_devedor, p.status, TRUE
            FROM parcelas p WHERE p.id = p_parcela_id;
        RETURN;
    END IF;

    -- PASSO 1: LOCK PESSIMISTA (serializa escritas na parcela)
    SELECT p.saldo_devedor, p.status
      INTO v_saldo_atual, v_status_atual
      FROM parcelas p WHERE p.id = p_parcela_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parcela % não encontrada', p_parcela_id;
    END IF;

    -- PASSO 2: VALIDAÇÕES DE NEGÓCIO
    IF v_status_atual IN ('paga', 'cancelada', 'renegociada') THEN
        RAISE EXCEPTION 'Parcela % não aceita pagamentos (status: %)',
            p_parcela_id, v_status_atual;
    END IF;
    IF p_valor_pago <= 0 THEN
        RAISE EXCEPTION 'Valor deve ser positivo: %', p_valor_pago;
    END IF;
    IF p_valor_pago > v_saldo_atual THEN
        RAISE EXCEPTION 'Pagamento (R$ %) excede saldo (R$ %)',
            p_valor_pago, v_saldo_atual;
    END IF;

    -- PASSO 3: INSERT com ON CONFLICT (safety net contra race condition)
    INSERT INTO pagamentos (parcela_id, valor_pago, forma_pagamento, codigo_transacao)
    VALUES (p_parcela_id, p_valor_pago, p_forma_pagamento, p_codigo_transacao)
    ON CONFLICT (codigo_transacao) DO NOTHING
    RETURNING id INTO v_pagamento_id;

    -- Race condition: outro TX inseriu entre o SELECT e o INSERT
    IF v_pagamento_id IS NULL THEN
        RETURN QUERY
            SELECT pg.id, par.saldo_devedor, par.status, TRUE
            FROM pagamentos pg JOIN parcelas par ON par.id = pg.parcela_id
            WHERE pg.codigo_transacao = p_codigo_transacao;
        RETURN;
    END IF;

    -- PASSO 4: ATUALIZAÇÃO ATÔMICA do saldo + status + versão OCC
    v_novo_saldo  := v_saldo_atual - p_valor_pago;
    v_novo_status := CASE WHEN v_novo_saldo = 0 THEN 'paga'::bancario.tipo_status_parcela
                          ELSE 'parcialmente_paga'::bancario.tipo_status_parcela END;

    UPDATE parcelas
       SET saldo_devedor = v_novo_saldo,
           status = v_novo_status,
           versao = versao + 1
     WHERE id = p_parcela_id;

    RETURN QUERY SELECT v_pagamento_id, v_novo_saldo, v_novo_status, FALSE;
END;
$$;

-- ─── 7.2 PAGAMENTO OCC ───────────────────────────────────────────────────
-- Concorrência otimista (Compare-And-Swap na coluna versao).
-- Sem lock — ideal para batch/liquidação com PgBouncer.
CREATE OR REPLACE FUNCTION bancario.registrar_pagamento_occ(
    p_parcela_id        UUID,
    p_valor_pago        NUMERIC(15, 2),
    p_forma_pagamento   bancario.tipo_forma_pagamento,
    p_codigo_transacao  VARCHAR(100),
    p_versao_esperada   INT
)
RETURNS TABLE (
    pagamento_id    UUID,
    novo_saldo      NUMERIC(15, 2),
    novo_status     bancario.tipo_status_parcela,
    nova_versao     INT,
    foi_idempotente BOOLEAN,
    conflito_versao BOOLEAN
)
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE
    v_existing_id    UUID;
    v_pagamento_id   UUID;
    v_saldo_atual    NUMERIC(15, 2);
    v_status_atual   bancario.tipo_status_parcela;
    v_novo_saldo     NUMERIC(15, 2);
    v_novo_status    bancario.tipo_status_parcela;
    v_rows           INT;
BEGIN
    -- PASSO 0: IDEMPOTÊNCIA
    SELECT pg.id INTO v_existing_id
      FROM pagamentos pg WHERE pg.codigo_transacao = p_codigo_transacao;

    IF FOUND THEN
        RETURN QUERY
            SELECT v_existing_id, p.saldo_devedor, p.status, p.versao, TRUE, FALSE
            FROM parcelas p WHERE p.id = p_parcela_id;
        RETURN;
    END IF;

    -- PASSO 1: SNAPSHOT READ (sem lock — não segura conexão no pool)
    SELECT p.saldo_devedor, p.status
      INTO v_saldo_atual, v_status_atual
      FROM parcelas p WHERE p.id = p_parcela_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parcela % não encontrada', p_parcela_id;
    END IF;

    -- PASSO 2: VALIDAÇÕES
    IF v_status_atual IN ('paga', 'cancelada', 'renegociada') THEN
        RAISE EXCEPTION 'Parcela % não aceita pagamentos (status: %)',
            p_parcela_id, v_status_atual;
    END IF;
    IF p_valor_pago <= 0 THEN RAISE EXCEPTION 'Valor deve ser positivo'; END IF;
    IF p_valor_pago > v_saldo_atual THEN
        RAISE EXCEPTION 'Pagamento (R$ %) excede saldo (R$ %)', p_valor_pago, v_saldo_atual;
    END IF;

    -- PASSO 3: CAS (Compare-And-Swap) — UPDATE só se versao não mudou
    v_novo_saldo  := v_saldo_atual - p_valor_pago;
    v_novo_status := CASE WHEN v_novo_saldo = 0 THEN 'paga'::bancario.tipo_status_parcela
                          ELSE 'parcialmente_paga'::bancario.tipo_status_parcela END;

    UPDATE parcelas
       SET saldo_devedor = v_novo_saldo,
           status = v_novo_status,
           versao = versao + 1
     WHERE id = p_parcela_id AND versao = p_versao_esperada;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- Conflito de versão: outro TX alterou a parcela entre o read e o update
    IF v_rows = 0 THEN
        RETURN QUERY
            SELECT NULL::UUID, par.saldo_devedor, par.status, par.versao, FALSE, TRUE
            FROM parcelas par WHERE par.id = p_parcela_id;
        RETURN;
    END IF;

    -- PASSO 4: CAS bem-sucedido → inserir pagamento (DEPOIS do CAS)
    -- Inserir ANTES do CAS exigiria DELETE em caso de conflito, mas
    -- fn_bloquear_delete bloqueia DELETE em pagamentos. Ordem invertida resolve.
    INSERT INTO pagamentos (parcela_id, valor_pago, forma_pagamento, codigo_transacao)
    VALUES (p_parcela_id, p_valor_pago, p_forma_pagamento, p_codigo_transacao)
    ON CONFLICT (codigo_transacao) DO NOTHING
    RETURNING id INTO v_pagamento_id;

    IF v_pagamento_id IS NULL THEN
        RETURN QUERY
            SELECT pg.id, par.saldo_devedor, par.status, par.versao, TRUE, FALSE
            FROM pagamentos pg JOIN parcelas par ON par.id = pg.parcela_id
            WHERE pg.codigo_transacao = p_codigo_transacao;
        RETURN;
    END IF;

    RETURN QUERY
        SELECT v_pagamento_id, v_novo_saldo, v_novo_status, p_versao_esperada + 1, FALSE, FALSE;
END;
$$;

-- ─── 7.3 ENCARGOS (JUROS + MULTAS) ──────────────────────────────────────
-- Job diário singleton: advisory lock impede execução concorrente.
-- SKIP LOCKED evita deadlock com pagamentos em paralelo.
--
-- BUG FIX v2: agora incrementa versao ao alterar saldo_devedor,
-- garantindo que pagamentos OCC concorrentes detectam a mudança.
-- BUG FIX v2: multas agora atualizam saldo_devedor (antes só inseriam o encargo).
CREATE OR REPLACE FUNCTION bancario.aplicar_encargos(p_data_referencia DATE)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE
    C_LOCK_ID CONSTANT BIGINT := 8675309001;
    v_count_juros   INT := 0;
    v_count_multas  INT := 0;
    v_parcela       RECORD;
    v_taxa_diaria   NUMERIC(10, 8);
    v_valor_juros   NUMERIC(15, 2);
BEGIN
    -- Advisory lock transacional: impede execução concorrente do mesmo job
    IF NOT pg_try_advisory_xact_lock(C_LOCK_ID) THEN
        RETURN jsonb_build_object(
            'status', 'ignorado',
            'mensagem', 'Outra instância do job já está executando'
        );
    END IF;

    -- ── JUROS MORA DIÁRIO ──────────────────────────────────────────────
    -- FOR UPDATE ... SKIP LOCKED: pula parcelas travadas por pagamentos
    FOR v_parcela IN
        SELECT p.id AS parcela_id, p.saldo_devedor, c.taxa_juros_mensal, p.data_vencimento
        FROM parcelas p
        JOIN contratos c ON c.id = p.contrato_id
        WHERE p.status IN ('atrasada', 'parcialmente_paga')
          AND p.data_vencimento < p_data_referencia
          AND p.saldo_devedor > 0
          AND NOT EXISTS (
              SELECT 1 FROM encargos_aplicados ea
              WHERE ea.parcela_id = p.id
                AND ea.data_referencia = p_data_referencia
                AND ea.tipo = 'juros_mora'
          )
        FOR UPDATE OF p SKIP LOCKED
    LOOP
        v_taxa_diaria := v_parcela.taxa_juros_mensal / 30.0;
        v_valor_juros := ROUND(v_parcela.saldo_devedor * v_taxa_diaria, 2);

        IF v_valor_juros > 0 THEN
            INSERT INTO encargos_aplicados (parcela_id, tipo, valor, data_referencia, justificativa)
            VALUES (v_parcela.parcela_id, 'juros_mora', v_valor_juros, p_data_referencia,
                    FORMAT('Juros mora: %s dia(s) de atraso',
                           (p_data_referencia - v_parcela.data_vencimento)));

            -- FIX: incrementa versao junto com saldo (consistência OCC)
            UPDATE parcelas
               SET saldo_devedor = saldo_devedor + v_valor_juros,
                   status = 'atrasada',
                   versao = versao + 1
             WHERE id = v_parcela.parcela_id;

            v_count_juros := v_count_juros + 1;
        END IF;
    END LOOP;

    -- ── MULTA FIXA (primeiro dia de atraso) ────────────────────────────
    -- FIX: CTE encadeado — INSERT do encargo + UPDATE do saldo_devedor + versao
    WITH multas_inseridas AS (
        INSERT INTO encargos_aplicados (parcela_id, tipo, valor, data_referencia, justificativa)
        SELECT p.id, 'multa_atraso', ROUND(p.valor_principal * c.taxa_multa_atraso, 2),
               p_data_referencia, 'Multa fixa por atraso — primeiro dia'
        FROM parcelas p
        JOIN contratos c ON c.id = p.contrato_id
        WHERE p.data_vencimento = p_data_referencia - INTERVAL '1 day'
          AND p.status IN ('pendente', 'parcialmente_paga')
          AND p.saldo_devedor > 0
          AND NOT EXISTS (
              SELECT 1 FROM encargos_aplicados ea
              WHERE ea.parcela_id = p.id AND ea.tipo = 'multa_atraso'
          )
        RETURNING parcela_id, valor
    ),
    -- FIX v2: atualizar saldo_devedor com valor da multa + incrementar versao
    saldos_atualizados AS (
        UPDATE parcelas p
           SET saldo_devedor = p.saldo_devedor + mi.valor,
               versao = p.versao + 1
          FROM multas_inseridas mi
         WHERE p.id = mi.parcela_id
        RETURNING p.id
    )
    SELECT COUNT(*) INTO v_count_multas FROM saldos_atualizados;

    -- Marcar como atrasada parcelas vencidas que ainda estão pendentes
    UPDATE parcelas
       SET status = 'atrasada'
     WHERE data_vencimento < p_data_referencia
       AND status = 'pendente'
       AND saldo_devedor > 0;

    RETURN jsonb_build_object(
        'status', 'concluido',
        'data_referencia', p_data_referencia,
        'juros_aplicados', v_count_juros,
        'multas_aplicadas', v_count_multas,
        'executado_em', clock_timestamp()
    );
END;
$$;

-- ─── 7.4 ANONIMIZAÇÃO LGPD ──────────────────────────────────────────────
-- Pseudo-anonimização: substitui PII por hash, preserva integridade
-- referencial para BACEN. NÃO retorna hash_cpf (brute-force em minutos).
CREATE OR REPLACE FUNCTION bancario.anonimizar_usuario(
    p_usuario_id    UUID,
    p_motivo        TEXT DEFAULT 'Solicitação LGPD Art. 18',
    p_forcar_ativo  BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE
    v_contratos_ativos INT;
    v_hash_cpf         TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM usuarios WHERE id = p_usuario_id AND anonimizado_em IS NOT NULL) THEN
        RETURN jsonb_build_object('status', 'ja_anonimizado',
            'mensagem', 'Usuário já foi anonimizado anteriormente');
    END IF;

    SELECT COUNT(*) INTO v_contratos_ativos FROM contratos
    WHERE usuario_id = p_usuario_id AND status IN ('ativo', 'inadimplente');

    IF v_contratos_ativos > 0 AND NOT p_forcar_ativo THEN
        RETURN jsonb_build_object('status', 'bloqueado',
            'mensagem', FORMAT('%s contrato(s) ativo(s). Anonimização bloqueada.', v_contratos_ativos),
            'contratos_ativos', v_contratos_ativos);
    END IF;

    v_hash_cpf := encode(digest(
        (SELECT cpf FROM usuarios WHERE id = p_usuario_id), 'sha256'
    ), 'hex');

    UPDATE usuarios
       SET cpf = 'ANON' || LEFT(v_hash_cpf, 7),
           nome = 'ANONIMIZADO', sobrenome = 'ANONIMIZADO',
           data_nascimento = '1900-01-01', estado_civil = NULL,
           sexo = 'nao_informado', anonimizado_em = clock_timestamp(),
           motivo_anonimizacao = p_motivo
     WHERE id = p_usuario_id;

    -- NÃO retorna hash_cpf: 11 dígitos = ~100 bilhões, quebrável em minutos
    RETURN jsonb_build_object(
        'status', 'anonimizado',
        'usuario_id', p_usuario_id,
        'executado_em', clock_timestamp()
    );
END;
$$;

-- ─── 7.5 ARCHIVING — Exportar e desanexar partições ──────────────────────
CREATE OR REPLACE FUNCTION bancario.arquivar_particao_encargos(
    p_ano INT, p_mes INT, p_exportar_csv BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE
    v_nome TEXT; v_path TEXT; v_count BIGINT;
BEGIN
    v_nome := FORMAT('encargos_aplicados_%s_%s', p_ano, LPAD(p_mes::TEXT, 2, '0'));
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_nome) THEN
        RETURN jsonb_build_object('status', 'erro',
            'mensagem', FORMAT('Partição %s não encontrada', v_nome));
    END IF;
    EXECUTE FORMAT('SELECT COUNT(*) FROM bancario.%I', v_nome) INTO v_count;
    IF p_exportar_csv THEN
        v_path := FORMAT('/var/lib/postgresql/archive/encargos/%s.csv', v_nome);
        EXECUTE FORMAT('COPY bancario.%I TO %L WITH (FORMAT CSV, HEADER TRUE)', v_nome, v_path);
    END IF;
    EXECUTE FORMAT('ALTER TABLE bancario.encargos_aplicados DETACH PARTITION bancario.%I', v_nome);
    RETURN jsonb_build_object('status', 'arquivado', 'particao', v_nome,
        'registros', v_count, 'csv_exportado', p_exportar_csv,
        'executado_em', clock_timestamp());
END;
$$;

CREATE OR REPLACE FUNCTION bancario.arquivar_particao_audit(
    p_ano INT, p_mes INT, p_exportar_csv BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE
    v_nome TEXT; v_path TEXT; v_count BIGINT;
BEGIN
    v_nome := FORMAT('audit_log_%s_%s', p_ano, LPAD(p_mes::TEXT, 2, '0'));
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_nome) THEN
        RETURN jsonb_build_object('status', 'erro',
            'mensagem', FORMAT('Partição %s não encontrada', v_nome));
    END IF;
    EXECUTE FORMAT('SELECT COUNT(*) FROM bancario.%I', v_nome) INTO v_count;
    IF p_exportar_csv THEN
        v_path := FORMAT('/var/lib/postgresql/archive/audit/%s.csv', v_nome);
        EXECUTE FORMAT('COPY bancario.%I TO %L WITH (FORMAT CSV, HEADER TRUE)', v_nome, v_path);
    END IF;
    EXECUTE FORMAT('ALTER TABLE bancario.audit_log DETACH PARTITION bancario.%I', v_nome);
    RETURN jsonb_build_object('status', 'arquivado', 'particao', v_nome,
        'registros', v_count, 'csv_exportado', p_exportar_csv,
        'executado_em', clock_timestamp());
END;
$$;

-- ─── 7.6 MANUTENÇÃO DE PARTIÇÕES FUTURAS ─────────────────────────────────
-- Idempotente. Executar via pg_cron diariamente.
CREATE OR REPLACE FUNCTION bancario.manter_particoes_futuras(p_meses_adiante INT DEFAULT 3)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE
    v_mes DATE; v_next DATE; v_nome TEXT;
    v_criadas TEXT[] := '{}'; v_existentes INT := 0; i INT;
BEGIN
    FOR i IN 0..p_meses_adiante LOOP
        v_mes  := date_trunc('month', CURRENT_DATE + (i || ' months')::INTERVAL);
        v_next := v_mes + INTERVAL '1 month';

        v_nome := FORMAT('encargos_aplicados_%s_%s',
                         EXTRACT(YEAR FROM v_mes)::INT,
                         LPAD(EXTRACT(MONTH FROM v_mes)::INT::TEXT, 2, '0'));
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_nome) THEN
            EXECUTE FORMAT('CREATE TABLE bancario.%I PARTITION OF bancario.encargos_aplicados '
                           'FOR VALUES FROM (%L) TO (%L)', v_nome, v_mes::DATE, v_next::DATE);
            v_criadas := array_append(v_criadas, v_nome);
        ELSE v_existentes := v_existentes + 1; END IF;

        v_nome := FORMAT('audit_log_%s_%s',
                         EXTRACT(YEAR FROM v_mes)::INT,
                         LPAD(EXTRACT(MONTH FROM v_mes)::INT::TEXT, 2, '0'));
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_nome) THEN
            EXECUTE FORMAT('CREATE TABLE bancario.%I PARTITION OF bancario.audit_log '
                           'FOR VALUES FROM (%L) TO (%L)', v_nome, v_mes::TIMESTAMPTZ, v_next::TIMESTAMPTZ);
            v_criadas := array_append(v_criadas, v_nome);
        ELSE v_existentes := v_existentes + 1; END IF;
    END LOOP;

    RETURN jsonb_build_object('status', 'concluido', 'criadas', to_jsonb(v_criadas),
        'ja_existiam', v_existentes, 'executado_em', clock_timestamp());
END;
$$;

-- ─── 7.7 MIGRAÇÃO DE DADOS DA PARTIÇÃO DEFAULT ──────────────────────────
-- Move registros que caíram na DEFAULT para a partição correta.
-- FIX v2: usa GUC bancario.bypass_delete_lock para permitir o DELETE
-- na DEFAULT sem ser bloqueado por fn_bloquear_delete.
CREATE OR REPLACE FUNCTION bancario.migrar_default_encargos()
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
DECLARE v_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM bancario.encargos_aplicados_default;
    IF v_count = 0 THEN
        RETURN jsonb_build_object('status', 'vazio', 'registros', 0);
    END IF;

    -- Garantir que as partições de destino existem
    PERFORM bancario.manter_particoes_futuras(3);

    -- Ativar bypass temporário (escopo da transação apenas)
    PERFORM set_config('bancario.bypass_delete_lock', 'on', true);

    WITH movidos AS (
        DELETE FROM bancario.encargos_aplicados_default RETURNING *
    )
    INSERT INTO bancario.encargos_aplicados OVERRIDING SYSTEM VALUE
    SELECT * FROM movidos;

    -- Desativar bypass
    PERFORM set_config('bancario.bypass_delete_lock', 'off', true);

    RETURN jsonb_build_object('status', 'migrado', 'registros', v_count,
        'executado_em', clock_timestamp());
END;
$$;

-- ─── 7.8 OUTBOX CONSUMER — Poller com SKIP LOCKED ───────────────────────
CREATE OR REPLACE FUNCTION bancario.consumir_outbox_eventos(p_batch_size INT DEFAULT 100)
RETURNS SETOF bancario.outbox_eventos
LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
BEGIN
    RETURN QUERY
    WITH lote AS (
        SELECT id FROM outbox_eventos
        WHERE publicado_em IS NULL ORDER BY criado_em
        LIMIT p_batch_size FOR UPDATE SKIP LOCKED
    )
    UPDATE outbox_eventos o
       SET publicado_em = clock_timestamp(), tentativas = tentativas + 1
      FROM lote WHERE o.id = lote.id
    RETURNING o.*;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 8: TRIGGERS
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 8.1 Trigger Functions ────────────────────────────────────────────────

-- Auto-update atualizado_em
CREATE OR REPLACE FUNCTION bancario.fn_atualizar_timestamp()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
BEGIN
    NEW.atualizado_em := clock_timestamp();
    RETURN NEW;
END;
$$;

-- Validação status ↔ saldo_devedor (data consistency guard)
CREATE OR REPLACE FUNCTION bancario.fn_validar_status_parcela()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
BEGIN
    IF NEW.status = 'paga' AND NEW.saldo_devedor <> 0 THEN
        RAISE EXCEPTION 'Parcela paga com saldo_devedor = %', NEW.saldo_devedor;
    END IF;
    IF NEW.saldo_devedor = 0 AND NEW.status NOT IN ('paga', 'cancelada', 'renegociada') THEN
        RAISE EXCEPTION 'saldo_devedor = 0 mas status = "%"', NEW.status;
    END IF;
    IF NEW.status = 'pendente' AND TG_OP = 'UPDATE' THEN
        IF EXISTS (SELECT 1 FROM pagamentos WHERE parcela_id = NEW.id LIMIT 1) THEN
            RAISE EXCEPTION 'Parcela com pagamentos não pode voltar a pendente';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- Auditoria genérica BACEN (JSONB completo, SECURITY DEFINER + search_path fixo)
CREATE OR REPLACE FUNCTION bancario.fn_audit_trigger()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = bancario, pg_temp
AS $$
DECLARE
    v_usuario_app VARCHAR(100);
    v_ip_origem   INET;
    v_old_json    JSONB;
    v_new_json    JSONB;
    v_registro_id TEXT;
BEGIN
    v_usuario_app := current_setting('app.current_user', true);
    BEGIN
        v_ip_origem := current_setting('app.client_ip', true)::INET;
    EXCEPTION WHEN invalid_text_representation THEN
        v_ip_origem := NULL;
    END;

    IF TG_OP = 'DELETE' THEN
        v_old_json := to_jsonb(OLD); v_registro_id := OLD.id::TEXT;
        INSERT INTO audit_log (tabela, registro_id, operacao, dados_antigos, usuario_app, ip_origem)
        VALUES (TG_TABLE_NAME, v_registro_id, 'DELETE', v_old_json, v_usuario_app, v_ip_origem);
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        v_old_json := to_jsonb(OLD); v_new_json := to_jsonb(NEW); v_registro_id := NEW.id::TEXT;
        IF v_old_json IS DISTINCT FROM v_new_json THEN
            INSERT INTO audit_log (tabela, registro_id, operacao, dados_antigos, dados_novos, usuario_app, ip_origem)
            VALUES (TG_TABLE_NAME, v_registro_id, 'UPDATE', v_old_json, v_new_json, v_usuario_app, v_ip_origem);
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        v_new_json := to_jsonb(NEW); v_registro_id := NEW.id::TEXT;
        INSERT INTO audit_log (tabela, registro_id, operacao, dados_novos, usuario_app, ip_origem)
        VALUES (TG_TABLE_NAME, v_registro_id, 'INSERT', v_new_json, v_usuario_app, v_ip_origem);
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;

-- Outbox: evento após pagamento registrado
CREATE OR REPLACE FUNCTION bancario.fn_outbox_pagamento()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
BEGIN
    INSERT INTO outbox_eventos (tipo_evento, aggregate_type, aggregate_id, payload, metadata)
    VALUES ('pagamento.registrado', 'parcela', NEW.parcela_id,
        jsonb_build_object('pagamento_id', NEW.id, 'parcela_id', NEW.parcela_id,
            'valor_pago', NEW.valor_pago, 'forma_pagamento', NEW.forma_pagamento,
            'codigo_transacao', NEW.codigo_transacao, 'data_pagamento', NEW.data_pagamento),
        jsonb_build_object('correlation_id', NEW.codigo_transacao,
            'source', 'sistema-bancario', 'timestamp', clock_timestamp()));
    RETURN NEW;
END;
$$;

-- Outbox: status da parcela mudou
CREATE OR REPLACE FUNCTION bancario.fn_outbox_parcela_status()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO outbox_eventos (tipo_evento, aggregate_type, aggregate_id, payload)
        VALUES ('parcela.status_alterado', 'parcela', NEW.id,
            jsonb_build_object('parcela_id', NEW.id, 'contrato_id', NEW.contrato_id,
                'status_anterior', OLD.status, 'status_novo', NEW.status,
                'saldo_devedor', NEW.saldo_devedor));
    END IF;
    RETURN NEW;
END;
$$;

-- Outbox: status do contrato mudou
CREATE OR REPLACE FUNCTION bancario.fn_outbox_contrato_status()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO outbox_eventos (tipo_evento, aggregate_type, aggregate_id, payload)
        VALUES ('contrato.status_alterado', 'contrato', NEW.id,
            jsonb_build_object('contrato_id', NEW.id, 'usuario_id', NEW.usuario_id,
                'status_anterior', OLD.status, 'status_novo', NEW.status));
    END IF;
    RETURN NEW;
END;
$$;

-- Defense-in-depth: bloquear DELETE em tabelas financeiras
-- FIX v2: GUC bancario.bypass_delete_lock permite bypass para migração interna
CREATE OR REPLACE FUNCTION bancario.fn_bloquear_delete()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = bancario, pg_temp
AS $$
BEGIN
    -- Bypass controlado para operações internas (migrar_default_encargos)
    IF current_setting('bancario.bypass_delete_lock', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'DELETE na tabela % bloqueado. Use procedure de anonimização ou archiving.', TG_TABLE_NAME;
    RETURN NULL;
END;
$$;

-- ─── 8.2 Triggers (CREATE OR REPLACE — PostgreSQL 14+) ──────────────────

-- Timestamp automático
CREATE OR REPLACE TRIGGER trg_usuarios_atualizado_em
    BEFORE UPDATE ON bancario.usuarios
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_atualizar_timestamp();

-- Validação de parcela
CREATE OR REPLACE TRIGGER trg_validar_status_parcela
    BEFORE INSERT OR UPDATE ON bancario.parcelas
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_validar_status_parcela();

-- Auditoria BACEN (todas as tabelas de negócio)
CREATE OR REPLACE TRIGGER trg_audit_usuarios
    AFTER INSERT OR UPDATE OR DELETE ON bancario.usuarios
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_audit_trigger();

CREATE OR REPLACE TRIGGER trg_audit_contratos
    AFTER INSERT OR UPDATE OR DELETE ON bancario.contratos
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_audit_trigger();

CREATE OR REPLACE TRIGGER trg_audit_parcelas
    AFTER INSERT OR UPDATE OR DELETE ON bancario.parcelas
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_audit_trigger();

CREATE OR REPLACE TRIGGER trg_audit_pagamentos
    AFTER INSERT OR UPDATE OR DELETE ON bancario.pagamentos
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_audit_trigger();

CREATE OR REPLACE TRIGGER trg_audit_encargos
    AFTER INSERT OR UPDATE OR DELETE ON bancario.encargos_aplicados
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_audit_trigger();

CREATE OR REPLACE TRIGGER trg_audit_acordos
    AFTER INSERT OR UPDATE OR DELETE ON bancario.acordos
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_audit_trigger();

-- Outbox pattern (Kafka/RabbitMQ)
CREATE OR REPLACE TRIGGER trg_outbox_pagamento
    AFTER INSERT ON bancario.pagamentos
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_outbox_pagamento();

CREATE OR REPLACE TRIGGER trg_outbox_parcela_status
    AFTER UPDATE ON bancario.parcelas
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_outbox_parcela_status();

CREATE OR REPLACE TRIGGER trg_outbox_contrato_status
    AFTER UPDATE ON bancario.contratos
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_outbox_contrato_status();

-- Bloqueio de DELETE (defense-in-depth)
CREATE OR REPLACE TRIGGER trg_bloquear_delete_pagamentos
    BEFORE DELETE ON bancario.pagamentos
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_bloquear_delete();

CREATE OR REPLACE TRIGGER trg_bloquear_delete_encargos
    BEFORE DELETE ON bancario.encargos_aplicados
    FOR EACH ROW EXECUTE FUNCTION bancario.fn_bloquear_delete();

-- ═══════════════════════════════════════════════════════════════════════════
-- SEÇÃO 9: SEGURANÇA FINAL (GRANTs, RLS, Views, Timeouts)
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 9.1 Views Operacionais ──────────────────────────────────────────────

CREATE OR REPLACE VIEW bancario.vw_usuarios_elegiveis_anonimizacao AS
SELECT u.id, u.cpf, u.nome, u.sobrenome,
    MAX(c.data_assinatura) AS ultimo_contrato,
    BOOL_AND(c.status IN ('quitado', 'cancelado')) AS todos_encerrados,
    CASE WHEN BOOL_AND(c.status IN ('quitado', 'cancelado'))
              AND MAX(c.data_assinatura) < NOW() - INTERVAL '5 years'
         THEN TRUE ELSE FALSE END AS elegivel
FROM bancario.usuarios u
JOIN bancario.contratos c ON c.usuario_id = u.id
WHERE u.anonimizado_em IS NULL
GROUP BY u.id, u.cpf, u.nome, u.sobrenome;

CREATE OR REPLACE VIEW bancario.vw_particoes_tamanho AS
SELECT parent.relname AS tabela_pai, child.relname AS particao,
    pg_size_pretty(pg_relation_size(child.oid)) AS tamanho,
    pg_relation_size(child.oid) AS tamanho_bytes,
    COALESCE(spc.spcname, 'pg_default') AS tablespace,
    CASE WHEN spc.spcname LIKE '%cold%' THEN 'COLD'
         WHEN spc.spcname LIKE '%warm%' THEN 'WARM'
         ELSE 'HOT' END AS tier
FROM pg_inherits inh
JOIN pg_class parent ON inh.inhparent = parent.oid
JOIN pg_class child  ON inh.inhrelid  = child.oid
LEFT JOIN pg_tablespace spc ON child.reltablespace = spc.oid
WHERE parent.relname IN ('encargos_aplicados', 'audit_log')
ORDER BY parent.relname, child.relname;

CREATE OR REPLACE VIEW bancario.vw_alerta_particao_default AS
SELECT 'encargos_aplicados_default' AS particao,
    (SELECT COUNT(*) FROM bancario.encargos_aplicados_default) AS registros_orfaos,
    CASE WHEN (SELECT COUNT(*) FROM bancario.encargos_aplicados_default) > 0
         THEN 'ALERTA: dados na DEFAULT — criar partição!' ELSE 'OK' END AS status
UNION ALL
SELECT 'audit_log_default',
    (SELECT COUNT(*) FROM bancario.audit_log_default),
    CASE WHEN (SELECT COUNT(*) FROM bancario.audit_log_default) > 0
         THEN 'ALERTA: dados na DEFAULT — criar partição!' ELSE 'OK' END;

CREATE OR REPLACE VIEW bancario.vw_health_check AS
SELECT
    (SELECT COUNT(*) FROM bancario.contratos WHERE status = 'ativo') AS contratos_ativos,
    (SELECT COUNT(*) FROM bancario.parcelas WHERE status = 'atrasada') AS parcelas_atrasadas,
    (SELECT COUNT(*) FROM bancario.parcelas WHERE status IN ('pendente', 'parcialmente_paga')) AS parcelas_abertas,
    (SELECT COUNT(*) FROM bancario.outbox_eventos WHERE publicado_em IS NULL) AS outbox_pendentes,
    (SELECT MAX(criado_em) FROM bancario.outbox_eventos WHERE publicado_em IS NULL) AS outbox_mais_antigo,
    (SELECT COUNT(*) FROM pg_inherits i JOIN pg_class p ON i.inhparent = p.oid
     WHERE p.relname = 'encargos_aplicados') AS particoes_encargos,
    (SELECT COUNT(*) FROM pg_inherits i JOIN pg_class p ON i.inhparent = p.oid
     WHERE p.relname = 'audit_log') AS particoes_audit;

-- ─── 9.2 Row-Level Security (RLS) ────────────────────────────────────────

ALTER TABLE bancario.contratos ENABLE ROW LEVEL SECURITY;
ALTER TABLE bancario.acordos   ENABLE ROW LEVEL SECURITY;

-- app_user: isolamento por usuario_id via GUC app.current_user_id
DO $$ BEGIN
    CREATE POLICY pol_contratos_user_own ON bancario.contratos FOR ALL TO app_user
        USING (usuario_id = current_setting('app.current_user_id', true)::UUID)
        WITH CHECK (usuario_id = current_setting('app.current_user_id', true)::UUID);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE POLICY pol_acordos_user_own ON bancario.acordos FOR ALL TO app_user
        USING (usuario_id = current_setting('app.current_user_id', true)::UUID)
        WITH CHECK (usuario_id = current_setting('app.current_user_id', true)::UUID);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- FORCE RLS para que até o owner da tabela seja filtrado
ALTER TABLE bancario.contratos FORCE ROW LEVEL SECURITY;
ALTER TABLE bancario.acordos   FORCE ROW LEVEL SECURITY;

-- Jobs e DBA: acesso total (bypass RLS)
DO $$ BEGIN
    CREATE POLICY pol_contratos_jobs_full ON bancario.contratos FOR ALL TO app_jobs USING (TRUE);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE POLICY pol_acordos_jobs_full ON bancario.acordos FOR ALL TO app_jobs USING (TRUE);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─── 9.3 GRANTs — PRINCÍPIO DO MENOR PRIVILÉGIO ─────────────────────────

-- Schema access
GRANT USAGE ON SCHEMA bancario TO app_readonly;

-- Revogar tudo do PUBLIC (zero trust)
REVOKE ALL ON ALL TABLES    IN SCHEMA bancario FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA bancario FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA bancario FROM PUBLIC;

-- READ ONLY (app_readonly): dashboards, BI, relatórios
GRANT SELECT ON ALL TABLES IN SCHEMA bancario TO app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA bancario GRANT SELECT ON TABLES TO app_readonly;

-- READ/WRITE (app_user): API principal
-- ⚠ SEM DELETE — app_user NUNCA pode deletar dados financeiros
-- ⚠ SEM DROP  — role NOLOGIN não tem CREATE/DROP por padrão
GRANT INSERT, UPDATE ON bancario.usuarios       TO app_user;
GRANT INSERT, UPDATE ON bancario.contratos      TO app_user;
GRANT INSERT, UPDATE ON bancario.parcelas       TO app_user;
GRANT INSERT, UPDATE ON bancario.pagamentos     TO app_user;
GRANT INSERT         ON bancario.acordos        TO app_user;
GRANT INSERT, UPDATE ON bancario.outbox_eventos TO app_user;
GRANT INSERT         ON bancario.audit_log      TO app_user;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA bancario TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA bancario GRANT USAGE ON SEQUENCES TO app_user;

GRANT EXECUTE ON FUNCTION bancario.registrar_pagamento_pessimista(UUID, NUMERIC, bancario.tipo_forma_pagamento, VARCHAR) TO app_user;
GRANT EXECUTE ON FUNCTION bancario.registrar_pagamento_occ(UUID, NUMERIC, bancario.tipo_forma_pagamento, VARCHAR, INT) TO app_user;
GRANT EXECUTE ON FUNCTION bancario.consumir_outbox_eventos(INT) TO app_user;

-- JOBS (app_jobs): encargos, reconciliação, limpeza outbox
GRANT INSERT, UPDATE ON bancario.encargos_aplicados TO app_jobs;
GRANT UPDATE         ON bancario.parcelas           TO app_jobs;
GRANT INSERT         ON bancario.audit_log          TO app_jobs;
GRANT DELETE         ON bancario.outbox_eventos     TO app_jobs;
GRANT EXECUTE ON FUNCTION bancario.aplicar_encargos(DATE) TO app_jobs;

-- DBA (app_dba): archiving, LGPD, manutenção de partições
GRANT ALL ON bancario.encargos_aplicados TO app_dba;
GRANT ALL ON bancario.audit_log          TO app_dba;
GRANT EXECUTE ON FUNCTION bancario.anonimizar_usuario(UUID, TEXT, BOOLEAN) TO app_dba;
GRANT EXECUTE ON FUNCTION bancario.arquivar_particao_encargos(INT, INT, BOOLEAN) TO app_dba;
GRANT EXECUTE ON FUNCTION bancario.arquivar_particao_audit(INT, INT, BOOLEAN) TO app_dba;
GRANT EXECUTE ON FUNCTION bancario.manter_particoes_futuras(INT) TO app_dba;
GRANT EXECUTE ON FUNCTION bancario.migrar_default_encargos() TO app_dba;

-- ─── 9.4 Timeouts por Role ──────────────────────────────────────────────

ALTER ROLE app_readonly SET search_path = bancario;
ALTER ROLE app_user     SET search_path = bancario;
ALTER ROLE app_jobs     SET search_path = bancario;
ALTER ROLE app_dba      SET search_path = bancario;

ALTER ROLE app_readonly SET statement_timeout = '60s';
ALTER ROLE app_readonly SET lock_timeout = '5s';

ALTER ROLE app_user SET statement_timeout = '30s';
ALTER ROLE app_user SET lock_timeout = '10s';
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '60s';

ALTER ROLE app_jobs SET statement_timeout = '10min';
ALTER ROLE app_jobs SET lock_timeout = '30s';
ALTER ROLE app_jobs SET idle_in_transaction_session_timeout = '5min';

ALTER ROLE app_dba SET idle_in_transaction_session_timeout = '10min';

-- ─── 9.5 Comentários ────────────────────────────────────────────────────

COMMENT ON SCHEMA bancario IS 'Motor financeiro: contratos, parcelas, pagamentos, encargos e compliance.';

COMMENT ON TABLE bancario.usuarios           IS 'Cadastro de clientes. Suporta pseudo-anonimização LGPD.';
COMMENT ON TABLE bancario.contratos          IS 'Contratos de crédito — regras imutáveis da assinatura.';
COMMENT ON TABLE bancario.parcelas           IS 'Obrigações de pagamento. Coluna versao suporta OCC.';
COMMENT ON TABLE bancario.pagamentos         IS 'Transações financeiras. DELETE bloqueado por trigger.';
COMMENT ON TABLE bancario.encargos_aplicados IS 'Ledger de juros/multas. Particionada por mês. DEFAULT como safety net.';
COMMENT ON TABLE bancario.acordos            IS 'Renegociações: contrato_original → novo_contrato.';
COMMENT ON TABLE bancario.audit_log          IS 'Auditoria BACEN. JSONB imutável. Particionada por mês.';
COMMENT ON TABLE bancario.outbox_eventos     IS 'Transactional Outbox para Kafka/RabbitMQ.';

COMMENT ON FUNCTION bancario.registrar_pagamento_pessimista IS 'Pagamento atômico + idempotente (lock pessimista). Para API real-time.';
COMMENT ON FUNCTION bancario.registrar_pagamento_occ        IS 'Pagamento OCC sem lock (CAS na coluna versao). Para batch/liquidação.';
COMMENT ON FUNCTION bancario.aplicar_encargos               IS 'Job singleton: juros diários + multa fixa. Advisory lock + SKIP LOCKED.';
COMMENT ON FUNCTION bancario.anonimizar_usuario             IS 'Pseudo-anonimização LGPD. Preserva integridade BACEN. Sem hash_cpf no retorno.';
COMMENT ON FUNCTION bancario.arquivar_particao_encargos     IS 'Archiving: COPY CSV + DETACH para cold storage.';
COMMENT ON FUNCTION bancario.arquivar_particao_audit        IS 'Archiving: COPY CSV + DETACH para cold storage.';
COMMENT ON FUNCTION bancario.manter_particoes_futuras       IS 'Cria partições futuras. Rodar via pg_cron diariamente.';
COMMENT ON FUNCTION bancario.migrar_default_encargos        IS 'Migra dados da DEFAULT para partição correta. Usa bypass de delete lock.';
COMMENT ON FUNCTION bancario.consumir_outbox_eventos        IS 'Poller outbox com SKIP LOCKED para consumers concorrentes.';

-- ═══════════════════════════════════════════════════════════════════════════
-- TEMPLATE DE CONEXÃO DA APLICAÇÃO
--
--   BEGIN;
--   SET LOCAL app.current_user    = 'joao.silva@empresa.com';
--   SET LOCAL app.current_user_id = '550e8400-e29b-41d4-a716-446655440000';
--   SET LOCAL app.client_ip       = '192.168.1.100';
--   -- ... operações ...
--   COMMIT;
--
-- pg_cron (partições):
--   SELECT cron.schedule('manter-particoes', '0 3 * * *',
--       $$SELECT bancario.manter_particoes_futuras(3)$$);
--
-- pg_cron (encargos diários):
--   SELECT cron.schedule('encargos-diarios', '0 2 * * *',
--       $$SELECT bancario.aplicar_encargos(CURRENT_DATE)$$);
--
-- pg_cron (limpeza outbox publicados > 7 dias):
--   SELECT cron.schedule('limpar-outbox', '0 4 * * *',
--       $$DELETE FROM bancario.outbox_eventos WHERE publicado_em < NOW() - INTERVAL '7 days'$$);
--
-- pg_cron (alerta DEFAULT não vazia):
--   SELECT cron.schedule('alerta-default', '*/30 * * * *',
--       $$SELECT * FROM bancario.vw_alerta_particao_default WHERE status <> 'OK'$$);
-- ═══════════════════════════════════════════════════════════════════════════

COMMIT;
