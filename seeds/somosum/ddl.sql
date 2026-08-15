-- Somos Um — schema do mandato participativo (semente pro vibe.sh)
-- {{SLUG}} é substituído pelo identificador do projeto na instalação.

create schema if not exists {{SLUG}};

create table if not exists {{SLUG}}.setores (
  id serial primary key,
  nome text not null,
  ativo boolean not null default true
);

create table if not exists {{SLUG}}.cidadaos (
  id bigserial primary key,
  tg_user_id bigint not null unique,
  nome text,
  setor_id int references {{SLUG}}.setores(id),
  consentiu_em timestamptz,
  consent_versao text,
  bloqueado boolean not null default false,
  criado_em timestamptz not null default now()
);

create table if not exists {{SLUG}}.usuarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  email text not null unique,
  senha_hash text not null,
  papel text not null check (papel in ('mediador','conselho','deputado','admin')),
  ativo boolean not null default true
);

create table if not exists {{SLUG}}.causas (
  id bigserial primary key,
  titulo text not null,
  resumo text,
  trilha text not null check (trilha in ('chamado','ideia')),
  tema text,
  competencia text check (competencia in
    ('estadual','municipal','federal','concessionaria','outra')),
  instrumento_sugerido text,
  setor_id int references {{SLUG}}.setores(id),
  apoios int not null default 0,
  status text not null default 'fila' check (status in
    ('fila','em_analise','no_conselho','aprovada','rejeitada',
     'devolvida','com_deputado','em_execucao','concluida')),
  criada_em timestamptz not null default now()
);

create table if not exists {{SLUG}}.demandas (
  id bigserial primary key,
  protocolo text not null unique,
  cidadao_id bigint not null references {{SLUG}}.cidadaos(id),
  causa_id bigint references {{SLUG}}.causas(id),
  trilha text not null check (trilha in ('chamado','ideia')),
  relato text not null,
  midia jsonb not null default '[]',
  local_texto text,
  setor_id int references {{SLUG}}.setores(id),
  tema text,
  competencia text,
  urgencia text,
  instrumento_sugerido text,
  triagem jsonb,
  embedding vector(1536),
  status text not null default 'recebida' check (status in
    ('recebida','triada','em_causa','aguardando_info','arquivada')),
  criada_em timestamptz not null default now()
);
create index if not exists demandas_causa_idx on {{SLUG}}.demandas (causa_id);
create index if not exists demandas_cidadao_idx on {{SLUG}}.demandas (cidadao_id);

create table if not exists {{SLUG}}.apoios (
  causa_id bigint not null references {{SLUG}}.causas(id),
  cidadao_id bigint not null references {{SLUG}}.cidadaos(id),
  criado_em timestamptz not null default now(),
  primary key (causa_id, cidadao_id)
);

create table if not exists {{SLUG}}.conselho_votos (
  id bigserial primary key,
  causa_id bigint not null references {{SLUG}}.causas(id),
  usuario_id uuid not null references {{SLUG}}.usuarios(id),
  voto text not null check (voto in ('aprova','rejeita','devolve')),
  justificativa text,
  criado_em timestamptz not null default now(),
  unique (causa_id, usuario_id)
);

create table if not exists {{SLUG}}.acoes_mandato (
  id bigserial primary key,
  causa_id bigint not null references {{SLUG}}.causas(id),
  tipo text not null check (tipo in
    ('indicacao','emenda','projeto_lei','requerimento',
     'audiencia','oficio','encaminhamento')),
  orgao_destino text,
  numero_oficial text,
  descricao text,
  status text not null default 'decidida' check (status in
    ('decidida','protocolada','em_execucao','concluida','negada')),
  decidida_por uuid references {{SLUG}}.usuarios(id),
  criada_em timestamptz not null default now()
);

create table if not exists {{SLUG}}.eventos (
  id bigserial primary key,
  entidade text not null,
  entidade_id bigint not null,
  tipo text not null,
  ator_tipo text not null,
  ator_id text,
  payload jsonb,
  criado_em timestamptz not null default now()
);
create index if not exists eventos_entidade_idx on {{SLUG}}.eventos (entidade, entidade_id);

create table if not exists {{SLUG}}.notificacoes (
  id bigserial primary key,
  cidadao_id bigint not null references {{SLUG}}.cidadaos(id),
  demanda_id bigint,
  causa_id bigint,
  mensagem text not null,
  status text not null default 'pendente'
    check (status in ('pendente','enviada','falhou')),
  tentativas int not null default 0,
  criada_em timestamptz not null default now(),
  enviada_em timestamptz
);
