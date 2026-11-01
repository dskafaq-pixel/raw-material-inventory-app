-- Reduce inventory write amplification and index the membership lookup paths.
-- This migration does not alter record values or remove any records.

begin;

create index if not exists inventory_members_user_id_workspace_id_idx
    on public.inventory_members(user_id,workspace_id);
create index if not exists inventory_backups_workspace_id_idx
    on public.inventory_backups(workspace_id);
create index if not exists inventory_state_updated_by_idx
    on public.inventory_state(updated_by);
create index if not exists inventory_workspaces_created_by_idx
    on public.inventory_workspaces(created_by);

create or replace function private.sync_inventory_record_tables(
    p_workspace_id uuid,p_payload jsonb,p_version bigint
) returns void language plpgsql set search_path = '' as $$
begin
    insert into public.inventory_company_settings(workspace_id,settings,updated_at)
    values(p_workspace_id,coalesce(p_payload->'companyConfig','{}'::jsonb),now())
    on conflict(workspace_id) do update set settings=excluded.settings,updated_at=excluded.updated_at
    where public.inventory_company_settings.settings is distinct from excluded.settings;

    insert into public.inventory_items(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbItems') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_id=excluded.record_id,record_data=excluded.record_data
    where public.inventory_items.record_id is distinct from excluded.record_id or public.inventory_items.record_data is distinct from excluded.record_data;
    delete from public.inventory_items where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbItems');

    insert into public.inventory_categories(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbCategories') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_id=excluded.record_id,record_data=excluded.record_data
    where public.inventory_categories.record_id is distinct from excluded.record_id or public.inventory_categories.record_data is distinct from excluded.record_data;
    delete from public.inventory_categories where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbCategories');

    insert into public.inventory_uoms(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbUoms') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_id=excluded.record_id,record_data=excluded.record_data
    where public.inventory_uoms.record_id is distinct from excluded.record_id or public.inventory_uoms.record_data is distinct from excluded.record_data;
    delete from public.inventory_uoms where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbUoms');

    insert into public.inventory_vendors(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'code'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVendors') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_id=excluded.record_id,record_data=excluded.record_data
    where public.inventory_vendors.record_id is distinct from excluded.record_id or public.inventory_vendors.record_data is distinct from excluded.record_data;
    delete from public.inventory_vendors where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbVendors');

    insert into public.inventory_grn_vouchers(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'no'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVouchersGrn') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_id=excluded.record_id,record_data=excluded.record_data
    where public.inventory_grn_vouchers.record_id is distinct from excluded.record_id or public.inventory_grn_vouchers.record_data is distinct from excluded.record_data;
    delete from public.inventory_grn_vouchers where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbVouchersGrn');

    insert into public.inventory_issue_vouchers(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'no'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVouchersIssue') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_id=excluded.record_id,record_data=excluded.record_data
    where public.inventory_issue_vouchers.record_id is distinct from excluded.record_id or public.inventory_issue_vouchers.record_data is distinct from excluded.record_data;
    delete from public.inventory_issue_vouchers where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbVouchersIssue');

    insert into public.inventory_adjustment_vouchers(workspace_id,row_index,record_id,record_data)
    select p_workspace_id,x.ord::integer,coalesce(nullif(btrim(x.data->>'id'),''),nullif(btrim(x.data->>'no'),''),'row-'||x.ord),x.data
    from jsonb_array_elements(p_payload->'dbVouchersAdj') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_id=excluded.record_id,record_data=excluded.record_data
    where public.inventory_adjustment_vouchers.record_id is distinct from excluded.record_id or public.inventory_adjustment_vouchers.record_data is distinct from excluded.record_data;
    delete from public.inventory_adjustment_vouchers where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbVouchersAdj');

    insert into public.inventory_voucher_lines(workspace_id,voucher_type,voucher_id,line_index,line_data)
    select p_workspace_id,'GRN',v.data->>'id',li.ord::integer,li.data
    from jsonb_array_elements(p_payload->'dbVouchersGrn') v(data)
    cross join lateral jsonb_array_elements(coalesce(v.data->'items','[]'::jsonb)) with ordinality li(data,ord)
    where nullif(v.data->>'id','') is not null
    on conflict(workspace_id,voucher_type,voucher_id,line_index) do update set line_data=excluded.line_data
    where public.inventory_voucher_lines.line_data is distinct from excluded.line_data;
    insert into public.inventory_voucher_lines(workspace_id,voucher_type,voucher_id,line_index,line_data)
    select p_workspace_id,'ISSUE',v.data->>'id',li.ord::integer,li.data
    from jsonb_array_elements(p_payload->'dbVouchersIssue') v(data)
    cross join lateral jsonb_array_elements(coalesce(v.data->'items','[]'::jsonb)) with ordinality li(data,ord)
    where nullif(v.data->>'id','') is not null
    on conflict(workspace_id,voucher_type,voucher_id,line_index) do update set line_data=excluded.line_data
    where public.inventory_voucher_lines.line_data is distinct from excluded.line_data;
    delete from public.inventory_voucher_lines l
    where l.workspace_id=p_workspace_id and (
        (l.voucher_type='GRN' and not exists (
            select 1 from jsonb_array_elements(p_payload->'dbVouchersGrn') v(data)
            cross join lateral jsonb_array_elements(coalesce(v.data->'items','[]'::jsonb)) with ordinality li(data,ord)
            where v.data->>'id'=l.voucher_id and li.ord=l.line_index
        )) or
        (l.voucher_type='ISSUE' and not exists (
            select 1 from jsonb_array_elements(p_payload->'dbVouchersIssue') v(data)
            cross join lateral jsonb_array_elements(coalesce(v.data->'items','[]'::jsonb)) with ordinality li(data,ord)
            where v.data->>'id'=l.voucher_id and li.ord=l.line_index
        ))
    );

    insert into public.inventory_audit_log(workspace_id,row_index,record_data)
    select p_workspace_id,x.ord::integer,x.data
    from jsonb_array_elements(p_payload->'dbWorkingLog') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_data=excluded.record_data
    where public.inventory_audit_log.record_data is distinct from excluded.record_data;
    delete from public.inventory_audit_log where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbWorkingLog');

    insert into public.inventory_trash_bin(workspace_id,row_index,record_data)
    select p_workspace_id,x.ord::integer,x.data
    from jsonb_array_elements(p_payload->'dbTrashBin') with ordinality x(data,ord)
    on conflict(workspace_id,row_index) do update set record_data=excluded.record_data
    where public.inventory_trash_bin.record_data is distinct from excluded.record_data;
    delete from public.inventory_trash_bin where workspace_id=p_workspace_id and row_index>jsonb_array_length(p_payload->'dbTrashBin');

    insert into public.inventory_record_sync_state(workspace_id,version,updated_at)
    values(p_workspace_id,p_version,now())
    on conflict(workspace_id) do update set version=excluded.version,updated_at=excluded.updated_at;
end;
$$;

commit;

