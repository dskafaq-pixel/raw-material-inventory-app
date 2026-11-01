-- Per-record inventory tables with a zero-loss compatibility snapshot.
-- Existing inventory_state rows remain intact and are updated atomically with
-- the per-record tables by save_inventory_state. Do not drop inventory_state.

begin;

-- Preserve the exact pre-migration payload and version before creating mirrors.
create table if not exists public.inventory_state_archive (
    archive_id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null,
    version bigint not null,
    archived_at timestamptz not null default now(),
    archive_tag text not null,
    payload jsonb not null,
    unique (workspace_id, version, archive_tag)
);
alter table public.inventory_state_archive enable row level security;
revoke all on public.inventory_state_archive from public, anon, authenticated;
insert into public.inventory_state_archive(workspace_id,version,archive_tag,payload)
select workspace_id,version,'before_inventory_records_v1',payload
from public.inventory_state
on conflict (workspace_id,version,archive_tag) do nothing;

create table if not exists public.inventory_company_settings (
    workspace_id uuid primary key references public.inventory_workspaces(workspace_id) on delete cascade,
    settings jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now()
);

create table if not exists public.inventory_items (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_id text not null,
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_categories (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_id text not null,
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_uoms (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_id text not null,
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_vendors (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_id text not null,
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_grn_vouchers (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_id text not null,
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_issue_vouchers (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_id text not null,
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_adjustment_vouchers (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_id text not null,
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_voucher_lines (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    voucher_type text not null check (voucher_type in ('GRN','ISSUE')),
    voucher_id text not null,
    line_index integer not null check (line_index > 0),
    line_data jsonb not null,
    primary key (workspace_id,voucher_type,voucher_id,line_index)
);
create table if not exists public.inventory_audit_log (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_trash_bin (
    workspace_id uuid not null references public.inventory_workspaces(workspace_id) on delete cascade,
    row_index integer not null check (row_index > 0),
    record_data jsonb not null,
    primary key (workspace_id,row_index)
);
create table if not exists public.inventory_record_sync_state (
    workspace_id uuid primary key references public.inventory_workspaces(workspace_id) on delete cascade,
    version bigint not null,
    updated_at timestamptz not null default now()
);

-- All public tables are RLS protected. Clients read their company rows;
-- writes go through the authenticated, version-checked save RPC below.
do $tables$
declare t text;
begin
    foreach t in array array[
        'inventory_company_settings','inventory_items','inventory_categories','inventory_uoms',
        'inventory_vendors','inventory_grn_vouchers','inventory_issue_vouchers',
        'inventory_adjustment_vouchers','inventory_voucher_lines','inventory_audit_log',
        'inventory_trash_bin','inventory_record_sync_state'
    ] loop
        execute format('alter table public.%I enable row level security',t);
        execute format('revoke all on public.%I from public, anon',t);
        execute format('grant select on public.%I to authenticated',t);
        execute format('drop policy if exists %I on public.%I',t||'_member_read',t);
        execute format('create policy %I on public.%I for select to authenticated using (public.is_inventory_member(workspace_id))',t||'_member_read',t);
    end loop;
end
$tables$;

create schema if not exists private;
revoke all on schema private from public,anon,authenticated;

create or replace function private.sync_inventory_record_tables(
    p_workspace_id uuid,p_payload jsonb,p_version bigint
) returns void language plpgsql set search_path = '' as $$
begin
    insert into public.inventory_company_settings(workspace_id,settings,updated_at)
    values(p_workspace_id,coalesce(p_payload->'companyConfig','{}'::jsonb),now())
    on conflict(workspace_id) do update set settings=excluded.settings,updated_at=excluded.updated_at;

    delete from public.inventory_items where workspace_id=p_workspace_id;
    insert into public.inventory_items(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbItems') with ordinality x(data,ord);

    delete from public.inventory_categories where workspace_id=p_workspace_id;
    insert into public.inventory_categories(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbCategories') with ordinality x(data,ord);

    delete from public.inventory_uoms where workspace_id=p_workspace_id;
    insert into public.inventory_uoms(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbUoms') with ordinality x(data,ord);

    delete from public.inventory_vendors where workspace_id=p_workspace_id;
    insert into public.inventory_vendors(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVendors') with ordinality x(data,ord);

    delete from public.inventory_grn_vouchers where workspace_id=p_workspace_id;
    insert into public.inventory_grn_vouchers(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'no'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVouchersGrn') with ordinality x(data,ord);

    delete from public.inventory_issue_vouchers where workspace_id=p_workspace_id;
    insert into public.inventory_issue_vouchers(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'no'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVouchersIssue') with ordinality x(data,ord);

    delete from public.inventory_adjustment_vouchers where workspace_id=p_workspace_id;
    insert into public.inventory_adjustment_vouchers(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'no'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVouchersAdj') with ordinality x(data,ord);

    delete from public.inventory_voucher_lines where workspace_id=p_workspace_id;
    insert into public.inventory_voucher_lines(workspace_id,voucher_type,voucher_id,line_index,line_data)
    select p_workspace_id,'GRN',v.data->>'id',li.ord::integer,li.data
    from jsonb_array_elements(p_payload->'dbVouchersGrn') v(data)
    cross join lateral jsonb_array_elements(coalesce(v.data->'items','[]'::jsonb)) with ordinality li(data,ord)
    where nullif(v.data->>'id','') is not null;
    insert into public.inventory_voucher_lines(workspace_id,voucher_type,voucher_id,line_index,line_data)
    select p_workspace_id,'ISSUE',v.data->>'id',li.ord::integer,li.data
    from jsonb_array_elements(p_payload->'dbVouchersIssue') v(data)
    cross join lateral jsonb_array_elements(coalesce(v.data->'items','[]'::jsonb)) with ordinality li(data,ord)
    where nullif(v.data->>'id','') is not null;

    delete from public.inventory_audit_log where workspace_id=p_workspace_id;
    insert into public.inventory_audit_log(workspace_id,row_index,record_data)
    select p_workspace_id,x.ord::integer,x.data
    from jsonb_array_elements(p_payload->'dbWorkingLog') with ordinality x(data,ord);

    delete from public.inventory_trash_bin where workspace_id=p_workspace_id;
    insert into public.inventory_trash_bin(workspace_id,row_index,record_data)
    select p_workspace_id,x.ord::integer,x.data
    from jsonb_array_elements(p_payload->'dbTrashBin') with ordinality x(data,ord);

    insert into public.inventory_record_sync_state(workspace_id,version,updated_at)
    values(p_workspace_id,p_version,now())
    on conflict(workspace_id) do update set version=excluded.version,updated_at=excluded.updated_at;
end;
$$;
revoke all on function private.sync_inventory_record_tables(uuid,jsonb,bigint) from public,anon,authenticated;

-- Backfill every current workspace from the existing, untouched JSONB state.
do $backfill$
declare r record;
begin
    for r in select workspace_id,version,payload from public.inventory_state loop
        if jsonb_typeof(r.payload->'dbItems') <> 'array'
           or jsonb_typeof(r.payload->'dbCategories') <> 'array'
           or jsonb_typeof(r.payload->'dbUoms') <> 'array'
           or jsonb_typeof(r.payload->'dbVendors') <> 'array'
           or jsonb_typeof(r.payload->'dbVouchersGrn') <> 'array'
           or jsonb_typeof(r.payload->'dbVouchersIssue') <> 'array'
           or jsonb_typeof(r.payload->'dbVouchersAdj') <> 'array'
           or jsonb_typeof(r.payload->'dbWorkingLog') <> 'array'
           or jsonb_typeof(r.payload->'dbTrashBin') <> 'array' then
            raise exception 'Workspace % has an incomplete inventory payload; migration stopped without changing its source state',r.workspace_id;
        end if;
        perform private.sync_inventory_record_tables(r.workspace_id,r.payload,r.version);
    end loop;
end
$backfill$;

-- Keep the existing versioned JSON payload as a rollback/concurrency journal,
-- but commit its update and every individual record row in one transaction.
create or replace function public.save_inventory_state(
    p_workspace_id uuid,p_expected_version bigint,p_payload jsonb,p_client_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_state public.inventory_state%rowtype;
begin
    if (select auth.uid()) is null then
        raise exception using errcode='42501',message='Authentication required';
    end if;
    if not public.is_inventory_writer(p_workspace_id) then
        raise exception using errcode='42501',message='Not an authorized inventory writer for this workspace';
    end if;
    if jsonb_typeof(p_payload)<>'object'
       or jsonb_typeof(p_payload->'dbItems')<>'array'
       or jsonb_typeof(p_payload->'dbCategories')<>'array'
       or jsonb_typeof(p_payload->'dbUoms')<>'array'
       or jsonb_typeof(p_payload->'dbVendors')<>'array'
       or jsonb_typeof(p_payload->'dbVouchersGrn')<>'array'
       or jsonb_typeof(p_payload->'dbVouchersIssue')<>'array'
       or jsonb_typeof(p_payload->'dbVouchersAdj')<>'array'
       or jsonb_typeof(p_payload->'dbWorkingLog')<>'array'
       or jsonb_typeof(p_payload->'dbTrashBin')<>'array' then
        raise exception using errcode='22023',message='Invalid inventory payload';
    end if;

    if p_expected_version=0 then
        insert into public.inventory_state(workspace_id,version,updated_at,updated_by,client_id,payload)
        values(p_workspace_id,1,now(),(select auth.uid()),p_client_id,p_payload)
        on conflict(workspace_id) do nothing returning * into v_state;
        if found then
            perform private.sync_inventory_record_tables(p_workspace_id,p_payload,v_state.version);
            return jsonb_build_object('workspace_id',v_state.workspace_id,'version',v_state.version,
                'updated_at',v_state.updated_at,'payload',v_state.payload,'client_id',v_state.client_id);
        end if;
    end if;

    select * into v_state from public.inventory_state where workspace_id=p_workspace_id for update;
    if not found or v_state.version<>p_expected_version then
        raise exception using errcode='40001',message='inventory_version_conflict';
    end if;
    update public.inventory_state set version=v_state.version+1,updated_at=now(),
        updated_by=(select auth.uid()),client_id=p_client_id,payload=p_payload
    where workspace_id=p_workspace_id returning * into v_state;
    perform private.sync_inventory_record_tables(p_workspace_id,p_payload,v_state.version);
    return jsonb_build_object('workspace_id',v_state.workspace_id,'version',v_state.version,
        'updated_at',v_state.updated_at,'payload',v_state.payload,'client_id',v_state.client_id);
end;
$$;
revoke all on function public.save_inventory_state(uuid,bigint,jsonb,uuid) from public,anon;
grant execute on function public.save_inventory_state(uuid,bigint,jsonb,uuid) to authenticated;

-- New companies receive their first normalized rows in the same transaction.
create or replace function public.create_inventory_workspace(
    p_name text,p_payload jsonb,p_client_id uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid:=gen_random_uuid(); v_user uuid:=(select auth.uid());
begin
    if v_user is null or not exists(select 1 from public.inventory_members m where m.user_id=v_user and m.role='admin') then
        raise exception using errcode='42501',message='Only a company administrator can add companies';
    end if;
    if p_name is null or length(trim(p_name)) not between 2 and 120 then
        raise exception using errcode='22023',message='Company name must be 2 to 120 characters';
    end if;
    if jsonb_typeof(p_payload)<>'object'
       or jsonb_typeof(p_payload->'dbItems')<>'array'
       or jsonb_typeof(p_payload->'dbCategories')<>'array'
       or jsonb_typeof(p_payload->'dbUoms')<>'array'
       or jsonb_typeof(p_payload->'dbVendors')<>'array'
       or jsonb_typeof(p_payload->'dbVouchersGrn')<>'array'
       or jsonb_typeof(p_payload->'dbVouchersIssue')<>'array'
       or jsonb_typeof(p_payload->'dbVouchersAdj')<>'array'
       or jsonb_typeof(p_payload->'dbWorkingLog')<>'array'
       or jsonb_typeof(p_payload->'dbTrashBin')<>'array' then
        raise exception using errcode='22023',message='Invalid initial company data';
    end if;
    insert into public.inventory_workspaces(workspace_id,name,created_by) values(v_id,trim(p_name),v_user);
    insert into public.inventory_members(workspace_id,user_id,role)
        select v_id,m.user_id,case when m.user_id=v_user then 'admin'
            when lower(u.email)=lower('operator@inv.com') then 'operator' else 'viewer' end
        from public.inventory_members m join auth.users u on u.id=m.user_id
        where m.workspace_id='20a727a3-8091-4a08-b1e6-5bff1a773ecc'::uuid
        on conflict(workspace_id,user_id) do update set role=excluded.role;
    insert into public.inventory_members(workspace_id,user_id,role)
        values(v_id,v_user,'admin') on conflict(workspace_id,user_id) do update set role='admin';
    insert into public.inventory_state(workspace_id,version,updated_at,updated_by,client_id,payload)
        values(v_id,1,now(),v_user,p_client_id,p_payload);
    perform private.sync_inventory_record_tables(v_id,p_payload,1);
    return v_id;
end;
$$;
revoke all on function public.create_inventory_workspace(text,jsonb,uuid) from public,anon;
grant execute on function public.create_inventory_workspace(text,jsonb,uuid) to authenticated;

commit;
notify pgrst,'reload schema';

